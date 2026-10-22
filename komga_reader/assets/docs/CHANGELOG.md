# Changelog

What changed in each build of BeDeReader, newest first. The version is on the About screen: **1.2.0 (build 52)**
means version 1.2.0, build number 52. Build numbers only ever go up.

Versions follow the releases' names from 1.2 on: builds after the 1.1 release are 1.2.0 builds, a few of them
become release candidates (`v1.2.0-rc.1`, ...), one becomes the release (`v1.2.0`), and the next build is the
first 1.3.0 build. The 1.1 release was numbered 0.1.1 (tag `v0.1.1`), and the 1.0 line 0.1.0.

## Unreleased

**Changed**

- Settings and the reader's panels: every choice now sits on its own line under its name, the full width of the panel. The position text and poster line toggles and the brightness Auto button are now the same slim buttons as every other choice. The choice in force shows in the accent colour, and a greyed-out choice (a series following the defaults) has no accent at all.
- Shift pairing by one is now a switch in the Comic settings panel, under This book, instead of a button on the reader's bottom bar.

## 1.4.0

### Build 131 - 2026-10-22

**Changed**

- **Pins always sync** - the Sync pins across devices switch went; every device has the shared list.
- **Page turn, for comics and eBooks alike** - both called Page turn, both kept on each device (eBooks' was synced:
  it starts at Slide). eBooks' is in Settings > eBooks > Screen.
- **Komga out of reach: the app asks, both ways** - "Can't reach Komga" offers Retry or Go offline (no Stay online),
  and once Komga answers again, "Komga is reachable again" offers Go online or Stay offline - asked once no book is
  open; closed, it stays offline. The "If Komga can't be reached" setting (and its automatic switch) went.
- **Fewer settings, fewer steps** (the settings review, step 2):
  - Gone: Page previews (previews are always on), Page strip as a setting (the Pages button in the reader keeps it),
    the image's Brightness and Contrast, and the Reset box at the bottom of each Settings page (Reset this device's
    settings, under About, stays).
  - Crop edges: Off, 2%, 4%, 6%. Keep the screen on: Off, 10 min, Always. Gutter: comics None, 2, 8, 16 px; eBooks
    12, 24, 48 px. Line spacing: Tight, Normal, Loose. Paragraph spacing: Book's, None, Normal, Large. Margins: Widest
    went.
  - A setting saved at a step that went is back to its default.
- **Settings and the reader's panels, lighter** (the settings review, step 1) - choices are slimmer buttons, the one
  in force a tint of the accent colour rather than solid; the reader's side panel is wider (460 px), so most rows
  fit on one line; screen brightness is one line - Brightness, Auto, the slider; eBooks' Font face shows the font in
  use, in its own face, and a tap opens the list of fonts, each in itself with a line of sample text.

**New**

- **Sign-in: a note when the API key would travel unencrypted** - an address outside your home network over plain
  http:// shows a warning under the Server field (https, home addresses and names, and Tailscale don't).

**Fixed**

- **eBooks in Dual page mode without Inset page: a darker band down the middle** - a shade drawn down the gutter
  (since eBooks first had two pages up) read as a different colour from the page. Gone: the two pages are one even
  colour.
- **Back held a little long with the controls up closed the book** - the press hid the controls, then Android took
  the rest of the held key as a second Back, which closed the book. A held Back (or Esc) now only hides the
  controls; a fresh press closes the book as before.

### Build 130 - 2026-10-20

**New**

- **Dual page mode: Gutter, the space between the two pages, in pixels** - comics: 2 px by default (the pages used
  to touch), in the Comic settings panel under Dual page mode, a default a series can override; the page curl turns
  the right-hand page from its own edge and lands it past the gutter. eBooks: with Inset page, the space between the
  two sheets - 24 px by default, as before - in the eBook panel and Settings > eBooks > Page.

### Build 129 - 2026-10-18

**Changed**

- **eBooks in Dual page mode: chapters start on the next page** - every chapter used to start on a right-hand page,
  leaving the page before it blank; a book of very short chapters showed every left-hand page empty. Now the pages
  run on through the book, a chapter starting on whichever side comes next. The print-book way is a setting:
  "Chapters start on" Next page / Right-hand page, in the eBook panel (Reading) and Settings > eBooks > Page.
- **eBooks are named by their title and author, not "Discworld #13"** - posters show the title, then the author;
  the book's menu, the reader's top bar (the author over the title), Book details, messages and a pinned eBook's
  name use the title too. Comics are named as before ("Saga #3").
- **Settings > Library & Home: eBook posters have their own lines** - "Under eBook posters": Title, Author, Series #,
  Release date (title and author to start with), apart from the comics' "Under comic posters" (Series #, Title,
  Release date, as they were).

### Build 128 - 2026-10-18

**New**

- **Pin to Home from a series', read list's or collection's menu** (right-click, long-press, or hold OK on the
  remote) - the plain view, as its own screen pins it; once pinned, the menu shows the pin's name to rename or unpin
  it.
- **Collections have a menu** - a right-click or long-press on a collection did nothing. Now: Pin to Home, Mark all
  as read / unread (every series in it, asked first), and Rename (admin accounts, as read lists). Read lists and
  collections found by Search have their menus too.

### Build 127 - 2026-10-18

**New**

- **Rename a read list** - ⋮ on a read list (or its poster's menu) > Rename. The new name goes to Komga; the list's
  screen and its pins on Home follow (a pin you named yourself keeps its name). Komga allows it to admin accounts
  only, and turns down a name another read list already has - both are said in words. Not available offline.

**Changed**

- **Pin a single book: named after its series, number and title** - "Discworld #13 · Small Gods" rather than "Small
  Gods" alone (the title is left out when it only repeats the series and number). You can still change the name
  before pinning.

### Build 126 - 2026-10-17

**Fixed**

- **Dual page mode, comics: the page curl showed the next spread through the background** - beside a page alone,
  the part of the screen that should stay until the page lands let the next spread show through at once, and
  the background on the turning half was drawn black whatever its colour. Both now keep the background until
  the turn is over.

### Build 125 - 2026-10-17

**Changed**

- **Dual page mode, comics: turning between a page alone and a spread** - a page alone (the cover) next to a pair or
  a double-page spread now turns as a double page as wide as that spread: the page with background either side of
  it, folding at the spread's gutter like any other spread, the next page on its back. Turning back onto it works
  the same way. The wider spread no longer appears round the page before the turn is over.

### Build 124 - 2026-10-16

**Changed**

- **Dual page mode, the page curl: the next page is on the back of the turning one** - as you lift the right-hand
  page, its back is the next spread's left-hand page, so it lands as that page instead of switching to it at the
  end. Turning back, the page coming over shows the left-hand page you're leaving on its back. Comics only hold the
  old left-hand page itself while the page turns: a double-page spread or a page alone that's wider shows round it
  from the start, as the next page does in a book. A page alone (the cover) still turns away whole. Comics and
  eBooks, Inset page's two sheets too.

## 1.3.0

**Released as build 123, tagged `v1.3.0`** (2026-10-16). Release candidates: build 105 (`v1.3.0-rc.1`).

### Build 123 - 2026-10-16

**New**
- **iPhone and iPad** - BeDeReader runs on iOS, in testing through TestFlight (not on the App Store). Everything the
  Android app does, with iOS's own screen brightness and keep-awake. On first connecting, allow BeDeReader on the
  local network when iOS asks (Settings > Privacy & Security > Local Network), or it can't reach Komga at home.

**Changed**
- **Inset page's spacing settled** - the sheet sits 60 px out from the text at the sides and 24 px above and below,
  and two pages up the sheets are 24 px apart. The three temporary sliders in the eBook panel are gone.

### Build 122 - 2026-10-16

**Changed**
- **Dual page mode: a spread in one picture turns like two pages** - with the page curl, its right half lifts from
  the middle of the picture and turns over onto the left half, and turning back onto it brings its right half back,
  as with a spread made of two pages. (Any page wider than tall counts as a spread.)

**Fixed**
- **Dual page mode, turning back with the page curl** - the left-hand page you were leaving stayed under the page as
  it lifted away, until the turn ended. Now, as in a book, the previous spread's left-hand page shows under it at
  once; only the right-hand side keeps the old page until the turning one lands on it. Comics and eBooks.

### Build 121 - 2026-10-16

**Changed (temporary)**
- **Inset page's gap round the text: two sliders** - "Inset page, sides" (left and right; the old gap slider) and
  "Inset page, top and bottom" (0 to 120 px, 20 to start), in the eBook panel's Reading group.

### Build 120 - 2026-10-16

**New (temporary)**
- **Two sliders in the eBook reader's panel (Reading), to dial Inset page in** - kept on each device, to go once the
  values are settled:
  - **Inset page gap**: how far the sheet sits out from the text, 0 to 120 px (20 to start).
  - **Distance between pages**: two pages up, how far apart the two sheets are, 0 to 200 px (32 to start) - each page,
    sheet and text together, slides to it, and the page curl lands across it.

### Build 119 - 2026-10-16

**Changed**
- **Inset page follows the text** - the sheet's edges now sit 20 px out from the text all round: left of where every
  line starts, above the first line, right of where lines end, below the last. Margins still decide where the text
  sits on the screen (or on its half, two pages up), and Inset page no longer moves it - turning it on or off doesn't
  count the book again. Wide screen shows the sheet when the screen is wider than tall; Always, always. A margin
  under 20 px leaves that side of the sheet at the screen's edge. With Margins: Book's, each page's sheet follows its
  chapter's own margins.
- **The Dark page colour sits on black** with Inset page (it was a near-black grey).

### Build 118 - 2026-10-16

**Changed**
- **eBooks in Dual page mode with Inset page: two separate pages, a gap between** - instead of meeting at the
  spine as an open book, each page is its own sheet with the surround between them as well as round them (Always:
  each card 16 px in all round; Wide screen: the two columns move in to the same gap). The page curl turns the
  right-hand sheet over the gap and lands it exactly on the left one. Without Inset page the pages still touch, with
  the shade down the gutter.

### Build 117 - 2026-10-16

**New**
- **eBooks in Dual page mode** - two pages side by side, as an open book: the Aa panel (Reading) and Settings >
  eBooks > Page, Off / Wide screen (the default) / Always, synced like the other eBook settings.
  - Each page is laid out at half the width, with the margins of a page that size; a book is counted again the first
    time it opens this way.
  - Every chapter starts on a right-hand page, as in a printed book - the page beside it blank when needed - so a
    spread never holds two chapters.
  - Inset page: the two sheets meet at the spine, the surround only round the outside (Always: each card runs to the
    spine; Wide screen: the two columns move in to meet), with a soft shade down the gutter.
  - The page curl turns the right-hand page over onto the left, attached at the spine; the left-hand page stays put
    meanwhile.
  - A turn goes a spread at a time; the position reads both pages ("Pg. 4-5/312"); the place saved is the left-hand
    page. Text can be selected, highlighted and defined on either page.
  - Turning the screen, or resizing the window, keeps the place.

**Fixed**
- **Dual page mode: the turning page no longer pulls away from the spine** - dragged all the way across, it went on
  past the other page and its spine edge lifted, the page beneath showing at the gutter. It now stays attached along
  the spine, its roll flattening as it goes, and lands flat exactly over the other page.

### Build 116 - 2026-10-16

**Changed**
- **Dual page mode** (two pages side by side; it was "Two pages") moved into the reader: Comic settings, with the page
  layout - and to Settings > Comics > Pages - defaults. It's now a reading default, the same on every device, that a
  series can override with its own (Override defaults, as for Fit and Direction); Make default carries it too. Off,
  Wide screen and Always as before. A device that had it off is back on Wide screen.

### Build 115 - 2026-10-16

**Changed**
- **Comics in two pages: the page curl turns one page, like a book** - going forward, the right-hand page lifts from
  the gutter and turns over onto the left while the left-hand page stays put; going back, the previous right-hand page
  comes back over. Right-to-left series turn the other way. A page alone (the cover) or a spread still curls whole.

### Build 114 - 2026-10-16

**New**
- **Comics in two pages side by side** - Settings > Comics > Screen > Two pages: Off, Wide screen (when the screen is
  wider than tall - the default) or Always; set on each device on its own.
  - The cover is alone, a spread (a page wider than tall) is alone, and a page alone is centred. The pages before a
    spread pair up so the spread starts on a left page, as in print - in a scan missing its inside cover, the page
    after the cover is the one alone.
  - A turn goes a pair at a time; the position reads "Pg. 4-5/40"; progress is the later page shown, so the last pair
    finishes the book. Turning the screen keeps the page.
  - **Shift pairing by one** on the bottom bar (two pages up) re-pairs the pages before the first spread, for that
    book on every device - for a scan whose pairs come out a page off.
  - Two pages show as one picture: fit, zoom and Enhance work on the pair; Crop trims each page before they meet.
  - Save page and Copy page ask which: the left, the right, or both as one picture.
  - Right-to-left series read their pairs right to left.
  - The page curl still turns both pages as one for now.
  - Books downloaded before this build pair without knowing their spreads - download them again.
- **Pin a single book to Home** - "Pin to Home" in a book's menu (long-press or right-click its poster) and a pin
  button on its Details screen. On Home it shows the book's cover, the name you gave the pin and how far through it
  you are ("34% read"); a tap opens the reader. Long-press it to rename or unpin it. Offline, a pinned book that isn't
  downloaded is hidden, as other pins with nothing downloaded are; one deleted from the server says so and offers
  Unpin.

### Build 113 - 2026-10-16

**Changed**
- **Inset page: the sheet is set in from the top and bottom on wide screens too** - Wide screen and Always draw the
  sheet 16 px in from the top and bottom of the screen, as Always's card on a narrow screen; the text moves in with
  it, so books on a wide screen count their pages again the first time.

### Build 112 - 2026-10-15

**Changed**
- **Settings > eBooks > Screen: Inset page** replaces the "Page as a sheet on wide screens" switch, with three
  choices: Never (the page's colour across the whole screen), Wide screen (the sheet as before, where the lines
  leave room to spare) and Always (on a narrow screen too: the page becomes a card set in from all four edges, the
  text laid out inside it - a portrait tablet's pages count again the first time). Set on each device on its own; a
  device that had the switch off is back on Wide screen.

### Build 111 - 2026-10-12

**Changed**
- **A downloaded book is read from the device, online too** - a comic's pages (the page strip and the slider's
  pictures too) and an eBook's file load from the download instead of Komga (faster, and no data used). Reading
  progress and highlights still go to Komga as you read. A book still downloading, or one whose files have gone, is
  read from Komga as before.

### Build 110 - 2026-10-12

**New**
- **Windows: the mouse pointer hides while you read with the keyboard** - turning a page with a key (or a remote)
  hides it; it's back as soon as the mouse moves. Turning pages with the mouse leaves it where it is.

### Build 109 - 2026-10-12

**Fixed**
- **Windows: a right-click with the mouse moving went missing** - in both readers (the controls) and on posters (the
  menu); so did a click that hides the reader's controls. Moved more than a short way while pressed, it wasn't taken
  as a click. Now they count however far the mouse moves.

### Build 108 - 2026-10-12

**New**
- **A key for the side menu**: Settings > Remote and keys > Anywhere else > Open the side menu - no key until you give
  it one. It opens the side menu on Home, a library, a series and the like (and closes it again); not while you're
  typing in a box. Kept on each device, like the reader's keys.

**Fixed**
- **Windows: mouse clicks went missing** - on Home's posters, and on an eBook's page (it took a couple of clicks to
  bring up the controls). A mouse moved by even a pixel while clicking was taken for a drag: on Home for the side
  menu's swipe (now a finger's only - the mouse has the menu button), on a page for selecting text. And a second click
  made in doubt cancelled the controls; a double click where there's no word now brings them up.
- **eBooks: highlights never reached Komga** (since they came in build 103) - Komga turned every save down (the
  name they're kept under had capital letters, which it doesn't take), so they stayed on the device they were made
  on. They're sent now - each book's the next time it's opened.

**Changed**
- **eBooks: a double click selects a word with the mouse only** - on a touch screen a word is a long press, as
  before, and a tap in the middle of the page opens the controls at once again (since build 106 it waited a moment
  for a second tap).

### Build 107 - 2026-10-12

**Fixed**
- **eBooks: the selection pane's buttons did nothing** (build 106) - a click or a tap on Highlight, Define or Copy
  made the pane vanish before it took the click.

### Build 106 - 2026-10-12

**Changed**
- **eBooks, selecting text: the same pane everywhere** - Copy, Highlight, Define - shows above the selection by
  itself once it's made, with the mouse too (on Windows it took a right-click and looked different).
- **eBooks: a double tap or double click on a word selects it** (in the middle of the page - the sides still turn
  pages at once). A single tap in the middle opens the controls a moment later than before, to tell the two apart.
- **eBooks: highlights are in the app's accent colour** (they were always yellow).

**Fixed**
- **eBooks: a highlight could only be removed by tapping it** - a selection over a highlight now offers Remove
  highlight.
- **Downloads went missing when Komga moved to a new address** (the same server, its database moved with it):
  downloads are kept per server address, so the new address started with none. Now, when the new address has no
  downloads and Komga there has the books downloaded at an old address, they carry over - with any reading progress
  not yet sent.

### Build 105 - 2026-10-11

**New**
- **Settings > eBooks > Screen: Page as a sheet on wide screens** - switch the sheet and its surround off to have
  the page's colour across the whole screen (the lines stay as they are). Set on each device on its own.

**Changed**
- **eBooks, Page turn: Curl - the back of the turning page is the page's own colour** (it was white paper, glaring
  on the dark and black pages).
- **eBooks: footnotes and endnotes open in a panel like Define's** - sliding up from the bottom, headed "Note" with
  its marker, the note in larger text; Back or a tap outside closes it (it was a plain box with a Close button).

**Fixed**
- **eBooks: a footnote showed every note in the book** in books that keep all their notes in one block (Hogfather
  and other calibre-made books); it now shows just the note tapped.

### Build 104 - 2026-10-11

**New**
- **eBook settings: Margins has a Book's step** - the book's own page margins, as a web browser shows them (a small
  edge where the book sets none, and always room at the edge for a line-end hyphen). Lines then run as long as the
  screen allows, and there's no sheet on a wide screen.
- **eBooks: page previews on the slider**, as comics have: dragging the slider shows a small picture of the page
  you'd go to, with its page number and chapter.

**Changed**
- **eBooks open sooner**: the book's own text size is measured on its first open and remembered, instead of
  loading five chapters to measure it every time the book is opened. It's now judged from all of the book's body
  text, not only its paragraphs.
- **eBook settings: Paragraph spacing now decides the gaps between paragraphs, and the Paragraphs setting is
  gone.** Its choices are Book's (the book's own gaps), Default (no gap, as before), Small, Medium, Large and
  Extra large. A step sets the gap between paragraphs rather than adding to the book's; where the book keeps a
  gap (paragraphs it doesn't indent, under a picture, scene breaks), it's never made smaller. Indents are always the
  book's own - a chapter's first paragraph and the one after a scene break are indented when the book indents them.
  Paragraphs with a hanging indent count as indented, as first-line ones do. (The old Paragraphs choice isn't
  carried over: everyone starts on Default.)
- **eBooks: bold text is no longer taken for a title.** In books that write their paragraphs as plain blocks of
  text (the Belgariad among them), a bold line opening a block used to be treated as a title; it's now a paragraph
  like the others - only text set larger than the text around it counts as a title, a short bold list item or
  quotation included. (The Belgariad's chapter titles now read as ordinary lines.)
- **eBooks: pictures.** A picture drop cap is drawn at its own size (it used to be enlarged to two lines of text). A
  picture that doesn't fit in the space left on a page goes to the next page at its size instead of being shrunk into
  the gap; only one taller than a whole page is shrunk. Black-and-white ornaments on a white ground are drawn in the
  page's colours more often (Hitchhiker's and Homeland's drop caps, The Dispossessed's chapter numbers, A Dance with
  Dragons' chapter bands were white boxes on a dark page), and those don't open full screen with a tap; maps and
  illustrations are left as they are.
- **eBooks: superscript is raised small text**, as a web browser draws it: footnote numbers, the "st" of 1st and
  note letters keep their own characters (they used to become superscript digits, and letters only got smaller).
  Note markers are raised small text too, still bold in the accent colour, instead of text-sized on the line; an
  asterisk marker stays at its usual height. Copied text has the characters as written, and a selection or a
  highlight on them is drawn where they are.

**Fixed**
- **eBooks, Page turn: Curl - a curl let go before it turned still counted as a page turn**: the page sprang back,
  but the place was saved as if it had turned, and on the last page the book could be marked read. A turn now counts
  only when it completes.
- **eBooks: build 103's first-paragraph fix (Foundation's double gap) went too far** in books whose ordinary
  paragraphs are set flush and only special passages are indented (a letter, verse, an epigraph - the Brian Herbert
  and Kevin J. Anderson Dune books): those passages had lost the space above them. They keep it again; Foundation
  and the like keep the fix. (It now applies with any Paragraph spacing step; the Paragraphs setting it was under is
  gone, above.)
- **eBooks: small pictures were tiny** (scene-break stars, chapter ornaments): pictures are now sized as a web browser
  sizes them - at the size the book gives, or a small one at its own size in points; big pictures still never get
  bigger than their own pixels.
- **eBooks, highlights: the list in Contents is in reading order** (chapter 10's came before chapter 2's), and damaged
  saved highlights no longer stop a book's highlights loading.

### Build 103 - 2026-10-11

**New**
- **eBooks on a wide screen read like a sheet of paper**: when the window (or the tablet in landscape) is wider than
  the page needs, the page is drawn as a sheet in the middle, with a soft shadow at its edges, on a surround a shade
  off the page colour. Turning a page slides the sheet; the surround stays put. Portrait and narrow windows are
  unchanged.
- **Define a word in an eBook**: select a word (or a short phrase) and press Define in the pane - its meanings,
  with examples, from an English dictionary built into the app (Open English WordNet), so it works offline. A word
  that's a form of another ("running", "mice") shows that one's meanings too. English only for now.
- **Highlight text in an eBook**: select and press Highlight. Highlights are kept on Komga with your account, so
  the tablet and the PC share them (made offline, they go up once Komga can be reached). Tap one to copy it or
  remove it; the Contents panel lists the book's highlights - tap one to go to it.
- **Page curl for eBooks**: eBook settings > Page turn has Curl, the 3D page turn comics have - a tap, a key or the
  remote plays the whole turn; a drag lifts the page with your finger (let go early and it falls back). On a wide
  screen the sheet turns over the surround.

**Fixed**
- **eBooks, Paragraphs: Auto - a double gap under a chapter's first paragraph** in books that start chapters with
  an unindented paragraph and indent the rest (Foundation): the gap under it is now the same as between the others.
  The book is laid out again the first time you open it.

### Build 102 - 2026-10-11

**Fixed**
- **Remote: you couldn't see when you were on the Filter button while filters were on** - its focus outline was the
  same colour as its fill. It now shows the same focus look as every other button.
- **The writer / author and artist pickers say when they don't list every name**: with nothing typed they list the
  first 50, and now say so at the end of the list - type a name to find the others.

### Build 101 - 2026-10-11

**Changed**
- **eBook pictures: the rotate buttons sit in the screen's top corners** now, and stay there as the picture turns
  (on the picture's own corners they moved with it).

**Fixed**
- **Windows: a right-click showed the reader's controls but didn't hide them again.** It does now, in comics and
  eBooks.

### Build 100 - 2026-10-08

**Fixed**
- **An eBook could forget where you were and open at its start**: closing it as the screen changed size (on the
  tablet: going back to Search, whose keyboard comes up) saved the book's start over the page you'd reached. The
  place reached is saved now, and the reader no longer lays the book out again for a keyboard.

### Build 99 - 2026-10-08

**New**
- **Rotate a picture in an eBook**: a tapped picture now opens at 95% of the screen with a rotate button in each top
  corner - left turns it counterclockwise, right clockwise. With the remote, Left / Right go to them and OK presses.
- **Select text in an eBook and copy it**: press and hold a word (on a PC: drag with the mouse), drag the handles to
  take more - across paragraphs on the page - and Copy from the pane that pops up (Ctrl+C on a PC). Copied text is
  plain: words split over two lines come out whole. A tap lets go of the selection; turning the page does too.
  (Holding a finger on the page now selects a word rather than turning the page.)

**Changed**
- **eBooks: the spinner while a book is laid out says "Adjusting and storing layout"** (it was "Laying out the
  book") - it shows the first time a book opens in your settings, and again after you change them.

### Build 98 - 2026-10-08

**Changed**
- **eBook margins in five steps**: Narrow, Normal, Wide, **Wider** and **Widest** - Widest leaves about a quarter of
  the page each side on the tablet. The top and bottom margins no longer change with them.
- **Line spacing in five steps**, 1 to 2: Compact, Tight, Normal, Loose, Double. **Paragraph spacing in five**: None,
  Small, Medium, Large, Extra large. What you had chosen keeps its spacing (paragraph "Small" now shows as Medium).
- **Filters**: no Clear filters button in the top bar any more - clear them in the filter panel or with the chips;
  the funnel is filled with your accent colour while filters are on.

**Fixed**
- **Option buttons too wide for the screen** (Keep the screen on, on a phone) were shrunk as a whole, hard to tap.
  Now only their text shrinks; the buttons keep their full size.

### Build 97 - 2026-10-08

**New**
- **Filters**: a funnel button on libraries (Series and Books), series, collections and read lists opens a filter
  panel (beside the grid on a tablet or PC, from the bottom on a phone): **Writer** (Author for eBooks), **Artist**
  (penciller, inker or cover), **Release years**, and for series **Publisher**, **Status** and **Genre**. Names are
  picked by typing; only what the view holds is offered; the Show button counts what you'll get. Active filters
  show as chips under the bar - tap one to remove it. Remembered per view, kept by pins, and working offline on your
  downloads.
- **Select several series** (library Series mode, a collection): mark them read or unread, or download them.

**Changed**
- **One top bar**: libraries, series, collections and read lists have their buttons in the same order (count, eye,
  filter, sort, select, size, pin, search, refresh, more); buttons that don't apply are left out.
- **Sort everywhere**: a series sorts by number, release date or date added (the oldest / newest toggle became the
  sort menu - a series set to newest first opens oldest first once); a collection by its own order, title, release
  date or date added; a read list by its order or release date; collections and read lists by name or last update.
  Refresh on every view.

### Build 96 - 2026-10-08

**Changed**
- **Your API key is now stored encrypted** (the Android Keystore; Windows' own data protection), no longer in plain
  text in the app's settings. **You'll need to sign in once more** after updating: the old plain-text key is
  removed, not moved over.

### Build 95 - 2026-10-08

**Fixed**
- **Search: the Books row left out the books of the series found** - it showed only books whose own title matched.
  It now also lists every book of the series in the Series row, after the matched ones, in series and number order,
  each once. Offline, the same from your downloads.
- **Downloading a whole series asked Komga the same three things for every book** (the series, the library list,
  the series' collections) - about 150 requests for a 50-book series. Now once per run of the queue.
- **One book Komga kept refusing (its reading progress) made every return to the app refresh all your downloaded
  series.** It's still retried every couple of minutes, when you come back online and when you sync, and at once if
  you read it again; on its own it no longer triggers the full refresh.
- **Fewer requests to Komga**: a Home reload asks for the synced settings once, not three times; the side menu keeps
  the library list instead of asking at every opening (it asks again when the app starts or comes back to the front,
  and on Home's Refresh); connections are closed after a failed sign-in and on signing out.
- **A book with no number showed as "Saga #null"** (the end card, the series line under posters, sync messages) **or
  "Saga #"** (elsewhere). It's now just "Saga", the same everywhere.

### Build 94 - 2026-10-07

**Changed**
- **Library & Home and Downloads have a "Reset to default" too.** The Black page colour's swatch has a light ring,
  so it shows on the dark background.

### Build 93 - 2026-10-07

**Fixed**
- **Settings > Remote and keys: + Add didn't take the key you pressed** (the volume keys included) on the tablet. It
  now takes the next key pressed, wherever the focus is.
- **eBook settings no longer lay the book out at every step**: changing the size five times in a row lays it out
  once, when you stop.
- **The brightness slider in the reader's panels had lost its label**; it's back.

**Changed**
- **Settings wording**: "Skipping to the next book" - "Mark the one you leave as read?" Yes / No / Ask (it was
  "'Next book' before the last page"); "Show page counter" (was Page corner); "Font face" and "Font size";
  Paragraphs Book's / Auto; "Auto-hyphenation"; "Override defaults" with no line under it; "Reset to default" on every
  page; Comics' groups "Pages - defaults" and "Image - defaults".
- **Position text names**: Chapter progress, Book progress and Chapter name for eBooks; Book title and Progress for
  comics.
- **The eBook text size is synced again**, with the rest of the eBook settings.
- **eBook page colours**: a Black page added; Sepia is now a warmer, more book-like paper with darker text.
- **Accent colours**: 12 colours spread round the wheel (several crowded round blue before) and four greys - White,
  Silver, Slate and Charcoal. Teal, Amber, Cyan, Sky, Indigo and Fuchsia are gone; a device using one goes back to
  Blue.
- **Settings > Reading: moving Screen brightness shows it** - the screen takes that brightness while you hold the
  slider (or the remote is on it), and goes back when you let go.
- Settings > Downloads: the "a book that won't fit" note is now part of Storage limit.

### Build 92 - 2026-10-07

**Fixed**
- **The remote lost its place** after removing a key in Settings > Remote and keys, or moving a Home section to the
  top or bottom with its arrows. The focus now goes to the row's Add, or stays on the arrow (dimmed at the ends).
- **A pin saved without a sort direction** showed its poster in one order and opened in the other, and pinning the
  same view again made a second pin. Both now use the sort's natural direction, as the screen does.
- **View series in a book's details said nothing** when Komga couldn't be reached; it now says so.
- **Sign-in: pressing Enter twice connected twice.** Book details now loads the book and its series together.
- **The Page corner setting's description was out of date**: it still said EPUBs show the pages left in the chapter.
  It now reads "The page you're on, "12 / 36"" - what both comics and EPUBs show.

**Changed**
- **A hidden spot in the position text over the slider is gone**, not a "hidden - tap to show" box. Tap where it was
  to bring it back.
- **Comics and eBooks each have their own page corner, rotation, clock and battery, progress bar and position text.**
  They start at their defaults (page corner: After a turn for comics, Always for eBooks).
- **eBooks: "Book's formatting" is now three settings** - Alignment (the book's, justified or left), Paragraphs (the
  book's indents and gaps, or yours) and Hyphenation (on or off). They start at Justified, Mine and on.
- **eBooks: the text size is kept on each device**, so the tablet and the PC can read at different sizes. The rest of
  the eBook look is still the same everywhere. "Reset this device's settings" puts it back too.
- **The volume keys are ordinary keys now.** "Volume keys turn pages" is gone: to turn pages with them, add Volume
  down to Next page and Volume up to Previous page in Settings > Remote and keys. Until then they change the volume.
- **Book posters: Series #, Title and Release date are three separate choices**, shown in that order - any of them,
  or none.
- **Settings are reorganised.** Under *Reading*: Reading (brightness, keeping the screen on, Next book - for both
  kinds of book), Comics, eBooks, Remote and keys. Under *App*: Server and sync, Library & Home, Downloads, Look.
  Under *Help*: About. Settings now opens on Reading.
  - Comics holds what used to be Reading defaults and the Comics page; eBooks holds everything for EPUBs, including
    their page corner, clock, progress bar and rotation.
  - Groups that are the same on every device are marked with a cloud and "synced". Server and sync says what Komga
    keeps in step, and has the Sync pins switch (it was in Library & Home).
  - Each page has its own "Back to the defaults" button, which asks first.
  - Night mode is one choice, Off / On / Scheduled, on Look.
  - The position text and the page strip can be set in Settings too (the position text for comics and eBooks
    separately).
  - Comics' Background and eBooks' Theme are both called **Page colours**; the comic page turn "Wipe" is now
    **Slide**, as for eBooks.
- **The reader's panels hold only what you'd change while reading.** *Comic settings* (was Reader): this page, this
  series' fit, direction and page colours, then position text, brightness, rotation and keeping the screen on.
  *eBook settings* (was Text and page): size, font, spacing and margins, alignment, paragraphs, hyphenation, then page
  colours, position text, brightness, rotation and keeping the screen on. Night mode is the top bar's moon; the rest
  is in Settings.

### Build 91 - 2026-10-07

**Fixed**
- **The last rows of a page sat behind Android's home / back bar** when the remote moved down to them (Comics > Keep
  the screen on, for one). Settings, Home, the libraries, search, a book's or series' details, Downloads, About and
  the documents now end above the bar.
- **With a remote, Up and Down in Settings and the readers' side panels skipped rows** - from a long row they jumped
  past a shorter one under it (Remote and keys: "Show the controls" to "Zoom in"; the EPUB panel: Font to Line
  spacing, Margins to Book's formatting). The fix for this in build 52 only ever worked in the test setup, never in
  the installed app. Up and Down now go to the next row's first control, every time.

**Changed**
- **Settings: "Reader" is now "Comics", and "Books (EPUB)" is "eBooks"** - the two pages for the two kinds of book.
- **EPUBs: the chapter's page over the slider reads "Ch. · Pg. 3/12"**, with no chapter number. The number was the
  book's own file count, so it could say "Ch. 4" under a chapter named "Chapter One".

### Build 90 - 2026-10-07

**Changed**
- **Comics and EPUBs now open in the same reader** (the second step of making them one). For EPUBs that brings:
  - **Next book and Previous book work as for comics**: Previous goes back through the books read in this visit,
    and Next retraces them; past those, the book before or after in the read list or series.
  - **A comic and an EPUB go on to each other in place** - in a read list that mixes them, Next book opens the other
    kind straight away, in the same reader.
  - **Night mode and Delete book** in the top bar.
  - **The way back on the slider**: after a jump (the slider, Contents or a link) a mark shows where you were, and
    a drag near it snaps back to it.
  - **The same end card, position text and page corner as comics**: the end card says "End of book"; over the
    slider the chapter's name is on top and the book's and chapter's pages below, each tapped to hide or show it;
    the "112 / 342" corner is the comics' grey pill, bottom right.
  - **Retry** when a book can't be opened.
- **EPUBs with "Book's formatting" off no longer indent every paragraph.** A paragraph's first line is
  indented only where the book itself indents it, and by the book's own amount. A book that marks its paragraphs
  with a space between them instead keeps that space (taking out both made the paragraphs run together).

### Build 89 - 2026-10-07

**Fixed**
- **EPUBs opened from a read list went on to the next book in their series**, not the read list's: the end card,
  Next book and Previous book all ignored the read list (Hitchhiker's Guide from a "Top 100" list offered its
  sequel instead of the list's next book). They follow the read list now, and the next book opens still in it. Opened
  with read books hidden, they also skip books already read, as comics do.
- **EPUBs: holding a remote button, or tapping quickly, made the page creep without turning.** Each turn asked for
  while a page was still sliding started the slide over from where it was. Now a turn asked for mid-slide waits and
  goes the moment the slide ends: a held button turns a page each time, and stops after one more when let go. A tap
  ends the slide at once and starts the next, so quick taps turn a page each.

**Changed**
- **EPUBs' page corner shows the book's page, "112 / 342"**, the same as comics' "12 / 36" - it showed the pages
  left in the chapter and the %.
- **An EPUB shows once its pages are counted.** Opening one now shows "Laying out the book" with the chapter it's
  on, and a Close button, until every page is counted - a few seconds for a typical novel the first time, longer for
  a very long book. From then on the page numbers, the slider and the corner are exact from the first page (before,
  the book opened at once but went by chapter, with only a % for the book, until it had been counted in the
  background). **The count is remembered on the device**, per book and per layout: opening the same book again at
  the same text settings and screen size is immediate. Changing the text size, font, spacing, margins or turning the
  screen lays the book out again behind the same spinner - instant for a layout already used.

### Build 88 - 2026-10-07

**Changed**
- **Comics: the end-of-book card has Next book and Close buttons**, as EPUBs' does. The remote lands on Next book
  (on Close when there's no next book); Up and Down move between them and OK presses the one it's on. A tap on the
  far side or the forward key still opens the next book, and a key held down still stops at the card. (OK on the
  card used to bring up the controls; a tap in the middle of the screen still does.) This is the first piece of the
  comic and EPUB readers becoming one reader.
- **One "Page corner" setting for comics and EPUBs**: Always / After a turn / Off. It replaces comics' "Page number
  after a turn" switch and EPUBs' own "Page corner", and it's now a setting of this device (in Settings > Reader,
  the comic Reader panel and the EPUB Aa panel alike). Comics' "12 / 36" moves to the bottom-right corner, where
  EPUBs' note is, and can now stay there all the time. Each device starts from what it had for EPUBs.
- **Comics: where you are, over the slider on two lines** - the book's title ("Saga #1 - Chapter One") on top, and
  the page and how far through ("Pg. 12/36 · 33%") on the left just above the slider, which gets the room the
  "12 / 36" beside it had. **Tap either one to hide it**; its place stays, dimmed, to tap it back. That's
  remembered on this device. (EPUBs get the same row when their reader moves over.)

### Build 87 - 2026-10-07

**Changed**
- **Zoom in from the remote or the keyboard goes to where reading starts**: from the whole page, the first step lands
  on the page's top-left corner (top-right in a right-to-left book), and further steps stay on it - it used to zoom
  into the middle of the page. Panned somewhere, a step keeps what's at that corner of the screen. Quick presses
  each zoom a full step. Pinch and double-tap still zoom where your finger is.

**Fixed**
- **Rotation lock: choose upside down** (Android). Portrait and Landscape now hold exactly one way up - the way
  you're holding the tablet when the lock starts (opening a book, or choosing it) - and turning the tablet doesn't
  move them. Tap Portrait or Landscape again while reading to turn the page upside down, to read that way on purpose;
  tap again to turn it back - the lock in force shows circling arrows beside its name, as a switch. Only Auto /
  Portrait / Landscape is remembered, not the way up. The lock now holds in
  EPUBs too (it was in their panel but did nothing).
- **EPUB: holding down an arrow key (or any page-turn key) turned no pages** - the page crept and never turned,
  each of the key's repeats starting the slide over. A held key now turns a page each time the slide ends.
- **EPUB: a word split across a page turn** ("ea-" at the bottom of one page, "gle" at the top of the next). As in
  print, a page no longer ends on a hyphenated word: that line goes over to the next page, leaving this one a line
  short.
- **EPUB, with your own formatting: text right under a picture** (a chapter's ornament, with the first line touching
  it). Your formatting takes out the book's gaps between paragraphs, and it took the one under a picture or a table
  too; that one stays now, as with the book's formatting.

### Build 86 - 2026-10-07

**Changed**
- **Downloads > Manage:** a series card's open / close arrow is at its left, away from the trash button.
- **Downloads > Queue:** no "Finished this session" list - what's downloaded is in Manage.
- **The eye is three-way, on every library screen**: each tap goes Show all → Hide read → Hide unread (only what
  you've finished; in progress counts as unread, as before). It's now in the Read lists and Collections views too:
  lists with nothing to show under the filter are left out, and their posters are made from what the filter shows -
  a read list's first four books (read or not on Show all - a finished list used to show Komga's poster; unread or
  read under the filter), a collection's first four matching series ("3 of 8 series unread"). Pins keep the filter.

### Build 85 - 2026-10-07

**Changed**
- **Downloads > Manage:** each book has a trash button again (it was a menu with one item), and a series' card has
  one for the whole series (it asks first). A series stands apart from its books: a shaded card with a series icon
  and its name in bold. The line above the storage bar starts with the number of books ("14 books · 1.0 GB used ·
  limit 10.0 GB").

### Build 84 - 2026-10-07

**Added**
- **Downloads > Manage: Group by series.** One group per series - its books, size and how many are read - closed
  until you tap it. Sorting by size puts the biggest series first; the filters apply inside the groups. In select
  mode a group's box ticks its whole series, and its menu removes the series. Remembered on each device.

**Fixed**
- **Progress bars looked full whatever they showed** - the storage bar in Downloads (10% used looked like 100%), a
  download's progress in the queue, and the bar under the search box: the unfilled part was drawn in the accent
  colour too. It's grey now.

### Build 83 - 2026-10-07

**Changed**
- **Downloads in two tabs: Queue and Manage.** Queue is what's downloading (pause, retry, cancel, as before).
  Manage is what you've downloaded: sort by name or by size (largest first), show all, only read, only unread, or
  books no longer on Komga, and remove in bulk - **Select** (or long-press a book) to tick several, with how many
  and how much space before you confirm; a book's menu removes it or its whole series; **Remove all read** clears
  everything you've finished. The screen opens on Queue while something is downloading, on Manage otherwise.
- Build tools: a build now closes the Desktop copy of the app if it's open, then updates it (it used to skip the
  update and say so).

## 1.2.0

**Released as build 82, tagged `v1.2.0`** (2026-10-07). Release candidates: build 62 (`v1.2.0-rc.1`).

### Build 82 - 2026-10-06

**Fixed**
- **Search: the progress bar stayed on** after clearing the box while a search was still running.
- **EPUB, downloaded books: the place you stopped stays right** through syncing - when another device read further it
  takes that place (the older one used to stay, and could be sent back over it), marking a book unread clears it,
  and removing a download before it's synced still sends the place. Saving a place offline no longer rewrites the
  whole downloads list.
- **EPUB: no false "Read on another device" questions about your own reading**, and no lost last page: Mark read /
  unread waits for a save on its way (it could put the book back in progress), a save that failed is sent again on
  closing, and a book closed and quickly opened again waits for the closing save.
- **EPUB: moving through a book** - a chapter that can't be loaded shows its error as a page, with the controls and
  page turns still working (it took over the screen, leaving only Retry and Close); turning back into a chapter goes
  to its last page; before the whole book is counted, a swipe goes on into the next chapter as taps and keys do;
  minimising the window no longer loses the place; a link whose target can't be found opens its chapter instead of
  doing nothing.
- **EPUB: how books look** - a book's styles now apply from its first rule (books made with Calibre lost it, often
  the one setting their body text); scene breaks drawn as a rule or a blank line keep their space; a drop cap written
  as a letter stays in its own paragraph; a floated picture on its own beside the text no longer disappears; French
  and other accented characters written as named entities (`&laquo;`, `&egrave;`...) show as the characters; a
  drop cap made by the book's style takes the opening quote mark with the letter; rules for a first paragraph
  (`:first-child`) apply; text after a picture in a paragraph keeps the paragraph's formatting; deeply indented text
  stays on the page; a table row taller than a page carries on over the next pages, and a table with very many
  columns keeps them in order; links and footnotes land on the right page in long chapters; a chapter with an odd
  character code or no room beside a picture no longer fails to show. Chapters with many copies of the same
  ornament load faster and use less memory.
- Build tools: a failed release step now really puts the changelog back; a build that fails early puts the version
  number back; and if a new Desktop copy can't be swapped in, the old one stays in place instead of none at all.

### Build 81 - 2026-10-06

**Removed**
- **The web version.** BeDeReader is an Android and Windows app; the browser build, its download and every
  browser-only path in the app are gone.

### Build 80 - 2026-10-06

**Fixed**
- **EPUB: a downloaded book opened at an older place** (left at 31%, it came up at 12% offline), and a page read
  offline could have moved Komga's place for it the wrong way. Downloaded EPUBs now keep the exact place - kept
  current while you read online or elsewhere - and send the place itself back to Komga when you're online again.
- **EPUB: the mouse wheel turns pages**, as it does with comics (it did nothing).
- **EPUB: resizing the window or changing a setting no longer moves you back** - each change started from the top of
  the page on screen, so a few of them walked back a page.
- **Downloads: an EPUB shows as "EPUB · size"**, not "0 pages".
- **EPUB: small black-and-white pictures on white** (chapter numbers, drop caps, ornaments) are drawn in the page's
  colours, instead of as a white box on a dark page.

### Build 79 - 2026-10-06

**Added**
- **EPUB: "Read on another device"** - as with comics, when a book was read further (or finished, or marked unread)
  on another device while it was open here, the reader asks before saving: stay where you are, or go to that place.
  Coming back to the app checks too, and closing the book never saves over another device's place.

**Changed**
- **EPUB: the page-turn measuring is off in everyday builds** (frame times and the rest, added in builds 76-78 to
  find what made turns less smooth than in comics). It's compiled in only for a measuring build; the reader's
  trace of what it did, kept for crashes, stays.

### Build 78 - 2026-10-06

**Fixed**
- **"Can't reach Komga": Retry could spin for good** when Komga had already answered while the message was
  opening - the message now closes itself as soon as Komga is reachable, and a Retry that gets through closes it.

**Changed**
- **EPUB: the reader's trace is written in the background**, never holding up a page turn (a candidate for the one
  frame each tap's turn still missed), and it now counts frames that started late and times what a page change does.

### Build 77 - 2026-10-06

**Changed**
- **EPUB: smoother page turns on a tap** - the slide takes a little longer (320 ms) and eases in and out, rather
  than starting with a jump, and the next page is ready before the turn starts (most tap turns skipped a frame at
  the start - measured on the tablet; swipes didn't).

### Build 76 - 2026-10-06

**Changed**
- **EPUB: the reader's trace now records how smoothly pages move** - frame times each second while pages are moving,
  and how long each chapter takes to lay out - to find what makes page turns less smooth than in comics.

### Build 75 - 2026-10-06

**Fixed**
- **EPUB: a hyphen missing where a word was split at the end of a paragraph's first line** ("power / ful"), in books
  with a text size of their own (since build 72): the hyphen was drawn at the wrong size, just above the line, and
  left out.
- **EPUB: books that write their paragraphs as plain blocks** (Codex Alera, Dune) now get Paragraph spacing and the
  reader's own formatting like any other, and Dune's text, set smaller all through, shows at your text size.
- **EPUB: the book's % no longer jumps when page counting finishes** (24% → 2% in The Dispossessed): until then,
  chapters are weighed by their length as Komga measures it, not counted as equal.
- **EPUB: boxes in place of dashes and quotes** in older, badly converted books (The Forever War's "Sir□we") show
  the characters they stood for.
- **EPUB: headings are no longer hyphenated** ("DEMOS-THENES"), and get a little space under them when the book
  leaves none (New Sun, Xanth, the Belgariad).
- **EPUB: a chapter number that links back to the contents no longer looks like a footnote marker** (Ender's Game).
- **EPUB: table columns are never narrower than their longest word** (the Three-Body Problem's list of characters).
- **EPUB: drop caps drawn as pictures are at least two lines tall** (Homeland's were a speck beside one line);
  larger ones still show at their own size.

### Build 74 - 2026-10-06

**Fixed**
- **Android: the app jumped back to Home by itself** when a remote or keyboard connected or disconnected (a
  Bluetooth remote waking up, the tablet waking from sleep): Android restarted the app's window for the change. The
  app now takes the change in its stride and stays where you were.
- **Switching Enhance on while reading made the page vanish** until the enhanced picture was ready. The page stays
  on screen meanwhile (a page appearing still waits for it, so there's no flash of the unprocessed page).
- **EPUB: some books came out boxed, bold and oddly indented** (Exile, for one): a border the book sets to width 0
  was drawn as a box round the text; a first-line indent given in points was taken as about 16 times too big (the
  first line started a third of the way across); and a book that sets all its text bold now shows at normal weight
  (as with a book-wide text size: the book's overall setting doesn't override yours; headings keep their bold).

### Build 73 - 2026-10-06

**Fixed**
- **Hiding a book or series from On deck could be undone at once** when Home was open underneath: Home's refresh put
  back the list from before the hide. Synced lists (pins, On deck hidden) and reader settings now take only Komga's
  copy when refreshing, and never over a change made here that hasn't reached Komga yet.
- **Starting the app could send an empty pins or On deck hidden list to Komga** (when a change from last time hadn't
  been sent): the list is now read from the device before anything goes.
- **Two quick On deck hides could reach Komga out of order, or one not at all**: they now go one at a time, and a
  failed one is tried again a minute later (as pins do).
- **Turning pin sync off while a send was failing** still sent this device's list over the shared pins a minute later.
- **Home loaded everything three times on each refresh** (and twice on opening): once now.
- **"Read further on another device" about your own page**: after a page save failed (a network blip), or coming
  back to the app while a save was on its way, the comic reader took its own earlier page for another device's and
  asked. A page now counts as saved only once Komga has it.
- **A save went through while that question was on screen**, putting this device's page over the other device's
  before you'd answered. It now waits for your answer, and is dropped if you go to the other device's page.
- **Connections piled up during reading**: page saves, settings saves and deletes left Komga's reply unread, so the
  connection couldn't be used again. Replies are now read to the end.
- **A page could stay on a spinner** when Enhance, Enhance colours or Crop edges failed (a page too big for the
  graphics chip, say): it now shows plain.
- **The page strip was off-centre on phones**, more the further into a book (about 200 pixels by page 100): the page
  picked is now in the middle.
- **Signing out didn't stop the book being downloaded**: it carried on to its last page with the old account. It now
  stops at once and waits in the queue.
- **Reading a downloaded book rewrote the whole downloads record on every page** (a few MB with hundreds of
  downloads). Reading progress now has its own small file (`progress.json` beside `index.json`), so a page turn
  writes only that. Moved over by itself on the first start, the old `index.json` kept as `index.v1.json`.
- **A page read while the background refresh was running could be put back to the page before**, and the next sync
  then reported a clash that wasn't one.
- **Comic reader, small things:** a failed "mark as read" on the way to the next book now says so (it said "Couldn't
  find the next book"); Next book no longer asks Komga again for the book the end card already showed (with "hide
  read" that could be hundreds of requests); the page curl no longer uses the last book's page shapes for the first
  turn of the next; a page that was opened at its end (turning back) no longer opens at its end later.
- **A page could be downloaded twice**: when a slow load of it failed after it had been asked for again, the newer
  load was thrown away too.
- **Download errors**: a full disk or a folder that can't be written, when queueing or removing a download, is now
  said in a message (it went unreported). On Android, a page that fails to save to the gallery no longer leaves a
  hidden half-saved picture behind for a week. Signing in again while a book was downloading no longer has two
  copies of the downloads record writing at once.

**Changed**
- **Smoother page curl**: the curl now redraws just itself as it moves, instead of the whole reader (about 23 times
  a turn, plus every finger movement).
- **Enhance colours doesn't hold up a book's first page**: it shows at once, then adjusts a moment later when the
  book's colour levels have been measured (from five pages of the book). Opening the book again, no wait at all.
- **The page strip uses less memory for downloaded books**: at most about 128 MB of pages kept (it could reach
  130-320 MB); pages scrolled away are read again from the download when needed.
- **Dragging the brightness slider no longer rebuilds the reader and every poster grid** behind it, many times a
  second.
- **What's new / Read me** load once when opened, not again on every settings change. And the colour levels
  remembered for books opened with Enhance colours are kept for the 300 most recent books, not every book ever
  opened.

### Build 72 - 2026-10-06

**Fixed**
- **EPUB: the app crashing while reading** (on the tablet and the PC, since EPUBs came in): working out where each
  line of text ends, the reader asked Flutter's engine which letter sits at a point on the line. On some lines that
  trips a check inside the engine, and its release version stops the app outright (the tablet's "SIGTRAP", the PC's
  "illegal instruction" - both while a chapter was being laid out). Line ends now come from the engine's own record
  of its lines; pages come out the same.
- **EPUB: the Margins setting did nothing on the tablet or the PC**: lines stopped at a fixed length there and
  the rest went to the margins, whatever the setting. The setting now sets that length - Narrow margins give longer
  lines, Wide shorter - as well as the margin on a phone.
- **EPUB: the font choices in the reader's Text and page panel were shrunk until they couldn't be read**: they now
  sit under the Font label at full size, wrapping onto two lines.
- **EPUB: the slider only went through the current chapter** until the whole book had been counted (a big book
  takes a while), so it couldn't take you far. It now always runs through the whole book - by percentage until the
  book is counted, by page after.
- **EPUB: page turns lagged.** Work in the background held the screen up mid-turn: counting the book's pages (a big
  book takes a minute or more) now pauses between chapters and waits while you're turning; the next chapter is got
  ready once a turn has finished sliding, not during it; and each page is drawn once and slid as a picture, not
  drawn again every frame of the slide.

**Added**
- **EPUB: Paragraph spacing** (Text and page, Settings > Books): None, Small or Large space between paragraphs, on
  top of the book's own (or of none, with your own formatting).

**Changed**
- **EPUB: the numbers over the slider say what they are**: "Book · Pg. 112/342 · 33%" at the left, "Ch. 7 · Pg. 4/12"
  at the right (the chapter numbered as the book's files run, so front matter counts).
- **EPUB: the end card shows what's next**, as the comic reader's does: "The End", then the next book's poster
  (at its own size) and title, with Next book and Close. The remote works on it: it starts on Next book, Up / Down
  move between the two, OK presses, Right goes on to the next book (or closes after the series' last), Left goes
  back to the last page.

### Build 71 - 2026-10-06

**Changed**
- **EPUB: your text size is the book's text size.** A book that sets its whole text smaller or larger (70 of the 339
  in the library: most at 85%, some Discworld books at 110-120%) no longer overrides the size you picked: its main
  text shows at your size, and its headings, notes and other sizes stay in proportion to it. A size the book sets on
  a few parts only (a prelude, a letter) is kept.
- **EPUB: where you are, redone** (replaces the "Position shows" setting). With the controls up, the chapter's name
  sits over the slider, the book's page and % at its left ("112 / 342 · 33%") and the page in the chapter at its
  right ("4 / 12") - all following the slider while you drag it. While reading, a quiet note in the page's corner
  says how many pages are left in the chapter and how far through the book you are ("8 left in chapter · 33%").
  Settings > Books > Page corner: Always (the default), After a turn (for a moment), or Off.

**Fixed**
- **EPUB: the slider jumped after a seek** (build 70): letting go, it went back to the page left for a moment, then
  to the new one. It now stays on the page picked while the reader goes there.
- **EPUB: right-aligned and centred text lined up on its own longest line**, not the page: Homeland's list of the
  author's other books came out as ragged groups from the left. They now line up on the text column.

### Build 70 - 2026-10-06

**Changed**
- **EPUB: pictures at their own size, and full screen with a tap.** A picture is drawn at its native resolution, one
  picture pixel to one screen pixel, centred - shrunk if it's bigger than the page, never enlarged (a small map was
  blown up and blurred). Tap a picture in the middle of the screen to see it over the book, fitted to the screen;
  pinch or the mouse wheel zooms, a tap, Back or Esc closes it. Only pictures 150 pixels or more both ways open
  (illustrations, maps, covers) - not drop caps, ornaments or chapter-head banners. Taps at the sides still turn
  the page.

**Fixed**
- **EPUB: stuck on a spinner after jumping far with the slider and back** (build 69): a chapter that had been laid
  out again at once (after the window or text size changed) and then let go of handed back its old, freed pages when
  it was come back to, instead of being laid out afresh - the reader waited for them for good.

### Build 69 - 2026-10-06

**Changed**
- **EPUB: the reader's controls are the comic reader's**: the same top bar (Close, the series and title, the clock,
  full screen on the PC, Mark read) and bottom bar (previous book, where you are, the slider, Contents, Text and page,
  next book). The remote walks them as with comics - arrows move between the controls, OK presses, OK on the slider
  then arrows scrub - and Back closes the controls before the book. The position shown follows the slider while
  you drag it. The Text and page panel has the comic panel's This device settings (brightness, night mode,
  rotation, keep the screen on), and the progress line along the bottom and the clock (Settings > Reader) show
  in books too.
- **EPUB: footnote markers are in the app's accent colour** (set in Settings), not a fixed blue.
- **EPUB: Next and Previous book** open the book in its own reader (a comic after an EPUB in the series opened in
  the EPUB reader); Next book mid-book asks, marks read or keeps it in progress as Settings > Reader says.

### Build 68 - 2026-10-06

**Changed**
- **EPUB: drop caps drawn as pictures sit beside the text**, as the book lays them out (Homeland, Sea of Swords, the
  Hitchhiker's books): a small picture floated at a paragraph's start is drawn at its own size with the first lines
  flowing beside it, instead of on a line of its own above the paragraph.
- **EPUB: footnote markers stand out**: a link that is a note marker (`*`, `[**]`, `†`, a number) is drawn raised,
  bold and blue, a lone `*` or `†` larger - before, Discworld's asterisks were plain small stars in the text colour and
  easy to miss. Tap one for its note, as before.

**Fixed**
- **EPUB: margins given in pixels were 16 times too big** - "30px" was read as 30 times the letter size - squeezing
  text into a sliver at the side (Homeland's list of the author's other books) or opening wide gaps. Most books in
  the library (258 of 339) set some margins this way.

### Build 67 - 2026-10-06

**Changed**
- **EPUB: spacing the book asks for is respected.** Margins now nest as in a browser: a wrapper's indent (a quotation,
  an epigraph, a letter...) carries down to the paragraphs inside it, and the space it asks for above and below
  stays. With your own formatting (Book's formatting off), only a chapter's usual gap between paragraphs goes; a
  paragraph that asks for more (a scene break, the first one after it) keeps it, and starts without an indent.
- **EPUB: the reader's panels look like the comic reader's**: Text and page (Aa) and Contents slide in from the side
  on a wide screen, with their title and Done, and come up from the bottom on a narrow one.

**Fixed**
- **EPUB: a crash on the PC after turning back and forth** (build 66, inside Flutter's engine - not repeatable since):
  chapters far from the page you're on are now let go of a moment later rather than at once, and two chapters either
  side are kept instead of one, so a page still on screen is never drawn from text or pictures already freed - the
  most likely cause. The EPUB reader also keeps a short trace of what it did (`%LOCALAPPDATA%\KomgaReader\epub-trace.log`
  on Windows) so that, should it crash again, the last lines say what led up to it.

### Build 66 - 2026-10-06

**Fixed**
- **EPUB: stuck on a spinner** after turning back and forth (seen on the PC): a chapter that failed to load once - a
  request to Komga timing out, say - stayed failed for good. Now the next try loads it afresh, and a chapter that
  can't be shown says why, with **Retry**. Unexpected errors are now also kept in Settings > Error log.

### Build 65 - 2026-10-06

**Added**
- **EPUB books** (Android and Windows): novels and other EPUBs open in their own reader, laid out by the app - not a
  browser inside it. Justified text with hyphenation (English and French, by the book's language), the book's
  pictures and covers, drop caps and pictures with the text wrapped round them, simple tables, bordered passages,
  hanging indents; footnotes open over the page when you tap their mark. Pages slide (or turn instantly); taps,
  swipes, the remote and the volume keys turn them as in the comic reader. **Contents** jump to a chapter; the
  slider and "page X of Y" cover the whole book once it has been counted (a few seconds after opening).
- **Where you stopped** is kept on Komga as its own EPUB reading position - the same one Komga's web reader uses - so
  either picks up where the other left off; Komga's read progress (and the posters' progress bars) follow it. A book
  reaching its end is marked read, with the next book in the series offered.
- **Text and page settings** (the reader's **Aa**, or Settings > Books (EPUB)), synced to every device: font
  (Literata - the default -, Lora, EB Garamond, Atkinson Hyperlegible Next, or the device's serif / sans), size, line
  spacing, margins, theme (dark, sepia, light), page turn, what the position line shows, and **Book's formatting**:
  off (the default), every book is justified with indented paragraphs; on, each publisher's own alignment and
  spacing. On a wide window, lines stay a comfortable length.
- **Downloaded EPUBs read offline**: a download keeps the book's file; reading done offline is sent to Komga later.
- The web version says EPUBs aren't supported there.

### Build 64 - 2026-10-06

**Added**
- **Release dates on book posters**: under the title, as "13 Mar 2024" - in libraries, series, read lists, Home and
  search. A switch in Settings > Library & Home > Posters ("Release date", on by default); a book without a date
  keeps the empty line, so every cover in a grid stays the same size.

### Build 63 - 2026-10-05

**Changed**
- **Screen brightness is the reader's**: your brightness - extra dim included - applies while a book is open; the rest
  of the app (Home, libraries, Settings) uses the screen's own brightness. Left at extra dim from reading in the dark,
  the app opened too dark to see in daylight, Settings included. The setting moved from Settings > Display to
  Settings > Reader ("Brightness while reading"); the reader's panel still has it.
- **The page background is a reading setting**: black, dark grey or white is now one of the reading defaults (Settings
  > Reading defaults, synced to every device), and a series can have its own with fit and direction ("Override the
  defaults" in the reader's panel). It was a setting of each device; that one is gone, so a device that had grey or
  white starts from the default (black) - pick it again once, as the default or for a series.

**Added**
- **Read on another device meanwhile**: with a book open (say the tablet locked mid-book, then read on the PC),
  BeDeReader checks Komga before saving your page and when you come back to the app. Finished elsewhere: **Stay
  here** (carry on; the book is in progress again) or **Mark as read** (it stays read, and you're on the end card for
  the next book). On another page elsewhere: **Stay on page N** or **Go to page M**. OK on the remote (or Back)
  stays. Closing the book never saves over the other device's progress. Before, the first page turn here quietly
  overwrote it.
- **Sync pins across devices** (Settings > Library & Home; on by default): switched off, a device keeps its own pins -
  a copy of the shared ones to start with - and pins made there stay there. Switched back on, the shared pins return;
  if the device has pins the shared list doesn't, it asks first.

**Fixed**
- Web: right-click on a poster opened the browser's own menu on top of the app's.
- Pins, reader settings and On deck hidden changed on another device only showed up after restarting the app (they
  were fetched from Komga at start-up only). Now they're fetched each time Home reloads - coming back to Home, pulling
  to refresh, or the app coming back to the front.
- Reader, the end card: the next book's picture is its poster as Komga has it (a poster picked in Komga included),
  at its own size - no bigger than the card - instead of its first page, which showed the middle of a double-page
  spread when the book opened with one. Its size now follows Komga's thumbnail size.

### Build 62 - 2026-10-03

**Changed**
- Reader: scrubbing the page slider (finger, mouse or remote) moves the page strip with it, to the page being picked.
- Posters fill their tiles again: build 61's "never enlarged" posters (shown at their own size inside Large tiles)
  are undone.

### Build 61 - 2026-10-03

**Added**
- Reader: **Original size**, a fourth fit next to screen, width and height - one page pixel to one screen pixel.
  A page bigger than the screen opens centred and scrolls whichever way it overflows: down with the keys, taps and
  wheel as in fit width; across by dragging (page swipes pause, and pulling on past the edge turns the page). The
  top bar's fit button goes round all four.
- Reader: **a page strip** - the book's pages as a film strip above the bottom bar, opened and closed with the new
  Pages button next to the slider. It opens at the page you're on; tap a page (or OK on it with the remote) to go
  there, and the strip stays up. Once opened it stays open - every time the controls come up, book after book and
  after a restart - until you close it with the same button; each time it's centred on the page you're reading. Thumbnails are up to 100 px tall, smaller on narrow screens so at least 8 pages
  always fit. The page you came from is marked, as on the slider. With the remote: Up from the bottom bar goes into
  the strip, Left / Right move along it. Right to left books start from the right.
- Reader: **Save page** and **Copy page**, side by side at the top of the Reader panel (the sliders button). They take
  the page's own picture as Komga has it (not the adjusted picture on screen). Save puts it in Pictures\BeDeReader on
  Windows, or the Pictures/BeDeReader album on Android, named for the book and page; Copy puts it on the clipboard,
  ready to paste.
- Breadcrumbs are links: in "Ongoing › Absolute Flash", tap (or OK on) "Ongoing" to open that library; "Read lists" and
  "Collections" open those. If you came from that library screen, it goes back to it (showing the right view) instead of
  opening another.

**Changed**
- Posters are never enlarged (Large tiles looked blurry: Komga's thumbnails are 300 px tall, a Large tile on a 1440p
  screen is taller). A poster smaller than its tile now shows at its own size, centred, instead of stretched; where it
  covers the tile it fills it as before. Uploaded posters over 500 px tall are shrunk to 500 first.

### Build 60 - 2026-10-02

**Changed**
- Reader, the page slider: after you jump away, the line marking the page you came from stays on the slider whenever
  the controls are up, not only while you scrub - until you turn a page normally or get back to it.

**Fixed**
- Reader: Esc or Back while dragging along the page slider (finger or mouse) cancels the pick - the controls close and
  you stay on your page. Letting go afterwards still jumped to the page picked.

### Build 59 - 2026-10-02

**Added**
- Reader, the page slider: while you pick a page, a line marks the page you started from, and a drag that comes close
  to it snaps onto it - so after looking at another page you can get straight back. The mark stays after you jump away
  (the next time you scrub it still shows the page you came from) until you turn a page normally - you're reading on
  from there - or you're back on that page.

### Build 58 - 2026-09-30

**Fixed**
- Settings with the remote: moving Up / Down a row now scrolls it into view - on a page taller than the screen the
  focus could end up below the bottom edge (found auditing the tests).
- On deck: hiding or showing something while offline reaches Komga as soon as the app is back online, not only at the
  next start (as pins and reader settings already did).
- Reader: with Fit height, a page wider than the screen dropping out of the page view (two turns on) made the reader
  rebuild at a moment Flutter doesn't allow - an error in debug builds (found auditing the tests).
- Offline mode (found auditing the tests):
  - Starting the app with offline mode on still asked Komga for the reader settings, pins and On deck hidden, and
    for Home's rows. Nothing is sent now; they load from this device.
  - Switched offline by hand after the "can't reach Komga" prompt, a late answer from Komga still offered "Komga is
    reachable again - Go online".
- Settings with the remote (found auditing the tests):
  - On Library & Home, Up and Down took the rows in the wrong order: up from the first library jumped down to Home
    sections (off the screen), and down from Posters skipped the libraries.
  - A page chosen from the list opened as far down as the page before it had been scrolled.
- Remote and keys: keys saved by older builds could leave no key that shows the reader's controls. Its default keys
  come back now.
- Signing out: coming back to the app afterwards still checked Komga with the old key. The connection and the
  download queue now let go of it.
- Tools (test audit): lint findings now fail the build and CI (they were all let through); a tagged build refuses
  -AllowDirty / -SkipTests, files changed by pub get, and an existing tag; the tablet install checks the tablet reports
  this build and holds this exact APK; the Desktop copy is unpacked fresh and swapped in (the old one kept as
  BeDeReader.previous, files from older builds no longer linger); release.ps1 only tags a build whose BUILD-INFO
  shows tests passed, a clean tree and release signing, and whose files match their checksums.
- A pinned side menu stays open beside a series, a collection and a read list too (it went away on those).
- Reader (from a code review):
  - A second "forward" while the next book was loading (a held key, a double press) opened the book after it and
    marked the one in between read. Page turns and book moves now wait while a book loads.
  - Next book part-way through a series' last book marked it read, then closing saved it back to "in progress".
  - Closing the reader while the next book loaded, or that book failing to open, saved your page to the wrong book.
    The book you're reading now stays current until the next one has loaded.
  - A page curl let go before halfway counted as a page turn (and could un-read a finished book); a tap while it
    sprang back could skip a page. Only finished curls count now, and taps wait for the curl to settle.
  - Going back to a page you'd zoomed into left it zoomed while the reader thought it wasn't (keys and swipes
    misbehaved). A page goes back to fit when you move off it.
  - Reaching the last page marks the book read straight away; after Mark unread there, the tick shows unread.
  - Turning "Override the defaults" on keeps a fit you'd picked for this book from the top bar.
  - A book with no pages crashed the controls. It now says so, with Next book and Close.
- Settings and pins kept in Komga (from a code review):
  - A reader-settings or pin change made while Komga couldn't be reached was lost at the next start (Komga's older
    copy won). It's now kept on the device, sent when Komga answers, and wins until it has been.
  - Series settings removed on another device (Reset all, Use the defaults) now go on this one too.
  - A change made while an earlier one was still being sent could be marked sent without reaching Komga.
  - Signing out now clears the account's pins, reader settings and On deck list from the device, so they can't show
    under - or be sent to - the next account. They come back from Komga when you sign in again.
- Downloads and offline (from a code review):
  - A page cut off mid-download (the app closed or killed) was counted as downloaded and stayed unreadable. Pages
    are now saved whole or not at all.
  - When Komga or the network went away, every queued book failed in turn. Now they wait ("waiting for Komga") and
    carry on by themselves when Komga answers. Offline mode is applied before the queue starts.
  - Pause is kept across a restart (it showed Pause while a book stayed stuck as paused).
  - Each server's downloads are kept apart: signing in to another server deleted the first one's unsent reading
    progress. Today's downloads stay where they are, as the current server's.
  - A deleted series, or one book Komga kept refusing, stopped the offline progress sync for everything after it.
    Now they're skipped; a deleted series' downloads show "no longer on Komga".
  - A page slower than 45 s no longer makes the app think Komga is down (no "go offline?" prompt for it).
  - Delete once read = Ask no longer asks again about a book you chose to keep.
- Screens and the remote (from a code review):
  - Remote and keys: Back (and Esc) in the "press a key" dialog cancel - Back used to be taken as the key, and then
    no longer closed the book. And the only key that shows the controls can't be given away: it says why.
  - Search results update after deleting or marking a book or series from its menu.
  - Deleting a series from its own screen closes that screen.
  - Book details, series details and the documents (What's new, Read me...): the remote's Up / Down scroll the page
    once there's no button that way - long summaries and the changelog couldn't be read past the screen.
  - A read list whose remaining books are in progress no longer shows as read: in progress counts as still to read.
- Windows: the window reopens where it was, at the size it was - with two monitors at different scaling it could come
  back on the other one at the wrong size, and with the taskbar at the top or left it crept each time (code review).
- Tools (code review): release.ps1 no longer glues the next build's heading onto the version note (it would have from
  1.3.0 on); build.ps1 won't commit or tag a -Bump build that isn't signed with the release key, and a failed tablet
  install or Desktop update is reported without stopping the rest.

**Added**
- Download on Wi-Fi only (Settings > Downloads, Android; off by default): on mobile data the queue waits - a book
  part way through keeps its pages - and carries on by itself back on Wi-Fi. The Downloads screen says it's waiting.
- Esc goes back one screen, like the remote's Back (a dialog, a menu or the side menu still closes first; on Home it
  does nothing).
- A downloaded book deleted on Komga is marked "no longer on Komga" on the Downloads screen, as a whole deleted series
  already was. It stays readable until you remove it.
- Going back online fetches the reader settings, pins and On deck hidden from Komga again (changed on another device
  meanwhile, or not fetched at all after starting offline); what was changed on this device is sent first.

### Build 57 - 2026-09-30

**Fixed**
- Moving on from the end card opened the next book on its own end card (so the card showed the book after that),
  instead of at its first page: the page view kept the last book's place. Each book now gets its own.

### Build 56 - 2026-09-30

**Fixed**
- Remote: holding OK on a poster opened its menu and at once pressed the menu's first entry (Details), because the
  held key kept repeating into it. The rest of a held press is now spent on opening the menu.

### Build 55 - 2026-09-30

**Added**
- Page previews setting (Settings > Reader, and the reader's panel): off, the slider shows just the page number
  while you pick a page, and nothing is asked of Komga - for when the link to your books is slow.

**Fixed**
- Page slider previews on a slow server: pages the reader already has (the one showing, its neighbours) preview
  at once, without asking Komga; while a page's picture is on its way the last one is shown faded under a spinner,
  so it isn't taken for this page; and a preview that takes too long no longer tells the app Komga is unreachable.
  (Komga makes each preview from the book file as it's asked: seconds each when the NAS is slow.)

### Build 54 - 2026-09-30

**Fixed**
- Remote in Settings and the reader panels: Up and Down always go to the row above or below, instead of skipping a
  row when a wide control sat over a short one. Home's sections count as a row each.
- Remote and keys: each key is one stop for the remote (it was two: the key, then its ✕).
- Choices beside their labels line up again, one width for the page; choices under their label span the row.
- With Override the defaults off, the choice in force stays highlighted (dimmed), so you can see the default.
- Going round the fits from the top bar a second time left a wide page at the left edge; it's centred every time.
- Page slider: scrubbing back and forth no longer freezes the preview (it asked Komga for every page passed, all at
  once; now only the page under your finger), and the page changes only when you let go.
- A series, a collection or a read list: Left from the leftmost book opens the side menu, as on Home and the libraries
  (a swipe does too). The back arrow stays.
- Home (Continue reading and the rest) could be out of date: it only reloaded when a screen it opened itself closed.
  Now Home, the libraries, series, collections, read lists and search results load afresh whenever they're back on
  top, however you got there (the side menu's Home, say), and when the app comes back into view.

### Build 53 - 2026-09-30

**New**
- **Hold OK on the remote to open an item's menu** (a book, series, read list, collection or pin) - the same menu as
  a long press or a right-click. A short press still opens it.

**Changed**
- **Override the defaults**, at the top of both reader panels' series settings ("Settings for Series: *name*"):
  - Off: the series follows your defaults, and the controls below are greyed out showing the default values. On:
    they're the series' own, starting from the defaults.
  - The Reader panel's covers fit and direction, the Image panel's the image settings - separately. The Image panel's
    Use the defaults button is gone (the toggle does it); Reset to original and Make default show with it on.
  - The top bar's fit button still works either way: for a series with its own layout it changes the series' fit;
    otherwise it changes the fit for this book only, for now (not saved).
  - Series with settings of their own from before keep them (both parts overridden).

### Build 52 - 2026-09-30

**New**
- **Zoom in and zoom out keys** (Remote and keys): + (or =) and - by default, a step each press, in fit screen.
- **Delete a downloaded book once it's read** is now **Never / Ask / Always**. Ask gathers the books you finish
  (here, offline or elsewhere) and asks once, with no book open. Anyone who had it on has Always.

**Changed**
- Accent colours: fourteen stronger colours instead of seven pale ones (your choice carries over, in its stronger
  version).
- **Volume keys turn pages** moved to the Remote and keys page.
- The Image panel's heading reads "Settings for Series: *name*".
- Fit width and fit height use double-headed arrows (↔ ↕).
- Brightness and contrast move in steps of 5, screen brightness and warmth in steps of 5 %.
- Night mode has no line of explanation under it any more.

**Fixed**
- With a remote, you can move off a slider in Settings and the reader's panels (Up and Down go to the next row;
  Left and Right adjust).
- In the reader's side sheets, sliders use the full width, and Keep the screen on no longer runs off the edge.
- A book that stopped for lack of room carries on when space is available - also when you delete a download, not
  only when the limit is raised (the note under the limit said otherwise).

### Build 51 - 2026-09-30

**Changed**
- **Previous book goes back through what you've read**: it returns to the book you read before this one since
  opening the reader (even though it's read now), and after going back, Next retraces forward again - like a
  browser's back and forward. Before the first book of the visit it goes to the previous book - with Hide read on,
  the previous one you haven't read.

### Build 50 - 2026-09-30

**New**
- **Remote and keys** (a new Settings page): choose which keys turn to the next or previous page, show the controls
  and close the book - for remotes that send other keys (media keys, letters). Press **Add** and then the key. A key
  has one job at a time; Show the controls always keeps one key; Reset keys goes back to the usual ones. Moving
  around the controls stays arrows and OK.

### Build 49 - 2026-09-30

**New**
- **Libraries on this device** (Settings > Library & Home): switch off libraries you don't want on this device. They're
  left out everywhere here - the side menu, Home and its rows (Continue reading, On deck...), All libraries, search,
  and offline. It's a per-device tidy-up; Komga's user permissions still decide what an account can see. At least one
  library stays shown.

### Build 48 - 2026-09-30

**New** (Settings > Display)
- **Night mode on a schedule**: on at one time and off at another (21:00 to 07:00 to start with). You can still switch
  it by hand in between; the schedule takes over again at its next change.
- **Text size**: 90 %, 100 %, 115 % or 130 % for this app, on top of the device's own text size.
- **Accent colour**: blue (as before), teal, green, amber, orange, pink or purple, for buttons, switches and
  highlights.

### Build 47 - 2026-09-30

**New**
- **Rotation lock** (Android; Settings > Reader, and the reader's Reader panel): in the reader, follow the device, or
  stay in portrait or landscape - for reading lying down.
- **Clock and battery** in the reader (Settings > Reader), which hides the system's status bar: off, with the controls
  (on the top bar, or just under it on a phone), or always (top right). The battery shows where the device has one.
- **Progress bar** (Settings > Reader): a thin line along the bottom of the page showing how far through the book you
  are, while the controls are hidden (with them up, the page slider shows it).

**Changed**
- **Next book follows Hide read.** Open a book from a series, read list or library with Hide read on, and the next book
  is the next one you haven't read, skipping books already read ("Next unread in the series" at the end of the
  book). Opened with Hide read off, or from Home or search, the next book is simply the next in order, as before.

### Build 46 - 2026-09-30

**Changed**
- The page number after a turn ("12 / 36") now shows in the bottom-left corner instead of the bottom right.
- The reader's **Reader** panel:
  - Its two groups say what they're for: "*Series* · this series" and "This device".
  - Direction is three icons (Auto, left to right, right to left).
  - Page number after a turn, Double-tap to zoom and Keep the screen on can now be changed there mid-book, as well as
    in Settings.
- The **Image** panel's Reset to original, Make default and Use the defaults are buttons under the settings instead of
  a ⋮ menu.

### Build 44 - 2026-09-30

**New**
- **Poster size button** (a grid icon with S, M or L) at the top of Home, libraries, series, collections and read
  lists: Small, Medium or Large posters, the same setting as Settings > Library & Home.

**Changed**
- Settings and the reader panels: the choice buttons on a page are all the same width, lined up on the right.

### Build 43 - 2026-09-30

**Changed**
- **Settings, redesigned** to be easier to take in at a glance:
  - One page at a time. The pages are listed down the side on a wide screen, or across the top on a phone.
  - Every setting is one row: its name on the left, its switch or choices on the right, one short line of explanation
    at most.
  - Each page says once where its settings are kept.
- **The reader's Reader and Image panels** use the same rows.
  - On a wide screen they open from the side, so the page stays in view while you adjust it.
  - Reader: fit is three icons, and the background is three swatches.
  - Image: Enhance and Enhance colours come first. Reset to original, Make these the default and a new **Use the
    defaults**, which drops a series' own settings, are in the ⋮ menu. The panel says whether the series has its own
    settings or follows the defaults.

### Build 42 - 2026-09-30

**New**
- **Double-tap to zoom** (fit screen): double-tap a spot to zoom in on it, double-tap again to zoom back out. To tell
  a double tap from a single one, taps wait a quarter of a second before turning the page or showing the controls;
  switch it off in Settings > Reader for instant taps.
- **Page previews on the slider**: while you pick a page on the slider (by touch, mouse or remote), a small picture of
  it shows over the thumb, with its page number.
- **Volume keys turn pages** (Android): volume down for the next page, volume up for the previous one. With the
  controls showing they change the volume as usual. On by default; switch it off in Settings > Reader.
- New settings, all kept on this device:
  - **'Next book' before the last page** (Settings > Reader): what happens to the book you're leaving - mark it
    read, no change (it stays in progress), or ask (as before).
  - **Background** (Settings > Reader): black, dark grey or white around the page.
  - **Keep the screen on** (Settings > Reader): off, 5, 10, 20 or 30 minutes after the last page turn or touch, or
    always. **Off by default**: until now the screen stayed on for as long as a book was open.
  - **Poster size** (Settings > Library & Home): small, medium or large posters in grids and on Home.
  - **Book posters show** (Settings > Library & Home): "Series #N" and the title, or the title only.
  - **Delete a downloaded book once it's read** (Settings > Downloads): when a book becomes read, here, offline or on
    another device, its download goes. A book open in the reader goes when it's closed.
  - **Reset this device's settings** (Settings > About): everything kept on this device back to the defaults. Synced
    settings, your sign-in and your downloads stay.

**Changed**
- Settings: the Reading card is now two cards. **Reading defaults** holds the defaults synced through Komga; **Reader**
  holds how the reader behaves on this device.
- Page turn animation is now **None / Wipe / Curl** (None was "Instant flip"). Your choice carries over.

### Build 41 - 2026-09-29

**New**
- Series, read list and collection screens show where they sit in the title bar: **Ongoing › Absolute Flash**,
  **Read lists › Civil War**, **Collections › Cosmic**.

**Fixed**
- On the PC, the first Continue reading book showed the keyboard/remote highlight as soon as the app opened. The
  highlight now shows only once an arrow, Tab or Enter key is used, and goes away again with a click or a touch.

## 0.1.1 - offline reading and better pages (the 1.1 release)

**Released as build 40, tagged `v0.1.1`** (2026-09-29) - the first public release. Release candidates: build 37
(`v0.1.1-rc.2`) and build 35 (`v0.1.1-rc.1`). Builds 21-26 still showed version 0.1.0.
### Build 39 - 2026-09-29

**Changed**
- **The app is now called BeDeReader** - a library and reader for Komga.
  Nothing to do: settings, downloads, reading progress and the Android install carry over. On Windows the program
  is now `BeDeReader.exe`, and the files in each release are named `BeDeReader-...`.
- Errors are in plain words everywhere - what happened and what to do - instead of the raw error text: "Can't
  reach Komga at 192.168.1.10:25600. Check you're on your home network and the server is running." A failed action
  names itself ("Couldn't mark "Saga #3" as read: can't reach Komga."), and each message has a **Details** link
  with the technical text (Copy). The last 50 errors are kept in **Settings > About > Error log**.
- If Komga stops accepting the API key (deleted in Komga, say), the app says so and offers **Use downloaded
  books** (they need no key) or **Sign in again**.
- A page that won't load now says why under the icon, and a book that won't open says so instead of spinning.
- Deleting without an admin account in Komga now says that's why, instead of blaming the API key.

**Fixed**
- Offline, the end of a book no longer skips ahead: if the book that comes next in the series or read list isn't
  downloaded, the end card says so and the arrow closes the book (it used to offer the next book that *was*
  downloaded, jumping over the missing ones). Books downloaded before this build still skip ahead in a series until
  they're downloaded again.
- End of book: the next book's poster was blurry (Komga's thumbnails are small). The book's cover page itself now
  replaces it, sharp, fetched ahead as you reach the last pages.

### Build 38 - 2026-09-29

**Fixed**
- With Enhance colours (or Enhance, or Crop edges) on, page turns hitched - most visibly the 3D page curl. The
  pages around the one you're reading are now processed between turns instead of during them, and in every page turn
  animation the next page is ready before you turn to it.
- Sign-in: an address typed without `http://`, or with a space after the colon (the tablet keyboard adds one), no
  longer fails with a "FormatException" - it's tidied up and the field shows the address used. The keyboard's
  word suggestions are off in that field.

### Build 37 - 2026-09-29

**Changed**
- Sign-in: the server field starts empty (with an example); signing in again fills in the last address.
- Android builds are now signed with the project's own release key. Installing one over an earlier test build needs
  that build uninstalled first, once.
- 3D page curl: the page stays attached along its spine - a diagonal drag tilts the curl but no longer peels the
  page up or down from the inside edge.
- 3D page curl: diagonal drags and flicks turn the page more readily, and a quick second swipe while a page is still
  turning turns the next one instead of being ignored.

**Fixed**
- After switching the fit mode through Fit height and back to Fit screen, swiping no longer turned pages.

### Build 36 - 2026-09-29

**Changed**
- Side menu: **App settings** is now **Settings**, and **Info** is now **About**. The server's address, status and
  Retry are in Settings > Server & connection only (About no longer repeats them).
- 3D page curl: only the comic page curls, not the black bars around it.
- 3D page curl: a drag can start anywhere on the screen - the distance to the edge you drag towards is the whole
  turn, so a slow drag from the middle finishes the page too.

### Build 35 - 2026-09-29

**Fixed**
- Licences: the Android version now carries the Apache 2.0 terms for the AndroidX and Kotlin libraries it includes
  (Info > licences page), and the third-party list covers each platform's extra parts. The Windows program's
  copyright line and the web version's title and description no longer show template text.

### Build 33 - 2026-09-29

**New**
- **What's new** and **Read me** in App settings > About and on the Info screen: this changelog, and what the
  app does, how to get started and where your settings live.
- **Third-party software** (App settings > About, and Info): everything the app relies on - libraries, fonts,
  services and build tools - with their licences.
- Komga Reader is now open source under the **MIT licence**. The licences page (Info) also carries AMD's notice for
  the page enhancement and the Material Icons attribution; the Info screen has an AI usage disclosure.

### Build 32 - 2026-09-29

**New**
- **3D page curl** - a third choice for *Page turn animation*. On a slow drag the page's corner follows your finger
  (hold it low to curl from the corner, mid-height to fold straight across); let go past halfway, or flick, and the
  page turns, otherwise it springs back. Taps, arrow keys, the remote and the mouse wheel play the whole curl; going
  back uncurls the previous page over the current one. The back of the page shows the print faintly, as through thin
  paper. Right-to-left books curl the other way. Zoomed in, or on a wide page in fit height, a drag still moves the
  page as before.
- **Crop edges** (Image settings) - cut 0 to 10% off every side of the page, per series (default in App settings >
  Reading), so the art fills more of the screen.

**Changed**
- *Page turn* is now **Page turn animation**, with **Wipe** / **Instant flip** / **3D page curl**. It only changes how
  a page change looks - tapping, swiping and the arrows turn pages the same way in all of them.
- With Instant flip or the page curl, the pages either side of the current one are kept ready, so the one you land
  on shows at once.

**Fixed**
- Opening a book with Enhance colours or Enhance no longer flashes the uncorrected page first - the page waits until
  it's ready. A book's colour measurement is now remembered, so reopening it is instant.

### Build 31 - 2026-09-29

**New**
- **Enhance colours** (Image settings) replaces Auto-levels: as well as balancing the page, it whitens yellowed paper
  and deepens faded ink, while leaving strong colours alone. Series that had Auto-levels on get it automatically.

**Changed**
- **Enhance** now enlarges pages with an edge-aware upscaler (AMD FSR 1), so diagonal lines and lettering stay smooth.

### Build 30 - 2026-09-29

**New**
- **Enhance** (Image settings) replaces Sharpen: the page is cleaned of JPEG speckle and grain, scaled with a
  high-quality filter and sharpened - once per page, on the graphics chip. Tuned on real old scans: lines about 1.2x
  crisper with less grain than no processing at all. Series that had Sharpen on get it automatically.
- **Page number after a turn** - "12 / 36" appears in the bottom-right corner for a moment (can be switched off).
- **Series details** (series menu) - poster, publisher, status, first release, how many books are read, language,
  age rating, genres and tags, summary, and the credits of all its books.
- **Hide from On deck** (book and series menus) - a series never shows there; a book is skipped until it's read.
  App settings shows what's hidden, with *Show all again*. Synced to your other devices.
- **Full screen on the PC**: an X at the right of every top bar leaves full screen.

**Changed**
- **App settings is the one place for every setting**, in sections that say where each is kept (this device, or
  synced through Komga): Server & connection, Reading (defaults for series you haven't adjusted, and *Reset all* for
  those you have), Display, Library & Home, Downloads, About. The reader's own panels are unchanged.
- Side menu: Reader settings and Sign out moved into App settings; tidier labels.

**Fixed**
- Sharpen used to draw pages unfiltered, which made enlarged pages blocky and shrunk pages shimmer.

### Build 29 - 2026-09-29

**Changed**
- **PC full screen is app-wide and remembered**: Esc closes the book and you stay in full screen, the next book opens
  in it, it's restored at start-up, and F11 works on every screen.

**Fixed**
- Closing a book from the end card now marks it read (it could save nothing if you'd just turned past the last page).
- PC: the mouse wheel no longer zooms the page when scrolling up. Ctrl+wheel zooms.

### Build 28 - 2026-09-29

**New**
- **Up next** on the end-of-book card: the next book's poster, number and title ("in the series" or "in this read
  list"), or "End of the series" on the last one.
- **Night mode** is also in App settings, since it tints the library screens too.

### Build 27 - 2026-09-29

**New**
- **Reading progress made offline reaches Komga** when it's back. If Komga changed too (you read on the web, say),
  the further position wins - nothing ever goes backwards or un-finishes - and a message lists those books.
- **Automatic offline mode**: when Komga can't be reached the app offers your downloaded books, and offers to go back
  online when Komga answers again. App settings > *If Komga can't be reached*: Ask first, or Automatic.
- **Downloaded badges** on posters: a blue tick when downloaded, a ring while downloading; series and read lists show
  how many of their books are downloaded.
- Fit width / fit height: a page bigger than the screen opens centred; in fit height a wide page can be dragged
  sideways to see the cut-off parts, and dragging on past its edge turns the page.

### Build 26 - 2026-09-28

**New**
- **Search** (Home and library screens): series, books, read lists and collections as you type. From a library it
  searches that library first; offline it searches your downloads.

**Changed**
- PC: Esc hides the reader's controls, or closes the book when they're hidden.

### Build 25 - 2026-09-28

**New**
- **Dockable side menu**: the pin in its header keeps it open beside the page on wider screens.
- **Pinned views are posters** on Home - a 2x2 of the view's first four items.
- **‹ › buttons** on Home rows to scroll them a screen at a time (mouse and remote friendly).

### Build 24 - 2026-09-28

**New**
- Four optional Home rows: **Recently read**, **Recently added books**, **Recently added series**, **Recent releases**.
- **Arrange Home**: reorder and show/hide every section (Home's ⋮ menu, or App settings).

### Build 23 - 2026-09-28

**Changed**
- Side menu order: Home, then libraries, then offline mode, downloads and the settings.
- A left-to-right swipe anywhere on Home and library screens opens the side menu.
- Offline, empty Home rows say "Nothing downloaded in progress" / "Nothing downloaded on deck".

### Build 22 - 2026-09-28

**New**
- Downloads: **Cancel all**, and **Download** for a multi-selected group of books.

**Fixed**
- Offline, pins with nothing downloaded are hidden, and opening one no longer claims it "no longer exists".

### Build 21 - 2026-09-28

**New**
- **Downloads**: download a book, or a series' / read list's unread or all books. Pages are saved with their place in
  the library, the queue survives restarts, and there's a storage limit (default 10 GB).
- **Downloads screen**: the queue with live progress, pause / resume / cancel / retry, and everything downloaded.
- **Offline mode** switch: the whole app shows just your downloaded books, and nothing contacts the server.
- **App settings** screen.

## 0.1.0-rc.1 - first release candidate

Build 20, tagged `v0.1.0-rc.1`. Everything from the first day of the project.

### Build 20 - 2026-09-28

**New**
- **Right-to-left reading**: follows each series' reading direction in Komga, or a per-series override. Taps, swipes,
  the arrows and the page slider all follow it.
- **Item count** in the header of library, series, collection and read-list screens.
- **Pull down to refresh** everywhere.

**Changed**
- Hide read is an icon-only button.

### Build 19 - 2026-09-28

**New**
- **Sort menu**: pick a field, then the direction. Remembered per library, kept in pins.
- **Series order**: oldest first / newest first.
- **Zoomed-in reading path**: forward steps across then down the page before turning it.
- **Page turn** setting: Swipe or Straight flip.

### Build 18 - 2026-09-28

**New**
- **Windows desktop app**: right-click menus, mouse-wheel page turns, F11 full screen, keyboard shortcuts, remembered
  window size and position.

### Build 17 - 2026-09-28

**New**
- **Info screen**: version, server status with Retry, credits for Komga.

**Fixed**
- The remote's highlight only appears once you press an arrow.

### Build 16 - 2026-09-28

**New**
- **Book details** (summary, credits) and **View series** in the book menu.
- Show or hide each Home section.

### Build 15 - 2026-09-28

**New**
- **Multi-select** for books, with Mark as read / unread and Delete.
- From the leftmost item, Left opens the side menu.

**Changed**
- Bigger, brighter read tick; a strong highlight for the remote everywhere; icon-only reader controls.

### Builds 12-14 - 2026-09-28

**New**
- The app icon.
- **Pins**: pin any library, series, collection or read-list view to Home under your own name. Synced to your
  other devices.

**Fixed**
- Long titles no longer shrink their poster; no yellow frame around the screen after using the remote.

### Builds 6-11 - 2026-09-28

**New**
- **Read-list posters** made of their first four unread books; long-press a series or read list to mark it all read
  or unread.
- **Reader controls, reworked**: a big Close button, fit / night / mark read / delete buttons, previous and next book;
  separate **Reader settings** and **Image settings** panels.
- Remote: Left/Right along a bar of controls, Up/Down between bars.

**Changed**
- Filtering is one **Hide read** toggle (in progress counts as unread). Pinch-zoom no longer turns pages by accident.

### Build 5 - 2026-09-28

**Changed**
- Progress is only saved once you've turned a page; mark read/unread in the reader sticks; *Next book* mid-book asks
  whether to mark it read; clearer "can't reach Komga" errors instead of endless spinners.

### Build 4 - 2026-09-28

**New**
- **Fit modes** (screen, width, height), **image adjustments** (brightness, contrast, sharpen, auto-levels), **night
  mode** and **screen brightness** - remembered per series, synced through Komga.
- Remote: OK shows and hides the reader's controls; Back hides them before closing the book.

### Build 3 - 2026-09-28

**New**
- The screen stays awake while reading; every grid loads more as you scroll.

### Build 2 - 2026-09-28

**New**
- **Home**: Continue reading, On deck and your libraries; a side menu; a better page slider in the reader.

### Build 1 - 2026-09-28

**New**
- The first build: sign in with a Komga API key, browse libraries, series, books, collections and read lists with
  posters, read with touch or a remote page-turner, mark read and unread, delete, and pages that follow the tablet's
  rotation.
