import 'dart:async';

import 'package:komga_reader/api.dart';

import 'no_network.dart';

/// Komga's client-settings store (where pins, reader settings and the On deck list sync), kept in memory: what's
/// written there, whether Komga can be reached ([down]), and optionally a write held in flight ([holdPut]).
///
/// One copy of what pins_test, settings_sync_test and ondeck_hidden_test each had (test audit, 2026-09-30).
mixin ClientSettingsStore on Komga {
  final written = <String, String>{};
  bool down = false;
  Completer<void>? holdPut; // a write on its way, until completed
  int puts = 0;

  @override
  Future<Map<String, dynamic>> clientSettings() async {
    if (down) throw KomgaUnreachable(baseUrl);
    return {for (final e in written.entries) e.key: {'value': e.value}};
  }

  @override
  Future<void> putClientSetting(String key, String value) async {
    if (down) throw KomgaUnreachable(baseUrl);
    puts++;
    await holdPut?.future;
    written[key] = value;
  }
}

/// A Komga that has only its client settings ([start]: already saved there). Build with `noNetwork(SettingsServer.new)`.
class SettingsServer extends TestKomga with ClientSettingsStore {
  SettingsServer([Map<String, String>? start]) {
    if (start != null) written.addAll(start);
  }
}
