import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show Listenable;
import 'package:flutter/painting.dart' show ImageProvider, NetworkImage;
import 'package:http/http.dart' as http;

import 'hidden_libraries.dart';
import 'view_filter.dart';

/// Thin client for the Komga REST API (checked against Komga 1.27.1's /v3/api-docs).
/// Every read-state change goes straight to the server - the app keeps no copy of reading state that could
/// override changes made in the web client.
class Komga {
  /// [client]: the HTTP client to use (the offline source passes one that never connects); by default its own.
  Komga(String baseUrl, this.apiKey, {http.Client? client})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client(),
        _ownClient = client == null;

  final bool _ownClient; // (a client given - the offline source's, a test's - is the only one: [ping] uses it too)
  final Zone _zone = Zone.current; // (where it was made: a client made for [ping] is made there too)

  final String baseUrl;

  /// How this device signs in: a Komga API key, or - when the server wouldn't make one at a password sign-in - the
  /// email and password as an HTTP Basic credential ([basic]: "Basic ..."; Komga's keys are hex, never that).
  final String apiKey;
  final http.Client _http;

  /// The email and password as a credential for [apiKey] (sent as HTTP Basic, which Komga accepts on every request).
  static String basic(String email, String password) => 'Basic ${base64Encode(utf8.encode('$email:$password'))}';

  bool get usesPassword => apiKey.startsWith('Basic ');

  Map<String, String> get _auth => usesPassword ? {'Authorization': apiKey} : {'X-API-Key': apiKey};

  int _inFlight = 0; // requests on their way
  bool _closing = false;

  /// This connection is dropped for good (a failed sign-in, signing out): its HTTP client - and the sockets it keeps
  /// open - is closed once the requests on their way have finished (code review 2026-10-05, #50: none was ever
  /// closed). Anything asked after that fails as unreachable.
  void close() {
    _closing = true;
    if (_inFlight == 0) _http.close();
  }

  Map<String, String> get headers => {..._auth, 'Accept': 'application/json'};

  /// For thumbnails and pages. The thumbnail endpoints can also produce application/json, so asking for JSON
  /// there gets JSON back instead of the image (no posters).
  Map<String, String> get imageHeaders => {..._auth, 'Accept': 'image/*'};

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
  /// [slowIsNotDown]: running out of time isn't taken as Komga being unreachable (still an error for the caller).
  Future<T> _net<T>(Future<T> Function() request, {Duration limit = timeout, bool slowIsNotDown = false}) async {
    _inFlight++;
    try {
      return await _netOnce(request, limit: limit, slowIsNotDown: slowIsNotDown);
    } finally {
      if (--_inFlight == 0 && _closing) _http.close();
    }
  }

  Future<T> _netOnce<T>(Future<T> Function() request, {required Duration limit, required bool slowIsNotDown}) async {
    limit = (Zone.current[_pingLimit] as Duration?) ?? limit; // ([ping]'s own, shorter)
    try {
      final r = await request().timeout(limit);
      onReachability?.call(this, true);
      return r;
    } on KomgaError catch (e) {
      if (e.status == 401) onKeyRefused?.call(this); // before "it answered": the connection mustn't offer to go back
      onReachability?.call(this, true); // it answered, with an error
      rethrow;
    } on KomgaNotKomga catch (e) {
      lastFailure = e;
      onReachability?.call(this, false); // something answered, but nothing this app can use
      rethrow;
    } on TimeoutException {
      if (!slowIsNotDown) {
        lastFailure = 'no answer within ${limit.inSeconds} s';
        onReachability?.call(this, false);
      }
      throw KomgaUnreachable(baseUrl);
    } on http.ClientException catch (e) {
      lastFailure = e; // (its message says how: refused, no route, network unreachable...)
      onReachability?.call(this, false);
      throw KomgaUnreachable(baseUrl); // package:http wraps socket errors (refused, no route) in this
    } catch (e) {
      // https with a certificate this device doesn't trust (a TLS handshake error, which package:http passes on raw)
      if ('${e.runtimeType}'.contains('Handshake') || '$e'.contains('CERTIFICATE_VERIFY_FAILED')) {
        lastFailure = e;
        onReachability?.call(this, false);
        throw KomgaCertificate(baseUrl);
      }
      rethrow;
    }
  }

  /// Told after every server call whether Komga answered (the connection uses it to offer offline mode).
  static void Function(Komga api, bool reachable)? onReachability;

  /// How the last call that didn't reach Komga failed (no answer in time, refused, no route...) - for the error log.
  static Object? lastFailure;

  /// Told when Komga refuses the API key (HTTP 401) - it was deleted, say (the connection offers downloaded books
  /// and signing in again).
  static void Function(Komga api)? onKeyRefused;

  /// Whether Komga is there, for the connection's check ([me], answered or thrown as for any request): asked on a
  /// connection of its own, closed after - not one kept open from before (user, 2026-10-26: Wi-Fi off, the iPad let
  /// requests wait on those until their 15 s ran out, and the offer to go offline came late) - and within
  /// [pingTimeout].
  Future<void> ping() async {
    final fresh = _ownClient ? _zone.run(http.Client.new) : null;
    try {
      await runZoned(me, zoneValues: {_pingClient: fresh, _pingLimit: pingTimeout});
    } finally {
      fresh?.close();
    }
  }

  static const pingTimeout = Duration(seconds: 5);
  static final _pingClient = Object(), _pingLimit = Object();

  Future<dynamic> _get(String path, [Map<String, Object?>? query]) => _net(() async {
        final client = (Zone.current[_pingClient] as http.Client?) ?? _http; // ([ping]'s own)
        final r = await client.get(_u(path, query), headers: headers);
        if (r.statusCode == 404) return null;
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, path);
        try {
          return jsonDecode(utf8.decode(r.bodyBytes));
        } on FormatException {
          throw KomgaNotKomga(baseUrl); // a web page (a router, another server on that port), not Komga's API
        }
      });

  /// A POST that answers (Komga's searches with a condition): [body] as JSON, the answer decoded.
  Future<dynamic> _post(String path, Map<String, Object?> query, Object body) => _net(() async {
        final r = await _http.post(_u(path, query), headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode(body));
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, path);
        try {
          return jsonDecode(utf8.decode(r.bodyBytes));
        } on FormatException {
          throw KomgaNotKomga(baseUrl);
        }
      });

  Future<void> _send(String method, String path, [Object? body]) => _net(() async {
        final req = http.Request(method, _u(path))..headers.addAll(headers);
        if (body != null) {
          req.headers['Content-Type'] = 'application/json';
          req.body = jsonEncode(body);
        }
        final r = await _http.send(req);
        // Komga's reply read to the end, even unused: left unread, the connection can't be used again and a reading
        // session piled up sockets (code review 2026-10-05, #7)
        await r.stream.drain<void>();
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, path);
      });

  // ---- account / libraries
  Future<Map<String, dynamic>?> me() async => await _get('/api/v2/users/me') as Map<String, dynamic>?;

  /// A new API key for the signed-in account, named [comment] (a password sign-in: the key is kept, the password
  /// isn't). Throws [KomgaError] when Komga won't make one (a restricted account, a Komga without API keys).
  Future<String> createApiKey(String comment) async {
    final made = await _post('/api/v2/users/me/api-keys', const {}, {'comment': comment});
    final key = made is Map ? made['key'] : null;
    if (key is! String || key.isEmpty) throw KomgaError(200, '/api/v2/users/me/api-keys (no key in the answer)');
    return key;
  }
  Future<List<dynamic>> libraries() async => (await _get('/api/v1/libraries')) as List<dynamic>;

  Future<List<dynamic>>? _librariesOnce;

  /// The library list, kept: fetched once, then again after [forgetLibraries] (the app back in the foreground) or a
  /// fresh fetch ([visibleLibraries] - Home's load and Refresh). A failed fetch isn't kept (asked again next time).
  /// Libraries change rarely; the side menu asked for them on every opening (code review 2026-10-05, #43).
  Future<List<dynamic>> keptLibraries() async {
    final kept = _librariesOnce ??= libraries();
    try {
      return await kept;
    } catch (_) {
      if (identical(_librariesOnce, kept)) _librariesOnce = null;
      rethrow;
    }
  }

  /// The kept library list is out of date (the app back in the foreground): the next use fetches it again.
  void forgetLibraries() => _librariesOnce = null;

  /// A library's name, for breadcrumbs ("Ongoing › Absolute Flash"), from the kept list; null if it can't be had
  /// (tried again next time).
  Future<String?> libraryName(String? id) async {
    if (id == null) return null;
    try {
      for (final l in await keptLibraries()) {
        if (l['id'] == id) return l['name'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The libraries this device shows (Settings > Library & Home): Home, the library picker. Fetched fresh, and kept
  /// for the side menu ([kept]: the kept list, fetched only if there's none).
  /// Told each time the library list is fetched fresh and answered: every library's id, the hidden ones too (pins to a
  /// library deleted on the server go - lib/pins.dart). The offline source and the folders answer too: the listener
  /// tells them apart.
  static void Function(Komga api, List<String> libraryIds)? onLibraries;

  Future<List<dynamic>> visibleLibraries({bool kept = false}) async {
    final List<dynamic> all;
    if (kept) {
      all = await keptLibraries();
    } else {
      all = await libraries();
      _librariesOnce = Future.value(all);
      onLibraries?.call(this, [for (final l in all) if (l['id'] case final String id) id]);
    }
    return [for (final l in all) if (!HiddenLibraries.instance.isHidden(l['id'] as String?)) l];
  }

  /// What to ask Komga for: one library, or - across libraries, with some hidden on this device - the shown ones
  /// (Komga takes a list), so every list leaves the hidden ones out. Null: no filter at all.
  Future<Object?> _scope(String? libraryId) async {
    if (libraryId != null || HiddenLibraries.instance.ids.isEmpty) return libraryId;
    try {
      final all = await keptLibraries();
      final shown = [for (final l in all) if (!HiddenLibraries.instance.isHidden(l['id'] as String?)) l['id'] as String];
      return shown.isEmpty ? null : shown; // (Settings keeps at least one shown)
    } catch (_) {
      return null; // can't tell which: the request itself will say what's wrong
    }
  }

  // ---- browsing (Komga pages: {content, totalElements, last})
  Future<Map<String, dynamic>> series({String? libraryId, String? collectionId, List<String>? readStatus,
      String sort = 'metadata.titleSort,asc', int page = 0, int size = 60}) async {
    return await _get('/api/v1/series', {
      'library_id': await _scope(libraryId), 'collection_id': collectionId, 'read_status': readStatus,
      'sort': sort, 'page': page, 'size': size,
    }) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> books({String? libraryId, List<String>? readStatus,
      String sort = 'metadata.releaseDate,desc', int page = 0, int size = 60}) async {
    return await _get('/api/v1/books', {
      'library_id': await _scope(libraryId), 'read_status': readStatus, 'sort': sort, 'page': page, 'size': size,
    }) as Map<String, dynamic>;
  }

  /// Books you are part-way through, most recently read first.
  Future<Map<String, dynamic>> inProgress({String? libraryId, int size = 30}) =>
      books(libraryId: libraryId, readStatus: const ['IN_PROGRESS'], sort: 'readProgress.readDate,desc', size: size);

  /// Komga's "On deck": the next unread book of series you have been reading.
  Future<Map<String, dynamic>> onDeck({String? libraryId, int size = 30}) async =>
      await _get('/api/v1/books/ondeck', {'library_id': await _scope(libraryId), 'page': 0, 'size': size}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> seriesBooks(String seriesId, {List<String>? readStatus,
      String sort = 'metadata.numberSort,asc', int page = 0, int size = 500}) async {
    final path = '/api/v1/series/$seriesId/books';
    final r = await _get(path, {'read_status': readStatus, 'sort': sort, 'page': page, 'size': size});
    if (r == null) throw KomgaError(404, path); // the series is gone (a null here broke the offline refresh - review)
    return r as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> collections({String? libraryId, int page = 0, int size = 200}) async =>
      await _get('/api/v1/collections', {'library_id': await _scope(libraryId), 'page': page, 'size': size}) as Map<String, dynamic>;

  Future<Map<String, dynamic>> readLists({String? libraryId, int page = 0, int size = 200}) async =>
      await _get('/api/v1/readlists', {'library_id': await _scope(libraryId), 'page': page, 'size': size}) as Map<String, dynamic>;

  // ---- search (Komga's own search, by title and more; optionally within one library)
  Future<Map<String, dynamic>> searchSeries(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/series', {'search': query, 'library_id': await _scope(libraryId), 'size': size}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchBooks(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/books', {'search': query, 'library_id': await _scope(libraryId), 'size': size}) as Map<String, dynamic>;
  /// The books of any of [seriesIds], by number - one request, however many series (Search's Books row: a series
  /// found brings its books along - bug #15).
  Future<Map<String, dynamic>> booksOfSeries(List<String> seriesIds, {int size = 300}) async =>
      await _post('/api/v1/books/list', {'size': size, 'sort': 'metadata.numberSort,asc'}, {
        'condition': {
          'anyOf': [for (final id in seriesIds) {'seriesId': {'operator': 'is', 'value': id}}],
        },
      }) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchReadLists(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/readlists', {'search': query, 'library_id': await _scope(libraryId), 'size': size}) as Map<String, dynamic>;
  Future<Map<String, dynamic>> searchCollections(String query, {String? libraryId, int size = 30}) async =>
      await _get('/api/v1/collections', {'search': query, 'library_id': await _scope(libraryId), 'size': size}) as Map<String, dynamic>;

  /// Books of a read list in the list's own order, optionally only unread / in progress / read.
  Future<Map<String, dynamic>> readListBooks(String readListId, {List<String>? readStatus, int page = 0, int size = 1000}) async =>
      await _get('/api/v1/readlists/$readListId/books',
          {'read_status': readStatus, 'page': page, 'size': size}) as Map<String, dynamic>;

  // ---- filtered views (the filter panel: lib/view_filter.dart) -------------------------------------------------------
  /// A view's series with its read filter and filters: one library ([libraryId]; null = all shown libraries) or a
  /// collection. With no filter (or only book-less ones) this is [series] - the same request as before filters existed;
  /// with one, Komga's search (POST /api/v1/series/list) with all of them as one condition.
  Future<Map<String, dynamic>> filteredSeries({String? libraryId, String? collectionId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String sort = 'metadata.titleSort,asc',
      int page = 0, int size = 60}) async {
    final f = filter.forView(seriesView: true);
    if (f.isEmpty) {
      return series(libraryId: libraryId, collectionId: collectionId, readStatus: read.api, sort: sort, page: page,
          size: size);
    }
    final condition = ViewFilter.allOf([
      if (await _scopeCondition(libraryId) case final scope?) scope,
      if (collectionId != null) _is('collectionId', collectionId),
      if (_readCondition(read) case final r?) r,
      ...f.conditions(seriesView: true),
    ]);
    return await _post('/api/v1/series/list', {'sort': sort, 'page': page, 'size': size}, {'condition': condition})
        as Map<String, dynamic>;
  }

  /// A view's books with its read filter and filters: a series' ([seriesId]), a read list's ([readListId]) or a
  /// library's (else; null = all shown libraries). The series filters (publisher, genre, status) don't apply to books.
  /// No filter: the same request as before filters existed - [seriesBooks], [readListBooks] (in list order: no
  /// [sort]) or [books]. [sort] / [size] null: that view's usual ones.
  /// With a filter (or a read list sorted otherwise than in list order): Komga's search, POST /api/v1/books/list.
  Future<Map<String, dynamic>> filteredBooks({String? libraryId, String? seriesId, String? readListId,
      ReadFilter read = ReadFilter.all, ViewFilter filter = ViewFilter.none, String? sort, int page = 0,
      int? size}) async {
    final f = filter.forView(seriesView: false);
    if (f.isEmpty) {
      if (seriesId != null) {
        return seriesBooks(seriesId, readStatus: read.api, sort: sort ?? 'metadata.numberSort,asc', page: page,
            size: size ?? 500);
      }
      if (readListId != null && sort == null) {
        return readListBooks(readListId, readStatus: read.api, page: page, size: size ?? 1000);
      }
      if (readListId == null) {
        return books(libraryId: libraryId, readStatus: read.api, sort: sort ?? 'metadata.releaseDate,desc', page: page,
            size: size ?? 60);
      }
    }
    final condition = ViewFilter.allOf([
      if (seriesId != null)
        _is('seriesId', seriesId)
      else if (readListId != null)
        _is('readListId', readListId)
      else if (await _scopeCondition(libraryId) case final scope?)
        scope,
      if (_readCondition(read) case final r?) r,
      ...f.conditions(seriesView: false),
    ]);
    final usualSort = seriesId != null
        ? 'metadata.numberSort,asc'
        : readListId != null
            ? 'readList.number,asc' // the list's own order
            : 'metadata.releaseDate,desc';
    return await _post('/api/v1/books/list', {
      'sort': sort ?? usualSort, 'page': page, 'size': size ?? (seriesId != null ? 500 : readListId != null ? 1000 : 60),
    }, {
      if (condition != null) 'condition': condition,
    }) as Map<String, dynamic>;
  }

  static Map<String, dynamic> _is(String field, String value) => {field: {'operator': 'is', 'value': value}};

  /// [_scope] as a search condition: one library, or any of the shown ones; null = every library.
  Future<Map<String, dynamic>?> _scopeCondition(String? libraryId) async {
    final scope = await _scope(libraryId);
    if (scope is String) return _is('libraryId', scope);
    if (scope is List<String>) return ViewFilter.anyOf([for (final id in scope) _is('libraryId', id)]);
    return null;
  }

  /// The eye as a search condition (any of its read statuses); null = everything.
  static Map<String, dynamic>? _readCondition(ReadFilter read) {
    final statuses = read.api;
    return statuses == null ? null : ViewFilter.anyOf([for (final s in statuses) _is('readStatus', s)]);
  }

  // ---- what the filter panel offers (value lists, scoped to the view) ------------------------------------------------
  /// Komga's scope parameters for the value lists: the narrowest of series, read list, collection, library (null =
  /// all shown libraries).
  Future<Map<String, Object?>> _valueScope({String? libraryId, String? collectionId, String? seriesId,
          String? readListId}) async =>
      seriesId != null
          ? {'series_id': seriesId}
          : readListId != null
              ? {'readlist_id': readListId}
              : collectionId != null
                  ? {'collection_id': collectionId}
                  : {'library_id': await _scope(libraryId)};

  /// The names of the authors in [roles] (any of them: Artist is penciller, inker or cover) in the view, A -> Z, each
  /// once; [search]: names containing it. Komga gives no book counts here.
  Future<List<String>> authorNames(List<String> roles, {String? search, String? libraryId, String? collectionId,
      String? seriesId, String? readListId, int size = 1000}) async {
    final scope = await _valueScope(libraryId: libraryId, collectionId: collectionId, seriesId: seriesId,
        readListId: readListId);
    final pages = await Future.wait([
      for (final role in roles)
        _get('/api/v2/authors', {
          'role': role, if (search != null && search.isNotEmpty) 'search': search, ...scope, 'page': 0, 'size': size,
        }),
    ]);
    final names = <String, String>{}; // lower case -> as Komga has it (first seen)
    for (final p in pages) {
      for (final a in (p as Map?)?['content'] as List? ?? const []) {
        final n = (a as Map)['name'];
        if (n is String && n.trim().isNotEmpty) names.putIfAbsent(n.toLowerCase(), () => n);
      }
    }
    return sortedValues(names.values);
  }

  /// The publishers of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> publishers({String? libraryId, String? collectionId}) async =>
      _strings(await _get('/api/v1/publishers', await _valueScope(libraryId: libraryId, collectionId: collectionId)));

  /// The genres of the series in a library (null = all shown) or a collection, A -> Z.
  Future<List<String>> genres({String? libraryId, String? collectionId}) async =>
      _strings(await _get('/api/v1/genres', await _valueScope(libraryId: libraryId, collectionId: collectionId)));

  /// Whether a library ([libraryId]; null = all shown), a series or a read list holds comics, eBooks or both - for the
  /// filter panel's words (Writer / Author) and whether it offers Artist. Komga keeps no kind per library, so it's
  /// asked once per view and kept while this connection lasts: two one-book searches (EPUB, and not EPUB), whose
  /// totals say which there are. Can't be had: [ViewKind.mixed] (asked again next time).
  Future<ViewKind> viewKind({String? libraryId, String? seriesId, String? readListId}) {
    final key = '$libraryId|$seriesId|$readListId';
    final kept = _kinds[key];
    if (kept != null) return kept;
    Future<ViewKind> ask() async {
      final scope = seriesId != null
          ? _is('seriesId', seriesId)
          : readListId != null
              ? _is('readListId', readListId)
              : await _scopeCondition(libraryId);
      Future<int> count(String operator) async {
        final r = await _post('/api/v1/books/list', {'page': 0, 'size': 1}, {
          'condition': ViewFilter.allOf([
            if (scope != null) scope,
            {'mediaProfile': {'operator': operator, 'value': 'EPUB'}},
          ]),
        }) as Map<String, dynamic>;
        return (r['totalElements'] as int?) ?? (r['content'] as List?)?.length ?? 0;
      }
      final counts = await Future.wait([count('is'), count('isNot')]);
      final epub = counts[0] > 0, other = counts[1] > 0;
      return epub == other ? ViewKind.mixed : (epub ? ViewKind.ebooks : ViewKind.comics);
    }
    final f = ask().catchError((Object _) {
      _kinds.remove(key);
      return ViewKind.mixed;
    });
    return _kinds[key] = f;
  }

  final _kinds = <String, Future<ViewKind>>{};

  static List<String> _strings(Object? r) =>
      sortedValues([if (r is List) for (final v in r) if (v is String && v.trim().isNotEmpty) v]);

  /// Each value once, A -> Z (case aside).
  static List<String> sortedValues(Iterable<String> values) =>
      values.toSet().toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  Future<Map<String, dynamic>?> oneSeries(String id) async => await _get('/api/v1/series/$id') as Map<String, dynamic>?;
  Future<Map<String, dynamic>?> readList(String id) async => await _get('/api/v1/readlists/$id') as Map<String, dynamic>?;

  /// Renames a read list (user, 2026-10-18). Komga allows it to admin accounts only (403 otherwise), and answers 400
  /// to a name another read list already has.
  Future<void> renameReadList(String id, String name) => _send('PATCH', '/api/v1/readlists/$id', {'name': name});

  /// Renames a collection - as [renameReadList] (admin accounts only; 400 for a name taken).
  Future<void> renameCollection(String id, String name) => _send('PATCH', '/api/v1/collections/$id', {'name': name});

  Future<Map<String, dynamic>?> book(String id) async => await _get('/api/v1/books/$id') as Map<String, dynamic>?;

  /// A collection's series in the collection's own order (Komga's: as arranged for an ordered collection, by title
  /// otherwise), optionally only unread / read; the shown libraries only, when some are hidden.
  Future<Map<String, dynamic>> collectionSeries(String collectionId, {List<String>? readStatus, int page = 0,
      int size = 60}) async {
    final path = '/api/v1/collections/$collectionId/series';
    final r = await _get(path, {'library_id': await _scope(null), 'read_status': readStatus, 'page': page, 'size': size});
    if (r == null) throw KomgaError(404, path); // the collection is gone
    return r as Map<String, dynamic>;
  }

  /// A read list's books sorted by a book field ([sort], e.g. "metadata.releaseDate,asc") instead of the list's
  /// order: Komga's book search with the list as the condition.
  Future<Map<String, dynamic>> readListBooksSorted(String readListId, String sort, {List<String>? readStatus,
      int page = 0, int size = 500}) async =>
      await _post('/api/v1/books/list', {'page': page, 'size': size, 'sort': sort}, {
        'condition': {
          'allOf': [
            {'readListId': {'operator': 'is', 'value': readListId}},
            if (readStatus != null)
              {'anyOf': [for (final s in readStatus) {'readStatus': {'operator': 'is', 'value': s}}]},
          ],
        },
      }) as Map<String, dynamic>;

  // ---- pages and posters
  /// A book downloaded on this device is read from the device, online too (user, 2026-10-12: "use a downloaded
  /// version of a comic if present, even if online") - its page list and pages ([localPages]: the downloads, for
  /// this server); anything else asks Komga.
  Future<List<dynamic>> pages(String bookId) async =>
      localPages?.pagesOf(baseUrl, bookId) ?? (await _get('/api/v1/books/$bookId/pages')) as List<dynamic>;

  /// The pages downloaded on this device (lib/offline/downloads.dart sets it): what [pages], [pageBytes] and
  /// [pageThumbBytes] take from the device rather than Komga.
  static LocalPages? localPages;
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
  /// The whole store. Callers asking while a request for it is on its way share that one answer: reader settings,
  /// pins and On deck hidden each refresh from it, and a Home reload asked three times (code review 2026-10-05, #35).
  /// A write starts afresh: nobody joins a request that went out before it.
  Future<Map<String, dynamic>> clientSettings() {
    final running = _settingsAsking;
    if (running != null) return running;
    late final Future<Map<String, dynamic>> asking;
    asking = _fetchClientSettings().whenComplete(() {
      if (identical(_settingsAsking, asking)) _settingsAsking = null;
    });
    return _settingsAsking = asking;
  }

  Future<Map<String, dynamic>>? _settingsAsking;

  Future<Map<String, dynamic>> _fetchClientSettings() async =>
      (await _get('/api/v1/client-settings/user/list') as Map<String, dynamic>?) ?? {};

  Future<void> putClientSetting(String key, String value) {
    _settingsAsking = null;
    return _send('PATCH', '/api/v1/client-settings/user', {key: {'value': value}});
  }

  // ---- EPUB books (Readium web publication): the manifest (reading order, table of contents) and the book's files
  /// Komga answers 406 to Accept: application/json here (its API docs list it; the server doesn't serve it), so it's
  /// asked for as Readium's own type.
  Future<Map<String, dynamic>?> epubManifest(String bookId) => _net(() async {
        final r = await _http.get(Uri.parse('$baseUrl/api/v1/books/$bookId/manifest/epub'),
            headers: {..._auth, 'Accept': 'application/webpub+json'});
        if (r.statusCode == 404) return null;
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'book contents');
        try {
          return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        } on FormatException {
          throw KomgaNotKomga(baseUrl);
        }
      });

  /// One file of an EPUB (a chapter, a stylesheet, a picture, a font) by its path inside the book.
  Future<Uint8List> epubResource(String bookId, String path) => _net(() async {
        final r = await _http.get(
            Uri.parse('$baseUrl/api/v1/books/$bookId/resource/${path.split('/').map(Uri.encodeComponent).join('/')}'),
            headers: _auth);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'book file $path');
        return r.bodyBytes;
      }, limit: pageTimeout, slowIsNotDown: true);

  /// Where reading stopped in an EPUB (Readium's progression: a locator - chapter file, how far in it - with the
  /// device and time); null if never read. Shared with Komga's own web reader.
  Future<Map<String, dynamic>?> epubProgression(String bookId) => _net(() async {
        final r = await _http.get(Uri.parse('$baseUrl/api/v1/books/$bookId/progression'),
            headers: {..._auth, 'Accept': 'application/vnd.readium.progression+json, application/json'});
        if (r.statusCode == 404 || r.statusCode == 204 || r.bodyBytes.isEmpty) return null;
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'reading position');
        return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      });

  /// Saves where reading stopped in an EPUB; Komga turns it into the book's read progress (page = how far through the
  /// book x its page count for it - see epub/progress.dart komgaEpubPage).
  Future<void> setEpubProgression(String bookId, Map<String, dynamic> progression) async {
    await _send('PUT', '/api/v1/books/$bookId/progression', progression);
    onProgressWritten?.call(this, ProgressWrite(bookId: bookId, place: progression)); // a downloaded copy follows
  }

  /// The book's own file (an EPUB, for reading offline).
  Future<Uint8List> bookFileBytes(String bookId) => _net(() async {
        final r = await _http.get(Uri.parse('$baseUrl/api/v1/books/$bookId/file'), headers: _auth);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'book file');
        return r.bodyBytes;
      }, limit: const Duration(minutes: 5), slowIsNotDown: true);

  /// The book's positions (Readium): roughly one per screenful, numbered from 1; Komga's page count for an EPUB.
  Future<List<dynamic>> epubPositions(String bookId) => _net(() async {
        final r = await _http.get(Uri.parse('$baseUrl/api/v1/books/$bookId/positions'),
            headers: {..._auth, 'Accept': 'application/vnd.readium.position-list+json, application/json'});
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'book positions');
        return ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['positions'] as List?) ?? const [];
      });

  // ---- raw page bytes (the reader decodes and adjusts them itself)
  Future<Uint8List> pageBytes(String bookId, int number) =>
      localPages?.pageOf(baseUrl, bookId, number) ?? _net(() async {
        final r = await _http.get(Uri.parse(pageUrl(bookId, number)), headers: imageHeaders);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'page $number');
        return r.bodyBytes;
        // a page that runs out of time is slow, not Komga gone: it fails on its own (Retry on the page), without the
        // "can't reach Komga" prompt or a switch to offline mode (code review, 2026-09-30)
      }, limit: pageTimeout, slowIsNotDown: true);

  /// A small picture of a page (Komga makes it, about 300 px wide) - the reader's slider previews. Komga makes each
  /// one from the book file as it's asked, so on a slow share they can take seconds (2026-09-30: 0.2-3.7 s each, and
  /// some queued past the time limit): one running out of time means slow, not gone - Komga isn't reported
  /// unreachable for it.
  Future<Uint8List> pageThumbBytes(String bookId, int number) =>
      localPages?.pageOf(baseUrl, bookId, number) ?? _net(() async { // (downloaded: the page itself, drawn small)
        final r = await _http.get(Uri.parse('${pageUrl(bookId, number)}/thumbnail'), headers: imageHeaders);
        if (r.statusCode >= 400) throw KomgaError(r.statusCode, 'page $number thumbnail');
        return r.bodyBytes;
      }, slowIsNotDown: true);

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

  // ---- local libraries (experimental/sources): folders on this device, beside or instead of Komga's ----------------
  /// The item ([id]: a book, series or library) is in a local library - a file here, not Komga's.
  bool isLocal(String id) => false;

  /// A local EPUB, read whole when the reader opens it - from this device or a share (null: not a local one).
  Future<Uint8List> Function()? localEpub(String bookId) => null;

  /// Told when the local libraries change (one added or removed, a scan found changes); null: no local libraries.
  Listenable? get localChanges => null;

  // ---- delete (removes the files on the server - callers must confirm first)
  Future<void> deleteBookFile(String bookId) => _send('DELETE', '/api/v1/books/$bookId/file');
  Future<void> deleteSeriesFiles(String seriesId) => _send('DELETE', '/api/v1/series/$seriesId/file');
}

/// Komga answered with an error status. What people see comes from lib/errors.dart; this text is for the error log.
/// The pages of the books downloaded on this device ([Komga.localPages]): null for a book that isn't (wholly)
/// downloaded from the server at [baseUrl] - then Komga is asked.
abstract interface class LocalPages {
  List<dynamic>? pagesOf(String baseUrl, String bookId);
  Future<Uint8List>? pageOf(String baseUrl, String bookId, int number);
}

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
  const ProgressWrite({this.bookId, this.seriesId, this.page, this.completed = false, this.unread = false, this.place});
  final String? bookId, seriesId;
  final int? page; // null with completed: the last page
  final bool completed, unread;
  final Map<String, dynamic>? place; // an EPUB's exact place (its progression), saved as it is
}

/// No answer from the server (away from home, Komga or the PC off, wrong address).
class KomgaUnreachable implements Exception {
  KomgaUnreachable(this.baseUrl);
  final String baseUrl;
  @override
  String toString() => 'no answer from $baseUrl';
}

/// The read filter: everything, hide what's read, or hide what isn't (user, 2026-10-07: three-way, on every library
/// screen). In-progress counts as unread, so each item falls on one side: "hide read" asks Komga for UNREAD +
/// IN_PROGRESS (for series: not every book finished), "hide unread" for READ (finished; a series: all of it).
enum ReadFilter { all, hideRead, hideUnread }

extension ReadFilterApi on ReadFilter {
  List<String>? get api => switch (this) {
        ReadFilter.all => null,
        ReadFilter.hideRead => const ['UNREAD', 'IN_PROGRESS'],
        ReadFilter.hideUnread => const ['READ'],
      };

  /// What the view shows, for names and counts ("unread", "read"); null for everything.
  String? get shows => switch (this) {
        ReadFilter.all => null,
        ReadFilter.hideRead => 'unread',
        ReadFilter.hideUnread => 'read',
      };

  /// A saved name; anything else is everything.
  static ReadFilter fromName(Object? name) =>
      ReadFilter.values.firstWhere((f) => f.name == name, orElse: () => ReadFilter.all);
}
