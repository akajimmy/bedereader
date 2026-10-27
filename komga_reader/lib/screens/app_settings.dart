import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../hidden_libraries.dart';
import '../ondeck_hidden.dart';
import '../offline/sync.dart' show ProgressSync;
import '../pins.dart';
import '../sync_status.dart';
import '../synced_ids.dart' show PairShift;
import '../reader_keys.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../screen.dart';
import '../settings.dart';
import '../view_prefs.dart';
import '../widgets/epub_settings.dart';
import '../widgets/connection_prompt.dart' show offlineBooks;
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import '../widgets/server_status.dart';
import '../widgets/setting_rows.dart';
import 'about.dart';
import 'app_log_screen.dart';
import 'document.dart';
import 'downloads_screen.dart';
import 'remote_test.dart';
import '../book_source.dart';
import '../api.dart' show Komga;
import '../combined_source.dart';
import 'local_settings.dart';
import 'login.dart' show LoginScreen;

/// The pages of Settings, in order (option A, "plain scopes" - user, 2026-10-07): the reading pages, then the app's,
/// then help.
enum SettingsPage { reading, comics, webtoons, ebooks, keys, server, library, libraries, downloads, look, about }

/// The headings the pages are listed under.
enum SettingsSection { reading, app, help }

extension SettingsSectionLabel on SettingsSection {
  String get label => switch (this) {
        SettingsSection.reading => 'Reading',
        SettingsSection.app => 'App',
        SettingsSection.help => 'Help',
      };
}

extension SettingsPageInfo on SettingsPage {
  String get label => switch (this) {
        SettingsPage.reading => 'All Book Types', // (user, 2026-10-27; it said Reading, as its heading does)
        SettingsPage.comics => 'Comics',
        SettingsPage.webtoons => 'Webtoons',
        SettingsPage.ebooks => 'eBooks',
        SettingsPage.keys => 'Remote and keys',
        SettingsPage.server => 'Server & Sync', // (user, 2026-10-27: as Library & Home)
        SettingsPage.library => 'Library & Home',
        SettingsPage.libraries => 'Libraries',
        SettingsPage.downloads => 'Storage & Downloads', // (user, 2026-10-27: the cache too)
        SettingsPage.look => 'Look',
        SettingsPage.about => 'About',
      };
  IconData get icon => switch (this) {
        SettingsPage.reading => Icons.menu_book_outlined,
        SettingsPage.comics => Icons.chrome_reader_mode_outlined,
        SettingsPage.webtoons => Icons.view_day_outlined,
        SettingsPage.ebooks => Icons.text_fields,
        SettingsPage.keys => Icons.settings_remote_outlined,
        SettingsPage.server => Icons.dns_outlined,
        SettingsPage.library => Icons.grid_view_outlined,
        SettingsPage.libraries => Icons.collections_bookmark_outlined,
        SettingsPage.downloads => Icons.download_outlined,
        SettingsPage.look => Icons.palette_outlined,
        SettingsPage.about => Icons.info_outline,
      };
  SettingsSection get section => switch (this) {
        SettingsPage.reading || SettingsPage.comics || SettingsPage.webtoons || SettingsPage.ebooks ||
            SettingsPage.keys =>
          SettingsSection.reading,
        SettingsPage.about => SettingsSection.help,
        _ => SettingsSection.app,
      };

  /// Where the page's settings are kept, said once under its title (a synced group is also marked itself).
  String? get scope => switch (this) {
        SettingsPage.reading => 'For every kind of book. Kept on this device',
        SettingsPage.comics || SettingsPage.webtoons || SettingsPage.ebooks => 'Groups marked synced are the same on every device (through '
            'Komga); the rest are kept on this device',
        SettingsPage.server => null,
        SettingsPage.library => 'Kept on this device, except On deck (synced)',
        SettingsPage.about => null,
        _ => 'Kept on this device',
      };
}

/// Every setting (side menu > Settings), one page at a time (user, 2026-09-30): the pages listed down the side on a
/// wide screen, or across the top as a table of contents on a narrow one, under their headings. The rows are the
/// shared setting rows (widgets/setting_rows.dart), the same as in the reader's panels.
class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut, this.initialPage = SettingsPage.reading,
      this.only});
  final BookSource api;

  /// Server & Sync's Sync now (tests find it by this).
  static const syncNowKey = ValueKey('syncNow');
  final VoidCallback onSignOut;
  final SettingsPage initialPage;
  /// Only these pages (the reader's More settings: Reading and the book's kind) - null: all of them.
  final List<SettingsPage>? only;

  /// No server mode -> Komga with the local libraries beside it, once Add a Komga server's sign-in has worked (set by
  /// the app, as the side menu's sign-out is).
  static Future<void> Function(Komga api) appAddKomga = (_) async {};

  /// No server mode's Add a Komga server and Leave rows (tests find them by these).
  static const addKomgaKey = ValueKey('addKomga'), leaveNoServerKey = ValueKey('leaveNoServer');

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late SettingsPage _page = widget.initialPage;

  /// The pages' entries in the side list, for Left from the page (below).
  final _navNodes = {for (final p in SettingsPage.values) p: FocusNode(debugLabel: 'settings-${p.name}')};

  /// The page beside the list (its controls are under it).
  final _pageNode = FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    for (final n in _navNodes.values) {
      n.dispose();
    }
    _pageNode.dispose();
    super.dispose();
  }

  /// The remote's Left on the page: the usual move left while it stays on the page or lands in the side list - else
  /// back to the page's entry in the list. The slim buttons (2026-10-21) are lower than the list's entries, so a row's
  /// first control could line up with none of them, and Flutter's move left went to the top bar or nowhere (it goes by
  /// what's level with it).
  KeyEventResult _leftToList(FocusNode _, KeyEvent e) {
    if ((e is! KeyDownEvent && e is! KeyRepeatEvent) || e.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    final at = FocusManager.instance.primaryFocus;
    if (at == null || !at.focusInDirection(TraversalDirection.left)) {
      _navNodes[_page]!.requestFocus();
      return KeyEventResult.handled;
    }
    // the move takes effect in a microtask: once it has, where did it land?
    scheduleMicrotask(() {
      final now = FocusManager.instance.primaryFocus;
      if (now == null || !(now.ancestors.contains(_pageNode) || _navNodes.containsValue(now))) {
        _navNodes[_page]!.requestFocus();
      }
    });
    return KeyEventResult.handled;
  }

  List<SettingsPage> get _pages => [
        for (final p in SettingsPage.values)
          if ((p != SettingsPage.downloads || Downloads.instance.anyReady) && (widget.only?.contains(p) ?? true)) p,
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: const [FullscreenExit()]),
      // the pages end above Android's navigation bar (the app is drawn edge to edge, under it): the lists set their
      // own padding, so they leave it no room, and the row the remote moved to was scrolled to an edge behind the bar
      // (user, 2026-10-07: Comics > Keep the screen on)
      body: SafeArea(top: false, child: LayoutBuilder(builder: (context, box) {
        final page = _pageBody(context);
        if (box.maxWidth >= 760) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 230,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 8, 24), children: [
                for (final section in SettingsSection.values) ...[
                  _SectionHeading(section.label),
                  for (final p in _pages)
                    if (p.section == section)
                      _NavItem(page: p, selected: p == _page, node: _navNodes[p]!, onTap: () => _go(p)),
                ],
              ]),
            ),
            const VerticalDivider(width: 1, color: Color(0xFF26282E)),
            Expanded(
              child: Focus(
                focusNode: _pageNode,
                onKeyEvent: _leftToList,
                child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  // a list per page: each opens at its top, not where the last one was scrolled to (missing-tests
                  // audit, 2026-09-30)
                  child: ListView(key: ValueKey(_page), padding: const EdgeInsets.fromLTRB(24, 16, 24, 40), children: page),
                ),
              ),
              ),
            ),
          ]);
        }
        // narrow: the pages as a table of contents at the top, then the chosen page
        return ListView(padding: const EdgeInsets.fromLTRB(14, 2, 14, 40), children: [
          for (final section in SettingsSection.values) ...[
            _SectionHeading(section.label),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _pages)
                if (p.section == section)
                  ChoiceChip(
                    avatar: Icon(p.icon, size: 18),
                    label: Text(p.label),
                    selected: p == _page,
                    showCheckmark: false,
                    onSelected: (_) => _go(p),
                  ),
            ]),
          ],
          const SizedBox(height: 18),
          ...page,
        ]);
      })),
    );
  }

  void _go(SettingsPage p) => setState(() => _page = p);

  List<Widget> _pageBody(BuildContext context) {
    final p = _page;
    return [
      Text(p.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
      const SizedBox(height: 16),
      KeyedSubtree(key: ValueKey(p), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (p) {
        SettingsPage.reading => [_live((s) => _reading(context, s))],
        SettingsPage.comics => [_live((s) => _comics(context, s))],
        SettingsPage.webtoons => [_live((s) => _webtoons(context, s))],
        SettingsPage.ebooks => [_live((s) => _ebooks(context, s))],
        SettingsPage.server => _server(context),
        SettingsPage.look => [_live((s) => _look(context, s))],
        SettingsPage.library => _library(),
        SettingsPage.libraries => _libraries(),
        SettingsPage.downloads => [ListenableBuilder(listenable: Downloads.instance, builder: (context, _) => _downloads(context))],
        SettingsPage.keys => [ListenableBuilder(listenable: ReaderKeys.instance, builder: (context, _) => _keys(context))],
        SettingsPage.about => _about(context),
      })),
    ];
  }

  /// Rebuilds [build] when the settings change.
  Widget _live(Widget Function(AppSettings s) build) =>
      ListenableBuilder(listenable: AppSettings.instance, builder: (context, _) => build(AppSettings.instance));

  // ---- Reading: for both kinds of book -----------------------------------------------------------------------------
  Widget _reading(BuildContext context, AppSettings s) {
    final d = s.display;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the reader's alone: everywhere else the screen follows the system (user, 2026-10-05)
      SettingsGroup(title: 'Screen while reading', children: [
        ...brightnessRows(s),
        screenOnRow(s),
        if (canRotate) rotationRow(s), // comics and eBooks alike (user, 2026-10-21)
      ]),
      _night(s),
      SettingsGroup(title: 'Display', children: overPageRows(s)), // (user, 2026-10-27; "Over the page")
      SettingsGroup(title: 'Behaviour', children: [ // (user, 2026-10-27; "Moving on")
        SegmentRow<MidBook>(
          // (user, 2026-10-21: the question as the title, no description; 2026-10-22: the reader's own Next book icon
          // in it, "not the emoji")
          title: 'Mark current read on ${SettingRow.iconHere} (Next Book)',
          titleIcon: Icons.skip_next,
          choices: const [Choice(MidBook.markRead, 'Yes'), Choice(MidBook.keep, 'No'), Choice(MidBook.ask, 'Ask')],
          value: d.midBook,
          onChanged: (m) => s.setDisplay(d.copyWith(midBook: m)),
        ),
      ]),
    ]);
  }

  // ---- Comics ----------------------------------------------------------------------------------------------------
  Widget _comics(BuildContext context, AppSettings s) {
    final p = s.defaults;
    final n = s.series.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
        child: Text('The defaults for every series; a series can override them in the reader (Comic settings).',
            style: TextStyle(color: hintColour)),
      ),
      SettingsGroup(title: 'Page Layout - default values', synced: true, children: layoutRows(p, s.setDefault)),
      SettingsGroup(title: 'Image - defaults', synced: true, children: [
        ...imageRows(p, s.setDefault),
        ActionRow(title: 'Image settings back to the original scan',
            button: TextButton(onPressed: () => s.setDefault(p.imageReset()), child: const Text('Reset to original'))),
      ]),
      // (user, 2026-10-27: "Turning pages" -> Appearance, its Double-tap to zoom into Controls)
      SettingsGroup(title: 'Appearance', children: [pageTurnRow(s)]),
      SettingsGroup(title: 'Controls', children: [
        doubleTapRow(s),
        positionTextRow(s, BookKind.comics),
      ]),
      SettingsGroup(title: 'Series with their own settings', synced: true, children: [
        ActionRow(
          title: n == 0 ? 'Every series follows the defaults' : '$n series ${n == 1 ? 'has its' : 'have their'} own settings',
          button: n == 0 ? null : TextButton(onPressed: () => _resetSeries(context, n), child: const Text('Reset all')),
        ),
      ]),
    ]);
  }

  // ---- Webtoons: their own settings - nothing shared with comics but the Reading page (user, 2026-10-22: "a clean
  // split") --------------------------------------------------------------------------------------------------------
  Widget _webtoons(BuildContext context, AppSettings s) {
    final p = s.webtoonDefaults;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
        child: Text('For the series Komga marks as webtoons; a series can override them in the reader (Webtoon '
            'settings).', style: TextStyle(color: hintColour)),
      ),
      SettingsGroup(title: 'Pages - defaults', synced: true, children: webtoonLayoutRows(p, s.setWebtoonDefault)),
      SettingsGroup(title: 'Image - defaults', synced: true, children: [
        ...imageRows(p, s.setWebtoonDefault),
        ActionRow(title: 'Image settings back to the original',
            button: TextButton(onPressed: () => s.setWebtoonDefault(p.imageReset()), child: const Text('Reset to original'))),
      ]),
      SettingsGroup(title: 'Scrolling', children: [webtoonScrollRow(s), webtoonTapsRow(s), autoScrollSpeedRow(s),
        webtoonDoubleTapRow(s)]),
      SettingsGroup(title: 'Controls', children: [positionTextRow(s, BookKind.webtoons)]),
    ]);
  }

  // ---- eBooks ----------------------------------------------------------------------------------------------------
  Widget _ebooks(BuildContext context, AppSettings s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...epubSettingRows(context, s.epub, s.setEpub, insetRow: insetPageRow(s), inset: s.display.insetPage),
        SettingsGroup(title: 'Controls', children: [positionTextRow(s, BookKind.ebooks)]),
        SettingsGroup(title: 'Screen', children: [epubTurnRow(s)]),
      ]);


  // ---- Server and sync -------------------------------------------------------------------------------------------
  List<Widget> _server(BuildContext context) => CombinedSource.noServerOf(widget.api) ? [
        SettingsGroup(title: 'No server', children: [
          const NoteRow('Books from the local libraries only. Settings, pins and reading progress stay on this '
              'device.'),
          ActionRow(
            key: AppSettingsScreen.addKomgaKey,
            title: 'Add a Komga server',
            icon: Icons.dns_outlined,
            subtitle: 'Its books beside the local libraries',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => LoginScreen(adding: true, onSignedIn: AppSettingsScreen.appAddKomga))),
          ),
          ActionRow(
            key: AppSettingsScreen.leaveNoServerKey,
            title: 'Leave No server mode',
            icon: Icons.logout,
            subtitle: 'Back to the sign-in screen; the local libraries stay',
            onTap: () => _signOut(context),
          ),
        ]),
      ] : [
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
        // what goes through Komga, said in one place (user, 2026-10-07; one line, and pins always sync - 2026-10-21),
        // when it last did, and Sync now for when something seems off (user, 2026-10-27)
        ListenableBuilder(
          listenable: Listenable.merge([SyncStatus.instance, Connection.instance]),
          builder: (context, _) {
            final last = SyncStatus.instance.last;
            return SettingsGroup(title: 'Sync', synced: true, children: [
              const NoteRow('Synced: reading settings, series settings, pins, On deck, reading progress.'),
              ActionRow(
                title: 'Last Sync',
                subtitle: last == null ? 'Not yet on this device' : syncTimeLabel(last, clock.now()),
                button: TextButton(
                  key: AppSettingsScreen.syncNowKey,
                  onPressed: _syncing || Connection.instance.offline ? null : () => _syncNow(context),
                  child: Text(_syncing ? 'Syncing…' : 'Sync now'),
                ),
              ),
            ]);
          },
        ),
        if (Connection.instance.available)
          ListenableBuilder(
            listenable: Connection.instance,
            builder: (context, _) {
              final c = Connection.instance;
              return SettingsGroup(title: 'Offline', children: [
                SwitchRow(
                  title: 'Offline mode',
                  subtitle: c.offline ? 'Showing ${offlineBooks(widget.api)} only' : 'Connected to Komga',
                  value: c.offline,
                  onChanged: c.setForcedOffline,
                ),
              ]);
            },
          ),
      ];

  // ---- Remote and keys -------------------------------------------------------------------------------------------
  Widget _keys(BuildContext context) {
    final k = ReaderKeys.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: 'In the reader, with the controls hidden', children: [
        for (final a in ReaderAction.values)
          if (a != ReaderAction.openMenu) _KeyRow(action: a, onAdd: () => _addKey(context, a)),
        NoteRow('${hasVolumeKeys ? 'Any key can be added, the volume keys too (to turn pages with them: Volume down to '
            'Next page, Volume up to Previous page). ' : ''}For a book read right to left, Left and Right swap. '
            'Shift+Space always goes back. Once the controls are up, the arrows and OK move around them.'),
        ActionRow(
          title: 'Reset to default',
          button: TextButton(onPressed: k.isDefault ? null : k.reset, child: const Text('Reset keys')),
        ),
      ]),
      // the screens with a side menu (Home, the libraries, a series...) - no key by default (user, 2026-10-12)
      SettingsGroup(title: 'Anywhere else', children: [
        _KeyRow(action: ReaderAction.openMenu, onAdd: () => _addKey(context, ReaderAction.openMenu)),
      ]),
      // what a remote sends, and where it's lost (user, 2026-10-25: the Chromecast remote on the iPad)
      SettingsGroup(title: 'Remote', children: [
        ActionRow(title: 'Test the remote', icon: Icons.settings_remote_outlined,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemoteTestScreen()))),
      ]),
    ]);
  }

  /// "+ Add": the next key pressed (on the remote or a keyboard) goes to [action].
  Future<void> _addKey(BuildContext context, ReaderAction action) async {
    // The key is caught from the keyboard itself while the dialog is up, not by a widget waiting for the focus: on
    // the tablet the dialog never got a key that way - not the volume keys, not any (user, build 92: "it does not let
    // me set the volume keys"). Every key is the answer, OK included, except Back and Esc, which cancel (code review,
    // 2026-09-30: Back was taken as the key, and then no longer closed the book). Taken keys go no further (a volume
    // key doesn't change the volume).
    BuildContext? dialog;
    var answered = false;
    bool onKey(KeyEvent e) {
      final ctx = dialog;
      if (ctx == null || !ctx.mounted) return false;
      if (e is KeyDownEvent && !answered) {
        answered = true;
        final cancel = e.logicalKey == LogicalKeyboardKey.goBack || e.logicalKey == LogicalKeyboardKey.escape;
        Navigator.pop(ctx, cancel ? null : e.logicalKey);
      }
      return true; // the rest of the press too, while the dialog is up
    }

    HardwareKeyboard.instance.addHandler(onKey);
    final LogicalKeyboardKey? key;
    try {
      key = await showDialog<LogicalKeyboardKey>(
        context: context,
        builder: (ctx) {
          dialog = ctx;
          return AlertDialog(
            title: Text('${action.label}: press a key'),
            content: const Text('Press the key on the remote or keyboard. (Back, Esc or a tap outside cancels.)'),
            actions: [
              // touch; never the remote's focus (OK on it would be the answer, not a press)
              ExcludeFocus(child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))),
            ],
          );
        },
      );
    } finally {
      HardwareKeyboard.instance.removeHandler(onKey);
    }
    if (key == null || !context.mounted) return;
    final no = ReaderKeys.instance.cantAssign(action, key);
    if (no != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(no)));
      return;
    }
    final was = await ReaderKeys.instance.assign(action, key);
    if (context.mounted && was != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('${ReaderKeys.nameOf(key)} now does ${action.label.toLowerCase()} (was: ${was.label.toLowerCase()})')));
    }
  }

  /// Night mode and its schedule - on All Book Types (user, 2026-10-27; it was in Look).
  Widget _night(AppSettings s) => SettingsGroup(title: 'Night', children: [
        ...nightRows(s),
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
      ]);

  // ---- Look ------------------------------------------------------------------------------------------------------
  Widget _look(BuildContext context, AppSettings s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingsGroup(title: 'Text and colour', children: [
          SegmentRow<double>(
            title: 'Text size',
            subtitle: "Relative to the device's own",
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

  // ---- Libraries -------------------------------------------------------------------------------------------------
  /// Every library in one place (user, 2026-10-27: the app reads from several sources, Komga one of them): the local
  /// and network ones, added and managed here, and Komga's - all of the server's, each switched on or off on this
  /// device (a folder that isn't wanted simply isn't added; a server brings all its libraries). The server's own
  /// settings stay on Server and sync.
  List<Widget> _libraries() {
    final api = widget.api;
    final local = api is CombinedSource ? api.local : null;
    final noServer = CombinedSource.noServerOf(api);
    return [
      if (local != null) ...[
        // (on top: not between two groups - user, 2026-10-27)
        SettingsGroup(title: 'Scan', children: [LibraryScanRow(local: local)]),
        LocalLibrariesGroup(local: local),
        LocalLibrariesGroup(local: local, network: true),
      ] else
        const SettingsGroup(title: 'Local', children: [NoteRow("Local libraries can't be kept on this device.")]),
      if (noServer)
        SettingsGroup(title: 'Komga', children: [
          ActionRow(title: 'Komga server', subtitle: 'None (No server mode) - one is added in Server & Sync',
              icon: Icons.dns_outlined, onTap: () => setState(() => _page = SettingsPage.server)),
        ])
      else
        _komgaLibraries(),
    ];
  }

  /// Komga's libraries (the server's, not the local ones), as this device's main source gives them.
  late final Future<List<dynamic>> _komga = switch (widget.api) {
    final CombinedSource c => c.main.libraries(),
    final other => other.libraries(),
  };

  /// Komga's libraries: a switch each - shown on this device or not (kept on this device). The last one shown can't
  /// be switched off: with none left, Komga would be asked for every library (api.dart _scope).
  Widget _komgaLibraries() => FutureBuilder<List<dynamic>>(
        future: _komga,
        builder: (context, snap) {
          final libs = snap.data ?? const [];
          final server = ActionRow(title: 'Komga server', subtitle: 'Its address, account and sync: Server & Sync',
              icon: Icons.dns_outlined, onTap: () => setState(() => _page = SettingsPage.server));
          return ListenableBuilder(
            listenable: HiddenLibraries.instance,
            builder: (context, _) {
              final h = HiddenLibraries.instance;
              final shown = libs.where((l) => !h.isHidden(l['id'] as String?)).length;
              return SettingsGroup(title: 'Komga', children: [
                server,
                for (final l in libs)
                  SwitchRow(
                    title: l['name'] as String? ?? '',
                    value: !h.isHidden(l['id'] as String?),
                    onChanged: !h.isHidden(l['id'] as String?) && shown <= 1
                        ? null // the last one shown stays
                        : (v) => h.setHidden(l['id'] as String, !v),
                  ),
                if (snap.hasError || (snap.hasData && libs.isEmpty))
                  const NoteRow("Komga's libraries can't be listed right now."),
              ]);
            },
          );
        },
      );

  // ---- Library & Home --------------------------------------------------------------------------------------------

  List<Widget> _library() => [
        _live((s) {
          final d = s.display, l = s.library; // (size: this device's; the captions: synced - LibraryPrefs)
          return SettingsGroup(title: 'Posters', children: [
            SegmentRow<PosterSize>(
              title: 'Size',
              choices: [for (final p in PosterSize.values) Choice(p, p.label)],
              value: d.posterSize,
              onChanged: (p) => s.setDisplay(d.copyWith(posterSize: p)),
            ),
            // any of three lines under a book's poster, always in this order (user, 2026-10-07); comics and eBooks each
            // their own (user, 2026-10-18)
            ToggleChipsRow(
              title: 'Under Comic & Webtoon Posters', // (user, 2026-10-27: a webtoon's are these)
              chips: [
                ToggleChip('Series #', l.posterSeries, (v) => s.setLibrary(l.copyWith(posterSeries: v))),
                ToggleChip('Title', l.posterTitle, (v) => s.setLibrary(l.copyWith(posterTitle: v))),
                ToggleChip('Release date', l.posterDate, (v) => s.setLibrary(l.copyWith(posterDate: v))),
              ],
            ),
            ToggleChipsRow(
              title: 'Under eBook posters',
              chips: [
                ToggleChip('Title', l.ebookPosterTitle, (v) => s.setLibrary(l.copyWith(ebookPosterTitle: v))),
                ToggleChip('Author', l.ebookPosterAuthor, (v) => s.setLibrary(l.copyWith(ebookPosterAuthor: v))),
                ToggleChip('Series #', l.ebookPosterSeries, (v) => s.setLibrary(l.copyWith(ebookPosterSeries: v))),
                ToggleChip('Release date', l.ebookPosterDate, (v) => s.setLibrary(l.copyWith(ebookPosterDate: v))),
              ],
            ),
            // (this device's own: which sources it has is this device's - user, 2026-10-26: "show source icon")
            SwitchRow(
              title: 'Show where books come from',
              subtitle: 'An icon on posters and libraries: this device, a network share, Komga',
              value: d.sourceIcon,
              onChanged: (v) => s.setDisplay(d.copyWith(sourceIcon: v)),
            ),
          ]);
        }),
        const SettingsGroup(title: 'Home sections', children: [
          Padding(padding: EdgeInsets.only(left: 6, bottom: 4), child: HomeSectionsEditor()),
        ]),
        ListenableBuilder(
          listenable: OnDeckHidden.instance,
          builder: (context, _) {
            final h = OnDeckHidden.instance;
            return SettingsGroup(title: 'On deck', synced: true, children: [
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


  // ---- Downloads -------------------------------------------------------------------------------------------------
  Widget _downloads(BuildContext context) {
    final d = Downloads.instance;
    // GB; null = no limit, 0 = off: nothing downloads (a book asked for stops for lack of room - user, 2026-10-27)
    const choices = <int?>[0, 2, 5, 10, 20, 50, 100, null];
    final current = d.capBytes == null ? null : (d.capBytes! / Downloads.gb).round();
    // MB; 0 = off: nothing is cached, a book is read from its source (user, 2026-10-27)
    const cacheChoices = <int>[0, 256, 512, 1024, 2048, 5120];
    final cacheMb = (Downloads.cacheCap / (1024 * 1024)).round();
    String mb(int m) => m == 0 ? 'Off' : (m < 1024 ? '$m MB' : '${m ~/ 1024} GB');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: 'Storage', children: [
        SettingRow(
          title: 'Downloads limit', // (user, 2026-10-27; "Storage limit")
          subtitle: '${DownloadsScreen.size(d.usedBytes)} used', // (user, 2026-10-21: just the amount)
          trailing: DropdownButton<int?>(
            value: choices.contains(current) ? current : 10,
            underline: const SizedBox.shrink(),
            items: [
              for (final c in choices)
                DropdownMenuItem(value: c, child: Text(c == null ? 'No limit' : (c == 0 ? 'Off' : '$c GB'))),
            ],
            onChanged: (c) => d.setCap(c == null ? null : c * Downloads.gb),
          ),
        ),
        // the books opened lately, kept to read again without the source (user, 2026-10-27: its own limit, and Clear)
        SettingRow(
          title: 'Cache limit',
          subtitle: '${DownloadsScreen.size(d.cacheBytes)} used',
          trailing: DropdownButton<int>(
            value: cacheChoices.contains(cacheMb) ? cacheMb : 512,
            underline: const SizedBox.shrink(),
            items: [for (final c in cacheChoices) DropdownMenuItem(value: c, child: Text(mb(c)))],
            onChanged: (c) {
              if (c != null) d.setCacheCap(c * 1024 * 1024);
            },
          ),
        ),
        ActionRow(
          title: 'Cached books',
          subtitle: 'Opened lately and kept, to read again without the server or share',
          button: TextButton(onPressed: d.cacheBytes == 0 ? null : d.clearCache, child: const Text('Clear cache')),
        ),
        // a phone or tablet (a PC has no mobile data to save)
        if (knowsMobileData)
          SwitchRow(
            title: 'Download on Wi-Fi only',
            subtitle: d.waitingForWifi ? 'Waiting for Wi-Fi' : null, // (only while waiting - user, 2026-10-21)
            value: d.wifiOnly,
            onChanged: d.setWifiOnly,
          ),
        SegmentRow<DeleteRead>(
          title: "Delete a downloaded book once it's read",
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
        // the links: titles only (user, 2026-10-21)
        ActionRow(title: 'About $appName', icon: Icons.info_outline, onTap: () => open(const AboutScreen())),
        ActionRow(title: "What's new", icon: Icons.new_releases_outlined, onTap: () => open(DocumentScreen.whatsNew())),
        ActionRow(title: 'Read me', icon: Icons.menu_book_outlined, onTap: () => open(DocumentScreen.readMe())),
        ActionRow(title: 'Third-party software', icon: Icons.extension_outlined,
            onTap: () => open(DocumentScreen.thirdParty())),
        ActionRow(title: 'Error log', icon: Icons.report_outlined, onTap: () => open(const ErrorLogScreen())),
        ActionRow(title: 'App log', icon: Icons.description_outlined, onTap: () => open(const AppLogScreen())),
      ]),
      const RemoteLogGroup(),
      SettingsGroup(title: 'This device', children: [
        ActionRow(
          title: "Reset this device's settings",
          subtitle: 'Everything kept on this device back to the defaults',
          icon: Icons.restart_alt,
          button: TextButton(onPressed: () => _resetDevice(context), child: const Text('Reset')),
        ),
      ]),
    ];
  }

  // ---- Sync now (Server & Sync) -----------------------------------------------------------------------------------
  bool _syncing = false;

  /// Everything synced through Komga, now: each store's changes waiting to go are sent, and Komga's are read again -
  /// past the few seconds a refresh is otherwise held back for - and reading done offline goes too. Komga not
  /// answering: said (Last Sync stays as it was).
  Future<void> _syncNow(BuildContext context) async {
    final before = SyncStatus.instance.last;
    setState(() => _syncing = true);
    try {
      await Future.wait([
        AppSettings.instance.refresh(force: true),
        Pins.instance.refresh(force: true),
        OnDeckHidden.instance.refresh(force: true),
        PairShift.instance.refresh(force: true),
      ]);
      await ProgressSync.instance.run();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (!context.mounted || SyncStatus.instance.last != before) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Komga didn't answer: nothing synced")));
  }

  // ---- confirmations ---------------------------------------------------------------------------------------------
  Future<void> _signOut(BuildContext context) async {
    final noServer = CombinedSource.noServerOf(widget.api);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(noServer ? 'Leave No server mode?' : 'Sign out?'),
        content: Text(noServer
            ? 'Back to the sign-in screen. The local libraries, their reading progress and the pins to them stay; '
                "this mode's reading settings go."
            : 'The API key is removed from this device; you can sign in again or connect to a different server. '
                'Downloads and settings stay.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(noServer ? 'Leave' : 'Sign out')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    widget.onSignOut();
  }

  /// Everything kept on this device only, back to the defaults - after asking. Synced settings (reading defaults,
  /// series settings, pins, On deck, posters' captions, Home's sections), the sign-in, the offline mode switch and the
  /// downloaded books stay.
  Future<void> _resetDevice(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Reset this device's settings?"),
        content: const Text('Back to the defaults: the reading settings kept on this device (brightness, the screen, '
            "what's shown over the page, rotation), the eBook font and text size, night mode and its schedule, app "
            "text size and "
            "accent colour, the reader's keys, poster size and the source icon, the libraries shown, every screen's remembered "
            'filter and sort, and the download limit and Delete once read.\n\nNot touched: settings synced '
            "through Komga (reading defaults, series settings, pins, On deck, posters' captions, Home sections), "
            'your sign-in and your downloaded books.'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
    s.setEpub(s.epub.copyWith(font: const EpubPrefs().font, size: const EpubPrefs().size)); // this device's own
    await HiddenLibraries.instance.clear(); // every library shown again
    await ReaderKeys.instance.reset(); // the reader's usual keys
    await ViewPrefs.clearAll();
    if (Downloads.instance.anyReady) {
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
class _KeyRow extends StatefulWidget {
  const _KeyRow({required this.action, required this.onAdd});
  final ReaderAction action;
  final VoidCallback onAdd;
  @override
  State<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<_KeyRow> {
  final _addNode = FocusNode(debugLabel: 'key-add');

  @override
  void dispose() {
    _addNode.dispose();
    super.dispose();
  }

  /// [key] off [ReaderAction]; the remote's focus, which was on its chip, goes to the row's Add (the chip is gone -
  /// the focus went with it; code review 2026-10-05, #26).
  void _remove(LogicalKeyboardKey key) {
    final hadFocus = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<_KeyRowState>() == this;
    ReaderKeys.instance.remove(widget.action, key);
    if (hadFocus) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _addNode.requestFocus(); });
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
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
              onPressed: removable ? () => _remove(key) : null,
            ),
          if (k.keys[action]!.isEmpty) const Text('No key', style: TextStyle(color: hintColour)),
          TextButton.icon(focusNode: _addNode, onPressed: widget.onAdd, icon: const Icon(Icons.add, size: 18),
              label: const Text('Add')),
        ]),
      ]),
    );
  }
}

/// A heading over the pages in the side list or the chips: Reading, App, Help.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(color: hintColour, fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.8)),
      );
}

/// A page in the side list (wide screens).
class _NavItem extends StatelessWidget {
  const _NavItem({required this.page, required this.selected, required this.node, required this.onTap});
  final SettingsPage page;
  final bool selected;
  final FocusNode node;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ListTile(
        dense: true,
        focusNode: node,
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
