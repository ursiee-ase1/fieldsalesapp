import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
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
      _sttReady ??= await _stt.initialize(onError: (_) => _finishListening(), onStatus: (s) {
        if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) _finishListening();
      });

  String _lastWords = '';

  void _finishListening() {
    final c = _listening;
    if (c != null && !c.isCompleted) c.complete(_lastWords);
  }

  @override
  Future<String> listenEnglish({required void Function(String partial) onPartial}) async {
    if (!await _ensureStt()) throw const VoiceUnavailable('Speech recognition is not available on this device.');
    _lastWords = '';
    final done = _listening = Completer<String>();
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
    return done.future;
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
    if (_stt.isListening) {
      await _stt.stop();
      _finishListening();
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
