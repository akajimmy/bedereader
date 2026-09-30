import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../hidden_libraries.dart';
import '../home_sections.dart';
import '../ondeck_hidden.dart';
import '../reader_keys.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../screen.dart';
import '../settings.dart';
import '../view_prefs.dart';
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import '../widgets/server_status.dart';
import '../widgets/setting_rows.dart';
import 'about.dart';
import 'document.dart';
import 'downloads_screen.dart';

/// The pages of Settings, in order.
enum SettingsPage { server, defaults, reader, keys, display, library, downloads, about }

extension on SettingsPage {
  String get label => switch (this) {
        SettingsPage.server => 'Server',
        SettingsPage.defaults => 'Reading defaults',
        SettingsPage.reader => 'Reader',
        SettingsPage.display => 'Display',
        SettingsPage.keys => 'Remote and keys',
        SettingsPage.library => 'Library & Home',
        SettingsPage.downloads => 'Downloads',
        SettingsPage.about => 'About',
      };
  IconData get icon => switch (this) {
        SettingsPage.server => Icons.dns_outlined,
        SettingsPage.defaults => Icons.menu_book_outlined,
        SettingsPage.reader => Icons.chrome_reader_mode_outlined,
        SettingsPage.display => Icons.brightness_6_outlined,
        SettingsPage.keys => Icons.settings_remote_outlined,
        SettingsPage.library => Icons.grid_view_outlined,
        SettingsPage.downloads => Icons.download_outlined,
        SettingsPage.about => Icons.info_outline,
      };

  /// Where the page's settings are kept, said once under its title.
  String? get scope => switch (this) {
        SettingsPage.defaults => 'Synced through Komga - every device',
        SettingsPage.library => 'Kept on this device, except On deck (synced)',
        SettingsPage.about => null,
        _ => 'Kept on this device',
      };
}

/// Every setting (side menu > Settings), one page at a time (user, 2026-09-30): the pages listed down the side on a
/// wide screen, or across the top as a table of contents on a narrow one. The rows are the shared setting rows
/// (widgets/setting_rows.dart), the same as in the reader's panels.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut, this.initialPage = SettingsPage.server});
  final Komga api;
  final VoidCallback onSignOut;
  final SettingsPage initialPage;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late SettingsPage _page = widget.initialPage;

  List<SettingsPage> get _pages => [
        for (final p in SettingsPage.values)
          if (p != SettingsPage.downloads || Downloads.instance.ready) p,
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: const [FullscreenExit()]),
      body: LayoutBuilder(builder: (context, box) {
        final page = _pageBody(context);
        if (box.maxWidth >= 760) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 230,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 8, 24), children: [
                for (final p in _pages) _NavItem(page: p, selected: p == _page, onTap: () => _go(p)),
              ]),
            ),
            const VerticalDivider(width: 1, color: Color(0xFF26282E)),
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ListView(padding: const EdgeInsets.fromLTRB(24, 16, 24, 40), children: page),
                ),
              ),
            ),
          ]);
        }
        // narrow: the pages as a table of contents at the top, then the chosen page
        return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 40), children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in _pages)
              ChoiceChip(
                avatar: Icon(p.icon, size: 18),
                label: Text(p.label),
                selected: p == _page,
                showCheckmark: false,
                onSelected: (_) => _go(p),
              ),
          ]),
          const SizedBox(height: 18),
          ...page,
        ]);
      }),
    );
  }

  void _go(SettingsPage p) => setState(() => _page = p);

  List<Widget> _pageBody(BuildContext context) {
    final p = _page;
    return [
      Text(p.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
      if (p.scope != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(p.scope!, style: const TextStyle(color: hintColour))),
      const SizedBox(height: 16),
      // the page's segmented choices share one width (a fresh column per page)
      SettingsColumn(key: ValueKey(p), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (p) {
        SettingsPage.server => _server(context),
        SettingsPage.defaults => [_live(_defaults)],
        SettingsPage.reader => [_live(_reader)],
        SettingsPage.display => [_live(_display)],
        SettingsPage.library => _library(),
        SettingsPage.downloads => [ListenableBuilder(listenable: Downloads.instance, builder: (context, _) => _downloads(context))],
        SettingsPage.keys => [ListenableBuilder(listenable: ReaderKeys.instance, builder: (context, _) => _keys(context))],
        SettingsPage.about => _about(context),
      })),
    ];
  }

  /// Rebuilds [build] when the settings change.
  Widget _live(Widget Function(AppSettings s) build) =>
      ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) => build(AppSettings.instance));

  // ---- Server ----------------------------------------------------------------------------------------------------
  List<Widget> _server(BuildContext context) => [
        SettingsGroup(title: 'Komga', children: [
          SettingRow(title: 'Address', trailing: SelectableText(widget.api.baseUrl, textAlign: TextAlign.right)),
          Padding(padding: const EdgeInsets.all(10), child: ServerStatus(api: widget.api)),
          ActionRow(
            title: 'Sign out / change server',
            icon: Icons.logout,
            subtitle: 'Downloads and settings stay',
            onTap: () => _signOut(context),
          ),
        ]),
        if (Connection.instance.available)
          ListenableBuilder(
            listenable: Connection.instance,
            builder: (context, _) {
              final c = Connection.instance;
              return SettingsGroup(title: 'Offline', children: [
                SwitchRow(
                  title: 'Offline mode',
                  subtitle: c.offline ? 'Showing downloaded books only' : 'Connected to Komga',
                  value: c.offline,
                  onChanged: c.setForcedOffline,
                ),
                SegmentRow<bool>(
                  title: "If Komga can't be reached",
                  subtitle: c.autoSwitch
                      ? 'Switches to downloaded books and back by itself'
                      : 'Asks before switching to downloaded books',
                  choices: const [Choice(false, 'Ask first'), Choice(true, 'Automatic')],
                  value: c.autoSwitch,
                  onChanged: c.setAutoSwitch,
                ),
              ]);
            },
          ),
      ];

  // ---- Reading defaults ------------------------------------------------------------------------------------------
  Widget _defaults(AppSettings s) {
    final p = s.defaults;
    final n = s.series.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
        child: Text("For every series you haven't adjusted. A series' own settings are changed in the reader.",
            style: TextStyle(color: hintColour)),
      ),
      SettingsGroup(title: 'Pages', children: fitDirectionRows(p, s.setDefault)),
      SettingsGroup(title: 'Image', children: [
        ...imageRows(p, s.setDefault),
        ActionRow(title: 'Image settings back to the original scan',
            button: TextButton(onPressed: () => s.setDefault(p.imageReset()), child: const Text('Reset to original'))),
      ]),
      SettingsGroup(title: 'Series with their own settings', children: [
        ActionRow(
          title: n == 0 ? 'Every series follows the defaults' : '$n series ${n == 1 ? 'has its' : 'have their'} own settings',
          button: n == 0 ? null : TextButton(onPressed: () => _resetSeries(context, n), child: const Text('Reset all')),
        ),
      ]),
    ]);
  }

  // ---- Reader ----------------------------------------------------------------------------------------------------
  Widget _reader(AppSettings s) {
    final d = s.display;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: 'Turning pages', children: [
        pageTurnRow(s),
        doubleTapRow(s),
      ]),
      // what's drawn over the page (set once, so Settings only - except the page number, also in the Reader panel)
      SettingsGroup(title: 'On the page', children: [
        pageNumberRow(s),
        clockRow(s),
        progressBarRow(s),
      ]),
      SettingsGroup(title: 'Moving on', children: [
        SegmentRow<MidBook>(
          title: "'Next book' before the last page", // wording: user, 2026-09-30
          subtitle: 'What should happen to the current book?',
          choices: [for (final m in const [MidBook.markRead, MidBook.keep, MidBook.ask]) Choice(m, m.label)],
          value: d.midBook,
          onChanged: (m) => s.setDisplay(d.copyWith(midBook: m)),
        ),
      ]),
      SettingsGroup(title: 'Screen', children: [
        backgroundRow(s),
        if (canRotate) rotationRow(s),
        screenOnRow(s),
      ]),
    ]);
  }

  // ---- Remote and keys -------------------------------------------------------------------------------------------
  Widget _keys(BuildContext context) {
    final k = ReaderKeys.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the volume keys live here with the other keys (tablet bug, 2026-09-30), not under Reader
      if (hasVolumeKeys)
        _live((s) => SettingsGroup(title: 'Volume keys', children: [
              SwitchRow(title: 'Volume keys turn pages', subtitle: 'Down: next page, up: previous',
                  value: s.display.volumeKeys, onChanged: (v) => s.setDisplay(s.display.copyWith(volumeKeys: v))),
            ])),
      SettingsGroup(title: 'In the reader, with the controls hidden', children: [
        for (final a in ReaderAction.values) _KeyRow(action: a, onAdd: () => _addKey(context, a)),
        const NoteRow('For a book read right to left, Left and Right swap. Shift+Space always goes back. Once the '
            'controls are up, the arrows and OK move around them.'),
        ActionRow(
          title: 'Back to the usual keys',
          button: TextButton(onPressed: k.isDefault ? null : k.reset, child: const Text('Reset keys')),
        ),
      ]),
    ]);
  }

  /// "+ Add": the next key pressed (on the remote or a keyboard) goes to [action].
  Future<void> _addKey(BuildContext context, ReaderAction action) async {
    final key = await showDialog<LogicalKeyboardKey>(
      context: context,
      builder: (ctx) => Focus(
        autofocus: true,
        // every key is the answer, OK and Esc included - nothing in the dialog takes the remote's focus
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent) Navigator.pop(ctx, e.logicalKey);
          return KeyEventResult.handled;
        },
        child: AlertDialog(
          title: Text('${action.label}: press a key'),
          content: const Text('Press the key on the remote or keyboard. (Back, or a tap outside, cancels.)'),
          actions: [
            ExcludeFocus(child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))), // touch
          ],
        ),
      ),
    );
    if (key == null || !context.mounted) return;
    final was = await ReaderKeys.instance.assign(action, key);
    if (context.mounted && was != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('${ReaderKeys.nameOf(key)} now does ${action.label.toLowerCase()} (was: ${was.label.toLowerCase()})')));
    }
  }

  // ---- Display ---------------------------------------------------------------------------------------------------
  Widget _display(AppSettings s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingsGroup(title: 'Brightness', children: brightnessRows(s)),
        SettingsGroup(title: 'Night', children: [
          ...nightRows(s),
          SwitchRow(
            title: 'On a schedule',
            subtitle: 'Turns night mode on and off by itself; you can still switch it in between',
            value: s.display.nightSchedule,
            onChanged: (v) => s.setDisplay(s.display.copyWith(nightSchedule: v)),
          ),
          if (s.display.nightSchedule)
            SettingRow(
              title: 'From / to',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                _timeButton(s.display.nightFrom, 'Night mode starts',
                    (m) => s.setDisplay(s.display.copyWith(nightFrom: m))),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('–')),
                _timeButton(s.display.nightTo, 'Night mode ends', (m) => s.setDisplay(s.display.copyWith(nightTo: m))),
              ]),
            ),
        ]),
        SettingsGroup(title: 'Look', children: [
          SegmentRow<double>(
            title: 'Text size',
            subtitle: 'This app only, on top of the device\'s own',
            choices: [for (final t in DisplayPrefs.textScales) Choice(t, '${(t * 100).round()}%')],
            value: s.display.textScale,
            onChanged: (t) => s.setDisplay(s.display.copyWith(textScale: t)),
          ),
          // fourteen swatches: under the label, wrapping, rather than squeezed beside it
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Accent colour', style: TextStyle(fontSize: 14.5)),
              const SizedBox(height: 6),
              Wrap(spacing: 2, runSpacing: 2, children: [
                for (final a in Accent.values)
                  ColourSwatch(colour: a.colour, label: a.label, selected: s.display.accent == a,
                      onTap: () => s.setDisplay(s.display.copyWith(accent: a))),
              ]),
            ]),
          ),
        ]),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('The whole app, not just the reader. Also in the reader\'s Reader panel.',
              style: TextStyle(color: hintColour, fontSize: 12)),
        ),
      ]);

  /// A time (minutes after midnight) as a button that opens the time picker.
  Widget _timeButton(int minutes, String help, ValueChanged<int> onPicked) {
    final t = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
    return OutlinedButton(
      onPressed: () async {
        final picked = await showTimePicker(context: context, initialTime: t, helpText: help);
        if (picked != null) onPicked(picked.hour * 60 + picked.minute);
      },
      child: Text(t.format(context)),
    );
  }

  // ---- Library & Home --------------------------------------------------------------------------------------------
  List<Widget> _library() => [
        _live((s) {
          final d = s.display;
          return SettingsGroup(title: 'Posters', children: [
            SegmentRow<PosterSize>(
              title: 'Size',
              choices: [for (final p in PosterSize.values) Choice(p, p.label)],
              value: d.posterSize,
              onChanged: (p) => s.setDisplay(d.copyWith(posterSize: p)),
            ),
            SegmentRow<bool>(
              title: 'Book posters show',
              choices: const [Choice(false, 'Series # and title'), Choice(true, 'Title only')],
              value: d.posterTitleOnly,
              onChanged: (v) => s.setDisplay(d.copyWith(posterTitleOnly: v)),
            ),
          ]);
        }),
        _librariesShown(),
        const SettingsGroup(title: 'Home sections', children: [
          NoteRow('Switch on or off; reorder with the arrows or the handle'),
          Padding(padding: EdgeInsets.only(left: 6, bottom: 4), child: HomeSectionsEditor()),
        ]),
        ListenableBuilder(
          listenable: OnDeckHidden.instance,
          builder: (context, _) {
            final h = OnDeckHidden.instance;
            return SettingsGroup(title: 'On deck', children: [
              ActionRow(
                title: 'Hidden from On deck',
                subtitle: h.isEmpty
                    ? 'Nothing (hide a series or book from its menu)'
                    : '${h.series.length} series · ${h.books.length} book${h.books.length == 1 ? '' : 's'}',
                button: h.isEmpty ? null : TextButton(onPressed: h.clear, child: const Text('Show all again')),
              ),
            ]);
          },
        ),
      ];

  late final Future<List<dynamic>> _allLibraries = widget.api.libraries();

  /// A switch per library: shown on this device or not. The last one shown can't be switched off.
  Widget _librariesShown() => FutureBuilder<List<dynamic>>(
        future: _allLibraries,
        builder: (context, snap) {
          final libs = snap.data;
          if (libs == null || libs.isEmpty) return const SizedBox.shrink(); // can't list them (offline, say)
          return ListenableBuilder(
            listenable: HiddenLibraries.instance,
            builder: (context, _) {
              final h = HiddenLibraries.instance;
              final shown = libs.where((l) => !h.isHidden(l['id'] as String?)).length;
              return SettingsGroup(title: 'Libraries on this device', children: [
                const NoteRow('Hidden ones are left out everywhere in the app on this device'),
                for (final l in libs)
                  SwitchRow(
                    title: l['name'] as String? ?? '',
                    value: !h.isHidden(l['id'] as String?),
                    onChanged: !h.isHidden(l['id'] as String?) && shown <= 1
                        ? null // the last one shown stays
                        : (v) => h.setHidden(l['id'] as String, !v),
                  ),
              ]);
            },
          );
        },
      );

  // ---- Downloads -------------------------------------------------------------------------------------------------
  Widget _downloads(BuildContext context) {
    final d = Downloads.instance;
    const choices = <int?>[2, 5, 10, 20, 50, 100, null]; // GB; null = no limit
    final current = d.capBytes == null ? null : (d.capBytes! / Downloads.gb).round();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: 'Storage', children: [
        SettingRow(
          title: 'Storage limit',
          subtitle: '${DownloadsScreen.size(d.usedBytes)} used on this device',
          trailing: DropdownButton<int?>(
            value: choices.contains(current) ? current : 10,
            underline: const SizedBox.shrink(),
            items: [for (final c in choices) DropdownMenuItem(value: c, child: Text(c == null ? 'No limit' : '$c GB'))],
            onChanged: (c) => d.setCap(c == null ? null : c * Downloads.gb),
          ),
        ),
        const NoteRow("A book that won't fit stops in the queue, and carries on when space is available."),
        SegmentRow<DeleteRead>(
          title: "Delete a downloaded book once it's read",
          subtitle: switch (d.deleteRead) {
            DeleteRead.never => 'Downloads stay until you remove them',
            DeleteRead.ask => 'Asks, once no book is open (read here, offline or elsewhere)',
            DeleteRead.always => 'Read here, offline or elsewhere; an open book goes when you close it',
          },
          choices: const [Choice(DeleteRead.never, 'Never'), Choice(DeleteRead.ask, 'Ask'), Choice(DeleteRead.always, 'Always')],
          value: d.deleteRead,
          onChanged: d.setDeleteRead,
        ),
        ActionRow(
          title: 'Open Downloads',
          icon: Icons.download_for_offline_outlined,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadsScreen())),
        ),
      ]),
    ]);
  }

  // ---- About -----------------------------------------------------------------------------------------------------
  List<Widget> _about(BuildContext context) {
    void open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    return [
      SettingsGroup(title: appName, children: [
        ActionRow(title: 'About $appName', subtitle: 'Version, author, licence, credits', icon: Icons.info_outline,
            onTap: () => open(AboutScreen(api: widget.api))),
        ActionRow(title: "What's new", subtitle: 'What changed in each build', icon: Icons.new_releases_outlined,
            onTap: () => open(DocumentScreen.whatsNew())),
        ActionRow(title: 'Read me', subtitle: 'What the app does, getting started, where settings live',
            icon: Icons.menu_book_outlined, onTap: () => open(DocumentScreen.readMe())),
        ActionRow(title: 'Third-party software', subtitle: 'Everything the app relies on, and its licences',
            icon: Icons.extension_outlined, onTap: () => open(DocumentScreen.thirdParty())),
        ActionRow(title: 'Error log', subtitle: 'The last errors, with their technical details', icon: Icons.report_outlined,
            onTap: () => open(const ErrorLogScreen())),
      ]),
      SettingsGroup(title: 'This device', children: [
        ActionRow(
          title: "Reset this device's settings",
          subtitle: 'Reader, display, Home and library layout back to the defaults',
          icon: Icons.restart_alt,
          button: TextButton(onPressed: () => _resetDevice(context), child: const Text('Reset')),
        ),
      ]),
    ];
  }

  // ---- confirmations ---------------------------------------------------------------------------------------------
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
    widget.onSignOut();
  }

  /// Everything kept on this device only, back to the defaults - after asking. Synced settings (reading defaults,
  /// series settings, pins, On deck), the sign-in, the offline mode switch and the downloaded books stay.
  Future<void> _resetDevice(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Reset this device's settings?"),
        content: const Text('Back to the defaults: the Reader page, screen brightness, night mode and its schedule, text '
            "size and accent colour, the reader's keys, posters, the libraries shown, Home "
            "sections, every screen's remembered filter and sort, \"If Komga can't be reached\", and the download "
            'limit and Delete once read.\n\nNot touched: settings synced through Komga (reading defaults, series '
            'settings, pins, On deck), your sign-in and your downloaded books.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    AppSettings.instance.setDisplay(const DisplayPrefs());
    await HomeSections.instance.reset();
    await HiddenLibraries.instance.clear(); // every library shown again
    await ReaderKeys.instance.reset(); // the reader's usual keys
    await ViewPrefs.clearAll();
    if (Connection.instance.available) await Connection.instance.setAutoSwitch(false);
    if (Downloads.instance.ready) {
      await Downloads.instance.setCap(Downloads.defaultCap);
      await Downloads.instance.setDeleteRead(DeleteRead.never);
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text("This device's settings are back to the defaults")));
    }
  }

  Future<void> _resetSeries(BuildContext context, int n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reset $n series to the defaults?'),
        content: const Text("Their own fit, reading direction and image settings are removed, on every device (they're "
            'synced through Komga). They follow the defaults from then on.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset all')),
        ],
      ),
    );
    if (ok == true) AppSettings.instance.resetAllSeries();
  }
}

/// One job's keys as chips (select one to remove it - Show the controls always keeps one), and + Add.
class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.action, required this.onAdd});
  final ReaderAction action;
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) {
    final k = ReaderKeys.instance;
    final removable = k.canRemove(action);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(action.label, style: const TextStyle(fontSize: 14.5)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final key in k.keys[action]!)
            // one stop per key for the remote: the ✕ is drawn in the label, not a second (focusable) delete button
            // (user, 2026-09-30); OK or a tap removes it
            InputChip(
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(ReaderKeys.nameOf(key)),
                if (removable) ...[const SizedBox(width: 6), const Icon(Icons.close, size: 16)],
              ]),
              visualDensity: VisualDensity.compact,
              tooltip: removable ? 'Remove ${ReaderKeys.nameOf(key)}' : 'Show the controls keeps at least one key',
              onPressed: removable ? () => k.remove(action, key) : null,
            ),
          if (k.keys[action]!.isEmpty) const Text('No key', style: TextStyle(color: hintColour)),
          TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add, size: 18), label: const Text('Add')),
        ]),
      ]),
    );
  }
}

/// A page in the side list (wide screens).
class _NavItem extends StatelessWidget {
  const _NavItem({required this.page, required this.selected, required this.onTap});
  final SettingsPage page;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        selected: selected,
        selectedColor: accent,
        selectedTileColor: accent.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        leading: Icon(page.icon, size: 22),
        minLeadingWidth: 24,
        title: Text(page.label, style: const TextStyle(fontSize: 14.5)),
        onTap: onTap,
      ),
    );
  }
}
