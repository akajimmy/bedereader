import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/content_changed.dart';
import 'package:komga_reader/widgets/refresh_on_return.dart';

/// Library views load afresh whenever they're back on top, however they got there (user, 2026-09-30: Home's
/// Continue reading was sometimes stale).
class _View extends StatefulWidget {
  const _View(this.name, this.counts);
  final String name;
  final Map<String, int> counts;
  @override
  State<_View> createState() => _ViewState();
}

class _ViewState extends State<_View> with RefreshOnReturn {
  @override
  void refreshView() => widget.counts[widget.name] = (widget.counts[widget.name] ?? 0) + 1;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text(widget.name));
}

void main() {
  late Map<String, int> counts;
  late NavigatorState nav;

  Future<void> start(WidgetTester tester) async {
    counts = {};
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: key, navigatorObservers: [ReturnObserver.instance],
        home: _View('home', counts)));
    nav = key.currentState!;
  }

  Future<void> push(WidgetTester tester, String name) async {
    nav.push(MaterialPageRoute(builder: (_) => _View(name, counts)));
    await tester.pumpAndSettle();
  }

  testWidgets('back from a screen: the one underneath refreshes', (tester) async {
    await start(tester);
    await push(tester, 'series');
    expect(counts, isEmpty);
    nav.pop();
    await tester.pumpAndSettle();
    expect(counts, {'home': 1});
  });

  testWidgets('several closed at once (the side menu\'s Home): only the one left on top refreshes', (tester) async {
    await start(tester);
    await push(tester, 'library');
    await push(tester, 'series');
    nav.popUntil((r) => r.isFirst);
    await tester.pumpAndSettle();
    expect(counts, {'home': 1});
  });

  testWidgets('a menu or dialog closing is not coming back', (tester) async {
    await start(tester);
    unawaited(showDialog<void>(context: tester.element(find.text('home')), builder: (_) => const Text('dialog')));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(counts, isEmpty);
  });

  testWidgets('the app brought back into view: only the screen on top refreshes', (tester) async {
    await start(tester);
    await push(tester, 'series');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(counts, {'series': 1});
  });

  testWidgets('what the views show changed by itself (Komga back after it couldn\'t be reached): the view on top '
      'loads again at once; the one underneath, once it\'s back on top', (tester) async {
    await start(tester);
    await push(tester, 'series');
    contentChanged.value++;
    await tester.pump();
    expect(counts, {'series': 1}, reason: 'on top: at once; Home underneath: not yet');
    nav.pop();
    await tester.pumpAndSettle();
    expect(counts, {'series': 1, 'home': 1}, reason: 'Home back on top');
  });

  // review, 2026-10-26: Komga back while "Can't reach Komga" was up - Home, under the dialog, wasn't on top and kept
  // saying Komga couldn't be reached once the dialog closed
  testWidgets('changed while a dialog is over the view: loaded again once the dialog closes - once; a dialog closing '
      'with nothing changed still loads nothing', (tester) async {
    await start(tester);
    final home = tester.element(find.text('home'));
    unawaited(showDialog<void>(context: home, builder: (_) => const Text('dialog')));
    await tester.pumpAndSettle();
    contentChanged.value++;
    await tester.pump();
    expect(counts, isEmpty, reason: 'under the dialog: not yet');
    nav.pop();
    await tester.pumpAndSettle();
    expect(counts, {'home': 1}, reason: 'uncovered: loaded again');

    unawaited(showDialog<void>(context: home, builder: (_) => const Text('dialog')));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();
    expect(counts, {'home': 1}, reason: 'nothing owed');
  });
}
