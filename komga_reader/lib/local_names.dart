import 'dart:io';

import 'package:flutter/foundation.dart';

/// Looks a host name up (tests replace it).
@visibleForTesting
Future<List<InternetAddress>> Function(String host) lookupHost = InternetAddress.lookup;

/// The address to connect to for [host]. A bare name (no dot) that DNS doesn't know is tried as name.local: a NAS
/// answers to that on the local network (mDNS), which Android and iOS look up - Windows finds the bare name that way
/// by itself, they don't (user, 2026-10-26: http://nick-nas:25600 "Can't reach Komga" on the tablet). Not found either
/// way: [host] as it is, for the connection to say so.
Future<String> hostAddress(String host) async {
  if (host.contains('.') || host.contains(':')) return host; // a full name, or an address
  for (final name in [host, '$host.local']) {
    try {
      final found = await lookupHost(name);
      if (found.isNotEmpty) {
        // IPv4 first: an IPv6 address the NAS also has may be one this device can't reach
        return found.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => found.first).address;
      }
    } catch (_) {
      // not found that way
    }
  }
  return host;
}

/// Every HttpClient the app makes - Komga's requests, its posters and pages - finds a bare host name the way
/// [hostAddress] does: as name.local when DNS doesn't know it. Plain http only: https connects by the name as given,
/// so its certificate is checked against it; through a proxy, the proxy is connected to as before. Set once at the
/// start (main.dart).
class LocalNames extends HttpOverrides {
  final Map<String, String> _found = {}; // bare names found this run (one not found is asked again next time)

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (proxyHost != null && proxyPort != null) return Socket.startConnect(proxyHost, proxyPort);
      // (the app trusts only certificates the device does: no bad-certificate callback to pass on)
      if (uri.scheme == 'https') return SecureSocket.startConnect(uri.host, uri.port, context: context);
      var address = _found[uri.host];
      if (address == null) {
        address = await hostAddress(uri.host);
        if (address != uri.host) _found[uri.host] = address;
      }
      return Socket.startConnect(address, uri.port);
    };
    return client;
  }
}
