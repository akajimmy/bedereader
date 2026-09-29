import 'package:flutter/material.dart';

import 'main.dart' show buildTheme;
import 'screens/document.dart';

/// Dev preview of About > What's new / Read me (no server needed):
///   flutter build web -t lib\dev_docs_preview.dart --base-href /komga_reader/build/web/
/// then open /komga_reader/build/web/ from a server at the repository root. ?doc=readme for Read me.
void main() {
  final readme = Uri.base.queryParameters['doc'] == 'readme';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: readme ? DocumentScreen.readMe() : DocumentScreen.whatsNew(),
  ));
}
