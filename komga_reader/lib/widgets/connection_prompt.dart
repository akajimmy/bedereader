import 'package:flutter/material.dart';

import '../api.dart';
import '../errors.dart';
import '../offline/connection.dart';

/// Komga refuses this device's API key: say so, and offer the downloaded books (which need no key) or signing in
/// again. Returns true for Sign in again. With nothing downloaded, Sign in again is the only way on.
Future<bool> showKeyRefusedPrompt(BuildContext context) async {
  final c = Connection.instance;
  final downloads = c.hasDownloads;
  final signIn = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.key_off, color: Color(0xFFFACC15)),
      title: const Text('API key not accepted'),
      content: Text([
        explain(KomgaError(401, '')).message,
        if (downloads) 'Your downloaded books can still be read meanwhile.',
      ].join('\n\n')),
      actions: [
        if (downloads) TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Use downloaded books')),
        FilledButton(autofocus: !downloads, onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign in again')),
      ],
    ),
  );
  if (signIn == true) {
    c.keyPromptAnswered();
    return true;
  }
  c.useDownloads();
  return false;
}

/// "Can't reach Komga": Use downloaded books / Retry / Stay online. With nothing downloaded it just says so (Retry /
/// OK). Closes itself if Komga answers meanwhile.
Future<void> showUnreachablePrompt(BuildContext context) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _UnreachablePrompt(),
    );

class _UnreachablePrompt extends StatefulWidget {
  const _UnreachablePrompt();
  @override
  State<_UnreachablePrompt> createState() => _UnreachablePromptState();
}

class _UnreachablePromptState extends State<_UnreachablePrompt> {
  final c = Connection.instance;
  bool _retrying = false, _stillDown = false, _closed = false;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!c.askPending) _close(); // answered elsewhere, or Komga is back
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  Future<void> _retry() async {
    setState(() { _retrying = true; _stillDown = false; });
    final ok = await c.check(); // success clears askPending, which closes this
    if (!mounted || ok) return;
    setState(() { _retrying = false; _stillDown = true; });
  }

  @override
  Widget build(BuildContext context) {
    final downloads = c.hasDownloads;
    return AlertDialog(
      icon: const Icon(Icons.cloud_off, color: Color(0xFFFACC15)),
      title: const Text("Can't reach Komga"),
      content: Text([
        "No answer from ${displayAddress(c.online?.baseUrl ?? 'the server')}. Check you're on your home network and "
            'the server is running.',
        if (_stillDown) 'Still no answer.',
        downloads ? 'Read your downloaded books instead?' : 'Nothing is downloaded on this device to read offline.',
      ].join('\n\n')),
      actions: [
        TextButton(onPressed: _retrying ? null : () { _close(); c.stayOnline(); }, child: Text(downloads ? 'Stay online' : 'OK')),
        TextButton(
          onPressed: _retrying ? null : _retry,
          child: _retrying ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Retry'),
        ),
        if (downloads)
          FilledButton(autofocus: true, onPressed: _retrying ? null : () { _close(); c.useDownloads(); },
              child: const Text('Use downloaded books')),
      ],
    );
  }
}
