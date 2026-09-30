import 'package:flutter/material.dart';

import '../api.dart';
import '../home_sections.dart';
import '../ondeck_hidden.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../settings.dart';
import '../view_prefs.dart';
import '../widgets/error_text.dart';
import '../widgets/display_panel.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import '../widgets/server_status.dart';
import 'about.dart';
import 'document.dart';
import 'downloads_screen.dart';

/// Every setting in one place (side menu > Settings), grouped, each group saying where it's kept: synced through
/// Komga (every device) or this device only. The reader's own panels stay for quick changes while reading.
/// Sections: Server & connection, Reading defaults, Reader, Display, Library & Home, Downloads, About.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut});
  final Komga api;
  final VoidCallback onSignOut;

  static const _hint = TextStyle(color: Color(0xFF9A9A9A));
  static const _small = TextStyle(color: Color(0xFF9A9A9A), fontSize: 12);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: const [FullscreenExit()]),
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
            _Card(title: 'Reading defaults', icon: Icons.menu_book_outlined, scope: 'Synced through Komga', children: [
              const Text("For every series you haven't adjusted. A series' own settings are changed in the reader "
                  '(Reader and Image settings).', style: _hint),
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
            ]),
            const _Card(title: 'Reader', icon: Icons.chrome_reader_mode_outlined, scope: 'This device', children: [
              Text('Page turn animation', style: _hint),
              PageTurnControl(),
              ReaderBehaviourControls(),
            ]),
            const _Card(title: 'Display', icon: Icons.brightness_6_outlined, scope: 'This device', children: [
              Text('Whole app, not just the reader (also in the reader\'s Reader settings)', style: _hint),
              ScreenBrightnessControls(),
              NightModeControls(),
            ]),
            _Card(title: 'Library & Home', icon: Icons.home_outlined, scope: 'Sections: this device · On deck: synced',
                children: [
              ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) => _posterRows()),
              const SizedBox(height: 10),
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
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Delete a downloaded book once it's read"),
                      subtitle: const Text('When it becomes read - here, offline, or on another device. A book open '
                          "in the reader goes when it's closed. Books already read when downloaded stay."),
                      value: d.deleteWhenRead,
                      onChanged: d.setDeleteWhenRead,
                    ),
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
                title: const Text('About $appName'),
                subtitle: const Text('Version, author, licence, credits'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AboutScreen(api: api))),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.new_releases_outlined),
                title: const Text("What's new"),
                subtitle: const Text('What changed in each build'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.whatsNew())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.menu_book_outlined),
                title: const Text('Read me'),
                subtitle: const Text('What the app does, getting started, where settings live'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.readMe())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.extension_outlined),
                title: const Text('Third-party software'),
                subtitle: const Text('Everything the app relies on, and its licences'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.thirdParty())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.report_outlined),
                title: const Text('Error log'),
                subtitle: const Text('The last errors, with their technical details (kept on this device)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ErrorLogScreen())),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restart_alt),
                title: const Text("Reset this device's settings"),
                subtitle: const Text('Reader, display, Home and library layout back to the defaults'),
                trailing: TextButton(onPressed: () => _resetDevice(context), child: const Text('Reset')),
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

  /// Poster size and poster text (Library & Home, this device).
  Widget _posterRows() {
    final s = AppSettings.instance, d = s.display;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Poster size', style: _hint),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SegmentedButton<PosterSize>(
          segments: [for (final p in PosterSize.values) ButtonSegment(value: p, label: Text(p.label))],
          selected: {d.posterSize},
          showSelectedIcon: false,
          onSelectionChanged: (v) => s.setDisplay(d.copyWith(posterSize: v.first)),
        ),
      ),
      const SizedBox(height: 4),
      const Text('Book posters show', style: _hint),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Series #, then title')),
            ButtonSegment(value: true, label: Text('Title only')),
          ],
          selected: {d.posterTitleOnly},
          showSelectedIcon: false,
          onSelectionChanged: (v) => s.setDisplay(d.copyWith(posterTitleOnly: v.first)),
        ),
      ),
    ]);
  }

  /// Everything kept on this device only, back to the defaults - after asking. Synced settings (reading defaults,
  /// series settings, pins, On deck), the sign-in, the offline mode switch and the downloaded books stay.
  Future<void> _resetDevice(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Reset this device's settings?"),
        content: const Text('Back to the defaults: page turn and the other Reader settings, screen brightness and '
            "night mode, poster size, Home's sections, every screen's remembered filter and sort, \"If Komga can't be "
            "reached\", and the download limit and Delete once read.\n\nNot touched: settings synced through Komga "
            '(reading defaults, series settings, pins, On deck), your sign-in and your downloaded books.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    AppSettings.instance.setDisplay(const DisplayPrefs());
    await HomeSections.instance.reset();
    await ViewPrefs.clearAll();
    if (Connection.instance.available) await Connection.instance.setAutoSwitch(false);
    if (Downloads.instance.ready) {
      await Downloads.instance.setCap(Downloads.defaultCap);
      await Downloads.instance.setDeleteWhenRead(false);
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text("This device's settings are back to the defaults")));
    }
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

/// Rounded section card with an icon + title header (same look as the About screen).
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
