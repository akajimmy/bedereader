import 'package:flutter/material.dart';

import '../api.dart';

/// Server address + a Komga API key (create one in the Komga web client: Account settings > API keys).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onSignedIn});
  final Future<void> Function(Komga api) onSignedIn;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(text: 'http://10.0.0.23:25600');
  final _key = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _connect() async {
    setState(() { _busy = true; _error = null; });
    final api = Komga(_server.text.trim(), _key.text.trim());
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
              TextField(controller: _server, decoration: const InputDecoration(labelText: 'Server')),
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
