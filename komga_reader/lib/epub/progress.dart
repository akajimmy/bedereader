/// EPUB reading progress through Komga's Readium progression (user, 2026-10-05: "Komga's EPUB position"): the
/// same place Komga's own web reader keeps, so either picks up where the other stopped. Komga turns a saved
/// progression into the book's read progress, which is what the posters show - its page is NOT the position number
/// but how far through the book times Komga's own page count for it (the book's media.pagesCount): The Dispossessed
/// saved at position 233 of 748 (31%) had page 95 of 305 (checked in Komga's database, 2026-10-06; taking the page
/// for a position opened it at 12% offline - [komgaEpubPage], [EpubProgress.load]).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

String get platformName => switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      _ => 'Linux',
    };

/// A place in the book: a chapter (its path in the book) and how far through it, 0..1.
class EpubLocation {
  const EpubLocation(this.path, this.progression);
  final String path;
  final double progression;
  @override
  String toString() => 'EpubLocation($path, $progression)';
}

/// This device, as named in a saved progression ("which device read it last").
Future<Map<String, String>> epubDevice() async {
  final p = await SharedPreferences.getInstance();
  var id = p.getString(_deviceKey);
  if (id == null) {
    final r = math.Random.secure();
    id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await p.setString(_deviceKey, id);
  }
  return {'id': id, 'name': 'BeDeReader ($platformName)'};
}

const _deviceKey = 'device.id';

/// Komga's read-progress page for a place [total] (0..1) through an EPUB it counts [pagesCount] pages in - what it
/// makes of a saved progression itself (page 95 of 305 for 31%), from 1. Null without a page count.
int? komgaEpubPage(double? total, int? pagesCount) {
  if (total == null || pagesCount == null || pagesCount < 1) return null;
  return (total * pagesCount).round().clamp(1, pagesCount);
}

/// Where Komga has a book now: its saved place ([path] null: none - not started, or marked unread) and whether it's
/// marked read. What the reader compares, before a save and on coming back to the app, with what it last loaded,
/// saved or accepted: different = another device moved the book on (as the comic reader does with pages).
@immutable
class EpubKomgaPlace {
  const EpubKomgaPlace(this.path, this.progression, this.total, {required this.finished});
  final String? path;
  final double progression; // in the chapter, 0..1
  final double? total; // in the book, 0..1 (as the device that saved it worked it out)
  final bool finished;

  bool sameAs(EpubKomgaPlace o) =>
      o.path == path && o.finished == finished && (o.progression - progression).abs() < 0.001;

  @override
  String toString() => 'EpubKomgaPlace($path, $progression, $total, finished: $finished)';
}

class EpubProgress {
  EpubProgress(this.api, this.bookId);
  final Komga api;
  final String bookId;

  List<dynamic>? _positions;

  /// Komga's positions for the book (fetched once): what a saved progression is matched against.
  Future<List<dynamic>> positions() async => _positions ??= await api.epubPositions(bookId);

  /// The path in the book of a Readium href (Komga writes some as full URLs: the part after /resource/).
  static String pathOf(String href) {
    final i = href.indexOf('/resource/');
    return Uri.decodeFull((i < 0 ? href : href.substring(i + '/resource/'.length)).split('#').first);
  }

  /// Where to open: the saved progression, else the read progress's page (a book read up to a page elsewhere, by a
  /// reader that doesn't save progressions): that far through the book ([komgaEpubPage]'s other way), at the position
  /// there; null for a book not started.
  Future<EpubLocation?> load(Map<String, dynamic> book) async {
    final saved = await api.epubProgression(bookId);
    final loc = saved?['locator'] as Map?;
    if (loc != null && loc['href'] is String) {
      final pr = ((loc['locations'] as Map?)?['progression'] as num?)?.toDouble() ?? 0;
      return EpubLocation(pathOf(loc['href'] as String), pr.clamp(0.0, 1.0));
    }
    final page = (book['readProgress']?['page'] as num?)?.toInt();
    if (page == null || page < 1) return null;
    final all = await positions();
    if (all.isEmpty) return null;
    final count = (book['media']?['pagesCount'] as num?)?.toInt();
    final Map p;
    if (count != null && count > 0) {
      // the position whose place in the book is nearest the page's
      final want = (page / count).clamp(0.0, 1.0);
      p = all.cast<Map>().reduce((a, b) => (_total(b, all) - want).abs() < (_total(a, all) - want).abs() ? b : a);
    } else {
      p = all[math.min(page, all.length) - 1] as Map; // no page count to go by: the page as a position
    }
    return EpubLocation(pathOf(p['href'] as String),
        ((p['locations'] as Map?)?['progression'] as num?)?.toDouble() ?? 0);
  }

  /// How far through the book position [p] is: its totalProgression, else its number among [all].
  static double _total(Map p, List<dynamic> all) {
    final at = p['locations'] as Map?;
    final t = (at?['totalProgression'] as num?)?.toDouble();
    if (t != null) return t;
    final n = (at?['position'] as num?)?.toInt() ?? 1;
    return (n - 1) / math.max(1, all.length);
  }

  /// Where Komga has the book now (its saved progression, and the book's read state). Throws if Komga can't say.
  Future<EpubKomgaPlace> place() async {
    final saved = await api.epubProgression(bookId);
    final book = await api.book(bookId);
    final finished = book?['readProgress']?['completed'] == true;
    final loc = saved?['locator'] as Map?;
    if (loc == null || loc['href'] is! String) return EpubKomgaPlace(null, 0, null, finished: finished);
    final at = loc['locations'] as Map?;
    return EpubKomgaPlace(pathOf(loc['href'] as String), ((at?['progression'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        (at?['totalProgression'] as num?)?.toDouble(), finished: finished);
  }

  /// Saves [path] at [progression] (in the chapter) and [total] (in the book): matched to Komga's position at or
  /// just before it, and written with Komga's own href for the chapter.
  Future<void> save(String path, double progression, double total) async {
    final all = await positions();
    Map? best;
    for (final p in all) {
      final m = p as Map;
      if (pathOf(m['href'] as String) != path) continue;
      final pr = ((m['locations'] as Map?)?['progression'] as num?)?.toDouble() ?? 0;
      if (pr <= progression + 1e-6 || best == null) best = m;
      if (pr > progression) break;
    }
    final href = best?['href'] as String? ?? path;
    final position = (best?['locations'] as Map?)?['position'] as num?;
    await api.setEpubProgression(bookId, {
      'device': await epubDevice(),
      'modified': DateTime.now().toUtc().toIso8601String(),
      'locator': {
        'href': href,
        'type': (best?['type'] as String?) ?? 'application/xhtml+xml',
        'locations': {
          'fragments': <String>[],
          'progression': progression.clamp(0.0, 1.0),
          'totalProgression': total.clamp(0.0, 1.0),
          if (position != null) 'position': position.toInt(),
        },
      },
    });
  }
}
