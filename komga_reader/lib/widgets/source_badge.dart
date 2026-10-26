import 'package:flutter/material.dart';

import '../api.dart';
import '../local/folder_komga.dart';
import '../local/mixed_komga.dart';
import '../settings.dart';

/// Where a book or series comes from (user, 2026-10-26: Settings > Library & Home, "show source icon").
enum BookSource { local, network, komga }

/// [id]'s source, a book or series of [api]'s: a local library on this device, one on a network share (\\host\share),
/// or Komga (its downloads too - they're Komga's books).
BookSource sourceOf(Komga api, String id) {
  final FolderKomga? local = switch (api) {
    final FolderKomga f => f,
    final LocalBeside m when m.isLocal(id) => m.local,
    _ => null,
  };
  if (local == null) return BookSource.komga;
  return local.onShare(id) ? BookSource.network : BookSource.local;
}

/// The source icon for a poster of [id] - or none, with the setting off (Settings > Library & Home, this device's).
Widget? sourceBadgeFor(Komga api, String id) =>
    AppSettings.instance.display.sourceIcon ? SourceBadge(sourceOf(api, id)) : null;

/// The poster's source icon, bottom left: white, on a small dark circle like the download badge's. One colour, drawn
/// here, made to read at 18 px (reports\10-26-source-icons.png): a folder, a folder on a network bar, Komga's K.
class SourceBadge extends StatelessWidget {
  const SourceBadge(this.source, {super.key});
  final BookSource source;

  static const size = 26.0, icon = 18.0;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: switch (source) {
          BookSource.local => 'On this device',
          BookSource.network => 'On a network share',
          BookSource.komga => 'From Komga',
        },
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), shape: BoxShape.circle),
          child: CustomPaint(size: const Size.square(icon), painter: _SourcePainter(source)),
        ),
      );
}

class _SourcePainter extends CustomPainter {
  _SourcePainter(this.source);
  final BookSource source;

  static final _white = Paint()..color = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    switch (source) {
      case BookSource.local:
        _folder(canvas, Rect.fromLTWH(s * 0.07, s * 0.16, s * 0.86, s * 0.68));
      case BookSource.network:
        _folder(canvas, Rect.fromLTWH(s * 0.10, s * 0.07, s * 0.80, s * 0.52));
        final stem = s * 0.09, barY = s * 0.84, barH = s * 0.09;
        canvas.drawRect(Rect.fromLTRB(s / 2 - stem / 2, s * 0.58, s / 2 + stem / 2, barY), _white);
        canvas.drawRRect(
            RRect.fromLTRBR(s * 0.06, barY - barH / 2, s * 0.94, barY + barH / 2, Radius.circular(barH / 2)), _white);
        canvas.drawCircle(Offset(s / 2, barY), s * 0.13, _white);
      case BookSource.komga:
        // Komga's K (its tray icon, MIT - THIRD_PARTY_NOTICES): its outline, slanted as there, in 92% of the box
        final k = 0.92 * s, o = (s - k) / 2;
        canvas.drawPath(Path()..addPolygon([for (final p in _komgaK) Offset(o + p.dx * k, o + p.dy * k)], true), _white);
    }
  }

  /// A folder: a tab top left, the body under it, softly rounded.
  static void _folder(Canvas canvas, Rect r) {
    final w = r.width, h = r.height, rad = Radius.circular(w * 0.08);
    final tabW = w * 0.42, tabH = h * 0.16;
    canvas.drawRRect(RRect.fromLTRBR(r.left, r.top, r.left + tabW, r.top + tabH * 2, rad), _white);
    canvas.drawPath(
        Path()
          ..addPolygon([
            Offset(r.left + tabW - w * 0.08, r.top),
            Offset(r.left + tabW + tabH, r.top + tabH),
            Offset(r.left + tabW - w * 0.08, r.top + tabH),
          ], true),
        _white);
    canvas.drawRRect(RRect.fromLTRBR(r.left, r.top + tabH, r.right, r.bottom, rad), _white);
  }

  @override
  bool shouldRepaint(_SourcePainter old) => old.source != source;
}

/// Komga's K in a unit box: the outline of path824 in komga-tray/src/main/resources/icons/komga-gray-minimal.svg
/// (github.com/gotson/komga, MIT), with its group's slant applied.
const _komgaK = [
  Offset(0.7349, 0.0000), Offset(0.6658, 0.4068), Offset(0.9772, 0.7834), Offset(0.6684, 0.8752),
  Offset(0.4508, 0.5732), Offset(0.5477, 0.9111), Offset(0.2488, 1.0000), Offset(0.0228, 0.2117),
  Offset(0.3217, 0.1229), Offset(0.4095, 0.4291), Offset(0.4545, 0.0834),
];
