import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/fullscreen_exit.dart';
import '../widgets/markdown.dart';

/// One of the app's own documents, bundled by the build (tools/build.ps1 copies them into assets/docs):
/// What's new (CHANGELOG.md) and Read me (README.md - the part before "For developers").
class DocumentScreen extends StatelessWidget {
  const DocumentScreen({super.key, required this.title, required this.asset, this.stopAt});
  final String title;
  final String asset;
  final String? stopAt; // a heading line where the document is cut off (the developer part of the README)

  static DocumentScreen whatsNew() =>
      const DocumentScreen(title: "What's new", asset: 'assets/docs/CHANGELOG.md');
  static DocumentScreen readMe() =>
      const DocumentScreen(title: 'Read me', asset: 'assets/docs/README.md', stopAt: '## For developers');

  Future<String> _load() async {
    var text = await rootBundle.loadString(asset);
    final stop = stopAt;
    if (stop != null) {
      final at = text.indexOf('\n$stop');
      if (at >= 0) text = text.substring(0, at);
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              child: MarkdownView(snap.data!),
            ),
          );
        },
      ),
    );
  }
}
