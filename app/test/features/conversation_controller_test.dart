import 'dart:async';
import 'dart:typed_data';

import 'package:field_sales/features/assistant/application/conversation_controller.dart';
import 'package:field_sales/features/assistant/data/assistant_repository.dart';
import 'package:field_sales/features/assistant/data/voice.dart';
import 'package:flutter_test/flutter_test.dart';

AssistantReply reply(String text, {String status = 'active', String action = 'ask', List<String>? summary,
        String? agentText, Uint8List? audio, bool twiVoice = false, List<String> notices = const []}) =>
    AssistantReply(
      sessionId: 's1',
      draftVersion: 1,
      status: status,
      action: action,
      replyText: text,
      agentText: agentText,
      replyAudio: audio,
      summary: summary,
      notices: notices,
      twiVoiceEnabled: twiVoice,
    );

class FakeApi implements AssistantApi {
  FakeApi(this.replies);

  final List<Object> replies; // AssistantReply or an exception to throw
  final sent = <String>[];

  Future<AssistantReply> _next() async {
    final r = replies.removeAt(0);
    if (r is AssistantReply) return r;
    throw r;
  }

  @override
  Future<AssistantReply> start({required bool voice, required AssistantLanguage language}) {
    sent.add('start:${voice ? 'voice' : 'text'}:${language.name}');
    return _next();
  }

  @override
  Future<AssistantReply> sendText(String sessionId, int version, String text,
      {required AssistantLanguage language, required bool voiceOut}) {
    sent.add('text:$text');
    return _next();
  }

  @override
  Future<AssistantReply> sendAudio(String sessionId, int version, Uint8List wav, {required AssistantLanguage language}) {
    sent.add('audio:${wav.length}');
    return _next();
  }

  @override
  Future<AssistantReply> confirm(String sessionId, int version,
      {required AssistantLanguage language, required bool voiceOut}) {
    sent.add('confirm');
    return _next();
  }

  @override
  Future<AssistantReply> finish(String sessionId, int version,
      {required AssistantLanguage language, required bool voiceOut}) {
    sent.add('finish');
    return _next();
  }

  @override
  Future<void> discard(String sessionId) async => sent.add('discard');
}

class FakeVoice implements VoiceIO {
  FakeVoice({this.heard = const [], this.micAllowed = true, this.listenError, this.lastEndReason});

  final List<String> heard;
  final bool micAllowed;
  final Object? listenError;
  final log = <String>[];
  Completer<void>? speaking;

  /// When set, listening stays open until the test completes it.
  Completer<String>? pendingListen;

  @override
  String? lastEndReason;

  @override
  Future<String> listenEnglish({required void Function(String partial) onPartial}) async {
    log.add('listen');
    if (listenError != null) throw listenError!;
    if (pendingListen != null) return pendingListen!.future;
    if (heard.isEmpty) return '';
    final words = heard.removeAt(0);
    onPartial(words);
    return words;
  }

  @override
  Future<bool> startRecording() async {
    log.add('record');
    return micAllowed;
  }

  @override
  Future<Uint8List?> stopInput() async {
    log.add('stopInput');
    return Uint8List(16000);
  }

  @override
  Future<void> speakEnglish(String text) async {
    log.add('say:$text');
    await speaking?.future;
  }

  @override
  Future<void> playWav(Uint8List wav) async => log.add('play:${wav.length}');

  @override
  Future<void> stopOutput() async {
    log.add('stopOutput');
    if (speaking != null && !speaking!.isCompleted) speaking!.complete();
  }
}

void main() {
  test('chat: question, answer, summary, confirm', () async {
    final api = FakeApi([
      reply('How many sales have you made today?'),
      reply('Here is your report. Shall I send it?', status: 'awaiting_confirmation', action: 'summary',
          summary: ['No sales today.']),
      reply('Thank you! Your report has been sent.', status: 'submitted', action: 'submitted'),
    ]);
    final c = ConversationController(api: api, voice: FakeVoice(), voiceMode: false, language: AssistantLanguage.en);
    await c.start();
    expect(c.lines.single.text, 'How many sales have you made today?');

    await c.sendText('None today');
    expect(c.lines.map((l) => l.fromAgent), [false, true, false]);
    expect(c.summary, ['No sales today.']);
    expect(api.sent, ['start:text:en', 'text:None today'], reason: 'nothing confirmed yet');

    await c.confirm();
    expect(c.submitted, isTrue);
    expect(c.summary, isNull);
    expect(c.phase, ConversationPhase.finished);
  });

  test('"Finish report" brings up the summary, and comes back after "Make changes"', () async {
    final api = FakeApi([
      reply('How many people did you speak to?'),
      reply('Here is your report. Shall I send it?', status: 'awaiting_confirmation', action: 'summary',
          summary: ['No sales today.']),
      reply('Here is your report. Shall I send it?', status: 'awaiting_confirmation', action: 'summary',
          summary: ['No sales today.']),
    ]);
    final c = ConversationController(api: api, voice: FakeVoice(), voiceMode: false, language: AssistantLanguage.en);
    await c.start();
    expect(c.canFinish, isTrue);

    await c.finish();
    expect(api.sent.last, 'finish');
    expect(c.summary, ['No sales today.']);
    expect(c.canFinish, isFalse, reason: 'the summary card has its own buttons');

    await c.makeChanges();
    expect(c.summary, isNull);
    expect(c.canFinish, isTrue, reason: 'the agent can always get back to sending');
    await c.finish();
    expect(c.summary, isNotNull);
  });

  test('English voice: speaks, listens, sends what was heard', () async {
    final voice = FakeVoice(heard: ['I sold four books']);
    final api = FakeApi([
      reply('How many sales have you made today?'),
      reply('Great. Was that cash or Mobile Money?'),
    ]);
    final c = ConversationController(api: api, voice: voice, voiceMode: true, language: AssistantLanguage.en);
    await c.start();
    expect(voice.log.take(3), ['say:How many sales have you made today?', 'listen', 'stopOutput']);
    expect(api.sent, contains('text:I sold four books'));
    expect(c.lines.last.text, 'Great. Was that cash or Mobile Money?');
  });

  test('tapping the mic while the assistant speaks interrupts it', () async {
    final voice = FakeVoice()..speaking = Completer<void>();
    final c = ConversationController(api: FakeApi([reply('A long question…')]), voice: voice, voiceMode: true,
        language: AssistantLanguage.en);
    unawaited(c.start());
    await pumpEventQueue();
    expect(c.phase, ConversationPhase.speaking);

    await c.tapMic();
    expect(voice.log, containsAllInOrder(['say:A long question…', 'stopOutput', 'listen']));
  });

  test('Twi voice: records, sends audio, shows what was recognised, plays the reply', () async {
    final voice = FakeVoice();
    final api = FakeApi([
      reply('[tw] greeting', audio: Uint8List(10), twiVoice: true),
      reply('[tw] Wotɔn sika anaa MoMo?', agentText: 'Matɔn nwoma anan', audio: Uint8List(20), twiVoice: true),
    ]);
    final c = ConversationController(api: api, voice: voice, voiceMode: true, language: AssistantLanguage.tw);
    await c.start();
    expect(voice.log, ['play:10', 'record']);
    expect(c.phase, ConversationPhase.recording);

    await c.tapMic(); // stop and send
    expect(api.sent.last, startsWith('audio:'));
    expect(c.lines.map((l) => l.text), ['[tw] greeting', 'Matɔn nwoma anan', '[tw] Wotɔn sika anaa MoMo?']);
    expect(voice.log, contains('play:20'));
  });

  test('Twi voice falls back to typing when the company has not switched it on', () async {
    final c = ConversationController(api: FakeApi([reply('[tw] greeting')]), voice: FakeVoice(), voiceMode: true,
        language: AssistantLanguage.tw);
    await c.start();
    expect(c.voiceMode, isFalse);
    expect(c.notices.single, contains("Twi voice isn't switched on"));
  });

  test('no microphone permission: explains and switches to typing', () async {
    final c = ConversationController(
      api: FakeApi([reply('[tw] greeting', twiVoice: true)]),
      voice: FakeVoice(micAllowed: false),
      voiceMode: true,
      language: AssistantLanguage.tw,
    );
    await c.start();
    expect(c.voiceMode, isFalse);
    expect(c.error, contains('Microphone permission'));
  });

  test('nothing heard: says so instead of silently resetting', () async {
    final c = ConversationController(api: FakeApi([reply('How many sales?')]), voice: FakeVoice(), voiceMode: true,
        language: AssistantLanguage.en);
    await c.start(); // speaks, then listens and hears nothing
    expect(c.phase, ConversationPhase.idle);
    expect(c.hint, contains("I didn't hear anything"));
    expect(c.voiceMode, isTrue);
  });

  test('tapping to talk while it is already listening keeps listening', () async {
    final voice = FakeVoice()..pendingListen = Completer<String>();
    final api = FakeApi([reply('How many sales?'), reply('Cash or Mobile Money?')]);
    final c = ConversationController(api: api, voice: voice, voiceMode: true, language: AssistantLanguage.en);
    unawaited(c.start());
    await pumpEventQueue();
    expect(c.phase, ConversationPhase.listening, reason: 'listens by itself after the question');

    await c.tapMic(); // the agent taps "to start talking"
    expect(c.phase, ConversationPhase.listening);
    expect(voice.log, isNot(contains('stopInput')));
    expect(c.hint, contains("I'm listening"));

    voice.pendingListen!.complete('I sold two books');
    await pumpEventQueue();
    expect(api.sent, contains('text:I sold two books'));
  });

  test('when nothing is heard, the browser\'s reason is shown for diagnosis', () async {
    final c = ConversationController(api: FakeApi([reply('How many sales?')]),
        voice: FakeVoice(lastEndReason: 'no-speech'), voiceMode: true, language: AssistantLanguage.en);
    await c.start();
    expect(c.hint, endsWith('(browser said: no-speech)'));
  });

  test('a blocked microphone is explained, and voice stays available to retry', () async {
    final blocked = VoiceUnavailable(describeSpeechError('not-allowed')!);
    final c = ConversationController(api: FakeApi([reply('How many sales?')]), voice: FakeVoice(listenError: blocked),
        voiceMode: true, language: AssistantLanguage.en);
    await c.start();
    expect(c.error, contains('microphone is blocked'));
    expect(c.voiceMode, isTrue);
    expect(c.phase, ConversationPhase.idle);
  });

  test('browsers without speech recognition fall back to typing', () async {
    const none = VoiceUnavailable('Speech recognition is not available here. On a computer, use Chrome or Edge.');
    final c = ConversationController(api: FakeApi([reply('How many sales?')]), voice: FakeVoice(listenError: none),
        voiceMode: true, language: AssistantLanguage.en);
    await c.start();
    expect(c.voiceMode, isFalse);
    expect(c.error, contains('Chrome or Edge'));
  });

  test('recogniser error codes map to actionable messages', () {
    expect(describeSpeechError('no-speech'), isNull);
    expect(describeSpeechError('error_no_match'), isNull);
    expect(describeSpeechError('not-allowed'), contains('blocked'));
    expect(describeSpeechError('error_permission'), contains('blocked'));
    expect(describeSpeechError('audio-capture'), contains('No microphone'));
    expect(describeSpeechError('network'), contains('internet'));
  });

  test('no connection: says so plainly and keeps the form as a way out', () async {
    final c = ConversationController(
      api: FakeApi([Exception('ClientException: Failed to fetch')]),
      voice: FakeVoice(),
      voiceMode: false,
      language: AssistantLanguage.en,
    );
    await c.start();
    expect(c.needsConnection, isTrue);
    expect(c.error, startsWith("Couldn't reach the server"));
  });
}
