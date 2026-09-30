import 'dart:async';

import 'package:flutter/widgets.dart';

/// Tells a screen when it's back on top - whichever way: its own back arrow, the side menu's Home, the reader
/// closing... (user, 2026-09-30: Home's Continue reading was sometimes stale). In MaterialApp.navigatorObservers;
/// screens hear of it through [RefreshOnReturn].
class ReturnObserver extends NavigatorObserver {
  static final instance = ReturnObserver();
  final Map<Route<dynamic>, Set<VoidCallback>> _listeners = {};

  void _add(Route<dynamic> r, VoidCallback f) => (_listeners[r] ??= {}).add(f);

  void _remove(Route<dynamic> r, VoidCallback f) {
    final l = _listeners[r];
    l?.remove(f);
    if (l != null && l.isEmpty) _listeners.remove(r);
  }

  void _back(Route<dynamic> route, Route<dynamic>? under) {
    // a menu, dialog or sheet closing isn't coming back to the screen
    if (route is! PageRoute || under == null) return;
    // popUntil takes several off at once: only the one left on top, once they're all off
    scheduleMicrotask(() {
      if (!under.isCurrent) return;
      for (final f in [...?_listeners[under]]) {
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
/// top after another screen, or the app brought back into view. Not live - nothing changes while you look at it.
mixin RefreshOnReturn<T extends StatefulWidget> on State<T> {
  /// Load again, keeping the scroll position.
  void refreshView();

  Route<dynamic>? _route;
  AppLifecycleListener? _life;

  void _returned() {
    if (mounted) refreshView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = ModalRoute.of(context);
    if (r != _route) {
      if (_route != null) ReturnObserver.instance._remove(_route!, _returned);
      _route = r;
      if (r != null) ReturnObserver.instance._add(r, _returned);
    }
    // back from another app, or the tablet waking: only the screen on top (the others refresh when they're back)
    _life ??= AppLifecycleListener(onShow: () {
      if (_route?.isCurrent ?? true) _returned();
    });
  }

  @override
  void dispose() {
    if (_route != null) ReturnObserver.instance._remove(_route!, _returned);
    _life?.dispose();
    super.dispose();
  }
}
