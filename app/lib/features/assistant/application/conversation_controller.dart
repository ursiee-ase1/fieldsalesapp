import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/errors.dart';
import '../data/assistant_repository.dart';
import '../data/voice.dart';

enum ConversationPhase { starting, idle, listening, recording, thinking, speaking, finished }

class ChatLine {
  const ChatLine({required this.fromAgent, required this.text});
  final bool fromAgent;
  final String text;
}

/// Drives one reporting conversation. Text and voice share everything here;
/// only how words get in and out differs.
class ConversationController extends ChangeNotifier {
  ConversationController({
    required this._api,
    required this._voice,
    required this.voiceMode,
    required this._language,
  });

  final AssistantApi _api;
  final VoiceIO _voice;
  bool voiceMode;
  AssistantLanguage _language;

  ConversationPhase phase = ConversationPhase.starting;
  final List<ChatLine> lines = [];
  String partial = '';

  /// Gentle guidance shown by the microphone, e.g. when nothing was heard.
  String? hint;
  List<String>? summary;
  List<String> notices = const [];
  String? error;
  bool needsConnection = false;
  bool submitted = false;
  bool twiVoiceEnabled = false;

  String? _sessionId;
  int _version = 0;
  bool _disposed = false;

  AssistantLanguage get language => _language;

  /// Twi speech only works when the company has switched it on.
  bool get canUseVoice => _language == AssistantLanguage.en || twiVoiceEnabled;

  bool get busy => phase == ConversationPhase.thinking || phase == ConversationPhase.starting;

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  Future<void> start() async {
    _set(() {
      phase = ConversationPhase.starting;
      error = null;
      needsConnection = false;
    });
    await _run(() => _api.start(voice: voiceMode, language: _language), isStart: true);
  }

  Future<void> setLanguage(AssistantLanguage value) async {
    if (value == _language) return;
    await _voice.stopOutput();
    _set(() => _language = value);
    if (voiceMode && !canUseVoice) _fallBackToTyping();
  }

  Future<void> sendText(String text) async {
    final t = text.trim();
    if (t.isEmpty || busy || _sessionId == null) return;
    await _voice.stopOutput();
    _set(() => lines.add(ChatLine(fromAgent: true, text: t)));
    await _run(() => _api.sendText(_sessionId!, _version, t, language: _language, voiceOut: voiceMode));
  }

  /// The single microphone button: talk, stop and send, or interrupt.
  Future<void> tapMic() async {
    switch (phase) {
      case ConversationPhase.speaking:
        await _voice.stopOutput(); // interrupt the assistant
        await _listen();
      case ConversationPhase.listening:
        if (partial.trim().isEmpty) {
          // Listening already started by itself after the question. A tap now
          // usually means "I want to talk", so keep listening.
          _set(() => hint = "I'm listening. Go ahead and speak, then tap when you finish.");
          return;
        }
        await _voice.stopInput(); // English: the final words are sent by _listen
      case ConversationPhase.recording:
        await _sendRecording();
      case ConversationPhase.idle:
        await _listen();
      default:
        break;
    }
  }

  Future<void> confirm() async {
    if (busy || _sessionId == null) return;
    await _voice.stopOutput();
    await _run(() => _api.confirm(_sessionId!, _version, language: _language, voiceOut: voiceMode));
  }

  /// "Finish report": go to the summary now (or answer the one essential
  /// question still open).
  Future<void> finish() async {
    if (busy || _sessionId == null) return;
    await _voice.stopOutput();
    await _voice.stopInput();
    _set(() => hint = null);
    await _run(() => _api.finish(_sessionId!, _version, language: _language, voiceOut: voiceMode));
  }

  /// Whether "Finish report" makes sense right now.
  bool get canFinish => _sessionId != null && summary == null && !submitted && phase != ConversationPhase.finished;

  /// Back to answering questions after seeing the summary.
  Future<void> makeChanges() async {
    await _voice.stopOutput();
    _set(() => summary = null);
    if (voiceMode) await _listen();
  }

  Future<void> discard() async {
    await _stopEverything();
    final id = _sessionId;
    if (id != null) {
      try {
        await _api.discard(id);
      } catch (_) {
        // Nothing to save; an open session simply expires with the day.
      }
    }
  }

  void switchToTyping() => _fallBackToTyping(notice: false);

  void switchToVoice() {
    if (!canUseVoice) return;
    _set(() => voiceMode = true);
  }

  void _fallBackToTyping({bool notice = true}) {
    _voice.stopOutput();
    _voice.stopInput();
    _set(() {
      voiceMode = false;
      if (phase != ConversationPhase.finished) phase = ConversationPhase.idle;
      if (notice) notices = ["Twi voice isn't switched on for your company yet. You can type in Twi, or speak in English."];
    });
  }

  Future<void> _listen() async {
    if (!voiceMode || submitted) return;
    if (!canUseVoice) return _fallBackToTyping();
    if (_language == AssistantLanguage.tw) {
      final ok = await _voice.startRecording();
      if (!ok) return _micDenied();
      _set(() => phase = ConversationPhase.recording);
      return;
    }
    _set(() {
      phase = ConversationPhase.listening;
      partial = '';
      hint = null;
      error = null;
    });
    String heard;
    try {
      heard = await _voice.listenEnglish(onPartial: (p) => _set(() => partial = p));
    } on VoiceUnavailable catch (e) {
      _set(() {
        error = e.message;
        partial = '';
        phase = ConversationPhase.idle; // tap to try again, or "Type instead"
      });
      if (e.message.startsWith('Speech recognition is not available')) _fallBackToTyping(notice: false);
      return;
    }
    _set(() {
      partial = '';
      phase = ConversationPhase.idle;
      if (heard.trim().isEmpty) {
        final why = _voice.lastEndReason;
        hint = "I didn't hear anything. Tap the microphone and speak, or type instead."
            '${why == null ? '' : ' (browser said: $why)'}';
      }
    });
    if (heard.trim().isNotEmpty) await sendText(heard);
  }

  void _micDenied() {
    _set(() => error = 'Microphone permission is needed for voice. You can type instead.');
    _fallBackToTyping(notice: false);
  }

  Future<void> _sendRecording() async {
    final wav = await _voice.stopInput();
    if (wav == null || wav.length < 3200) {
      // Under ~0.1 s of audio: nothing to send.
      _set(() {
        phase = ConversationPhase.idle;
        hint = "I didn't hear anything. Tap the microphone, speak, then tap again to send.";
      });
      return;
    }
    _set(() => hint = null);
    _set(() => lines.add(const ChatLine(fromAgent: true, text: '🎤 …')));
    await _run(() => _api.sendAudio(_sessionId!, _version, wav, language: _language));
  }

  Future<void> _run(Future<AssistantReply> Function() call, {bool isStart = false}) async {
    _set(() {
      phase = ConversationPhase.thinking;
      error = null;
      needsConnection = false;
    });
    AssistantReply reply;
    try {
      reply = await call();
    } catch (e) {
      final message = describeError(e);
      _set(() {
        // Drop the placeholder for a recording that never reached the server.
        if (lines.isNotEmpty && lines.last.fromAgent && lines.last.text == '🎤 …') lines.removeLast();
        error = message;
        needsConnection = message.startsWith("Couldn't reach the server");
        phase = isStart ? ConversationPhase.finished : ConversationPhase.idle;
      });
      return;
    }

    _set(() {
      _sessionId = reply.sessionId;
      _version = reply.draftVersion;
      twiVoiceEnabled = reply.twiVoiceEnabled;
      if (isStart) {
        lines
          ..clear()
          ..addAll(reply.history.map((h) => ChatLine(fromAgent: h.fromAgent, text: h.text)));
      }
      // Show what the recogniser heard in place of the recording placeholder.
      if (reply.agentText != null && lines.isNotEmpty && lines.last.text == '🎤 …') {
        lines[lines.length - 1] = ChatLine(fromAgent: true, text: reply.agentText!);
      }
      lines.add(ChatLine(fromAgent: false, text: reply.replyText));
      summary = reply.awaitingConfirmation ? reply.summary : null;
      notices = reply.notices;
      submitted = reply.submitted;
      phase = submitted || reply.action == 'pause' ? ConversationPhase.finished : ConversationPhase.idle;
    });

    if (voiceMode) {
      await _speak(reply);
      if (!submitted && reply.action != 'pause' && phase == ConversationPhase.idle) await _listen();
    }
    if (isStart && voiceMode && !canUseVoice) _fallBackToTyping();
  }

  Future<void> _speak(AssistantReply reply) async {
    final wasFinished = phase == ConversationPhase.finished;
    _set(() => phase = ConversationPhase.speaking);
    try {
      if (reply.replyAudio != null) {
        await _voice.playWav(reply.replyAudio!);
      } else if (_language == AssistantLanguage.en || reply.notices.isNotEmpty) {
        await _voice.speakEnglish(reply.replyText);
      }
    } catch (_) {
      // Speech output is a convenience: the text is always on screen.
    }
    // Interrupted (tapMic) moves the phase on; only reset if still speaking.
    if (phase == ConversationPhase.speaking) _set(() => phase = wasFinished ? ConversationPhase.finished : ConversationPhase.idle);
  }

  Future<void> _stopEverything() async {
    await _voice.stopOutput();
    await _voice.stopInput();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopEverything();
    super.dispose();
  }
}
