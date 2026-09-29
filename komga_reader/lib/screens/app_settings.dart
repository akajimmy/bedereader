import 'package:flutter/material.dart';

import '../api.dart';
import '../home_sections.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../widgets/display_panel.dart';
import '../widgets/home_sections_editor.dart';
import 'downloads_screen.dart';

/// App-wide settings (side menu > App settings; not reachable from the reader, as reader/image settings are the
/// reader's). Starts with the server and the Home sections; offline/download settings will join it (1.1).
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut});
  final Komga api;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final sections = HomeSections.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListenableBuilder(
            listenable: sections,
            builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
              _Card(title: 'Server', icon: Icons.dns_outlined, children: [
                Row(children: [
                  const SizedBox(width: 90, child: Text('Address', style: TextStyle(color: Color(0xFF9A9A9A)))),
                  Expanded(child: SelectableText(api.baseUrl)),
                ]),
                if (Connection.instance.available) ListenableBuilder(
                  listenable: Connection.instance,
                  builder: (context, _) => SwitchListTile(
                    secondary: Icon(Connection.instance.offline ? Icons.cloud_off : Icons.cloud_outlined),
                    title: const Text('Offline mode'),
                    subtitle: Text(Connection.instance.offline ? 'Showing downloaded books only' : 'Connected to Komga'),
                    value: Connection.instance.offline,
                    onChanged: (v) => Connection.instance.setForcedOffline(v),
                  ),
                ),
                if (Connection.instance.available) ListenableBuilder(
                  listenable: Connection.instance,
                  builder: (context, _) => ListTile(
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
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    autofocus: true,
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Sign out?'),
                          content: const Text('The API key is removed from this device; you can sign in again or '
                              'connect to a different server. Downloads and settings stay.'),
                          actions: [
                            TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
                          ],
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      onSignOut();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out / change server'),
                  ),
                ),
              ]),
              if (Downloads.instance.ready)
                ListenableBuilder(
                  listenable: Downloads.instance,
                  builder: (context, _) {
                    final d = Downloads.instance;
                    const choices = <int?>[2, 5, 10, 20, 50, 100, null]; // GB; null = no limit
                    final current = d.capBytes == null ? null : (d.capBytes! / Downloads.gb).round();
                    return _Card(title: 'Downloads', icon: Icons.download_outlined, children: [
                      Text('${DownloadsScreen.size(d.usedBytes)} used on this device',
                          style: const TextStyle(color: Color(0xFF9A9A9A))),
                      const SizedBox(height: 8),
                      Row(children: [
                        const Expanded(child: Text('Storage limit')),
                        DropdownButton<int?>(
                          value: choices.contains(current) ? current : 10,
                          items: [
                            for (final c in choices)
                              DropdownMenuItem(value: c, child: Text(c == null ? 'No limit' : '$c GB')),
                          ],
                          onChanged: (c) => d.setCap(c == null ? null : c * Downloads.gb),
                        ),
                      ]),
                      const Text('A book that would go over the limit stops in the queue with a note, and carries on by itself when the limit is raised.',
                          style: TextStyle(color: Color(0xFF9A9A9A), fontSize: 12)),
                    ]);
                  },
                ),
              const _Card(title: 'Display', icon: Icons.nightlight_outlined, children: [
                Text('Whole app, this device (also in the reader\'s Reader settings)',
                    style: TextStyle(color: Color(0xFF9A9A9A))),
                NightModeControls(),
              ]),
              _Card(title: 'Home', icon: Icons.home_outlined, children: [
                const Text('Sections on Home: switch on or off, and move with ▲▼ or the handle',
                    style: TextStyle(color: Color(0xFF9A9A9A))),
                const HomeSectionsEditor(),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Rounded section card with an icon + title header (same look as the Info screen).
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children});
  final String title;
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
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
          ),
        ),
      );
}
