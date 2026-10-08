import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'no_network.dart';

/// Komga for the reader: a 3-page book (B1, "Test #1", series S1) whose pages never finish loading - enough to drive
/// the controls. Records progress saves, read marks and next-book requests; [next] is the book after this one (null:
/// the last). Build with `noNetwork(ReaderServer.new)`.
///
/// Was reader_test's FakeKomga, imported from there by reader_keys_test (test audit, 2026-09-30).
class ReaderServer extends TestKomga {
  final theBook = {'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Test', 'metadata': {'number': '1', 'title': 'T'}};
  static String direction = 'LEFT_TO_RIGHT'; // the series' reading direction in Komga
  @override
  Future<Map<String, dynamic>?> book(String id) async => withProgress(theBook);
  @override
  Future<Map<String, dynamic>?> oneSeries(String id) async => {'id': id, 'metadata': {'readingDirection': direction}};
  @override
  Future<List<dynamic>> pages(String bookId) async => [{'number': 1}, {'number': 2}, {'number': 3}];
  @override
  Future<Uint8List> pageBytes(String bookId, int number) => Future.any([]); // never completes
  @override
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    saves.add(page);
    if (completed) finished.add(page);
    // kept, as Komga keeps it: asked for the book again, it comes with it (the reader checks before saving whether
    // another device moved it - 2026-10-05)
    savedProgress[bookId] = {'page': page, 'completed': completed};
  }

  /// A book's poster on the end card: a 1 x 1 picture from memory. Komga's is a NetworkImage - dart:io, which
  /// [noNetwork] doesn't stop: every end card with a next book made a real request, answered 400 and swallowed
  /// (test audit, 2026-10-07).
  @override
  ImageProvider thumbImage(String ref) => MemoryImage(onePixel);
  static final onePixel = Uint8List.fromList(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));

  /// Progress saved here, by book ([withProgress] puts it on a book as Komga would).
  final savedProgress = <String, Map<String, dynamic>?>{};

  /// [b] as Komga would return it now: with the progress saved for it, if any.
  Map<String, dynamic>? withProgress(Map<String, dynamic>? b) {
    if (b == null || !savedProgress.containsKey(b['id'])) return b;
    return {...b, 'readProgress': savedProgress[b['id']]};
  }

  final finished = <int>[]; // saves that marked the book read
  final saves = <int>[];
  final marked = <String>[];
  int nextCalls = 0;
  @override
  Future<void> markRead(String bookId) async {
    marked.add(bookId);
    savedProgress[bookId] = {'page': 3, 'completed': true};
  }
  @override
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    nextCalls++;
    askedReadList = readListId;
    return next;
  }

  Map<String, dynamic>? next; // the book after this one (null = last one)
  String? askedReadList = 'not asked';
  @override
  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async => null;
  @override
  Future<Map<String, dynamic>> clientSettings() async => {};
  @override
  Future<void> putClientSetting(String key, String value) async {}
}
