import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'errors.dart';
import 'local/library_fs.dart';
import 'opened_file.dart';
import 'screens/reader.dart';
import 'widgets/error_text.dart';

/// A book file handed to the app from outside: Windows' Open with (the file on the command line, or passed on by a
/// second start to the window already open), Android's Open with and Share, iOS's Open in (user, 2026-10-27). It opens
/// straight in the reader, over whatever is on screen - a book open there is closed first, its place saved - and
/// nothing of it is kept ([OpenedFile]). Closed, it's back where it came from: Android goes back to the app it came
/// from; Windows and iOS show the screen under it (iOS has its own way back, top left).
class OpenWith {
  /// [fs]: where the files are read from (tests give their own; else this device's files).
  @visibleForTesting
  OpenWith({LibraryFs? fs}) : _fs = fs;
  static final instance = OpenWith();
  final LibraryFs? _fs;

  /// The platform's side: MainActivity.kt, AppDelegate.swift, windows/runner (a second start passing its file on).
  static const channel = MethodChannel('komga_reader/open_with');

  GlobalKey<NavigatorState>? _nav;
  final _ready = Completer<void>();
  Future<void> _turn = Future.value(); // one file at a time, in the order they came

  /// Listens for files; [args]: the app's command line (Windows: Open with's file is its first argument).
  void start(GlobalKey<NavigatorState> nav, List<String> args) {
    _nav = nav;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open') _take(call.arguments as Map);
    });
    final file = args.where((a) => !a.startsWith('-')).firstOrNull;
    if (file != null) _take({'path': file});
    // (Android, iOS: the ones handed over before the app was listening)
    channel.invokeListMethod<Map>('pending').then((files) {
      for (final f in files ?? const <Map>[]) {
        _take(f);
      }
    }, onError: (Object _) {}); // (Windows: none)
  }

  /// The app has loaded (settings, the first screen): files can be opened.
  void ready() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void _take(Map file) => _turn = _turn.then((_) => _open(file)).catchError((Object _) {});

  int _taken = 0; // the files taken so far: a reader closed for a newer one doesn't go back to the other app

  /// Opens [file] in the reader - done once it's on screen (not once it's closed: a file coming meanwhile takes its
  /// place - on the tablet, a second one shared waited for the first to be closed).
  Future<void> _open(Map file) async {
    await _ready.future;
    final n = ++_taken;
    final path = file['path'] as String;
    final name = file['name'] as String? ?? path.substring(path.lastIndexOf(RegExp(r'[\\/]')) + 1);
    AppLog.instance.info('open with', 'opening "$name"');
    final nav = _nav?.currentState;
    if (nav == null) return _done(file);
    await ReaderScreen.leaveAll('a file opened with the app');
    final OpenedFile book;
    try {
      book = await OpenedFile.open(path, name: file['name'] as String?, onClose: () => _done(file), fs: _fs);
    } catch (e, st) {
      AppLog.instance.warn('open with', 'couldn\'t open "$name": $e');
      final ctx = _nav?.currentContext;
      // ignore: use_build_context_synchronously
      if (ctx != null && ctx.mounted) showErrorSnack(ctx, couldnt('open "$name"', e, thing: 'book'), e, st);
      return;
    }
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(api: book, book: book.bookJson, saveProgress: false))).then((_) {
      book.close();
      // closed by the user: Android goes back to the app it came from (not when a newer file took its place)
      if (n == _taken && defaultTargetPlatform == TargetPlatform.android) {
        unawaited(channel.invokeMethod('back').catchError((Object _) {}));
      }
    }));
  }

  /// What the platform holds open for [file] let go (Android: the file; iOS: the access to it).
  void _done(Map file) {
    final token = file['token'];
    if (token == null) return;
    unawaited(channel.invokeMethod('done', {'token': token}).catchError((Object _) {}));
  }
}
