import 'package:flutter/material.dart';

import '../api.dart';
import '../ondeck_hidden.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import 'downloads_screen.dart';
import 'info.dart';

/// Every setting in one place (side menu > App settings), grouped, each group saying where it's kept: synced through
/// Komga (every device) or this device only. The reader's own panels stay for quick changes while reading.
/// Sections: Server & connection, Reading, Display, Library & Home, Downloads, About.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut});
  final Komga api;
  final VoidCallback onSignOut;

  static const _hint = TextStyle(color: Color(0xFF9A9A9A));
  static const _small = TextStyle(color: Color(0xFF9A9A9A), fontSize: 12);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App settings'), actions: const [FullscreenExit()]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
            _Card(title: 'Server & connection', icon: Icons.dns_outlined, scope: 'This device', children: [
              Row(children: [
                const SizedBox(width: 90, child: Text('Address', style: _hint)),
                Expanded(child: SelectableText(api.baseUrl)),
              ]),
              const SizedBox(height: 8),
              ServerStatus(api: api),
              if (Connection.instance.available) ...[
                const SizedBox(height: 6),
                ListenableBuilder(
                  listenable: Connection.instance,
                  builder: (context, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(Connection.instance.offline ? Icons.cloud_off : Icons.cloud_outlined),
                    title: const Text('Offline mode'),
                    subtitle: Text(Connection.instance.offline ? 'Showing downloaded books only' : 'Connected to Komga'),
                    value: Connection.instance.offline,
                    onChanged: (v) => Connection.instance.setForcedOffline(v),
                  ),
                ),
                ListenableBuilder(
                  listenable: Connection.instance,
                  builder: (context, _) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text("If Komga can't be reached"),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(Connection.instance.autoSwitch
                          ? 'Switches to the downloaded books and back by itself (back online once the book is closed)'
                          : 'Asks before switching to the downloaded books, and offers to go back online'),
                      const SizedBox(height: 8),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: false, label: Text('Ask first')),
                          ButtonSegment(value: true, label: Text('Automatic')),
                        ],
                        selected: {Connection.instance.autoSwitch},
                        onSelectionChanged: (s) => Connection.instance.setAutoSwitch(s.first),
                      ),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _signOut(context),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out / change server'),
                ),
              ),
            ]),
            _Card(title: 'Reading', icon: Icons.menu_book_outlined, scope: 'Defaults synced through Komga', children: [
              const Text("Defaults for every series you haven't adjusted. A series' own settings are changed in the "
                  "reader (Reader and Image settings).", style: _hint),
              const ReadingDefaults(),
              const SizedBox(height: 6),
              ListenableBuilder(
                listenable: AppSettings.instance,
                builder: (context, _) {
                  final n = AppSettings.instance.series.length;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.tune),
                    title: Text(n == 0
                        ? 'Every series follows the defaults'
                        : '$n series ${n == 1 ? 'has its' : 'have their'} own settings'),
                    trailing: n == 0 ? null : TextButton(onPressed: () => _resetSeries(context, n), child: const Text('Reset all')),
                  );
                },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('PAGE TURN · THIS DEVICE', style: TextStyle(fontSize: 11, letterSpacing: 1.1, color: Color(0xFF9A9A9A))),
              ),
              const PageTurnControl(),
            ]),
            const _Card(title: 'Display', icon: Icons.brightness_6_outlined, scope: 'This device', children: [
              Text('Whole app, not just the reader (also in the reader\'s Reader settings)', style: _hint),
              ScreenBrightnessControls(),
              NightModeControls(),
            ]),
            _Card(title: 'Library & Home', icon: Icons.home_outlined, scope: 'Sections: this device · On deck: synced',
                children: [
              const Text('Sections on Home: switch on or off, and move with ▲▼ or the handle', style: _hint),
              const HomeSectionsEditor(),
              ListenableBuilder(
                listenable: OnDeckHidden.instance,
                builder: (context, _) {
                  final h = OnDeckHidden.instance;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.visibility_off_outlined),
                    title: const Text('Hidden from On deck'),
                    subtitle: Text(h.isEmpty
                        ? 'Nothing (hide a series or book from its menu)'
                        : '${h.series.length} series · ${h.books.length} book${h.books.length == 1 ? '' : 's'}'),
                    trailing: h.isEmpty ? null : TextButton(onPressed: h.clear, child: const Text('Show all again')),
                  );
                },
              ),
            ]),
            if (Downloads.instance.ready)
              ListenableBuilder(
                listenable: Downloads.instance,
                builder: (context, _) {
                  final d = Downloads.instance;
                  const choices = <int?>[2, 5, 10, 20, 50, 100, null]; // GB; null = no limit
                  final current = d.capBytes == null ? null : (d.capBytes! / Downloads.gb).round();
                  return _Card(title: 'Downloads', icon: Icons.download_outlined, scope: 'This device', children: [
                    Text('${DownloadsScreen.size(d.usedBytes)} used on this device', style: _hint),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Expanded(child: Text('Storage limit')),
                      DropdownButton<int?>(
                        value: choices.contains(current) ? current : 10,
                        items: [
                          for (final c in choices) DropdownMenuItem(value: c, child: Text(c == null ? 'No limit' : '$c GB')),
                        ],
                        onChanged: (c) => d.setCap(c == null ? null : c * Downloads.gb),
                      ),
                    ]),
                    const Text('A book that would go over the limit stops in the queue with a note, and carries on by '
                        'itself when the limit is raised.', style: _small),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadsScreen())),
                        icon: const Icon(Icons.download_for_offline_outlined),
                        label: const Text('Open Downloads'),
                      ),
                    ),
                  ]);
                },
              ),
            _Card(title: 'About', icon: Icons.info_outline, children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: const Text('Info'),
                subtitle: const Text('Version, licences, Komga credits'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => InfoScreen(api: api))),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _signOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('The API key is removed from this device; you can sign in again or connect to a different '
            'server. Downloads and settings stay.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    onSignOut();
  }

  Future<void> _resetSeries(BuildContext context, int n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset $n series to the defaults?'),
        content: const Text("Their own fit, reading direction and image settings are removed, on every device (they're "
            'synced through Komga). They follow the defaults above from then on.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset all')),
        ],
      ),
    );
    if (ok == true) AppSettings.instance.resetAllSeries();
  }
}

/// Rounded section card with an icon + title header (same look as the Info screen).
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children, this.scope});
  final String title;
  final String? scope; // where it's kept: "This device" / synced through Komga
  final IconData icon;
  final List<Widget> children;
  @override
  // A Material (not a coloured box) so the switch rows' ripple and remote focus highlight show on the card.
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Material(
          color: const Color(0xFF15161A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF26282E)),
          ),
          child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 18, color: const Color(0xFF9A9A9A)),
            const SizedBox(width: 8),
            Text(title.toUpperCase(),
                style: const TextStyle(fontSize: 12, letterSpacing: 1.2, color: Color(0xFF9A9A9A), fontWeight: FontWeight.w600)),
            const Spacer(),
            if (scope != null)
              Flexible(
                flex: 3,
                child: Text(scope!, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6E7380))),
              ),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
          ),
        ),
      );
}
