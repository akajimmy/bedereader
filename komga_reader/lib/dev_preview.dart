import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'page_image.dart';
import 'settings.dart';

/// Developer preview of the page renderer (fit modes, image adjustments, sharpen shader) on a synthetic page:
/// yellowed paper, grey "blacks", soft lines. No server needed. Run: flutter run -d web-server -t lib/dev_preview.dart
void main() => runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Preview()));

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  PageData? _data;
  ReaderPrefs _p = const ReaderPrefs();
  final _scroll = ScrollController();
  final _scroll2 = ScrollController();

  @override
  void initState() {
    super.initState();
    _makePage();
  }

  Future<void> _makePage() async {
    // a real page copied next to index.html as page.jpg wins over the synthetic one
    try {
      final r = await http.get(Uri.base.resolve('page.jpg'));
      if (r.statusCode == 200) {
        final frame = await (await ui.instantiateImageCodec(r.bodyBytes)).getNextFrame();
        setState(() => _data = PageData(frame.image, r.bodyBytes));
        return;
      }
    } catch (_) {}
    const w = 800.0, h = 1200.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFD9CC9E)); // yellowed paper
    final ink = Paint()..color = const Color(0xFF3A3530)..style = PaintingStyle.stroke..strokeWidth = 3;
    for (var i = 0; i < 3; i++) {
      c.drawRect(Rect.fromLTWH(30, 30 + i * 385.0, w - 60, 360), ink); // panels
    }
    c.drawCircle(const Offset(250, 210), 110, Paint()..color = const Color(0xFFB0453A));
    c.drawCircle(const Offset(560, 600), 140, Paint()..color = const Color(0xFF3F6FA0));
    for (var x = 60.0; x < w - 60; x += 14) {
      c.drawLine(Offset(x, 830), Offset(x + 60, 1100), Paint()..color = const Color(0xFF4A4540)..strokeWidth = 1.2);
    }
    final tp = TextPainter(
      text: const TextSpan(text: 'KRAKA-THOOM!', style: TextStyle(fontSize: 64, fontWeight: FontWeight.w900, color: Color(0xFF3A3530))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, const Offset(140, 540));
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    setState(() => _data = PageData(frame.image, png));
  }

  Widget _slider(String label, double v, double min, double max, ValueChanged<double> f) => Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.white))),
        Expanded(child: Slider(value: v, min: min, max: max, onChanged: f)),
        SizedBox(width: 40, child: Text(v.toStringAsFixed(2), style: const TextStyle(color: Colors.white54, fontSize: 11))),
      ]);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(children: [
        // left: untouched, right: with the adjustments (same fit mode)
        Expanded(child: _data == null ? const SizedBox() : PageCanvas(data: _data!, prefs: ReaderPrefs(fit: _p.fit), scroll: _scroll)),
        const SizedBox(width: 4),
        Expanded(child: _data == null ? const SizedBox() : PageCanvas(data: _data!, prefs: _p, scroll: _scroll2, levels: () => Levels.measure(_data!.bytes))),
        SizedBox(
          width: 300,
          child: Material(
            color: const Color(0xFF141416),
            child: ListView(padding: const EdgeInsets.all(12), children: [
              SegmentedButton<FitMode>(
                segments: [for (final f in FitMode.values) ButtonSegment(value: f, label: Text(f.label))],
                selected: {_p.fit},
                onSelectionChanged: (s) => setState(() => _p = _p.copyWith(fit: s.first)),
              ),
              _slider('Bright', _p.brightness, -0.3, 0.3, (v) => setState(() => _p = _p.copyWith(brightness: v))),
              _slider('Contrast', _p.contrast, -0.5, 0.5, (v) => setState(() => _p = _p.copyWith(contrast: v))),
              SwitchListTile(title: const Text('Sharpen', style: TextStyle(color: Colors.white)), value: _p.sharpen,
                  onChanged: (v) => setState(() => _p = _p.copyWith(sharpen: v))),
              SwitchListTile(title: const Text('Auto-levels', style: TextStyle(color: Colors.white)), value: _p.autoLevels,
                  onChanged: (v) => setState(() => _p = _p.copyWith(autoLevels: v))),
            ]),
          ),
        ),
      ]),
    );
  }
}
