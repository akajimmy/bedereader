import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Looks a host name up (tests replace it).
@visibleForTesting
Future<List<InternetAddress>> Function(String host) lookupHost = InternetAddress.lookup;

/// Connects to [host] by name - every address it has tried in turn, as the system does (tests replace it).
@visibleForTesting
Future<ConnectionTask<Socket>> Function(String host, int port) connectHost =
    (host, port) => Socket.startConnect(host, port);

/// The name to connect to for [host]: a bare name (no dot) the system can't find is tried as name.local - a NAS
/// answers to that on the local network (mDNS), which Android and iOS look up, but they don't find the bare name by
/// itself, as Windows does (user, 2026-10-26: http://nick-nas:25600 "Can't reach Komga" on the tablet). A name the
/// system finds - a full one, an address, "localhost", a bare name that already worked - is used as it is.
Future<String> hostToConnect(String host) async {
  if (host.contains('.') || host.contains(':')) return host;
  if (await _found(host)) return host;
  return await _found('$host.local') ? '$host.local' : host;
}

Future<bool> _found(String name) async {
  try {
    return (await lookupHost(name)).isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Every HttpClient the app makes - Komga's requests, its posters and pages - finds a bare host name the way
/// [hostToConnect] does. Only the choice of name is kept for the run, never an address: each connection is made by
/// name, so every address is tried (IPv6 ones with their scope), and a NAS given a new address is found at its new one
/// (review, 2026-10-26: the experiment kept the first address it found for good). A connection that fails forgets the
/// choice - asked again next time. Plain http only: https connects by the name as given, so its certificate is
/// checked against it; through a proxy, the proxy is connected to as before. Set once at the start (main.dart).
class LocalNames extends HttpOverrides {
  final Map<String, String> _names = {}; // bare name -> the name connected to for it (itself, or name.local)

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
      // (the app trusts only certificates the device does: no bad-certificate callback to pass on)
      if (uri.scheme == 'https') return SecureSocket.startConnect(uri.host, uri.port, context: context);
      final host = uri.host;
      final name = _names[host] ??= await hostToConnect(host);
      final task = await connectHost(name, uri.port);
      unawaited(task.socket.then((_) {}, onError: (Object _) => _names.remove(host)));
      return task;
    };
    return client;
  }
}
