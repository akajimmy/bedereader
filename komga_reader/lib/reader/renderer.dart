import 'package:flutter/widgets.dart';

import '../api.dart';
import 'position_row.dart';

/// What a renderer - the pages of one kind of book (comic pages, an EPUB) - may ask of the Reader it's in (the one
/// Reader, user 2026-10-07; reports\plan-reader-renderer-2026-10-07.md). The Reader implements it; the renderer
/// never needs to know more of it.
///
/// Places: what the Reader counts in - a renderer's pages, 0..last, and last + 1 is the end card.
abstract class ReaderHost {
  BuildContext get context;
  bool get mounted;
  TickerProvider get vsync;
  Komga get api;

  /// The controls are up (the page's own gestures wait).
  bool get controlsUp;

  /// Another book is on its way: turns wait for it.
  bool get busy;

  /// The place picked on the slider right now (null: none) - the page strip follows it.
  int? get scrub;

  /// The place to come back to after a slider or strip jump (null: none) - marked on the strip.
  int? get wayBack;

  /// Something the Reader draws from the renderer changed: rebuild.
  void changed();

  /// A touch or a turn: the screen stays on.
  void awake();

  /// A single tap at [x] (0..1 across the screen), not taken by the page: the Reader's tap zones.
  void tap(double x);

  /// Right-click: the controls up or down.
  void toggleControls();

  /// The controls down (a chapter picked in Contents: the reader goes to read it).
  void hideControls();

  /// The page view moved to [place]. [curling]: a page curl started it - it counts as a turn once the curl
  /// completes ([turned]), not yet.
  void pageChanged(int place, {required bool curling});

  /// A page curl completed: the turn to [place] counts now.
  void turned(int place);

  /// The renderer put the book at [place] itself (laid out, or out again at a new size): where it opened, not a turn.
  void placed(int place);

  /// Forward from the end card: the next book.
  void nextBook();

  /// A jump picked on the renderer's own controls (the page strip, the contents): as one from the slider - the way
  /// back is kept.
  void jumpTo(int place);

  /// The page after the last: what's next.
  Widget endCard();
}

/// A control the renderer adds to the Reader's bars, with its focus node for the remote's walk.
class BarButton {
  const BarButton(this.node, this.child);
  final FocusNode node;
  final Widget child;
}

/// The question when another device moved the book on: its wording, per kind (decision 6: pages for comics, % for
/// EPUBs).
typedef ElsewhereText = ({String title, String text, String stay, String go});

/// One kind of book's pages in the Reader (the one Reader, user 2026-10-07): the comic renderer and the EPUB
/// renderer. The Reader does the rest - the bars, the slider and the position text, the page corner, the end card,
/// keys and taps, moving between books, and the saving of progress, whose content (pages, or a place in the book) is
/// the renderer's.
abstract class Renderer extends ChangeNotifier {
  Renderer(this.host);

  final ReaderHost host;
  Komga get api => host.api;

  // ---- opening a book

  /// Gets [book] ready to show - nothing on screen changes (the book being read stays until [show]). Throws if it
  /// can't be opened. Returns what [show] takes.
  Future<Object> prepare(Map book);

  /// Shows [book], from [prepare].
  void show(Map book, Object prepared);

  /// A book is shown (a page view, or its waiting screen).
  bool get opened;

  /// The book can be read: turns, the slider, the controls. (An EPUB is laid out and counted first.)
  bool get ready => opened;

  /// Shown instead of the pages while the book is [opened] but not [ready] (an EPUB being counted).
  Widget waiting(BuildContext context) => const SizedBox.shrink();

  /// The book's record changed (marked read, say): the same pages.
  void bookChanged(Map book);

  /// The book shown, as the renderer has it now.
  Map get book;

  // ---- places

  /// Where the reader is: 0..[last], [last] + 1 on the end card.
  int get place;
  int get last;

  /// The place the book opened at (opening alone isn't a turn).
  int get openedAt;

  /// A turn's animation is under way (a held key's repeats wait for it).
  bool get sliding => false;

  // ---- the look

  Color get background;
  Color ink(double alpha); // text on the background
  bool get rtl => false;

  // ---- moving

  /// A turn forward or back; from the end card forward is the next book. [snap]: a tap - a turn under way ends at
  /// once.
  void forward({bool snap = false});
  void back({bool snap = false});

  /// To [place] at once (the slider, another device's place) - not a turn (the Reader knows it's coming).
  void jumpTo(int place);
  void zoomStep(bool zoomIn) {}

  // ---- drawing

  /// The pages (and their gestures), filling the Reader's stack.
  List<Widget> buildPages(BuildContext context);
  List<BarButton> topButtons() => const [];
  List<BarButton> bottomButtons(BuildContext context);

  /// A row of its own over the bottom bar (the comic page strip): drawn, its focus node (the remote's walk), and the
  /// bottom bar's control below it.
  Widget? above(BuildContext context) => null;
  FocusNode? get rowNode => null;
  FocusNode? get rowBelow => null;
  void rowFocus() {}
  void controlsShown() {}
  void scrubStarted() {}

  /// A picture over the slider's thumb while a place is picked (comics: the page); null: none.
  Widget? preview(BuildContext context, int shown, double x) => null;

  /// Up / Down step the slider too while scrubbing (comics).
  bool get sliderUpDown => false;

  // ---- what's said

  /// The position text's spots for [place] (decision 5: the title or chapter on top, the book's place left).
  ({SpotText? left, SpotText? centre, SpotText? right}) spots(int place);

  /// The page corner for [place]: "12 / 36" (user, 2026-10-07: book progress only, both kinds).
  String corner(int place);

  /// The slider's spoken label for [place].
  String placeLabel(int place);

  /// Where the reader is, for the "Mark as read?" question: "You are on page 3 of 36."
  String get whereText;

  // ---- progress on Komga (comics: a page and finished; EPUBs: a place in the book)

  /// Progress is saved at all (a book shown from memory in tests: not).
  bool get savesProgress => true;

  /// Komga's progress as [prepare] found it.
  Object? get openedProgress;

  /// Reads the open book's progress on Komga now - captured now, for a save that may run once another book has
  /// opened. Throws: Komga can't say.
  Future<Object?> Function() progressReader();

  /// Saves [place] as the open book's progress - captured now - and returns Komga's progress after it (this
  /// reader's). [place] past the last page: the book is read.
  Future<Object?> Function() progressSaver(int place);

  /// Komga's progress after this reader marked the book read or unread; [fresh]: the book as Komga has it now.
  Future<Object?> progressAfterMark(Map fresh) => progressReader()();

  /// Komga's progress is the same as [b] (another device didn't move it).
  bool sameProgress(Object? a, Object? b) => a == b;

  /// Saving at [place] marks the book read (comics: the last page; EPUBs: the end card).
  bool finishedAt(int place);

  /// The question's wording for [moved] (another device's progress); [here]: the place being read.
  ElsewhereText elsewhereText(Object? moved, int here);

  /// The reader goes with [moved]: the place to go to ([last] + 1: the end card); the renderer's book record takes
  /// it on.
  int acceptElsewhere(Object? moved);
}
