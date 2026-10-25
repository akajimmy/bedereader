// ios parity (test audit, 2026-10-23: pc_rotation_test.dart folded in).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screen.dart';

// iOS brought in line with Android (user, 2026-10-22: "brightness like Android, Save / Copy page, Wi-Fi only
// downloads, Device serif = Georgia"): the Dart side asks iOS's native side as it asks Android's.

// ---- from pc_rotation_test.dart
// Rotation on Windows (user, 2026-10-22: "lock, where it can"): on a PC that turns its screen by itself (a tablet,
// a 2-in-1) the lock is Windows' own auto-rotation preference; a desktop has no Rotation.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('komga_reader/screen');
  late List<MethodCall> calls;
  late Object? Function(MethodCall c) answer;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls = [];
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return answer(c);
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('brightness: the backlight is set, as on Android (the Auto + slider row), not just dimmed', () async {
    expect(hasBacklightControl, isTrue);
    await setScreenBrightness(0.4);
    expect(calls.first.method, 'brightness');
    expect(calls.first.arguments, 0.4);
    expect(calls.skip(1).map((c) => c.method), everyElement('getBrightness'),
        reason: 'only read back after (for the app log)');
  });

  test('Wi-Fi only: iOS is asked which network it is on - mobile data waits, Wi-Fi goes', () async {
    expect(knowsMobileData, isTrue);
    answer = (_) => 'cellular';
    expect(await onWifi(), isFalse);
    answer = (_) => 'wifi';
    expect(await onWifi(), isTrue);
    expect(calls.map((c) => c.method), ['network', 'network']);
  });

  test("Save / Copy page: there on iOS; the picture's bytes go to the native side (Photos, the clipboard)", () async {
    expect(canSaveCopyPictures, isTrue);
    answer = (c) => c.method == 'savePicture' ? 'Photos' : true;
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]);
    expect(await savePicture(png, 'Saga #1 - page 3'), 'Photos');
    await copyPicture(png, 'Saga #1 - page 3');
    expect(calls.map((c) => c.method), ['savePicture', 'copyPicture']);
    for (final c in calls) {
      final args = c.arguments as Map;
      expect(args['bytes'], png, reason: c.method);
      expect(args['mime'], 'image/png', reason: c.method);
    }
  });

  test('Device serif is Georgia on iOS (iOS has no font called "serif": it fell back on its sans)', () {
    expect(deviceSerifFamily, 'Georgia');
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(deviceSerifFamily, 'serif', reason: "Android's own serif");
  });

  group('pc rotation', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('komga_reader/screen');
    late List<MethodCall> calls;
    var sensor = false;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        return c.method == 'canRotate' ? sensor : true;
      });
    });
    tearDown(() async {
      sensor = false;
      await checkPcRotation(); // (back to a desktop for the other tests)
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('Rotation is there only on a PC with a rotation sensor', () async {
      sensor = false;
      await checkPcRotation();
      expect(canRotate, isFalse, reason: 'a desktop');
      sensor = true;
      await checkPcRotation();
      expect(canRotate, isTrue, reason: 'a tablet, a 2-in-1');
    });

    test("the lock is Windows' own: held, turned over, let go", () async {
      sensor = true;
      await checkPcRotation();
      calls.clear();
      final lock = OrientationLock.instance;
      await lock.hold(portrait: false, landscape: true);
      await lock.flip();
      await lock.hold(portrait: true, landscape: false);
      await lock.release();
      expect([for (final c in calls) '${c.method} ${c.arguments}'], [
        'holdOrientation landscape',
        'holdOrientation reverseLandscape',
        'holdOrientation portrait',
        'holdOrientation none',
      ]);
    });
  });
}
