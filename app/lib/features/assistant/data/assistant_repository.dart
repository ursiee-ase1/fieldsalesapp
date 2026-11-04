import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AssistantLanguage {
  en('English'),
  tw('Twi');

  const AssistantLanguage(this.label);
  final String label;

  static AssistantLanguage parse(String? v) => v == 'tw' ? tw : en;
}

class HistoryLine {
  const HistoryLine(this.fromAgent, this.text);
  final bool fromAgent;
  final String text;
}

/// One response from the assistant Edge Function.
class AssistantReply {
  const AssistantReply({
    required this.sessionId,
    required this.draftVersion,
    required this.status,
    required this.action,
    required this.replyText,
    required this.notices,
    required this.twiVoiceEnabled,
    this.agentText,
    this.replyAudio,
    this.summary,
    this.history = const [],
  });

  factory AssistantReply.fromJson(Map<String, dynamic> j) => AssistantReply(
        sessionId: j['session_id'] as String,
        draftVersion: j['draft_version'] as int,
        status: j['status'] as String,
        action: j['action'] as String,
        agentText: j['agent_text'] as String?,
        replyText: j['reply_text'] as String,
        replyAudio: j['reply_audio_wav_b64'] == null ? null : base64Decode(j['reply_audio_wav_b64'] as String),
        summary: (j['summary'] as List?)?.cast<String>(),
        notices: (j['notices'] as List? ?? const []).cast<String>(),
        twiVoiceEnabled: j['twi_voice_enabled'] as bool? ?? false,
        history: [
          for (final h in (j['history'] as List? ?? const []))
            HistoryLine((h as Map)['role'] == 'agent', h['text'] as String),
        ],
      );

  final String sessionId;
  final int draftVersion;

  /// active | awaiting_confirmation | submitted | abandoned
  final String status;

  /// ask | summary | submitted | pause | not_understood | abandoned
  final String action;
  final String? agentText;
  final String replyText;
  final Uint8List? replyAudio;
  final List<String>? summary;
  final List<String> notices;
  final bool twiVoiceEnabled;
  final List<HistoryLine> history;

  bool get awaitingConfirmation => status == 'awaiting_confirmation';
  bool get submitted => status == 'submitted';
}

abstract interface class AssistantApi {
  Future<AssistantReply> start({required bool voice, required AssistantLanguage language});
  Future<AssistantReply> sendText(String sessionId, int version, String text,
      {required AssistantLanguage language, required bool voiceOut});
  Future<AssistantReply> sendAudio(String sessionId, int version, Uint8List wav,
      {required AssistantLanguage language});
  Future<AssistantReply> confirm(String sessionId, int version, {required AssistantLanguage language, required bool voiceOut});
  Future<void> discard(String sessionId);
}

final assistantApiProvider = Provider<AssistantApi>((ref) => SupabaseAssistantApi(Supabase.instance.client));

/// All AI and speech-provider calls go through the server; the app holds no provider keys.
class SupabaseAssistantApi implements AssistantApi {
  SupabaseAssistantApi(this._client);

  final SupabaseClient _client;

  Future<AssistantReply> _call(Map<String, dynamic> body) async {
    final res = await _client.functions.invoke('assistant', body: body);
    return AssistantReply.fromJson(Map<String, dynamic>.from(res.data as Map));
  }

  @override
  Future<AssistantReply> start({required bool voice, required AssistantLanguage language}) => _call({
        'action': 'start',
        'channel': voice ? 'app_voice' : 'app_text',
        'language': language.name,
        'voice_out': voice,
      });

  @override
  Future<AssistantReply> sendText(String sessionId, int version, String text,
          {required AssistantLanguage language, required bool voiceOut}) =>
      _call({
        'action': 'turn',
        'session_id': sessionId,
        'draft_version': version,
        'language': language.name,
        'text': text,
        'voice_out': voiceOut,
      });

  @override
  Future<AssistantReply> sendAudio(String sessionId, int version, Uint8List wav, {required AssistantLanguage language}) =>
      _call({
        'action': 'turn',
        'session_id': sessionId,
        'draft_version': version,
        'language': language.name,
        'audio_wav_b64': base64Encode(wav),
        'voice_out': true,
      });

  @override
  Future<AssistantReply> confirm(String sessionId, int version,
          {required AssistantLanguage language, required bool voiceOut}) =>
      _call({
        'action': 'confirm',
        'session_id': sessionId,
        'draft_version': version,
        'language': language.name,
        'voice_out': voiceOut,
      });

  @override
  Future<void> discard(String sessionId) => _call({'action': 'abandon', 'session_id': sessionId});
}
