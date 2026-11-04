import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech in and out, behind interfaces so providers can change without
/// touching the conversation logic.
///
/// English uses the phone's own speech recognition and voice (free, fast).
/// Twi is recorded here and recognised/synthesised on the server (Khaya).
abstract interface class VoiceIO {
  /// English speech recognition on the device. Resolves with the final text
  /// (empty if nothing was heard).
  Future<String> listenEnglish({required void Function(String partial) onPartial});

  /// Starts recording audio for server-side (Twi) recognition.
  Future<bool> startRecording();

  /// Stops listening or recording. Returns the WAV recording, if any.
  Future<Uint8List?> stopInput();

  Future<void> speakEnglish(String text);
  Future<void> playWav(Uint8List wav);

  /// Interrupts whatever is being spoken.
  Future<void> stopOutput();

  /// Why the last English listen ended (recogniser status or error code),
  /// shown when nothing was heard so problems can be diagnosed.
  String? get lastEndReason;
}

final voiceProvider = Provider<VoiceIO>((ref) {
  final voice = DeviceVoiceIO();
  ref.onDispose(voice.dispose);
  return voice;
});

class DeviceVoiceIO implements VoiceIO {
  final _stt = SpeechToText();
  final _tts = FlutterTts();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool? _sttReady;
  StreamSubscription<Uint8List>? _recording;
  BytesBuilder? _pcm;
  Completer<String>? _listening;

  static const _sampleRate = 16000;

  Future<bool> _ensureStt() async =>
      _sttReady ??= await _stt.initialize(onError: _onSttError, onStatus: _onSttStatus);

  String _lastWords = '';

  /// Only end a listen after this listen actually started: browsers can
  /// report a stale "not listening" from before, which used to end the new
  /// listen instantly with no words.
  bool _sawListening = false;

  @override
  String? lastEndReason;

  Timer? _grace;

  void _onSttStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      _sawListening = true;
    } else if ((status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) && _sawListening) {
      lastEndReason ??= status;
      _finishSoon();
    }
  }

  void _onSttError(SpeechRecognitionError e) {
    final c = _listening;
    if (c == null || c.isCompleted) return;
    lastEndReason = e.errorMsg;
    final problem = describeSpeechError(e.errorMsg);
    if (problem == null) {
      _finishSoon(); // "no speech" etc.: just nothing heard
    } else {
      _grace?.cancel();
      c.completeError(VoiceUnavailable(problem));
    }
  }

  /// Chrome sends the final words shortly *after* signalling that listening
  /// stopped, so wait briefly for them instead of ending with nothing.
  void _finishSoon() {
    if (_listening == null || _listening!.isCompleted || (_grace?.isActive ?? false)) return;
    _grace = Timer(const Duration(milliseconds: 1200), _finishListening);
  }

  void _finishListening() {
    _grace?.cancel();
    final c = _listening;
    if (c != null && !c.isCompleted) c.complete(_lastWords);
  }

  @override
  Future<String> listenEnglish({required void Function(String partial) onPartial}) async {
    if (!await _ensureStt()) {
      throw const VoiceUnavailable(
          'Speech recognition is not available here. On a computer, use Chrome or Edge. You can also type.');
    }
    _lastWords = '';
    _sawListening = false;
    lastEndReason = null;
    _grace?.cancel();
    final done = _listening = Completer<String>();
    try {
      await _stt.listen(
        onResult: (r) {
          _lastWords = r.recognizedWords;
          onPartial(_lastWords);
          if (r.finalResult) _finishListening();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(seconds: 60),
          pauseFor: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      throw VoiceUnavailable('Could not start the microphone ($e). You can type instead.');
    }
    // If the recogniser never starts (e.g. a blocked permission prompt), say so.
    return done.future.timeout(const Duration(seconds: 75), onTimeout: () async {
      await _stt.stop();
      return _lastWords;
    });
  }

  @override
  Future<bool> startRecording() async {
    if (!await _recorder.hasPermission()) return false;
    _pcm = BytesBuilder(copy: false);
    final stream = await _recorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRate, numChannels: 1),
    );
    _recording = stream.listen((chunk) => _pcm?.add(chunk));
    return true;
  }

  @override
  Future<Uint8List?> stopInput() async {
    if (_listening != null && !_listening!.isCompleted) {
      lastEndReason ??= 'stopped by tap';
      await _stt.stop();
      _finishSoon(); // the final words may still be on their way
    }
    if (_recording == null) return null;
    await _recorder.stop();
    await _recording?.cancel();
    _recording = null;
    final pcm = _pcm?.takeBytes();
    _pcm = null;
    return pcm == null || pcm.isEmpty ? null : wavFromPcm16(pcm, sampleRate: _sampleRate);
  }

  @override
  Future<void> speakEnglish(String text) async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(text);
  }

  @override
  Future<void> playWav(Uint8List wav) async {
    final done = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) => done.isCompleted ? null : done.complete());
    await _player.play(BytesSource(wav));
    await done.future.timeout(const Duration(minutes: 2), onTimeout: () {});
    await sub.cancel();
  }

  @override
  Future<void> stopOutput() async {
    await _tts.stop();
    await _player.stop();
  }

  void dispose() {
    _recorder.dispose();
    _player.dispose();
  }
}

/// Turns recogniser error codes (browser and Android) into something the
/// agent can act on. Returns null when it simply means "nothing was heard".
String? describeSpeechError(String code) {
  final c = code.toLowerCase();
  if (c.contains('no-speech') || c.contains('no_match') || c.contains('speech_timeout') || c.contains('aborted')) {
    return null;
  }
  if (c.contains('not-allowed') || c.contains('service-not-allowed') || c.contains('permission')) {
    return 'The microphone is blocked. Allow microphone access for this site (the icon in the address bar), '
        'then try again. You can also type.';
  }
  if (c.contains('audio-capture') || c.contains('error_audio')) {
    return 'No microphone was found. Check that one is connected, or type instead.';
  }
  if (c.contains('network') || c.contains('server')) {
    return 'Speech recognition needs an internet connection. Check your connection, or type instead.';
  }
  return 'Speech recognition stopped ($code). Tap the microphone to try again, or type.';
}

class VoiceUnavailable implements Exception {
  const VoiceUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Wraps raw 16-bit mono PCM in a WAV header (what Khaya's recogniser expects).
Uint8List wavFromPcm16(Uint8List pcm, {required int sampleRate}) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM chunk size
  header.setUint16(20, 1, Endian.little); // PCM format
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  header.setUint16(32, 2, Endian.little); // block align
  header.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}
