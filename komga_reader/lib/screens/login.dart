import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

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

/// Server address + a Komga API key (create one in the Komga web client: Account settings > API keys).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});
  final Future<void> Function(Komga api) onSignedIn;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _key = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // signing in again (after Sign out): the last server address is still saved on the device
    SharedPreferences.getInstance().then((p) {
      final last = p.getString('server');
      if (last != null && mounted && _server.text.isEmpty) _server.text = last;
    });
  }

  Future<void> _connect() async {
    final server = serverAddress(_server.text);
    if (server == null) {
      setState(() => _error = "That isn't a server address - it should look like http://192.168.1.10:25600");
      return;
    }
    _server.text = server; // show what's actually used
    setState(() { _busy = true; _error = null; });
    final api = Komga(server, _key.text.trim());
    try {
      final me = await api.me();
      if (me == null) throw Exception('No user returned');
      await widget.onSignedIn(api);
    } catch (e) {
      setState(() => _error = '$e');
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
              Text('Komga', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              TextField(controller: _server, keyboardType: TextInputType.url, autocorrect: false,
                  enableSuggestions: false, // no predictive text: it adds spaces after "10.0.0.23:"
                  decoration: const InputDecoration(labelText: 'Server', hintText: 'http://192.168.1.10:25600')),
              const SizedBox(height: 12),
              TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'API key'),
                  onSubmitted: (_) => _connect()),
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _connect, child: Text(_busy ? 'Connecting…' : 'Connect')),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
            ]),
          ),
        ),
      ),
    );
  }
}
