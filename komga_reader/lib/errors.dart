import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'offline/offline_komga.dart' show NotAvailableOffline;

/// Every error the app shows goes through here: plain words - what happened and what to do - never the raw error
/// text (user, 2026-09-29: "completely unparseable to your average human"). The raw text isn't lost: it's behind
/// Details on each message (lib/widgets/error_text.dart) and in the error log (Settings > About > Error log).
///
/// Agreed wording: plain and brief; the server address without http://; Komga's error number kept in brackets on
/// server faults; a failed action names the action, then the reason ([couldnt]).

/// What kind of problem, for the few places that act on it (the dead API key goes to offline mode / sign in).
enum ErrorKind {
  unreachable, keyRefused, forbidden, gone, serverFault, refused, notKomga, certificate, badAddress,
  offline, storageFull, storage, unreadablePage, unexpected,
}

class Explained {
  const Explained(this.kind, this.message, this.reason);
  final ErrorKind kind;

  /// On its own: a sentence or two, ending with what to do.
  final String message;

  /// After "Couldn't (the action): " - a lower-case clause, no full stop.
  final String reason;
}

/// "http://10.0.0.23:25600/" -> "10.0.0.23:25600".
String displayAddress(String url) => url.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '').replaceAll(RegExp(r'/+$'), '');

String _sentence(String clause) => '${clause[0].toUpperCase()}${clause.substring(1)}.';

/// [e] in plain words. [signIn]: said on the sign-in screen (checking the address, a key just typed). [thing]: what
/// a missing item is ("book", "series"...). [forbidden]: why this particular action isn't allowed, when that's known
/// (deleting files needs an admin account).
Explained explain(Object e, {bool signIn = false, String thing = 'item', String? forbidden}) {
  if (e is KomgaUnreachable) {
    final at = displayAddress(e.baseUrl);
    return Explained(ErrorKind.unreachable,
        signIn
            ? "Can't reach Komga at $at. Check the address and port, and that the server is running."
            : "Can't reach Komga at $at. Check you're on your home network and the server is running.",
        "can't reach Komga");
  }
  if (e is KomgaNotKomga) {
    final at = displayAddress(e.baseUrl);
    return Explained(ErrorKind.notKomga,
        "Something answered at $at, but it isn't Komga. Check the port; Komga's is usually 25600.",
        "something answered at $at, but it isn't Komga");
  }
  if (e is KomgaCertificate) {
    final host = Uri.tryParse(e.baseUrl)?.host ?? displayAddress(e.baseUrl);
    return Explained(ErrorKind.certificate,
        "Couldn't make a secure connection to $host: this device doesn't trust the server's certificate. Use "
            'http:// at home, or a certificate from a trusted provider.',
        "this device doesn't trust the server's HTTPS certificate");
  }
  if (e is KomgaError) {
    final s = e.status;
    if (s == 401) {
      return signIn
          ? const Explained(ErrorKind.keyRefused,
              "Komga didn't accept that API key. Copy it again from Komga (your account > API keys).",
              "Komga didn't accept that API key")
          : const Explained(ErrorKind.keyRefused,
              "Komga no longer accepts this device's API key. It may have been deleted. Create a new one in Komga "
                  '(your account > API keys) and sign in again.',
              "Komga no longer accepts this device's API key");
    }
    if (s == 403) {
      final why = forbidden ?? "your Komga account isn't allowed to do that";
      return Explained(ErrorKind.forbidden, _sentence(why), why);
    }
    if (s == 404) {
      return Explained(ErrorKind.gone,
          'That $thing is no longer on Komga. It may have been deleted or moved; pull down to refresh.',
          "it's no longer on Komga");
    }
    if (s >= 500) {
      return Explained(ErrorKind.serverFault,
          "Komga ran into a problem (error $s). Try again; if it keeps happening, Komga's logs will say why.",
          'Komga ran into a problem (error $s)');
    }
    return Explained(ErrorKind.refused, 'Komga turned that down (error $s).', 'Komga turned that down (error $s)');
  }
  if (e is NotAvailableOffline) {
    final what = e.what;
    final clause = what == 'The next book' || what.startsWith('Page ')
        ? "$what isn't downloaded"
        : "$what needs Komga, and you're using downloaded books only";
    return Explained(ErrorKind.offline, _sentence(clause), clause[0].toLowerCase() + clause.substring(1));
  }
  if (e is PageUnreadable) {
    return const Explained(ErrorKind.unreadablePage,
        "This page couldn't be shown: the image file is damaged or in a format this device can't read.",
        "the image file is damaged or in a format this device can't read");
  }
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    final full = code == 28 || code == 112 || code == 39 || '${e.osError?.message}'.toLowerCase().contains('space');
    return full
        ? const Explained(ErrorKind.storageFull, 'This device is out of storage space. Free some up, then try again.',
            'this device is out of storage space')
        : const Explained(ErrorKind.storage, "Couldn't save to this device's storage.",
            "couldn't save to this device's storage");
  }
  if ((e is FormatException || e is ArgumentError) && RegExp('scheme|host|port|uri', caseSensitive: false).hasMatch('$e')) {
    return const Explained(ErrorKind.badAddress,
        "That isn't a server address. It should look like 192.168.1.10:25600.", "that isn't a server address");
  }
  return const Explained(ErrorKind.unexpected, 'Something unexpected went wrong.', 'something unexpected went wrong');
}

/// Why a delete was refused (Komga answers 403: only admins may delete files).
const deleteNeedsAdmin = 'deleting files needs an admin account in Komga';

/// A failed action: "Couldn't mark "Saga #3" as read: can't reach Komga."
String couldnt(String action, Object e, {String thing = 'item', String? forbidden}) =>
    "Couldn't $action: ${explain(e, thing: thing, forbidden: forbidden).reason}.";

/// Part of a batch done, then a failure: "Marked 4 of 7 as read, then stopped: can't reach Komga."
String stoppedAfter(String done, Object e, {String? forbidden}) =>
    '$done, then stopped: ${explain(e, forbidden: forbidden).reason}.';

/// A page that loaded but couldn't be decoded (a damaged file, or an image format this device can't read).
class PageUnreadable implements Exception {
  PageUnreadable(this.cause);
  final Object cause;
  @override
  String toString() => 'PageUnreadable: $cause';
}

/// The last errors shown, with their raw text, newest first - Settings > About > Error log. Kept on the device
/// (50 at most) so a problem can still be looked at after the app was closed.
class ErrorLog extends ChangeNotifier {
  ErrorLog._();
  static final ErrorLog instance = ErrorLog._();
  static const _key = 'errorLog';
  static const keep = 50;

  final List<ErrorEntry> entries = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final saved = (await SharedPreferences.getInstance()).getStringList(_key) ?? const [];
      entries.insertAll(0, [for (final s in saved) ErrorEntry.fromJson(jsonDecode(s) as Map<String, dynamic>)]);
    } catch (_) {
      // an unreadable log is no reason to fail: start a new one
    }
    notifyListeners();
  }

  /// Records an error as shown ([message]) and as it really was ([error], [stack]).
  void record(String message, Object error, [StackTrace? stack]) {
    final frames = stack?.toString().split('\n').where((l) => l.trim().isNotEmpty).take(6).join('\n');
    entries.insert(0, ErrorEntry(DateTime.now(), message, '${error.runtimeType}: $error', frames));
    if (entries.length > keep) entries.removeRange(keep, entries.length);
    notifyListeners();
    _save();
  }

  Future<void> clear() async {
    entries.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(_key, [for (final e in entries) jsonEncode(e.toJson())]);
    } catch (_) {
      // the log is a convenience; losing it is fine
    }
  }

  /// The whole log as text (Copy).
  String get asText => entries.map((e) => e.asText).join('\n\n');
}

class ErrorEntry {
  ErrorEntry(this.time, this.message, this.detail, [this.stack]);
  factory ErrorEntry.fromJson(Map<String, dynamic> j) =>
      ErrorEntry(DateTime.parse(j['time'] as String), j['message'] as String, j['detail'] as String, j['stack'] as String?);
  final DateTime time;
  final String message, detail;
  final String? stack;
  Map<String, dynamic> toJson() => {'time': time.toIso8601String(), 'message': message, 'detail': detail, 'stack': stack};
  String get asText => '${time.toIso8601String()}\n$message\n$detail${stack == null ? '' : '\n$stack'}';
}
