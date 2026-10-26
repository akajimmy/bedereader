// Settings > Remote and keys > Test the remote (lib/screens/remote_test.dart): what the app is given, from Flutter's
// keys and from the system before Flutter (iOS), listed as it comes (user, 2026-10-25: the Chromecast remote on the
// iPad reaches nothing).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/remote_test.dart';

void main() {
  testWidgets('the native side is started while the screen is open and stopped after; its events and the keys '
      'Flutter is given are both listed, newest first', (tester) async {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(RemoteTestScreen.channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(RemoteTestScreen.channel, null));

    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteTestScreen())),
        child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(calls, ['start']);

    // the system's (iOS) report of a press with no keyboard key, as the runner sends it
    await messenger.handlePlatformMessage(RemoteTestScreen.channel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('event', 'screen press began: type 4 (select)')),
        (_) {});
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final lines = [for (final e in find.byType(Text).evaluate()) (e.widget as Text).data ?? '']
        .where((t) => t.contains('select') || t.contains('Arrow Right')).toList();
    expect(lines.length, 3, reason: 'the press, then the key down and up: $lines');
    expect(lines.last, contains('iOS screen press began: type 4 (select)'), reason: 'oldest at the bottom');
    expect(lines.first, contains('Flutter up: Arrow Right'));

    Navigator.of(tester.element(find.byType(RemoteTestScreen))).pop();
    await tester.pumpAndSettle();
    expect(calls, ['start', 'stop']);
  });
}
