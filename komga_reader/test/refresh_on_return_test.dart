import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    showDialog<void>(context: tester.element(find.text('home')), builder: (_) => const Text('dialog'));
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
}
