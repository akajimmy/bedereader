import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/arrow_scroll.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/markdown.dart';

/// One of the app's own documents, bundled by the build (tools/build.ps1 copies them into assets/docs):
/// What's new (CHANGELOG.md), Read me (README.md - the part before "For developers") and Third-party software
/// (THIRD_PARTY_NOTICES.md).
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.title, required this.asset, this.stopAt, this.leaveOut = const []});
  final String title;
  final String asset;
  final String? stopAt; // a heading line where the document is cut off (the developer part of the README)
  final List<String> leaveOut; // heading lines whose sections are left out (the README's screenshots: no images here)

  static DocumentScreen whatsNew() =>
      const DocumentScreen(title: "What's new", asset: 'assets/docs/CHANGELOG.md');
  static DocumentScreen thirdParty() =>
      const DocumentScreen(title: 'Third-party software', asset: 'assets/docs/THIRD_PARTY_NOTICES.md');
  static DocumentScreen readMe() => const DocumentScreen(title: 'Read me', asset: 'assets/docs/README.md',
      stopAt: '## For developers', leaveOut: ['## Screenshots']);

  /// [text] cut off at the heading line [stopAt], with the sections under the heading lines [leaveOut] taken out
  /// (each up to the next heading of the same level).
  static String trimmed(String text, {String? stopAt, List<String> leaveOut = const []}) {
    text = text.replaceAll('\r\n', '\n'); // (the README is kept with Windows line ends)
    if (stopAt != null) {
      final at = text.indexOf('\n$stopAt');
      if (at >= 0) text = text.substring(0, at);
    }
    for (final heading in leaveOut) {
      final at = text.indexOf('\n$heading\n');
      if (at < 0) continue;
      final level = heading.substring(0, heading.indexOf(' ') + 1); // "## "
      final next = text.indexOf('\n$level', at + heading.length + 1);
      text = text.substring(0, at) + (next < 0 ? '\n' : text.substring(next));
    }
    return text;
  }

  Future<String> _load() async {
    // decoded here, not by loadString: past 50 KB that hands the decoding to a background isolate (the changelog
    // passed it on 2026-10-06, and What's new stayed on its spinner in the tests); a few dozen KB is nothing to decode
    final data = await rootBundle.load(asset);
    return trimmed(utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
        stopAt: stopAt, leaveOut: leaveOut);
  }

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  // loaded once, when the screen opens: made in build, any rebuild (a settings change anywhere) loaded it again and
  // jumped back to the top (code review 2026-10-05, #48)
  late final Future<String> _text = widget._load();

  @override
  Widget build(BuildContext context) {
    return ArrowScroll(builder: (scroll) => Scaffold( // the remote's Up / Down scroll the text
      appBar: AppBar(title: Text(widget.title), actions: const [FullscreenExit()]),
      // above Android's navigation bar (the app is drawn edge to edge, under it): the remote's focus was scrolled to an
      // edge behind it (user, 2026-10-07)
      body: SafeArea(top: false, child: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Not included in this build.', style: TextStyle(color: Color(0xFF9A9A9A))));
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: MarkdownView(snap.data!, controller: scroll),
            ),
          );
        },
      )),
    ));
  }
}
