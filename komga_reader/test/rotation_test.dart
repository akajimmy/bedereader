// Auto rotation on Android, the app's own (lib/rotation.dart - user, 2026-10-24: "the app should handle the rotation
// so it's not turning every time the tablet turns. We're just using the tablet setting to determine whether or not we
// should rotate"). The Android side's readings are played in here as it sends them.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/rotation.dart';
import 'package:komga_reader/screen.dart';

void main() {
  const rotation = MethodChannel('komga_reader/rotation'), screen = MethodChannel('komga_reader/screen');
  late List<Object?> requests; // SystemChrome's orientation requests
  late List<Object?> follow; // what the app asked the Android side ('follow')
  late bool systemAuto; // the tablet's auto-rotate
  late String wayUp; // the screen's way up now

  setUp(() {
    requests = [];
    follow = [];
    systemAuto = true;
    wayUp = 'landscape';
  });

  Future<void> start(WidgetTester tester) async {
    final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') requests.add(call.arguments);
      return null;
    });
    m.setMockMethodCallHandler(rotation, (call) async {
      if (call.method != 'follow') return null;
      follow.add(call.arguments);
      return systemAuto;
    });
    m.setMockMethodCallHandler(screen, (call) async => call.method == 'currentWayUp' ? wayUp : null);
    addTearDown(() async {
      systemAuto = false;
      await OrientationLock.instance.release();
      m.setMockMethodCallHandler(SystemChannels.platform, null);
      m.setMockMethodCallHandler(rotation, null);
      m.setMockMethodCallHandler(screen, null);
    });
    await OrientationLock.instance.release(); // Auto, no lock of the reader's: as the app starts
    await tester.pump();
  }

  /// The Android side tells the app [method] ([args]): a tilt reading, or the tablet's auto-rotate changed.
  Future<void> fromAndroid(WidgetTester tester, String method, Object? args) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        rotation.name, const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)), (_) {});
    await tester.pump();
  }

  const portrait = ['DeviceOrientation.portraitUp'], landscape = ['DeviceOrientation.landscapeLeft'];

  testWidgets('tablet auto-rotate on: the screen is held the way it is up, and turns only once the tablet has stayed '
      'turned for a moment', (tester) async {
    await start(tester);
    expect(requests.last, landscape, reason: 'held the way it is up');
    await fromAndroid(tester, 'tilt', 5); // turned to portrait (a few degrees off)
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests.last, landscape, reason: 'not yet');
    await fromAndroid(tester, 'tilt', 2); // still portrait
    await tester.pump(AutoRotation.hold);
    expect(requests.last, portrait, reason: 'held there: turned');
  });

  testWidgets('a tilt and back within the moment turns nothing; nor a lean near a diagonal, or the tablet lying flat',
      (tester) async {
    await start(tester);
    final before = requests.length;
    await fromAndroid(tester, 'tilt', 180); // over to portrait upside down...
    await tester.pump(const Duration(milliseconds: 500));
    await fromAndroid(tester, 'tilt', 90); // ...and back
    await tester.pump(AutoRotation.hold * 2);
    await fromAndroid(tester, 'tilt', 40); // near the diagonal between portrait and landscape
    await tester.pump(AutoRotation.hold * 2);
    await fromAndroid(tester, 'tilt', 0); // portrait...
    await tester.pump(const Duration(milliseconds: 500));
    await fromAndroid(tester, 'tilt', -1); // ...laid flat
    await tester.pump(AutoRotation.hold * 2);
    expect(requests.length, before, reason: 'nothing turned');
  });

  testWidgets("tablet auto-rotate off: the tablet's own way (its lock) and no turning; switched on: held the way it "
      'is, turning from there; off again: the lock', (tester) async {
    systemAuto = false;
    await start(tester);
    expect(requests.last, isEmpty, reason: "the tablet's own way: its lock");
    await fromAndroid(tester, 'tilt', 0);
    await tester.pump(AutoRotation.hold * 2);
    expect(requests.last, isEmpty, reason: 'not turned');

    wayUp = 'portrait';
    await fromAndroid(tester, 'systemAutoRotate', true);
    await tester.pump();
    expect(requests.last, portrait, reason: 'held the way it is');
    await fromAndroid(tester, 'tilt', 270);
    await tester.pump(AutoRotation.hold);
    expect(requests.last, ['DeviceOrientation.landscapeRight']);

    await fromAndroid(tester, 'systemAutoRotate', false);
    await tester.pump();
    expect(requests.last, isEmpty);
  });

  testWidgets("a reader's lock set while the screen's way up is still being asked: the lock stands (code review, "
      '2026-10-24: the way up was applied after it)', (tester) async {
    systemAuto = false;
    await start(tester);
    final asked = Completer<String>();
    var wayUpCalls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(screen, (call) async {
      if (call.method != 'currentWayUp') return null;
      return ++wayUpCalls == 1 ? asked.future : 'portrait'; // the first answer is slow
    });
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(rotation.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('systemAutoRotate', true)), (_) {});
    await tester.pump(); // auto-rotate switched on: the way up asked for...
    await OrientationLock.instance.hold(portrait: true, landscape: false); // ...and the reader locks meanwhile
    await tester.pump();
    final held = requests.last;
    expect(held, portrait);
    asked.complete('landscape');
    await tester.pump();
    expect(requests.last, held, reason: 'the lock holds');
  });

  testWidgets("a reader's lock (Portrait, Landscape) takes over: no readings wanted, the tablet turning doesn't move "
      'it; let go, the app follows the tablet again', (tester) async {
    await start(tester);
    expect(follow.last, true);
    await OrientationLock.instance.hold(portrait: false, landscape: true);
    expect(follow.last, false, reason: 'readings no longer wanted');
    final held = requests.last;
    await fromAndroid(tester, 'tilt', 0);
    await tester.pump(AutoRotation.hold * 2);
    expect(requests.last, held, reason: 'the lock holds');
    await OrientationLock.instance.release();
    await tester.pump();
    expect(follow.last, true);
  });
}
