import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
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

/// The [typed] address sends the API key or password unencrypted beyond the home network: plain http:// to a host that isn't
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

/// The name of the API key a password sign-in makes: the app, the device kind and when (Komga lists it under the
/// account's API keys; dated, so signing in again on the same device never repeats a name).
String apiKeyName() {
  final kind = switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.macOS => 'macOS',
    _ => defaultTargetPlatform.name,
  };
  final t = clock.now();
  String two(int n) => '$n'.padLeft(2, '0');
  return '$appName on $kind, ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Server address, then either the account's email and password or a Komga API key (user, 2026-10-24: "Password |
/// API key" tabs, Password first). A password sign-in makes an API key for this device and keeps only that; when
/// the server won't make one (a restricted or demo account), the email and password are kept instead (encrypted,
/// like a key). The email is filled in again after Sign out; the password and key never are.
///
/// Or No server mode ([onNoServer]): the local libraries alone. [adding]: opened from No server mode to add a Komga
/// server (Settings > Server and sync) - a screen over the app with a way back, and no No server choice.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn, this.client, this.onNoServer, this.adding = false});
  final Future<void> Function(Komga api) onSignedIn;

  /// Use without a server (null: not offered).
  final Future<void> Function(BuildContext context)? onNoServer;
  final bool adding;

  /// The Use without a server button (tests find it by this).
  static const noServerKey = ValueKey('noServer');

  /// Builds the client Connect tries (tests: a fake); null = the real [Komga].
  final Komga Function(String server, String apiKey)? client;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _key = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _byPassword = true;
  Object? _error; // shown through lib/errors.dart
  bool _errorWithPassword = false; // (the error came from a password sign-in: said in those words)
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _server.addListener(() { if (mounted) setState(() {}); }); // (the http note follows the address as it's typed)
    // signing in again (after Sign out): the last server address and email are still saved on the device
    SharedPreferences.getInstance().then((p) {
      final last = p.getString('server'), email = p.getString('email');
      if (last != null && mounted && _server.text.isEmpty) _server.text = last;
      if (email != null && mounted && _email.text.isEmpty) _email.text = email;
    });
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Komga _client(String server, String credential) => (widget.client ?? Komga.new)(server, credential);

  /// Signs in with the email and password: Komga is asked who they are, then for an API key for this device. The
  /// key is what's kept; a server that won't make one (4xx) keeps the password client instead.
  Future<Komga> _withPassword(String server) async {
    final byPassword = _client(server, Komga.basic(_email.text.trim(), _password.text));
    try {
      if (await byPassword.me() == null) throw KomgaNotKomga(server); // no user from /users/me: not Komga there
      final String key;
      try {
        key = await byPassword.createApiKey(apiKeyName());
      } on KomgaError catch (e) {
        if (e.status >= 500) rethrow;
        return byPassword; // this server won't make a key for this account: the password it is
      }
      byPassword.close();
      return _client(server, key);
    } catch (_) {
      byPassword.close();
      rethrow;
    }
  }

  Future<void> _connect() async {
    if (_busy) return; // Enter pressed again while connecting (code review 2026-10-05, #20)
    final server = serverAddress(_server.text);
    if (server == null) {
      setState(() => _error = FormatException('not a server address (scheme/host)', _server.text));
      return;
    }
    _server.text = server; // show what's actually used
    final byPassword = _byPassword;
    setState(() { _busy = true; _error = null; });
    Komga? api;
    var handedOver = false;
    try {
      if (byPassword) {
        api = await _withPassword(server);
      } else {
        api = _client(server, _key.text.trim());
        final me = await api.me();
        if (me == null) throw KomgaNotKomga(server); // no user from /users/me: not Komga at that address
      }
      if (byPassword) await (await SharedPreferences.getInstance()).setString('email', _email.text.trim());
      handedOver = true;
      await widget.onSignedIn(api);
    } catch (e) {
      // this attempt's connection isn't used again: its client goes (code review 2026-10-05, #50: one left per try)
      if (!handedOver) api?.close();
      if (mounted) setState(() { _error = e; _errorWithPassword = byPassword; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _noServer() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await widget.onNoServer!(context);
    } catch (e) {
      if (mounted) setState(() { _error = e; _errorWithPassword = false; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: widget.adding ? AppBar(title: const Text('Add a Komga server')) : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView( // (a short screen: a phone on its side, the keyboard up)
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.adding)
                const Text('Its books show beside the local libraries; settings, pins and progress then sync through '
                    'it.', style: TextStyle(color: Colors.white60))
              else ...[
                Text(appName, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 4),
                const Text('$appTagline. Sign in to your Komga server.', style: TextStyle(color: Colors.white60)),
              ],
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Password')),
                  ButtonSegment(value: false, label: Text('API key')),
                ],
                selected: {_byPassword},
                showSelectedIcon: false,
                onSelectionChanged: _busy ? null : (s) => setState(() { _byPassword = s.single; _error = null; }),
              ),
              const SizedBox(height: 12),
              TextField(controller: _server, keyboardType: TextInputType.url, autocorrect: false,
                  enableSuggestions: false, // no predictive text: it adds spaces after "192.168.1.10:"
                  decoration: const InputDecoration(labelText: 'Server', hintText: 'http://192.168.1.10:25600')),
              if (sendsKeyInTheClear(_server.text))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.lock_open, size: 18, color: Color(0xFFFFB74D)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                        'This address is outside your home network over plain http: your '
                        '${_byPassword ? 'password' : 'API key'} would travel unencrypted. Use https if your server '
                        'has it.',
                        style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 13))),
                  ]),
                ),
              const SizedBox(height: 12),
              if (_byPassword) ...[
                TextField(controller: _email, keyboardType: TextInputType.emailAddress, autocorrect: false,
                    enableSuggestions: false, decoration: const InputDecoration(labelText: 'Email')),
                const SizedBox(height: 12),
                TextField(controller: _password, obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'), onSubmitted: (_) => _connect()),
              ] else
                TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API key'),
                    onSubmitted: (_) => _connect()),
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect')),
              if (widget.onNoServer != null && !widget.adding) ...[
                const SizedBox(height: 28),
                OutlinedButton.icon(key: LoginScreen.noServerKey, onPressed: _busy ? null : _noServer,
                    icon: const Icon(Icons.folder_outlined), label: const Text('Use without a server')),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Books from folders on this device. A Komga server can be added later, in Settings.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: grey)),
                ),
              ],
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
                  child: ErrorText(explain(_error!, signIn: true, password: _errorWithPassword).message, _error!)),
            ]),
          ),
        ),
      ),
    );
  }
}
