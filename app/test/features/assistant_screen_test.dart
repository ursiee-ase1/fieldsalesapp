import 'dart:typed_data';

import 'package:field_sales/core/design/theme.dart';
import 'package:field_sales/features/assistant/data/assistant_repository.dart';
import 'package:field_sales/features/assistant/data/voice.dart';
import 'package:field_sales/features/assistant/presentation/assistant_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'conversation_controller_test.dart' show FakeApi, FakeVoice, reply;

void main() {
  test('WAV header wraps 16 kHz mono PCM correctly', () {
    final wav = wavFromPcm16(Uint8List(32000), sampleRate: 16000);
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint16(34, Endian.little), 16, reason: '16-bit');
    expect(b.getUint32(40, Endian.little), 32000);
    expect(wav.length, 44 + 32000);
  });

  testWidgets('chat report: answer, then confirm the summary with labelled buttons', (tester) async {
    final api = FakeApi([
      reply('How many sales have you made today?'),
      reply('Here is your report. Shall I send it?', status: 'awaiting_confirmation', action: 'summary',
          summary: ['No sales today.', 'Stock left: Book A 9.']),
      reply('Thank you! Your report has been sent.', status: 'submitted', action: 'submitted'),
    ]);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(onPressed: () => context.push('/chat'), child: const Text('open')),
        ),
      ),
      GoRoute(path: '/chat', builder: (_, _) => const AssistantScreen(voice: false)),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        assistantApiProvider.overrideWithValue(api),
        voiceProvider.overrideWithValue(FakeVoice()),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('How many sales have you made today?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), "None, 9 left, that's all");
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    expect(find.text('Check your report'), findsOneWidget);
    expect(find.text('• Stock left: Book A 9.'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Make changes'), findsOneWidget);
    expect(api.sent.where((s) => s == 'confirm'), isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Confirm and send'));
    await tester.pumpAndSettle();
    expect(api.sent.last, 'confirm');
    expect(find.text('Report sent'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Back to home'), findsOneWidget);
  });
}
