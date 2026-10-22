import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../app_identity.dart';
import '../errors.dart';
import '../widgets/error_text.dart';

/// The server field tidied up: spaces removed (the tablet keyboard puts one after the colon), http:// added when no
/// scheme was typed (Komga at home is usually plain http), slashes off the end. Null when it still isn't an address.
String? serverAddress(String typed) {
  var s = typed.replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) s = 'http://$s';
  s = s.replaceAll(RegExp(r'/+$'), ''); // after the scheme check: "http://" alone isn't turned into "http:"
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
  return s;
}

/// The [typed] address sends the API key unencrypted beyond the home network: plain http:// to a host that isn't
/// local (user, 2026-10-08 / 2026-10-21: a note on the sign-in screen). Local: private and loopback addresses
/// (10.x, 172.16-31.x, 192.168.x, 127.x, IPv6 fc00::/7, fe80::/10, ::1), localhost, a name without a dot (a home
/// network's own name, "nick-nas"), .local / .lan / .home.arpa / .internal names - and Tailscale (100.64.0.0/10,
/// .ts.net), whose tunnel is encrypted already. https never.
bool sendsKeyInTheClear(String typed) {
  final address = serverAddress(typed);
  if (address == null) return false;
  final uri = Uri.parse(address);
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || !host.contains('.') && !host.contains(':')) return false;
  for (final end in ['.local', '.lan', '.home.arpa', '.internal', '.ts.net', '.localhost']) {
    if (host.endsWith(end)) return false;
  }
  final v4 = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!), b = int.parse(v4.group(2)!);
    return !(a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
        (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127));
  }
  if (host.contains(':')) {
    final h = host.replaceAll(RegExp(r'[\[\]]'), '');
    return !(h == '::1' || RegExp(r'^f[cd]').hasMatch(h) || RegExp(r'^fe[89ab]').hasMatch(h));
  }
  return true; // a name on the internet
}

/// Server address + a Komga API key (create one in the Komga web client: Account settings > API keys).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn, this.client});
  final Future<void> Function(Komga api) onSignedIn;

  /// Builds the client Connect tries (tests: a fake); null = the real [Komga].
  final Komga Function(String server, String apiKey)? client;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _key = TextEditingController();
  Object? _error; // shown through lib/errors.dart
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _server.addListener(() { if (mounted) setState(() {}); }); // (the http note follows the address as it's typed)
    // signing in again (after Sign out): the last server address is still saved on the device
    SharedPreferences.getInstance().then((p) {
      final last = p.getString('server');
      if (last != null && mounted && _server.text.isEmpty) _server.text = last;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return; // Enter pressed again while connecting (code review 2026-10-05, #20)
    final server = serverAddress(_server.text);
    if (server == null) {
      setState(() => _error = FormatException('not a server address (scheme/host)', _server.text));
      return;
    }
    _server.text = server; // show what's actually used
    setState(() { _busy = true; _error = null; });
    final api = (widget.client ?? Komga.new)(server, _key.text.trim());
    var handedOver = false;
    try {
      final me = await api.me();
      if (me == null) throw KomgaNotKomga(server); // no user from /users/me: not Komga at that address
      handedOver = true;
      await widget.onSignedIn(api);
    } catch (e) {
      // this attempt's connection isn't used again: its client goes (code review 2026-10-05, #50: one left per try)
      if (!handedOver) api.close();
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(appName, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text('$appTagline. Sign in to your Komga server.', style: TextStyle(color: Colors.white60)),
              const SizedBox(height: 24),
              TextField(controller: _server, keyboardType: TextInputType.url, autocorrect: false,
                  enableSuggestions: false, // no predictive text: it adds spaces after "192.168.1.10:"
                  decoration: const InputDecoration(labelText: 'Server', hintText: 'http://192.168.1.10:25600')),
              if (sendsKeyInTheClear(_server.text))
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.lock_open, size: 18, color: Color(0xFFFFB74D)),
                    SizedBox(width: 8),
                    Expanded(child: Text(
                        "This address is outside your home network over plain http: your API key would travel "
                        'unencrypted. Use https if your server has it.',
                        style: TextStyle(color: Color(0xFFFFB74D), fontSize: 13))),
                  ]),
                ),
              const SizedBox(height: 12),
              TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API key'),
                  onSubmitted: (_) => _connect()),
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect')),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
                  child: ErrorText(explain(_error!, signIn: true).message, _error!)),
            ]),
          ),
        ),
      ),
    );
  }
}
