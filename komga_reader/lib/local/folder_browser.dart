import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'device_folders.dart';
import 'library_fs.dart';

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
  Object? _error;
  int _loads = 0;

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
    if (mounted && _path == null && places != null && places.length == 1) await _open(places.single);
  }

  static String _sep(String p) => p.contains('\\') ? '\\' : '/';
  static String _join(String p, String name) => p.endsWith(_sep(p)) ? '$p$name' : '$p${_sep(p)}$name';

  /// One level up; null: the places.
  String? get _up {
    final p = _path;
    if (p == null || (_root != null && p == _root)) return null;
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
      _look = null;
      _error = null;
    });
    try {
      if (path == null) {
        final places = await widget.source.places();
        if (mounted && load == _loads) setState(() => _places = places);
      } else {
        final look = await widget.source.look(path);
        if (mounted && load == _loads) setState(() => _look = look);
      }
    } catch (e) {
      if (mounted && load == _loads) setState(() => _error = e);
    }
  }

  Future<void> _open(Place p) async {
    if (!await widget.source.openPlace(context)) return;
    _root = p.path;
    _rootLabel = p.label;
    await _go(p.path);
  }

  Future<void> _type() async {
    final c = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type a folder'),
        content: TextField(controller: c, autofocus: true, autocorrect: false, enableSuggestions: false,
            decoration: InputDecoration(labelText: 'Folder', hintText: switch (defaultTargetPlatform) {
              TargetPlatform.windows => r'C:\Comics',
              TargetPlatform.android => '/storage/emulated/0/Comics',
              _ => 'Comics',
            }),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
        ],
      ),
    );
    if (path != null && path.trim().isNotEmpty && mounted) Navigator.pop(context, path.trim());
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
                            ListTile(autofocus: i == 0, leading: Icon(pl.path.startsWith('/storage/') &&
                                    !pl.path.startsWith('/storage/emulated') ? Icons.sd_card_outlined : Icons.folder_outlined),
                                title: Text(pl.label), onTap: () => _open(pl)),
                          ListTile(autofocus: places.isEmpty, leading: const Icon(Icons.edit_outlined),
                              title: const Text('Type a folder…'), onTap: _type),
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
