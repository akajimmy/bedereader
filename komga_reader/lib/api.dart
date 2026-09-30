import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show ImageProvider, NetworkImage;
import 'package:http/http.dart' as http;

/// Thin client for the Komga REST API (checked against Komga 1.27.1's /v3/api-docs).
/// Every read-state change goes straight to the server - the app keeps no copy of reading state that could
/// override changes made in the web client.
class Komga {
  Komga(String baseUrl, this.apiKey) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  final String apiKey;
  final http.Client _http = http.Client();

  Map<String, String> get headers => {'X-API-Key': apiKey, 'Accept': 'application/json'};

  /// For thumbnails and pages. The thumbnail endpoints can also produce application/json, so asking for JSON
  /// there gets JSON back instead of the image (no posters).
  Map<String, String> get imageHeaders => {'X-API-Key': apiKey, 'Accept': 'image/*'};

  Uri _u(String path, [Map<String, Object?>? query]) {
    final q = <String, dynamic>{};
    query?.forEach((k, v) {
      if (v == null) return;
      q[k] = v is Iterable ? v.map((e) => '$e').toList() : '$v';
    });
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  static const timeout = Duration(seconds: 15);
  static const pageTimeout = Duration(seconds: 45); // big scans on a slow link

  /// Runs a request with a time limit, turning "no answer" into one clear error instead of a spinner forever.
  Future<T> _net<T>(Future<T> Function() request, {Duration limit = timeout}) async {
    try {
      final r = await request().timeout(limit);
      onReachability?.call(this, true);
      return r;
    } on KomgaError catch (e) {
      if (e.status == 401) onKeyRefused?.call(this); // before "it answered": the connection mustn't offer to go back
      onReachability?.call(this, true); // it answered, with an error
      rethrow;
    } on KomgaNotKomga {
      onReachability?.call(this, false); // something answered, but nothing this app can use
      rethrow;
    } on TimeoutException {
      onReachability?.call(this, false);
      throw KomgaUnreachable(baseUrl);
    } on http.ClientException {
      onReachability?.call(this, false);
      throw KomgaUnreachable(baseUrl); // package:http wraps socket errors (refused, no route) in this
    } catch (e) {
      // https with a certificate this device doesn't trust (a TLS handshake error, which package:http passes on raw)
      if ('${e.runtimeType}'.contains('Handshake') || '$e'.contains('CERTIFICATE_VERIFY_FAILED')) {
        onReachability?.call(this, false);
        throw KomgaCertificate(baseUrl);
      }
      rethrow;
    }
  }

  /// Told after every server call whether Komga answered (the connection uses it to offer offline mode).
  static void Function(Komga api, bool reachable)? onReachability;

  /// Told when Komga refuses the API key (HTTP 401) - it was deleted, say (the connection offers downloaded books
  /// and signing in again).
  static void Function(Komga api)? onKeyRefused;

  Future<dynamic> _get(String path, [Map<String, Object?>? query]) => _net(() async {
        final r = await _http.get(_u(path, query), headers: headers);
        if (r.statusCode == 404) return null;
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, path);
        try {
          return jsonDecode(utf8.decode(r.bodyBytes));
        } on FormatException {
          throw KomgaNotKomga(baseUrl); // a web page (a router, another server on that port), not Komga's API
        }
      });

  Future<void> _send(String method, String path, [Object? body]) => _net(() async {
        final req = http.Request(method, _u(path))..headers.addAll(headers);
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        final r = await _http.send(req);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, path);
      });

  // ---- account / libraries
  Future<Map<String, dynamic>?> me() async => await _get('/api/v2/users/me') as Map<String, dynamic>?;
  Future<List<dynamic>> libraries() async => (await _get('/api/v1/libraries')) as List<dynamic>;

  Future<List<dynamic>>? _librariesOnce;

  /// A library's name, for breadcrumbs ("Ongoing › Absolute Flash"). The list is fetched once per connection; null
  /// if it can't be had (tried again next time).
  Future<String?> libraryName(String? id) async {
    if (id == null) return null;
    try {
      final all = await (_librariesOnce ??= libraries());
      for (final l in all) {
        if (l['id'] == id) return l['name'] as String?;
      }
      return null;
    } catch (_) {
      _librariesOnce = null;
      return null;
    }
  }

  // ---- browsing (Komga pages: {content, totalElements, last})
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    return await _get('/api/v1/series', {
      'library_id': libraryId, 'collection_id': collectionId, 'read_status': readStatus,
      'sort': sort, 'page': page, 'size': size,
    }) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    return await _get('/api/v1/books', {
      'library_id': libraryId, 'read_status': readStatus, 'sort': sort, 'page': page, 'size': size,
    }) as Map<String, dynamic>;
  }

  /// Books you are part-way through, most recently read first.
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) =>
      books(libraryId: libraryId, readStatus: const ['IN_PROGRESS'], sort: 'readProgress.readDate,desc', size: size);

  /// Komga's "On deck": the next unread book of series you have been reading.
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async =>
      await _get('/api/v1/books/ondeck', {'library_id': libraryId, 'page': 0, 'size': size}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    return await _get('/api/v1/series/$seriesId/books',
        {'read_status': readStatus, 'sort': sort, 'page': page, 'size': size}) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async =>
      await _get('/api/v1/collections', {'library_id': libraryId, 'page': page, 'size': size}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async =>
      await _get('/api/v1/readlists', {'library_id': libraryId, 'page': page, 'size': size}) as Map<String, dynamic>;

  // ---- search (Komga's own search, by title and more; optionally within one library)
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/series', {'search': query, 'library_id': libraryId, 'size': size}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/books', {'search': query, 'library_id': libraryId, 'size': size}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/readlists', {'search': query, 'library_id': libraryId, 'size': size}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/collections', {'search': query, 'library_id': libraryId, 'size': size}) as Map<String, dynamic>;

  /// Books of a read list in the list's own order, optionally only unread / in progress / read.
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      await _get('/api/v1/readlists/$readListId/books',
          {'read_status': readStatus, 'page': page, 'size': size}) as Map<String, dynamic>;

  Future<Map<String, dynamic>?> oneSeries(String id) async => await _get('/api/v1/series/$id') as Map<String, dynamic>?;
  Future<Map<String, dynamic>?> readList(String id) async => await _get('/api/v1/readlists/$id') as Map<String, dynamic>?;

  Future<Map<String, dynamic>?> book(String id) async => await _get('/api/v1/books/$id') as Map<String, dynamic>?;

  // ---- pages and posters
  Future<List<dynamic>> pages(String bookId) async => (await _get('/api/v1/books/$bookId/pages')) as List<dynamic>;
  String pageUrl(String bookId, int number) => '$baseUrl/api/v1/books/$bookId/pages/$number'; // 1-based
  String seriesThumb(String id) => '$baseUrl/api/v1/series/$id/thumbnail';
  String bookThumb(String id) => '$baseUrl/api/v1/books/$id/thumbnail';
  String readListThumb(String id) => '$baseUrl/api/v1/readlists/$id/thumbnail';
  String collectionThumb(String id) => '$baseUrl/api/v1/collections/$id/thumbnail';

  /// The image for a thumbnail reference from the methods above. Screens go through this rather than building
  /// network images themselves, so the offline source can hand back images from disk (lib/offline/).
  ImageProvider thumbImage(String ref) => NetworkImage(ref, headers: imageHeaders);

  // ---- reading state (always straight to the server)
  // After each write [onProgressWritten] is told, so a downloaded copy of the book follows (lib/offline/sync.dart).
  Future<void> setProgress(String bookId, int page, {bool completed = false}) async {
    await _send('PATCH', '/api/v1/books/$bookId/read-progress', {'page': page, 'completed': completed});
    onProgressWritten?.call(this, ProgressWrite(bookId: bookId, page: page, completed: completed));
  }

  Future<void> markRead(String bookId) async {
    await _send('PATCH', '/api/v1/books/$bookId/read-progress', {'completed': true});
    onProgressWritten?.call(this, ProgressWrite(bookId: bookId, completed: true));
  }

  Future<void> markUnread(String bookId) async {
    await _send('DELETE', '/api/v1/books/$bookId/read-progress');
    onProgressWritten?.call(this, ProgressWrite(bookId: bookId, unread: true));
  }

  Future<void> markSeriesRead(String seriesId) async {
    await _send('POST', '/api/v1/series/$seriesId/read-progress');
    onProgressWritten?.call(this, ProgressWrite(seriesId: seriesId, completed: true));
  }

  Future<void> markSeriesUnread(String seriesId) async {
    await _send('DELETE', '/api/v1/series/$seriesId/read-progress');
    onProgressWritten?.call(this, ProgressWrite(seriesId: seriesId, unread: true));
  }

  static void Function(Komga api, ProgressWrite write)? onProgressWritten;

  // ---- next book: within the read list it was opened from, else within its series
  Future<Map<String, dynamic>?> nextBook(String bookId, {String? readListId}) async {
    final path = readListId != null
        ? '/api/v1/readlists/$readListId/books/$bookId/next'
        : '/api/v1/books/$bookId/next';
    return await _get(path) as Map<String, dynamic>?;
  }

  Future<Map<String, dynamic>?> previousBook(String bookId, {String? readListId}) async {
    final path = readListId != null
        ? '/api/v1/readlists/$readListId/books/$bookId/previous'
        : '/api/v1/books/$bookId/previous';
    return await _get(path) as Map<String, dynamic>?;
  }

  // ---- this app's settings, kept in the user's Komga client-settings store (key -> {value})
  Future<Map<String, dynamic>> clientSettings() async =>
      (await _get('/api/v1/client-settings/user/list') as Map<String, dynamic>?) ?? {};
  Future<void> putClientSetting(String key, String value) =>
      _send('PATCH', '/api/v1/client-settings/user', {key: {'value': value}});

  // ---- raw page bytes (the reader decodes and adjusts them itself)
  Future<Uint8List> pageBytes(String bookId, int number) => _net(() async {
        final r = await _http.get(Uri.parse(pageUrl(bookId, number)), headers: imageHeaders);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'page $number');
        return r.bodyBytes;
      }, limit: pageTimeout);

  /// A small picture of a page (Komga makes it, about 300 px wide) - the reader's slider previews.
  Future<Uint8List> pageThumbBytes(String bookId, int number) => _net(() async {
        final r = await _http.get(Uri.parse('${pageUrl(bookId, number)}/thumbnail'), headers: imageHeaders);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'page $number thumbnail');
        return r.bodyBytes;
      });

  // ---- what a book belongs to (the download engine snapshots this for offline browsing)
  Future<List<dynamic>> bookReadLists(String bookId) async =>
      (await _get('/api/v1/books/$bookId/readlists') as List<dynamic>?) ?? [];
  Future<List<dynamic>> seriesCollections(String seriesId) async =>
      (await _get('/api/v1/series/$seriesId/collections') as List<dynamic>?) ?? [];

  /// A poster's image bytes (null if it has none).
  Future<Uint8List?> thumbBytes(String url) => _net(() async {
        final r = await _http.get(Uri.parse(url), headers: imageHeaders);
        if (r.statusCode == 404) return null;
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'thumbnail');
        return r.bodyBytes;
      });

  // ---- delete (removes the files on the server - callers must confirm first)
  Future<void> deleteBookFile(String bookId) => _send('DELETE', '/api/v1/books/$bookId/file');
  Future<void> deleteSeriesFiles(String seriesId) => _send('DELETE', '/api/v1/series/$seriesId/file');
}

/// Komga answered with an error status. What people see comes from lib/errors.dart; this text is for the error log.
class KomgaError implements Exception {
  KomgaError(this.status, this.path);
  final int status;
  final String path;
  @override
  String toString() => 'HTTP $status on $path';
}

/// Something answered at the address, but not Komga's API (a web page: wrong port, a router, another server).
class KomgaNotKomga implements Exception {
  KomgaNotKomga(this.baseUrl);
  final String baseUrl;
  @override
  String toString() => 'not a Komga API response from $baseUrl';
}

/// https to a server whose certificate this device doesn't trust (self-signed, expired, wrong name).
class KomgaCertificate implements Exception {
  KomgaCertificate(this.baseUrl);
  final String baseUrl;
  @override
  String toString() => 'TLS certificate not trusted: $baseUrl';
}

/// A reading-progress change just written to Komga: one book, or every book of a series.
class ProgressWrite {
  const ProgressWrite({this.bookId, this.seriesId, this.page, this.completed = false, this.unread = false});
  final String? bookId, seriesId;
  final int? page; // null with completed: the last page
  final bool completed, unread;
}

/// No answer from the server (away from home, Komga or the PC off, wrong address).
class KomgaUnreachable implements Exception {
  KomgaUnreachable(this.baseUrl);
  final String baseUrl;
  @override
  String toString() => 'no answer from $baseUrl';
}

/// The one read filter (user's call): show everything, or hide what's read. In-progress counts as unread, so
/// "hide read" asks Komga for UNREAD + IN_PROGRESS (for series: not every book finished).
enum ReadFilter { all, hideRead }

extension ReadFilterApi on ReadFilter {
  List<String>? get api => switch (this) {
        ReadFilter.all => null,
        ReadFilter.hideRead => const ['UNREAD', 'IN_PROGRESS'],
      };

  /// Saved names, including the four-way filter of builds 5-7 (unread / in progress became "hide read").
  static ReadFilter fromName(Object? name) =>
      const {'hideRead', 'unread', 'inProgress'}.contains(name) ? ReadFilter.hideRead : ReadFilter.all;
}
