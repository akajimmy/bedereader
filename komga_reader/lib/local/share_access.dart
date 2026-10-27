import 'package:flutter/material.dart';

import 'library_fs.dart';
import 'smb_fs.dart';

/// A share's folder, reachable before it's kept as a library: tried as it is first (a share open to guests needs no
/// login - user, 2026-10-25), a login asked for only when the share refuses one (one that doesn't answer, or a folder
/// that isn't there, can't be helped by signing in - tablet, 2026-10-25), Retry when it doesn't answer. False:
/// cancelled, or the folder isn't there (said first). Its errors are told apart by the share's own files ([classify]).
Future<bool> ensureShare(BuildContext context, String path, {Shares? shares}) async {
  final s = shares ?? Shares.instance;
  final parts = splitUnc(path);
  if (parts == null) return true; // (not a share)
  final (host, share, folder) = parts;
  final where = '\\\\$host\\$share';
  // a login given here and not working out (refused, then Cancel; the share not answering) isn't kept: the share's
  // login as it was before (the review, 2026-10-26: a refused one stayed, and was used for the next listing)
  final before = s.loginFor(path);
  var tried = false;
  Future<bool> no() async {
    if (tried) await s.setLogin(path, before);
    return false;
  }

  String? problem; // said above the login fields (null: nothing went wrong - a guest refused)
  var ask = false;
  while (true) {
    if (ask) {
      if (!context.mounted) return no();
      final login = await askShareLogin(context, where, was: s.loginFor(path), problem: problem);
      if (login == null) return no();
      await s.setLogin(path, login);
      tried = true;
    }
    final fs = s.fsFor(path);
    Object error;
    try {
      if (await fs.exists(path)) return true;
      if (context.mounted) {
        await _say(context, 'Folder not found', "Connected to $where, but there's no folder $folder on it.");
      }
      return false; // (the login worked: kept)
    } catch (e) {
      error = e;
    }
    switch (fs.classify(error)) {
      case FileTrouble.refused:
        problem = s.loginFor(path) == null && !ask ? null : 'The share refused that user name and password.';
        ask = true;
      case FileTrouble.gone:
        if (context.mounted) await _say(context, 'Share not found', 'There is no share $share on $host.');
        return no();
      case FileTrouble.noAnswer || FileTrouble.damaged:
        if (!context.mounted || !await _retry(context, where, '$error')) return no();
        ask = false; // (tried again as it was)
    }
  }
}

/// "Can't reach the share": Retry (true) or Cancel. [why] - the client's own words - in small print.
Future<bool> _retry(BuildContext context, String where, String why) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Can't reach the share"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('No answer from $where. Check the address, and that the server is on and on this network.'),
          Padding(padding: const EdgeInsets.only(top: 10),
              child: Text(why, style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, true), child: const Text('Retry')),
        ],
      ),
    ) ??
    false;

Future<void> _say(BuildContext context, String title, String text) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(title: Text(title), content: Text(text), actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ]));

/// A user name and password (and a domain, rarely needed) for [where] (\\host\share, or \\host to list its shares);
/// null: cancelled.
Future<SmbLogin?> askShareLogin(BuildContext context, String where, {SmbLogin? was, String? problem}) =>
    showDialog<SmbLogin>(context: context, builder: (_) => ShareLoginDialog(where: where, was: was, problem: problem));

/// The fields are the dialog's own: let go when it's gone, not while it's still closing (they're drawn until then -
/// the experiment's review).
class ShareLoginDialog extends StatefulWidget {
  const ShareLoginDialog({super.key, required this.where, this.was, this.problem});
  final String where;
  final SmbLogin? was;
  final String? problem;

  @override
  State<ShareLoginDialog> createState() => _ShareLoginDialogState();
}

class _ShareLoginDialogState extends State<ShareLoginDialog> {
  late final _user = TextEditingController(text: widget.was?.user ?? '');
  final _password = TextEditingController();
  late final _domain = TextEditingController(text: widget.was?.domain ?? '');

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  void _done() {
    final user = _user.text.trim(), domain = _domain.text.trim();
    Navigator.pop(context, user.isEmpty ? null : SmbLogin(user, _password.text, domain: domain.isEmpty ? null : domain));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Sign in to ${widget.where}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.problem != null)
              Padding(padding: const EdgeInsets.only(bottom: 12),
                  child: Text(widget.problem!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            TextField(controller: _user, autofocus: true, autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'User name')),
            TextField(controller: _password, obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'), onSubmitted: (_) => _done()),
            TextField(controller: _domain, autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Domain (usually empty)')),
            Padding(padding: const EdgeInsets.only(top: 10), child: Text(
                'Kept encrypted on this device, for this share only.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: _done, child: const Text('Sign in')),
        ],
      );
}
