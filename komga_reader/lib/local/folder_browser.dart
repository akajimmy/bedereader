import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../screens/actions.dart' show askName;
import 'device_folders.dart';
import 'library_fs.dart';
import 'local_library.dart';
import 'share_access.dart' show askShareLogin;
import 'smb_fs.dart';

/// Where the folder browser starts: this device's storage, a card or drive, the iPad's app folder.
class Place {
  const Place(this.label, this.path);
  final String label;
  final String path;
}

/// What the folder browser reads (tests give their own).
abstract interface class BrowseSource {
  /// The places to start from.
  Future<List<Place>> places();

  /// Before a place is opened (Android: All files access); false: not allowed.
  Future<bool> openPlace(BuildContext context);

  /// What's in [path].
  Future<FolderLook> look(String path);
}

/// This device's folders.
class DeviceBrowse implements BrowseSource {
  @override
  Future<List<Place>> places() async {
    final out = <Place>[];
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        out.add(Place('This device', await DeviceFolders.storageRoot() ?? '/storage/emulated/0'));
        // a card or USB drive: /storage/XXXX-XXXX (not the emulated storage itself)
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
        final docs = await DeviceFolders.documents();
        if (docs != null) out.add(Place("This device (the app's folder in Files)", docs));
      default:
        final home = Platform.environment['HOME'];
        if (home != null) out.add(Place('Home', home));
    }
    return out;
  }

  @override
  Future<bool> openPlace(BuildContext context) => DeviceFolders.allFiles(context);

  @override
  Future<FolderLook> look(String path) => LocalFs().look(path);
}

/// A server's shares as well (Add a shared folder): a place may be a server, \\host - its shares listed, and opened
/// one by one.
abstract interface class NetworkBrowseSource implements BrowseSource {
  /// The folder shares on [host].
  Future<List<String>> shares(String host);

  /// [error] is a server or share refusing the login (one can be asked for).
  bool refused(Object error);

  /// [login] to list [host]'s shares with - kept for the share opened from it, if that has none of its own.
  Future<void> useLogin(String host, SmbLogin login);

  /// [login] for the share [path] is on (kept).
  Future<void> setLogin(String path, SmbLogin login);
}

/// The network's shares, through [Shares]: the servers already used ([known]: the libraries' paths, and the logins
/// kept), and any other by its name.
class NetworkBrowse implements NetworkBrowseSource {
  NetworkBrowse({this.known = const [], Shares? shares}) : _shares = shares ?? Shares.instance;
  final List<String> known;
  final Shares _shares;
  final _hostLogins = <String, SmbLogin>{}; // given while browsing, to list a server's shares

  @override
  Future<List<Place>> places() async {
    final hosts = <String, String>{}; // lower case -> as written
    for (final p in known) {
      if (splitUnc(p) case (final host, _, _)) hosts.putIfAbsent(host.toLowerCase(), () => host);
    }
    return [for (final h in hosts.values) Place(h, '\\\\$h')];
  }

  @override
  Future<bool> openPlace(BuildContext context) async => true;

  @override
  Future<List<String>> shares(String host) =>
      _shares.sharesOn(host, _hostLogins[host.toLowerCase()] ?? _shares.loginForHost(host));

  @override
  Future<FolderLook> look(String path) async {
    // a share opened with the login its server's shares were listed with, if it has none of its own
    if (splitUnc(path) case (final host, final share, _)) {
      final given = _hostLogins[host.toLowerCase()];
      if (given != null && _shares.viaApp && _shares.loginFor(path) == null) {
        await _shares.setLogin('\\\\$host\\$share', given);
      }
    }
    return _shares.fsFor(path).look(path);
  }

  @override
  bool refused(Object error) => SmbFs.troubleOf(error) == FileTrouble.refused;

  @override
  Future<void> useLogin(String host, SmbLogin login) async => _hostLogins[host.toLowerCase()] = login;

  @override
  Future<void> setLogin(String path, SmbLogin login) => _shares.setLogin(path, login);
}

/// A library to add: its folder ([pickFolder]), then what's in it ([askLibraryKind]). Null: cancelled.
Future<LocalLibrary?> pickLibrary(BuildContext context, {BrowseSource? source}) async {
  final path = await pickFolder(context, source: source);
  if (path == null || !context.mounted) return null;
  final kind = await askLibraryKind(context);
  return kind == null ? null : LocalLibrary.at(path, kind: kind);
}

/// What a library folder holds; null: cancelled.
Future<LibraryKind?> askLibraryKind(BuildContext context) => showDialog<LibraryKind>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text("What's in this folder?"),
        children: [
          for (final (i, k) in LibraryKind.values.indexed)
            SimpleDialogOption(
              child: ListTile(autofocus: i == 0, leading: Icon(libraryKindIcon(k)), title: Text(libraryKindLabel(k)),
                  onTap: () => Navigator.pop(ctx, k)),
            ),
        ],
      ),
    );

String libraryKindLabel(LibraryKind k) => switch (k) {
      LibraryKind.seriesFolders => 'One folder per series',
      LibraryKind.oneSeries => 'Books of one series',
      LibraryKind.readList => 'Books of several series, in order (a read list)',
    };

IconData libraryKindIcon(LibraryKind k) => switch (k) {
      LibraryKind.seriesFolders => Icons.folder_copy_outlined,
      LibraryKind.oneSeries => Icons.collections_bookmark_outlined,
      LibraryKind.readList => Icons.format_list_numbered,
    };

/// Picks a library folder on this device, browsed folder by folder: its path, or null.
Future<String?> pickFolder(BuildContext context, {BrowseSource? source}) => Navigator.of(context)
    .push<String>(MaterialPageRoute(builder: (_) => FolderBrowser(source: source ?? DeviceBrowse())));

class FolderBrowser extends StatefulWidget {
  const FolderBrowser({super.key, required this.source});
  final BrowseSource source;

  @override
  State<FolderBrowser> createState() => _FolderBrowserState();
}

class _FolderBrowserState extends State<FolderBrowser> {
  String? _path; // null: the places
  String? _root; // the place it was entered from (Up from there: the places)
  String? _rootLabel;
  List<Place>? _places;
  FolderLook? _look;
  List<String>? _shares; // a server's (path \\host)
  Object? _error;
  int _loads = 0;

  NetworkBrowseSource? get _net => switch (widget.source) { final NetworkBrowseSource n => n, _ => null };

  /// \\host alone: a server, its shares listed.
  static bool _isServer(String p) => p.startsWith(r'\\') && !p.startsWith(r'\\?') && splitUnc(p) == null;

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// One place to start from (a tablet's storage, the iPad's app folder): opened straight away - a list of one is
  /// a screen with nothing to choose (user, 2026-10-26). Up from its top shows the list, with Type a folder.
  Future<void> _start() async {
    await _go(null);
    final places = _places;
    if (_net != null) return; // (servers: the list, with Connect to a server)
    if (mounted && _path == null && places != null && places.length == 1) await _open(places.single);
  }

  static String _sep(String p) => p.contains('\\') ? '\\' : '/';
  static String _join(String p, String name) => p.endsWith(_sep(p)) ? '$p$name' : '$p${_sep(p)}$name';

  /// One level up; null: the places.
  String? get _up {
    final p = _path;
    if (p == null || _isServer(p)) return null;
    if (splitUnc(p) case (final host, _, final rest) when rest.isEmpty) return '\\\\$host'; // a share's top: its server
    if (_root != null && p == _root) return null;
    final cut = p.replaceAll(RegExp(r'[\\/]+$'), '');
    final i = cut.lastIndexOf(_sep(cut));
    if (i <= 0) return null;
    final parent = cut.substring(0, i);
    return parent.endsWith(':') ? '$parent\\' : parent; // C:\Comics -> C:\
  }

  /// [refusedBefore]: a login given for it was refused (said above the fields when one is asked for again).
  Future<void> _go(String? path, {bool refusedBefore = false}) async {
    final load = ++_loads;
    setState(() {
      _path = path;
      if (path == null) _root = null;
      _look = null;
      _shares = null;
      _error = null;
    });
    try {
      if (path == null) {
        final places = await widget.source.places();
        if (mounted && load == _loads) setState(() => _places = places);
      } else if (_isServer(path)) {
        final shares = await _net!.shares(path.substring(2));
        if (mounted && load == _loads) setState(() => _shares = shares);
      } else {
        final look = await widget.source.look(path);
        if (mounted && load == _loads) setState(() => _look = look);
      }
    } catch (e) {
      if (!mounted || load != _loads) return;
      final net = _net;
      if (net != null && path != null && net.refused(e)) {
        // a server or share refusing a guest (or the login given): a login asked for, then tried again
        final server = _isServer(path);
        final where = server ? path : switch (splitUnc(path)) { (final h, final s, _) => '\\\\$h\\$s', _ => path };
        final login = await askShareLogin(context, where,
            problem: refusedBefore ? 'The server refused that user name and password.' : null);
        if (!mounted || load != _loads) return;
        if (login != null) {
          server ? await net.useLogin(path.substring(2), login) : await net.setLogin(path, login);
          if (mounted && load == _loads) await _go(path, refusedBefore: true);
          return;
        }
      }
      setState(() => _error = e);
    }
  }

  /// Connect to a server: by its name or address; its shares listed.
  Future<void> _connect() async {
    final host = (await askName(context, title: 'Connect to a server', label: 'Server name or address',
            hint: 'nick-nas', plain: true))
        ?.replaceAll(RegExp(r'^(smb:)?[\\/]+'), '').replaceAll(RegExp(r'[\\/].*$'), '');
    if (host == null || host.isEmpty || !mounted) return;
    _root = '\\\\$host';
    _rootLabel = host;
    await _go('\\\\$host');
  }

  Future<void> _open(Place p) async {
    if (!await widget.source.openPlace(context)) return;
    _root = p.path;
    _rootLabel = p.label;
    await _go(p.path);
  }

  Future<void> _type() async {
    final path = await askName(context, title: 'Type a folder', label: 'Folder', plain: true,
        hint: _net != null ? r'\\server\share\Comics' : switch (defaultTargetPlatform) {
          TargetPlatform.windows => r'C:\Comics',
          TargetPlatform.android => '/storage/emulated/0/Comics',
          _ => 'Comics',
        });
    if (path != null && mounted) Navigator.pop(context, path);
  }

  static String _name(String p) {
    final cut = p.replaceAll(RegExp(r'[\\/]+$'), '');
    final n = cut.substring(cut.lastIndexOf(RegExp(r'[\\/]')) + 1);
    return n.isEmpty ? p : n;
  }

  @override
  Widget build(BuildContext context) {
    final p = _path, look = _look, places = _places;
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: Text(p == null ? 'Choose a library folder' : p == _root ? _rootLabel ?? _name(p) : _name(p)),
        actions: [
          if (p != null)
            IconButton(tooltip: 'Up', icon: const Icon(Icons.arrow_upward), onPressed: () {
              final up = _up;
              if (up == null) _root = null;
              _go(up);
            }),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (p != null)
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text(p, style: TextStyle(fontSize: 13, color: grey))),
        Expanded(
          child: _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text("Couldn't read that folder."),
                    const SizedBox(height: 12),
                    TextButton(autofocus: true, onPressed: () => _go(p), child: const Text('Try again')),
                  ])))
              : p == null
                  ? places == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(children: [
                          for (final (i, pl) in places.indexed)
                            ListTile(autofocus: i == 0, leading: Icon(_isServer(pl.path) ? Icons.dns_outlined
                                    : pl.path.startsWith('/storage/') && !pl.path.startsWith('/storage/emulated')
                                        ? Icons.sd_card_outlined : Icons.folder_outlined),
                                title: Text(pl.label), onTap: () => _open(pl)),
                          if (_net != null)
                            ListTile(autofocus: places.isEmpty, leading: const Icon(Icons.add_link),
                                title: const Text('Connect to a server…'), onTap: _connect),
                          ListTile(autofocus: places.isEmpty && _net == null, leading: const Icon(Icons.edit_outlined),
                              title: const Text('Type a folder…'), onTap: _type),
                        ])
                  : _isServer(p)
                      ? _shares == null
                          ? const Center(child: CircularProgressIndicator())
                          : _shares!.isEmpty
                              ? const Center(child: Text('No shared folders on this server'))
                              : ListView(children: [
                                  for (final (i, s) in _shares!.indexed)
                                    ListTile(autofocus: i == 0, leading: const Icon(Icons.folder_shared_outlined),
                                        title: Text(s), onTap: () => _go('$p\\$s')),
                                ])
                  : look == null
                      ? const Center(child: CircularProgressIndicator())
                      : look.folders.isEmpty
                          ? const Center(child: Text('No folders in here'))
                          : ListView(children: [
                              for (final (i, f) in look.folders.indexed)
                                ListTile(autofocus: i == 0, leading: const Icon(Icons.folder_outlined), title: Text(f),
                                    onTap: () => _go(_join(p, f))),
                            ]),
        ),
      ]),
      bottomNavigationBar: look != null && p != null
          ? SafeArea(child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                      '${look.folders.length} folder${look.folders.length == 1 ? '' : 's'}'
                      '${look.books > 0 ? ', ${look.books} book${look.books == 1 ? '' : 's'}' : ''} in here.',
                      style: TextStyle(fontSize: 12, color: grey)),
                ),
                FilledButton(autofocus: look.folders.isEmpty, onPressed: () => Navigator.pop(context, p),
                    child: const Text('Use this folder')),
              ]),
            ))
          : null,
    );
  }
}
