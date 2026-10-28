// Apply edits to files (user, 2026-10-27; reports\10-27-apply-edits-plan.md): a local or network library's edits,
// kept alongside its books, put into the books themselves - their metadata written in, files and folders renamed -
// when the user asks, after a warning that says what will change.
import 'dart:convert';
import 'dart:typed_data';

import 'file_zip.dart';
import 'in_file_meta.dart';
import 'library_fs.dart';
import 'local_meta.dart';
import 'local_store.dart';

/// [e] written into [b]'s own file ([fs]: its library's files): a CBZ's ComicInfo.xml (made if it has none), an EPUB's
/// package file - the book rewritten safely ([rewriteZip]: checked before it takes the old one's place). Its own file, never a downloaded copy.
Future<void> writeEditsIntoBook(LibraryFs fs, LocalBook b, BookEdits e) async {
  final zip = await ComicArchive.open(fs, b.path);
  final Map<String, Uint8List> replace, add;
  try {
    if (b.epub) {
      final container = await zip.read(zip.find('META-INF/container.xml') ?? 'META-INF/container.xml');
      final opfPath = container == null
          ? null
          : RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(utf8.decode(container, allowMalformed: true))?[1];
      final opf = opfPath == null ? null : await zip.read(opfPath);
      if (opfPath == null || opf == null) throw const FormatException('No package file in the EPUB');
      replace = {opfPath: Uint8List.fromList(utf8.encode(opfWith(utf8.decode(opf, allowMalformed: true), e)))};
      add = const {};
    } else {
      final name = zip.find('ComicInfo.xml');
      final was = name == null ? null : await zip.read(name);
      final xml = Uint8List.fromList(
          utf8.encode(comicInfoWith(was == null ? null : utf8.decode(was, allowMalformed: true), e)));
      replace = name == null ? const {} : {name: xml};
      add = name == null ? {'ComicInfo.xml': xml} : const {};
    }
  } finally {
    await zip.close();
  }
  await rewriteZip(fs, b.path, replace: replace, add: add);
}
