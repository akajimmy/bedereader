// Runs before every test file (Flutter's test config).
import 'dart:async';

import 'package:komga_reader/reader/spreads.dart' show twoPagesAllowed;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // one page at a time: the test window (800 x 600) is wider than tall, and Two pages' default is Wide screen - the
  // two-page tests turn it back on (test/two_pages_test.dart)
  twoPagesAllowed = false;
  await testMain();
}
