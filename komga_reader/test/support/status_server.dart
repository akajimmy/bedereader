import 'package:komga_reader/api.dart';

import 'no_network.dart';

/// Komga at 192.168.1.10:25600 whose me() - the server status check - answers as [next] says: 'ok' (connected as
/// nick@test), 'refused' (HTTP 401) or 'down'; [calls] counts the checks. No libraries. Build with
/// `noNetwork(StatusServer.new)`.
///
/// One copy of what about_test and app_settings_test each had (test audit, 2026-09-30).
class StatusServer extends TestKomga {
  StatusServer() : super('http://192.168.1.10:25600');
  String next = 'ok';
  int calls = 0;
  @override
  Future<List<dynamic>> libraries() async => [];
  @override
  Future<Map<String, dynamic>?> me() async {
    calls++;
    if (next == 'refused') throw KomgaError(401, '/api/v2/users/me');
    if (next == 'down') throw KomgaUnreachable(baseUrl);
    return {'email': 'nick@test'};
  }
}
