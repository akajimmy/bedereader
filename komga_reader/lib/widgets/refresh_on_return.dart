import 'dart:async';

import 'package:flutter/widgets.dart';

import '../content_changed.dart';
import '../screens/reader.dart' show ReaderScreen;

/// Tells a screen when it's back on top - whichever way: its own back arrow, the side menu's Home, the reader
/// closing... (user, 2026-09-30: Home's Continue reading was sometimes stale). In MaterialApp.navigatorObservers;
/// screens hear of it through [RefreshOnReturn].
class ReturnObserver extends NavigatorObserver {
  static final instance = ReturnObserver();
  final Map<Route<dynamic>, Set<VoidCallback>> _listeners = {};
  // told when a menu, dialog or sheet over the screen closes (it isn't coming back to it - see [RefreshOnReturn])
  final Map<Route<dynamic>, Set<VoidCallback>> _uncovered = {};

  static void _addTo(Map<Route<dynamic>, Set<VoidCallback>> m, Route<dynamic> r, VoidCallback f) =>
      (m[r] ??= {}).add(f);

  static void _removeFrom(Map<Route<dynamic>, Set<VoidCallback>> m, Route<dynamic> r, VoidCallback f) {
    final l = m[r];
    l?.remove(f);
    if (l != null && l.isEmpty) m.remove(r);
  }

  void _back(Route<dynamic> route, Route<dynamic>? under) {
    if (under == null) return;
    // a menu, dialog or sheet closing isn't coming back to the screen: only those that asked to hear of it
    final which = route is PageRoute ? _listeners : _uncovered;
    // popUntil takes several off at once: only the one left on top, once they're all off
    scheduleMicrotask(() {
      if (!under.isCurrent) return;
      for (final f in [...?which[under]]) {
        f();
      }
    });
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _back(route, previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _back(route, previousRoute);
}

/// A library view (Home, a library, a series, a read list...) that loads afresh whenever it's shown again: back on
/// top after another screen, or the app brought back into view - and, on top, when what it shows changed by itself
/// ([contentChanged]).
mixin RefreshOnReturn<T extends StatefulWidget> on State<T> {
  /// Load again, keeping the scroll position.
  void refreshView();

  Route<dynamic>? _route;
  AppLifecycleListener? _life;
  bool _listening = false;

  // what it shows changed while a dialog was over it: loaded again once that's closed (review, 2026-10-26: Komga
  // back while "Can't reach Komga" was up - Home wasn't on top, and kept saying Komga couldn't be reached)
  bool _owed = false;

  // only the view on top: the others load again when they're back on top
  void _changed() {
    if (_route?.isCurrent ?? true) {
      _returned();
    } else {
      _owed = true;
    }
  }

  void _uncovered() {
    if (_owed) _returned();
  }

  void _returned() {
    _owed = false;
    if (!mounted) return;
    // a book just closed: its last place read saved first - asked at once, Komga still had the place before and
    // Home showed it (user, 2026-10-25). Nothing on its way: at once.
    ReaderScreen.closing().then((_) {
      if (mounted) refreshView();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r != _route) {
      _forget();
      _route = r;
      if (r != null) {
        final o = ReturnObserver.instance;
        ReturnObserver._addTo(o._listeners, r, _returned);
        ReturnObserver._addTo(o._uncovered, r, _uncovered);
      }
    }
    // back from another app, or the tablet waking: only the screen on top (the others refresh when they're back)
    _life ??= AppLifecycleListener(onShow: () {
      if (_route?.isCurrent ?? true) _returned();
    });
    if (!_listening) {
      _listening = true;
      contentChanged.addListener(_changed);
    }
  }

  void _forget() {
    final r = _route;
    if (r == null) return;
    final o = ReturnObserver.instance;
    ReturnObserver._removeFrom(o._listeners, r, _returned);
    ReturnObserver._removeFrom(o._uncovered, r, _uncovered);
  }

  @override
  void dispose() {
    _forget();
    _life?.dispose();
    contentChanged.removeListener(_changed);
    super.dispose();
  }
}
