import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/arrow_scroll.dart';
import '../widgets/fullscreen_exit.dart';
import '../widgets/markdown.dart';

/// One of the app's own documents, bundled by the build (tools/build.ps1 copies them into assets/docs):
/// What's new (CHANGELOG.md), Read me (README.md - the part before "For developers") and Third-party software
/// (THIRD_PARTY_NOTICES.md).
class DocumentScreen extends StatelessWidget {
  const DocumentScreen({super.key, required this.title, required this.asset, this.stopAt});
  final String title;
  final String asset;
  final String? stopAt; // a heading line where the document is cut off (the developer part of the README)

  static DocumentScreen whatsNew() =>
      const DocumentScreen(title: "What's new", asset: 'assets/docs/CHANGELOG.md');
  static DocumentScreen thirdParty() =>
      const DocumentScreen(title: 'Third-party software', asset: 'assets/docs/THIRD_PARTY_NOTICES.md');
  static DocumentScreen readMe() =>
      const DocumentScreen(title: 'Read me', asset: 'assets/docs/README.md', stopAt: '## For developers');

  Future<String> _load() async {
    // decoded here, not by loadString: past 50 KB that hands the decoding to a background isolate (the changelog
    // passed it on 2026-10-06, and What's new stayed on its spinner in the tests); a few dozen KB is nothing to decode
    final data = await rootBundle.load(asset);
    var text = utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final stop = stopAt;
    if (stop != null) {
      final at = text.indexOf('\n$stop');
      if (at >= 0) text = text.substring(0, at);
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return ArrowScroll(builder: (scroll) => Scaffold( // the remote's Up / Down scroll the text
      appBar: AppBar(title: Text(title), actions: const [FullscreenExit()]),
      body: FutureBuilder<String>(
        future: _load(),
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
      ),
    ));
  }
}
