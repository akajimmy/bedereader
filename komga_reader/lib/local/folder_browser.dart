import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screen.dart' show appDocumentsDir;
import '../widgets/error_text.dart';
import 'access.dart';
import 'folder_komga.dart';
import 'folder_scan.dart' show LibraryKind, LocalLibrary;
import 'storage.dart';
import 'where.dart';

/// Where the folder browser starts: this device's storage, a drive, a server.
class Place {
  const Place(this.label, this.path, {this.server = false});
  final String label;
  final String path; // a folder, or \\host for a server (its shares listed)
  final bool server;
}

/// What the folder browser reads (tests give it a fake).
abstract class BrowseSource {
  /// The places to start from.
  Future<List<Place>> places();

  /// Before a place on this device is opened (Android: All files access); false: not allowed.
  Future<bool> openDevice(BuildContext context);

  /// The folder shares on [host].
  Future<List<String>> shares(String host);

  /// What's in [path].
  Future<FolderLook> look(String path);

  /// [error] is a server refusing the login (one can be asked for).
  bool refused(Object error);

  /// [login] for \\host (to list its shares) and the shares on it that have none kept yet.
  Future<void> useLogin(String host, SmbLogin login);
}

/// The device's own folders and the network's shares, through [Storage].
class DeviceBrowse implements BrowseSource {
  final _hostLogins = <String, SmbLogin>{}; // given while browsing, to list a server's shares

  @override
  Future<List<Place>> places() async {
    final out = <Place>[];
    await DeviceRoots.load(); // (for the paths said plainly)
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final root = await FolderAccess.storageRoot() ?? '/storage/emulated/0';
        out.add(Place('This device', root));
        // an SD card or USB drive: /storage/XXXX-XXXX (not the emulated storage itself)
        try {
          await for (final e in Directory('/storage').list()) {
            final name = e.path.split('/').last;
            if (e is Directory && name != 'emulated' && name != 'self') out.add(Place('Card or drive $name', e.path));
          }
        } catch (_) {}
      case TargetPlatform.windows:
        for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
          final drive = '${String.fromCharCode(c)}:\\';
          if (await Directory(drive).exists()) out.add(Place(drive, drive));
        }
      case TargetPlatform.iOS:
        // the app's own folder, which the Files app shows under the app's name (On My iPad / iPhone): books copied
        // there. Asked of iOS itself - the HOME it was found from isn't set in the app (user, 2026-10-26: "the only
        // option under add a library is connect to a server")
        final docs = await appDocumentsDir();
        if (docs != null) out.add(Place("This device (the app's folder in Files)", docs));
      default:
        final home = Platform.environment['HOME'];
        if (home != null) out.add(Place('Home', home));
    }
    // the servers already used: the libraries' and the logins'
    final hosts = <String, String>{}; // lower case -> as written
    for (final l in await FolderKomga.savedLibraries()) {
      if (splitUnc(l.path) case (final host, _, _)) hosts.putIfAbsent(host.toLowerCase(), () => host);
    }
    for (final host in hosts.values) {
      out.add(Place(host, '\\\\$host', server: true));
    }
    return out;
  }

  @override
  Future<bool> openDevice(BuildContext context) => FolderAccess.allFiles(context);

  @override
  Future<List<String>> shares(String host) async {
    final storage = Storage.instance;
    await storage.load();
    return storage.sharesOn(host, _hostLogins[host.toLowerCase()] ?? storage.loginForHost(host));
  }

  @override
  Future<FolderLook> look(String path) async {
    final storage = Storage.instance;
    await storage.load();
    // a share opened with the login its server's shares were listed with, if it has none of its own
    if (splitUnc(path) case (final host, final share, _)) {
      final given = _hostLogins[host.toLowerCase()];
      if (given != null && storage.viaSmb(path) && storage.loginFor(path) == null) {
        await storage.setLogin('\\\\$host\\$share', given);
      }
    }
    return storage.of(path).look(path);
  }

  @override
  bool refused(Object error) =>
      error is Smb2Exception && (error.isAuthError || error.type == Smb2ErrorType.accessDenied);

  @override
  Future<void> useLogin(String host, SmbLogin login) async {
    _hostLogins[host.toLowerCase()] = login;
  }
}

/// Picks a library folder: this device's storage, a drive, or a share on the network, browsed folder by folder.
/// Returns its path (\\host\share\folder for a share), or null.
Future<String?> pickFolder(BuildContext context, {BrowseSource? source}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FolderBrowser(source: source ?? DeviceBrowse())));

/// A library to add: its folder ([pickFolder]), then what's in it ([askLibraryKind]). Null: cancelled.
Future<LocalLibrary?> pickLibrary(BuildContext context, {BrowseSource? source}) async {
  final path = await pickFolder(context, source: source);
  if (path == null || path.trim().isEmpty || !context.mounted) return null;
  final kind = await askLibraryKind(context);
  return kind == null ? null : LocalLibrary.at(path, kind: kind);
}

/// "This library contains:" - how its books are laid out (user, 2026-10-26). Null: cancelled.
Future<LibraryKind?> askLibraryKind(BuildContext context) => showDialog<LibraryKind>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('This library contains:'),
        children: [
          for (final k in LibraryKind.values)
            ListTile(
              leading: Icon(libraryKindIcon(k)),
              title: Text(libraryKindLabel(k)),
              onTap: () => Navigator.pop(ctx, k),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ),
          ),
        ],
      ),
    );

String libraryKindLabel(LibraryKind k) => switch (k) {
      LibraryKind.seriesFolders => 'One folder per series',
      LibraryKind.oneSeries => 'Multiple books for a single series',
      LibraryKind.readList => 'Multiple books for multiple series (a read list)',
    };

IconData libraryKindIcon(LibraryKind k) => switch (k) {
      LibraryKind.seriesFolders => Icons.folder_copy_outlined,
      LibraryKind.oneSeries => Icons.collections_bookmark_outlined,
      LibraryKind.readList => Icons.format_list_numbered,
    };

class FolderBrowser extends StatefulWidget {
  const FolderBrowser({super.key, required this.source});
  final BrowseSource source;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

/// One level of the browser: the places, a server's shares, or a folder's folders.
sealed class _Level {}

class _Places extends _Level {
  _Places(this.places);
  final List<Place> places;
}

class _Shares extends _Level {
  _Shares(this.shares);
  final List<String> shares;
}

class _Folder extends _Level {
  _Folder(this.look);
  final FolderLook look;
}

class _FolderBrowserState extends State<FolderBrowser> {
  String? _path; // null: the places
  String? _root; // the place a device folder was entered from (Up from there: the places)
  String? _rootLabel; // its name ("This device"), the title there - not the path's last part ("0")
  _Level? _level;
  Object? _error;
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    _go(null);
  }

  /// \\host (no share): a server, its shares listed.
  static bool _isServer(String p) => p.startsWith('\\\\') && splitUnc(p) == null;

  static String _sep(String p) => p.contains('\\') ? '\\' : '/';

  static String _join(String p, String name) => p.endsWith(_sep(p)) ? '$p$name' : '$p${_sep(p)}$name';

  /// One level up: a share's top goes to its server, a place's top (or a server) to the places.
  String? get _up {
    final p = _path;
    if (p == null || _isServer(p)) return null;
    if (splitUnc(p) case (final host, _, final rest) when rest.isEmpty) return '\\\\$host';
    if (_root != null && p == _root) return null;
    final cut = p.replaceAll(RegExp(r'[\\/]+$'), '');
    final i = cut.lastIndexOf(_sep(cut));
    if (i <= 0) return null;
    final parent = cut.substring(0, i);
    return parent.endsWith(':') ? '$parent\\' : parent; // C:\Comics -> C:\
  }

  Future<void> _go(String? path) async {
    final load = ++_loads;
    setState(() {
      _path = path;
      if (path == null) _root = null;
      _level = null;
      _error = null;
    });
    try {
      final _Level level = path == null
          ? _Places(await widget.source.places())
          : _isServer(path)
          ? _Shares(await widget.source.shares(path.substring(2)))
          : _Folder(await widget.source.look(path));
      if (mounted && load == _loads) setState(() => _level = level);
    } catch (e) {
      if (!mounted || load != _loads) return;
      if (path != null && path.startsWith('\\\\') && widget.source.refused(e)) {
        final host = path.substring(2).split(RegExp(r'[\\/]')).first;
        final login = await FolderAccess.askLogin(context, '\\\\$host', null, null);
        if (login == null || !mounted) {
          if (mounted) setState(() => _error = e);
          return;
        }
        await widget.source.useLogin(host, login);
        return _go(path);
      }
      setState(() => _error = e);
    }
  }

  Future<void> _openPlace(Place p) async {
    if (!p.server && !await widget.source.openDevice(context)) return;
    _root = p.server ? null : p.path;
    _rootLabel = p.label;
    await _go(p.path);
  }

  Future<String?> _ask(String title, String label, String hint) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, autocorrect: false, enableSuggestions: false,
            decoration: InputDecoration(labelText: label, hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  Future<void> _connect() async {
    final host = (await _ask('Connect to a server', 'Server name or address', 'nick-nas'))
        ?.trim().replaceAll(RegExp(r'^(smb:)?[\\/]+'), '').replaceAll(RegExp(r'[\\/].*$'), '');
    if (host == null || host.isEmpty) return;
    await _go('\\\\$host');
  }

  Future<void> _type() async {
    final path = (await _ask('Type a folder', 'Folder', r'\\server\share\Comics'))?.trim();
    if (path != null && path.isNotEmpty && mounted) Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final p = _path;
    final level = _level;
    final up = _up;
    final books = level is _Folder ? level.look.books : 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(p == null ? 'Choose a library folder' : p == _root ? _rootLabel ?? _name(p) : _name(p)),
        actions: [
          if (p != null)
            IconButton(tooltip: 'Up', icon: const Icon(Icons.arrow_upward), onPressed: () {
              if (up == null) _root = null;
              _go(up);
            }),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (p != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(whereHere(p).toString(), style: const TextStyle(fontSize: 13, color: Color(0xFF9A9A9A))),
          ),
        Expanded(child: switch (level) {
          _ when _error != null => Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ErrorText(_problem(_error!), _error!, centre: true),
                const SizedBox(height: 12),
                TextButton(onPressed: () => _go(p), child: const Text('Try again')),
              ]))),
          null => const Center(child: CircularProgressIndicator()),
          _Places(:final places) => ListView(children: [
              for (final pl in places)
                ListTile(leading: Icon(pl.server ? Icons.dns_outlined : Icons.folder_outlined), title: Text(pl.label),
                    subtitle: switch (whereHere(pl.path).inside) {
                      _ when pl.server || pl.label == pl.path => null,
                      '' => null,
                      final inside => Text(inside), // (iOS: Documents/)
                    },
                    onTap: () => _openPlace(pl)),
              ListTile(leading: const Icon(Icons.add), title: const Text('Connect to a server…'),
                  subtitle: const Text('A shared folder on your network (SMB)'), onTap: _connect),
              ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Type a folder…'), onTap: _type),
            ]),
          _Shares(:final shares) => shares.isEmpty
              ? const Center(child: Text('No shared folders on this server'))
              : ListView(children: [
                  for (final s in shares)
                    ListTile(leading: const Icon(Icons.dns_outlined), title: Text(s), onTap: () => _go('$p\\$s')),
                ]),
          _Folder(:final look) => look.folders.isEmpty
              ? const Center(child: Text('No folders in here'))
              : ListView(children: [
                  for (final f in look.folders)
                    ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f), onTap: () => _go(_join(p!, f))),
                ]),
        }),
      ]),
      bottomNavigationBar: level is _Folder
          ? SafeArea(child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${level.look.folders.length} folder${level.look.folders.length == 1 ? '' : 's'}'
                    '${books > 0 ? ', $books book${books == 1 ? '' : 's'}' : ''} in here. Next you say how its books '
                    'are laid out.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9A9A9A))),
                ),
                FilledButton(onPressed: () => Navigator.pop(context, p), child: const Text('Use this folder')),
              ]),
            ))
          : null,
    );
  }

  static String _name(String p) {
    final parts = p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? p : parts.last;
  }

  static String _problem(Object e) => switch (e) {
        Smb2Exception(:final type, :final message) => "Couldn't reach the server (${type.name}): $message",
        FileSystemException(:final message, :final osError) =>
          "Couldn't open that folder: ${osError?.message.isNotEmpty == true ? osError!.message : message}",
        _ => "Couldn't open that: $e",
      };
}
