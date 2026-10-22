import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screen.dart';

/// Rotation on Windows (user, 2026-10-22: "lock, where it can"): on a PC that turns its screen by itself (a tablet,
/// a 2-in-1) the lock is Windows' own auto-rotation preference; a desktop has no Rotation.
void main() {
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
}
