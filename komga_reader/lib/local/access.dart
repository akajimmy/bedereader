import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'storage.dart';

/// Getting at a library's folder (experimental/sources): a share's login, asked for and tried before it's kept; on
/// Android, All files access for the tablet's own folders. Shared by the sign-in screen's No server and Settings'
/// Add a library.
class FolderAccess {
  static const _files = MethodChannel('komga_reader/files');

  /// Android: All files access is granted (elsewhere: nothing to grant).
  static Future<bool> hasAllFiles() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _files.invokeMethod<bool>('hasAllFiles') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Where the tablet's own storage starts (/storage/emulated/0), for the folder field's hint; null elsewhere.
  static Future<String?> storageRoot() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _files.invokeMethod<String>('storageRoot');
    } catch (_) {
      return null;
    }
  }

  /// [path] can be read: for a share, a login that works (asked for if none is kept, or if the kept one is refused);
  /// on Android, All files access for the tablet's folders. False: cancelled, or the folder isn't there - said in a
  /// dialog first.
  static Future<bool> ensure(BuildContext context, String path) async {
    final storage = Storage.instance;
    await storage.load();
    if (storage.viaSmb(path)) {
      // with no login kept, tried as a guest first: a share open to anyone needs none (user, 2026-10-25), and
      // refusing a guest is no failure - only then is a login asked for, with nothing said against it
      String? problem;
      var asked = false;
      while (true) {
        var login = storage.loginFor(path);
        if (asked || problem != null) {
          if (!context.mounted) return false;
          final (host, share, _) = splitUnc(path)!;
          login = await askLogin(context, '\\\\$host\\$share', login, problem);
          if (login == null) return false;
          await storage.setLogin(path, login);
        }
        try {
          final fs = storage.of(path);
          if (await fs.exists(path)) return true;
          problem = "Connected, but there's no folder ${splitUnc(path)!.$3} on that share.";
        } on Smb2Exception catch (e) {
          final refused = e.isAuthError || e.type == Smb2ErrorType.accessDenied;
          if (refused && login == null && !asked) {
            asked = true; // a guest refused: ask, saying nothing went wrong
            continue;
          }
          problem = refused
              ? 'The share refused that user name and password.'
              : "Couldn't reach the share (${e.type.name}): ${e.message}";
        } catch (e) {
          problem = "Couldn't reach the share: $e";
        }
      }
    }
    if (!context.mounted || !await allFiles(context)) return false;
    if (await Directory(path).exists()) return true;
    if (context.mounted) {
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text("Can't find that folder"),
        content: Text(path),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ));
    }
    return false;
  }

  /// Android: All files access, asked for until it's granted (Open Settings, then "I've allowed it"); false:
  /// cancelled. Elsewhere: nothing to grant.
  static Future<bool> allFiles(BuildContext context) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      while (!await hasAllFiles()) {
        if (!context.mounted) return false;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Allow access to your files'),
            content: const Text("To read books from a folder on this tablet, the app needs Android's All files "
                'access. Open Settings, turn it on for BeDeReader, then come back here.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(
                onPressed: () async {
                  try {
                    await _files.invokeMethod('askAllFiles');
                  } catch (_) {}
                },
                child: const Text('Open Settings'),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("I've allowed it")),
            ],
          ),
        );
        if (go != true) return false;
      }
    }
    return true;
  }

  /// A user name and password (and domain, rarely needed) for [where] (\\host\share, or \\host to list its
  /// shares); null: cancelled.
  static Future<SmbLogin?> askLogin(BuildContext context, String where, SmbLogin? was, String? problem) =>
      showDialog<SmbLogin>(context: context, builder: (_) => _LoginDialog(where, was, problem));
}

/// The fields are the dialog's own: let go when it's gone, not while it's still closing (they're drawn until then).
class _LoginDialog extends StatefulWidget {
  const _LoginDialog(this.where, this.was, this.problem);
  final String where;
  final SmbLogin? was;
  final String? problem;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
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
            if (widget.problem != null) Padding(padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.problem!, style: const TextStyle(color: Color(0xFFFF8A80)))),
            TextField(controller: _user, autofocus: true, autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'User name')),
            TextField(controller: _password, obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                onSubmitted: (_) => _done()),
            TextField(controller: _domain, autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Domain (usually empty)')),
            const Padding(padding: EdgeInsets.only(top: 10), child: Text(
                'Kept encrypted on this device, for this server only.', style: TextStyle(fontSize: 12))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: _done, child: const Text('Sign in')),
        ],
      );
}
