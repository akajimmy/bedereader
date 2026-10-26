import 'package:flutter/material.dart';

import '../api.dart';
import '../errors.dart';
import '../offline/connection.dart';

/// What there is to read without Komga: "your downloaded books", "your local libraries", or both.
String offlineBooks(Connection c) => [
      if (c.hasDownloads) 'your downloaded books',
      if (c.hasLocal) 'your local libraries',
    ].join(' and ');

/// Komga refuses this device's API key: say so, and offer the downloaded books (which need no key) or signing in
/// again. Returns true for Sign in again. With nothing downloaded, Sign in again is the only way on.
Future<bool> showKeyRefusedPrompt(BuildContext context) async {
  final c = Connection.instance;
  final downloads = c.hasDownloads || c.hasLocal; // (something to read offline)
  final password = c.online?.usesPassword ?? false;
  final signIn = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.key_off, color: Color(0xFFFACC15)),
      title: Text(password ? 'Password not accepted' : 'API key not accepted'),
      content: Text([
        explain(KomgaError(401, ''), password: password).message,
        if (downloads) '${offlineBooks(c)[0].toUpperCase()}${offlineBooks(c).substring(1)} can still be read meanwhile.',
      ].join('\n\n')),
      actions: [
        if (downloads) TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Read offline')),
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

/// "Can't reach Komga": Retry / Go offline (user, 2026-10-21: "prompt the user to retry or go offline"). With nothing
/// downloaded it says so - Retry / OK, and OK goes offline too: true, and the caller takes the user back to Home (user,
/// 2026-10-22: OK "just leads me back to a non-responsive page. make sure it puts it in offline mode and dumps the user
/// to the home screen"). Closes itself if Komga answers meanwhile.
Future<bool> showUnreachablePrompt(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _UnreachablePrompt(),
    ) ??
    false;

/// Komga is reachable again, while offline after "can't reach Komga": Go online / Stay offline (user, 2026-10-21: "when
/// back online prompt. if user dismisses prompt, stay in offline mode"). Closed any other way, it stays offline.
Future<void> showReachableAgainPrompt(BuildContext context) async {
  final c = Connection.instance;
  final online = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.cloud_done_outlined, color: Color(0xFF4ADE80)),
      title: const Text('Komga is reachable again'),
      content: Text('${displayAddress(c.online?.baseUrl ?? 'The server')} answers again. Go back online?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Stay offline')),
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Go online')),
      ],
    ),
  );
  if (!c.reachableAgain) return; // (gone meanwhile - answered elsewhere, or Komga went again)
  online == true ? await c.goOnline() : c.stayOffline();
}

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
    // Komga may have answered while this was opening (the change came before this listened): nothing left to ask.
    // Missed, a Retry that then reached Komga changed nothing and spun for good (tablet, build 77)
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!c.askPending) _close(); // answered elsewhere, or Komga is back
  }

  void _close([bool toHome = false]) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(toHome);
  }

  Future<void> _retry() async {
    setState(() { _retrying = true; _stillDown = false; });
    final ok = await c.check();
    if (!mounted) return;
    if (ok) {
      _close(); // Komga answered: closed here, not left to a change that may already have come
      return;
    }
    setState(() { _retrying = false; _stillDown = true; });
  }

  @override
  Widget build(BuildContext context) {
    final downloads = c.hasDownloads || c.hasLocal; // (something to read offline: downloads, or local libraries)
    return AlertDialog(
      icon: const Icon(Icons.cloud_off, color: Color(0xFFFACC15)),
      title: const Text("Can't reach Komga"),
      content: Text([
        "No answer from ${displayAddress(c.online?.baseUrl ?? 'the server')}. Check you're on your home network and "
            'the server is running.',
        if (_stillDown) 'Still no answer.',
        downloads ? 'Read ${offlineBooks(c)} instead?' : 'Nothing is downloaded on this device to read offline.',
      ].join('\n\n')),
      actions: [
        // nothing to read either way: offline, and back to Home (the page behind is waiting on Komga)
        if (!downloads)
          TextButton(onPressed: _retrying ? null : () { _close(true); c.useDownloads(); }, child: const Text('OK')),
        TextButton(
          onPressed: _retrying ? null : _retry,
          child: _retrying ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Retry'),
        ),
        if (downloads)
          FilledButton(autofocus: true, onPressed: _retrying ? null : () { _close(); c.useDownloads(); },
              child: const Text('Go offline')),
      ],
    );
  }
}
