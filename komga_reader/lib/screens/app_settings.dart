import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../hidden_libraries.dart';
import '../home_sections.dart';
import '../ondeck_hidden.dart';
import '../pins.dart';
import '../reader_keys.dart';
import '../offline/connection.dart';
import '../offline/downloads.dart';
import '../screen.dart';
import '../settings.dart';
import '../view_prefs.dart';
import '../widgets/epub_settings.dart';
import '../widgets/display_panel.dart';
import '../widgets/error_text.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/home_sections_editor.dart';
import '../widgets/server_status.dart';
import '../widgets/setting_rows.dart';
import 'about.dart';
import 'document.dart';
import 'downloads_screen.dart';

/// The pages of Settings, in order (option A, "plain scopes" - user, 2026-10-07): the reading pages, then the app's,
/// then help.
enum SettingsPage { reading, comics, ebooks, keys, server, library, downloads, look, about }

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
        SettingsPage.reading => 'Reading',
        SettingsPage.comics => 'Comics',
        SettingsPage.ebooks => 'eBooks',
        SettingsPage.keys => 'Remote and keys',
        SettingsPage.server => 'Server and sync',
        SettingsPage.library => 'Library & Home',
        SettingsPage.downloads => 'Downloads',
        SettingsPage.look => 'Look',
        SettingsPage.about => 'About',
      };
  IconData get icon => switch (this) {
        SettingsPage.reading => Icons.menu_book_outlined,
        SettingsPage.comics => Icons.chrome_reader_mode_outlined,
        SettingsPage.ebooks => Icons.text_fields,
        SettingsPage.keys => Icons.settings_remote_outlined,
        SettingsPage.server => Icons.dns_outlined,
        SettingsPage.library => Icons.grid_view_outlined,
        SettingsPage.downloads => Icons.download_outlined,
        SettingsPage.look => Icons.palette_outlined,
        SettingsPage.about => Icons.info_outline,
      };
  SettingsSection get section => switch (this) {
        SettingsPage.reading || SettingsPage.comics || SettingsPage.ebooks || SettingsPage.keys => SettingsSection.reading,
        SettingsPage.about => SettingsSection.help,
        _ => SettingsSection.app,
      };

  /// Where the page's settings are kept, said once under its title (a synced group is also marked itself).
  String? get scope => switch (this) {
        SettingsPage.reading => 'For comics and eBooks alike. Kept on this device',
        SettingsPage.comics || SettingsPage.ebooks => 'Groups marked synced are the same on every device (through '
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
  const AppSettingsScreen({super.key, required this.api, required this.onSignOut, this.initialPage = SettingsPage.reading});
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
                    if (p.section == section) _NavItem(page: p, selected: p == _page, onTap: () => _go(p)),
                ],
              ]),
            ),
            const VerticalDivider(width: 1, color: Color(0xFF26282E)),
            Expanded(
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
      if (p.scope != null)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(p.scope!, style: const TextStyle(color: hintColour))),
      const SizedBox(height: 16),
      // the page's segmented choices share one width (a fresh column per page)
      SettingsColumn(key: ValueKey(p), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (p) {
        SettingsPage.reading => [_live((s) => _reading(context, s))],
        SettingsPage.comics => [_live((s) => _comics(context, s))],
        SettingsPage.ebooks => [_live((s) => _ebooks(context, s))],
        SettingsPage.server => _server(context),
        SettingsPage.look => [_live((s) => _look(context, s))],
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

  // ---- Reading: for both kinds of book -----------------------------------------------------------------------------
  Widget _reading(BuildContext context, AppSettings s) {
    final d = s.display;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // the reader's alone: everywhere else the screen follows the system (user, 2026-10-05)
      SettingsGroup(title: 'Screen while reading', children: [
        ...brightnessRows(s),
        screenOnRow(s),
      ]),
      SettingsGroup(title: 'Moving on', children: [
        SegmentRow<MidBook>(
          title: 'Skipping to the next book', // wording: user, 2026-10-07 QA
          subtitle: 'Mark the one you leave as read?',
          choices: const [Choice(MidBook.markRead, 'Yes'), Choice(MidBook.keep, 'No'), Choice(MidBook.ask, 'Ask')],
          value: d.midBook,
          onChanged: (m) => s.setDisplay(d.copyWith(midBook: m)),
        ),
      ]),
      _resetRow(context, 'Reading', 'Screen brightness, Keep the screen on and Next book back to the defaults.', () {
        const z = DisplayPrefs();
        s.setDisplay(s.display.copyWith(brightness: () => z.brightness, screenOn: z.screenOn, midBook: z.midBook));
      }),
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
      SettingsGroup(title: 'Pages - defaults', synced: true, children: layoutRows(p, s.setDefault)),
      SettingsGroup(title: 'Image - defaults', synced: true, children: [
        ...imageRows(p, s.setDefault),
        ActionRow(title: 'Image settings back to the original scan',
            button: TextButton(onPressed: () => s.setDefault(p.imageReset()), child: const Text('Reset to original'))),
      ]),
      SettingsGroup(title: 'Turning pages', children: [
        pageTurnRow(s),
        doubleTapRow(s),
      ]),
      SettingsGroup(title: 'Over the page', children: [
        pageNoteRow(s, BookKind.comics),
        clockRow(s, BookKind.comics),
        progressBarRow(s, BookKind.comics),
      ]),
      SettingsGroup(title: 'Controls', children: [
        positionTextRow(s, BookKind.comics),
        pagePreviewsRow(s),
        pageStripRow(s),
      ]),
      if (canRotate) SettingsGroup(title: 'Screen', children: [rotationRow(s, BookKind.comics)]),
      SettingsGroup(title: 'Series with their own settings', synced: true, children: [
        ActionRow(
          title: n == 0 ? 'Every series follows the defaults' : '$n series ${n == 1 ? 'has its' : 'have their'} own settings',
          button: n == 0 ? null : TextButton(onPressed: () => _resetSeries(context, n), child: const Text('Reset all')),
        ),
      ]),
      _resetRow(context, 'Comics', "Every setting on this page back to the defaults - Pages and Image on every device "
          "(they're synced). Series with their own settings keep them.", () {
        const z = DisplayPrefs();
        s.setDefault(const ReaderPrefs());
        s.setDisplay(s.display.copyWith(pageTurn: z.pageTurn, doubleTapZoom: z.doubleTapZoom,
            pagePreviews: z.pagePreviews, pageStrip: z.pageStrip, comics: z.comics));
      }),
    ]);
  }

  // ---- eBooks ----------------------------------------------------------------------------------------------------
  Widget _ebooks(BuildContext context, AppSettings s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ...epubSettingRows(context, s.epub, s.setEpub),
        SettingsGroup(title: 'Over the page', children: [
          pageNoteRow(s, BookKind.ebooks),
          clockRow(s, BookKind.ebooks),
          progressBarRow(s, BookKind.ebooks),
        ]),
        SettingsGroup(title: 'Controls', children: [positionTextRow(s, BookKind.ebooks)]),
        if (canRotate) SettingsGroup(title: 'Screen', children: [rotationRow(s, BookKind.ebooks)]),
        _resetRow(context, 'eBooks', "Every setting on this page back to the defaults - Text, Formatting and Page on "
            "every device (they're synced).", () {
          s.setEpub(const EpubPrefs());
          s.setDisplay(s.display.copyWith(ebooks: const DisplayPrefs().ebooks));
        }),
      ]);

  /// A page's reset (user, 2026-10-07: one on each page), asked first: [what] says what goes back.
  Widget _resetRow(BuildContext context, String page, String what, VoidCallback reset) => SettingsGroup(children: [
        ActionRow(
          title: 'Reset to default',
          icon: Icons.restart_alt,
          button: TextButton(
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Reset $page?'),
                  content: Text(what),
                  actions: [
                    TextButton(autofocus: true, onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
                  ],
                ),
              );
              if (ok == true) reset();
            },
            child: Text('Reset $page'),
          ),
        ),
      ]);

  // ---- Server and sync -------------------------------------------------------------------------------------------
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
        // what goes through Komga, said in one place (user, 2026-10-07)
        ListenableBuilder(
          listenable: Pins.instance,
          builder: (context, _) {
            final pins = Pins.instance;
            return SettingsGroup(title: "What's synced through Komga", synced: true, children: [
              const NoteRow('The same on every device signed in to this account: comics\' Pages and Image defaults and '
                  "each series' own; eBooks' Text, Formatting and Page settings; what's hidden "
                  'from On deck; reading progress.'),
              SwitchRow(
                title: 'Sync pins across devices',
                subtitle: pins.sync
                    ? 'The same pins on every device signed in to this account'
                    : 'This device has its own pins',
                value: pins.sync,
                onChanged: (on) => _setPinSync(context, on),
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

  // ---- Remote and keys -------------------------------------------------------------------------------------------
  Widget _keys(BuildContext context) {
    final k = ReaderKeys.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroup(title: 'In the reader, with the controls hidden', children: [
        for (final a in ReaderAction.values) _KeyRow(action: a, onAdd: () => _addKey(context, a)),
        NoteRow('${hasVolumeKeys ? 'Any key can be added, the volume keys too (to turn pages with them: Volume down to '
            'Next page, Volume up to Previous page). ' : ''}For a book read right to left, Left and Right swap. '
            'Shift+Space always goes back. Once the controls are up, the arrows and OK move around them.'),
        ActionRow(
          title: 'Reset to default',
          button: TextButton(onPressed: k.isDefault ? null : k.reset, child: const Text('Reset keys')),
        ),
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

  // ---- Look ------------------------------------------------------------------------------------------------------
  Widget _look(BuildContext context, AppSettings s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingsGroup(title: 'Night', children: [
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
        ]),
        SettingsGroup(title: 'Text and colour', children: [
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
          padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
          child: Text("The whole app, not just the reader. In the reader, the top bar's moon switches night mode.",
              style: TextStyle(color: hintColour, fontSize: 12)),
        ),
        _resetRow(context, 'Look', 'Night mode, its schedule and warmth, the text size and the accent colour back to '
            'the defaults.', () {
          const z = DisplayPrefs();
          s.setDisplay(s.display.copyWith(night: z.night, nightSchedule: z.nightSchedule, nightFrom: z.nightFrom,
              nightTo: z.nightTo, warmth: z.warmth, textScale: z.textScale, accent: z.accent));
        }),
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
            // any of three lines under a book's poster, always in this order (user, 2026-10-07)
            ToggleChipsRow(
              title: 'Under book posters',
              chips: [
                ToggleChip('Series #', d.posterSeries, (v) => s.setDisplay(d.copyWith(posterSeries: v))),
                ToggleChip('Title', d.posterTitle, (v) => s.setDisplay(d.copyWith(posterTitle: v))),
                ToggleChip('Release date', d.posterDate, (v) => s.setDisplay(d.copyWith(posterDate: v))),
              ],
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

  /// Sync pins across devices (user, 2026-10-05). Back on, the shared list returns: this device's pins that it
  /// doesn't have would go - asked first, naming how many.
  Future<void> _setPinSync(BuildContext context, bool on) async {
    if (on) {
      final only = await Pins.instance.deviceOnly();
      if (only.isNotEmpty && context.mounted) {
        final n = only.length;
        final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Sync pins across devices?'),
            content: Text("This device has $n pin${n == 1 ? '' : 's'} the shared list doesn't "
                "(${only.map((p) => p.name).join(', ')}). Syncing shows the shared list instead - "
                "${n == 1 ? 'that pin goes' : 'those pins go'} from this device."),
            actions: [
              TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sync')),
            ],
          ),
        );
        if (ok != true) return;
      }
    }
    await Pins.instance.setSync(on);
  }

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
          // what the limit does, with it (user, 2026-10-07 QA: it was a line of its own, with no control)
          subtitle: '${DownloadsScreen.size(d.usedBytes)} used on this device. A book that won\'t fit waits in the '
              'queue, and carries on when there\'s room.',
          trailing: DropdownButton<int?>(
            value: choices.contains(current) ? current : 10,
            underline: const SizedBox.shrink(),
            items: [for (final c in choices) DropdownMenuItem(value: c, child: Text(c == null ? 'No limit' : '$c GB'))],
            onChanged: (c) => d.setCap(c == null ? null : c * Downloads.gb),
          ),
        ),
        if (canRotate) // Android: a PC has no mobile data to save (the same test: a phone or tablet)
          SwitchRow(
            title: 'Download on Wi-Fi only',
            subtitle: d.waitingForWifi
                ? 'Waiting for Wi-Fi - the queue carries on when you are back on it'
                : 'On mobile data the queue waits, and carries on on Wi-Fi',
            value: d.wifiOnly,
            onChanged: d.setWifiOnly,
          ),
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
            onTap: () => open(const AboutScreen())),
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
          subtitle: 'Everything kept on this device back to the defaults',
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
        content: const Text('Back to the defaults: the reading settings kept on this device (brightness, the screen, '
            "what's shown over the page, rotation), night mode and its schedule, text size and "
            "accent colour, the reader's keys, posters, the libraries shown, Home "
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
    final s = AppSettings.instance;
    s.setDisplay(const DisplayPrefs());
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
