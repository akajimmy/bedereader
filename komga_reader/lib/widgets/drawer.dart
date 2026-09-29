import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../screens/app_settings.dart';
import '../screens/downloads_screen.dart';
import '../screens/info.dart';
import '../screens/library.dart';
import 'display_panel.dart';

/// Side navigation: Home, each library, sign out. Home is always the root route, so every entry first pops back to it.
class AppDrawer extends StatefulWidget {
  const AppDrawer({super.key, required this.api, required this.onSignOut});
  final Komga api;
  final VoidCallback onSignOut;
  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  List<dynamic> _libraries = [];

  @override
  void initState() {
    super.initState();
    widget.api.libraries().then((l) { if (mounted) setState(() => _libraries = l); }).catchError((_) {});
  }

  void _go(String? libraryId, {bool home = false}) {
    final nav = Navigator.of(context);
    Scaffold.maybeOf(context)?.closeDrawer(); // popUntil alone leaves the drawer open when already on Home
    nav.popUntil((r) => r.isFirst);
    if (!home) {
      nav.push(MaterialPageRoute(builder: (_) => LibraryScreen(api: widget.api, onSignOut: widget.onSignOut, libraryId: libraryId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Remote: Right closes the menu (focus goes back to where it was, see DrawerEdge)
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowRight) {
          Scaffold.maybeOf(context)?.closeDrawer();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _drawer(context),
    );
  }

  Widget _drawer(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF111113),
      child: SafeArea(
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 20, 12),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/icon.png', width: 36, height: 36,
                    errorBuilder: (_, __, ___) => const SizedBox(width: 36, height: 36)),
              ),
              const SizedBox(width: 12),
              const Text('Komga Reader', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
            ]),
          ),
          ListTile(autofocus: true, leading: const Icon(Icons.home_outlined), title: const Text('Home'),
              onTap: () => _go(null, home: true)),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.collections_bookmark_outlined), title: const Text('All libraries'),
              onTap: () => _go(null)),
          for (final l in _libraries)
            ListTile(leading: const Icon(Icons.folder_outlined), title: Text(l['name'] as String),
                onTap: () => _go(l['id'] as String)),
          if (Connection.instance.available)
            ListenableBuilder(
            listenable: Connection.instance,
            builder: (context, _) => SwitchListTile(
              secondary: Icon(Connection.instance.offline ? Icons.cloud_off : Icons.cloud_outlined),
              title: const Text('Offline mode'),
              subtitle: Text(Connection.instance.offline ? 'Showing downloaded books only' : 'Connected to Komga'),
              value: Connection.instance.offline,
              onChanged: (v) => Connection.instance.setForcedOffline(v),
            ),
          ),
          if (Downloads.instance.ready)
            ListenableBuilder(
              listenable: Downloads.instance,
              builder: (context, _) {
                final q = Downloads.instance.queue.length;
                return ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Downloads'),
                  trailing: q == 0 ? null : Badge(label: Text('$q')), // books waiting or downloading
                  onTap: () {
                    Scaffold.maybeOf(context)?.closeDrawer();
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadsScreen()));
                  },
                );
              },
            ),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('App settings'),
              onTap: () {
                Scaffold.maybeOf(context)?.closeDrawer();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AppSettingsScreen(api: widget.api, onSignOut: widget.onSignOut)));
              }),
          ListTile(leading: const Icon(Icons.tune), title: const Text('Reader settings (brightness, night mode)'),
              onTap: () { Navigator.of(context).pop(); showReaderPanel(context); }),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('Info'),
              onTap: () {
                Scaffold.maybeOf(context)?.closeDrawer();
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => InfoScreen(api: widget.api)));
              }),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'),
              onTap: () { Navigator.of(context).popUntil((r) => r.isFirst); widget.onSignOut(); }),
        ]),
      ),
    );
  }
}

/// Wraps a screen body: pressing Left on the leftmost item of a row (nothing further left to move to) opens the side
/// menu, whose first entry takes focus. When the menu closes, focus returns to the item it came from - hook [restore]
/// up to the Scaffold's onDrawerChanged.
class DrawerEdge extends StatefulWidget {
  const DrawerEdge({super.key, required this.scaffoldKey, required this.child});
  final GlobalKey<ScaffoldState> scaffoldKey;
  final Widget child;
  @override
  State<DrawerEdge> createState() => DrawerEdgeState();
}

class DrawerEdgeState extends State<DrawerEdge> {
  FocusNode? _before;

  /// Call when the drawer closes.
  void restore() {
    final n = _before;
    _before = null;
    if (n != null && n.context != null) n.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    final f = FocusManager.instance.primaryFocus;
    if (f == null) return KeyEventResult.ignored;
    if (f.focusInDirection(TraversalDirection.left)) return KeyEventResult.handled; // normal move
    _before = f;
    widget.scaffoldKey.currentState?.openDrawer();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
}
