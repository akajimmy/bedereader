import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_log.dart';

/// Settings > Remote and keys > Test the remote: every press the app is given, as it's given - to find out what a
/// remote sends, and where on the way it's lost (user, 2026-10-25: the Chromecast remote pairs with the iPad, but
/// the reader sees none of its buttons).
///
/// Two sources. Flutter's own key events (every platform): what the reader's keys are matched against. And on iOS,
/// what the system gives the app before Flutter (the runner's RemoteLog, "komga_reader/remote"): every event the app
/// is sent that isn't a touch, every button press on the screen - including those without a keyboard key, which
/// Flutter drops - game controllers, and the volume.
class RemoteTestScreen extends StatefulWidget {
  const RemoteTestScreen({super.key});

  @visibleForTesting
  static const channel = MethodChannel('komga_reader/remote');

  @override
  State<RemoteTestScreen> createState() => _RemoteTestScreenState();
}

class _RemoteTestScreenState extends State<RemoteTestScreen> {
  final _lines = <String>[]; // newest first
  final _start = DateTime.now();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    RemoteTestScreen.channel.setMethodCallHandler((call) async {
      if (call.method == 'event') _add('iOS ${call.arguments}');
      return null;
    });
    RemoteTestScreen.channel.invokeMethod('start').catchError((_) => null); // (no native side: Flutter's events only)
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    RemoteTestScreen.channel.setMethodCallHandler(null);
    RemoteTestScreen.channel.invokeMethod('stop').catchError((_) => null);
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    final kind = switch (e) { KeyDownEvent() => 'down', KeyUpEvent() => 'up', _ => 'repeat' };
    _add('Flutter $kind: ${e.logicalKey.debugName ?? e.logicalKey.keyId.toRadixString(16)} '
        '(logical 0x${e.logicalKey.keyId.toRadixString(16)}, physical 0x${e.physicalKey.usbHidUsage.toRadixString(16)})');
    // Back and Esc still leave; everything else stays here, so nothing else on the screen acts on it
    return e.logicalKey != LogicalKeyboardKey.goBack && e.logicalKey != LogicalKeyboardKey.escape;
  }

  void _add(String line) {
    if (!mounted) return;
    AppLog.instance.info('remote test', line); // (so the remote log carries it too)
    final t = DateTime.now().difference(_start);
    setState(() {
      _lines.insert(0, '${(t.inMilliseconds / 1000).toStringAsFixed(2).padLeft(7)}  $line');
      if (_lines.length > 300) _lines.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Test the remote'), actions: [
          IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: _lines.reversed.join('\n')))),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.clear_all), onPressed: () => setState(_lines.clear)),
        ]),
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Press each button on the remote, one at a time. Everything the app is given shows here, '
                'newest at the top. Copy puts the list on the clipboard.',
                style: TextStyle(color: Color(0xFF9A9A9A))),
          ),
          Expanded(child: _lines.isEmpty
              ? const Center(child: Text('Nothing yet', style: TextStyle(color: Color(0xFF6A6A6A))))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(_lines[i], style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                  ),
                )),
        ]),
      );
}
