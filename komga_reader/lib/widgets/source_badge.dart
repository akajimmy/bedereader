import 'package:flutter/material.dart';

import '../book_source.dart';
import '../combined_source.dart';
import '../local/local_source.dart';
import '../settings.dart';

/// Where a book, series or library comes from (user, 2026-10-26: Settings > Library & Home, "show source icon").
enum Origin { local, network, komga }

/// [id]'s origin, a book, series or library of [api]'s: a local library on this device, one on a network share
/// (\\host\share), or Komga (its downloads too - they're Komga's books).
Origin originOf(BookSource api, String id) => switch (CombinedSource.of(api, id)) {
      final LocalSource l => l.onShare(id) ? Origin.network : Origin.local,
      _ => Origin.komga,
    };

/// The source icon for a poster of [id] - or none, with the setting off (Settings > Library & Home, this device's).
Widget? sourceBadgeFor(BookSource api, String id) =>
    AppSettings.instance.display.sourceIcon ? SourceBadge(originOf(api, id)) : null;

/// A library's icon: its origin's (with the setting on - Komga's libraries and local ones of the same name looked
/// alike in the side menu), else the plain folder.
Widget libraryIcon(BookSource api, String libraryId, {double? size}) => AppSettings.instance.display.sourceIcon
    ? SourceIcon(originOf(api, libraryId), size: size)
    : Icon(Icons.folder_outlined, size: size);

/// The poster's source icon, bottom left: white, on a small dark circle like the download badge's. One colour, drawn
/// here, made to read at 18 px: a folder, a folder on a network bar, Komga's K.
class SourceBadge extends StatelessWidget {
  const SourceBadge(this.origin, {super.key});
  final Origin origin;

  static const size = 26.0, icon = 18.0;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: originLabel(origin),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), shape: BoxShape.circle),
          child: CustomPaint(size: const Size.square(icon), painter: _OriginPainter(origin, Colors.white)),
        ),
      );
}

String originLabel(Origin o) => switch (o) {
      Origin.local => 'On this device',
      Origin.network => 'On a network share',
      Origin.komga => 'From Komga',
    };

/// An origin's icon on its own, in the colour and size icons have where it is (a library in a list: 24; on a button:
/// 18 - at 24 there it made the library buttons taller than All libraries' beside them, tablet 2026-10-26).
class SourceIcon extends StatelessWidget {
  const SourceIcon(this.origin, {super.key, this.size, this.colour});
  final Origin origin;
  final double? size; // null: the icon theme's, as an Icon's
  final Color? colour; // null: the icon theme's

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final colour = this.colour ?? theme.color ?? Colors.white, size = this.size ?? theme.size ?? 24;
    // (drawn nearly to the box's edge: with a 10% margin they came out about 10% smaller than the Material icons
    // beside them, measured on the tablet; at 2% the folder spans what Material's own folder does)
    return SizedBox.square(
      dimension: size,
      child: Padding(padding: EdgeInsets.all(size * 0.02), child: CustomPaint(painter: _OriginPainter(origin, colour))),
    );
  }
}

class _OriginPainter extends CustomPainter {
  _OriginPainter(this.origin, this.colour) : _paint = Paint()..color = colour;
  final Origin origin;
  final Color colour;
  final Paint _paint;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    switch (origin) {
      case Origin.local:
        _folder(canvas, Rect.fromLTWH(s * 0.07, s * 0.16, s * 0.86, s * 0.68), _paint);
      case Origin.network:
        _folder(canvas, Rect.fromLTWH(s * 0.10, s * 0.07, s * 0.80, s * 0.52), _paint);
        final stem = s * 0.09, barY = s * 0.84, barH = s * 0.09;
        canvas.drawRect(Rect.fromLTRB(s / 2 - stem / 2, s * 0.58, s / 2 + stem / 2, barY), _paint);
        canvas.drawRRect(
            RRect.fromLTRBR(s * 0.06, barY - barH / 2, s * 0.94, barY + barH / 2, Radius.circular(barH / 2)), _paint);
        canvas.drawCircle(Offset(s / 2, barY), s * 0.13, _paint);
      case Origin.komga:
        // Komga's K (its tray icon, MIT - THIRD_PARTY_NOTICES): its outline, slanted as there, in 92% of the box
        final k = 0.92 * s, o = (s - k) / 2;
        canvas.drawPath(Path()..addPolygon([for (final p in _komgaK) Offset(o + p.dx * k, o + p.dy * k)], true), _paint);
    }
  }

  /// A folder: a tab top left, the body under it, softly rounded.
  static void _folder(Canvas canvas, Rect r, Paint paint) {
    final w = r.width, h = r.height, rad = Radius.circular(w * 0.08);
    final tabW = w * 0.42, tabH = h * 0.16;
    canvas.drawRRect(RRect.fromLTRBR(r.left, r.top, r.left + tabW, r.top + tabH * 2, rad), paint);
    canvas.drawPath(
        Path()
          ..addPolygon([
            Offset(r.left + tabW - w * 0.08, r.top),
            Offset(r.left + tabW + tabH, r.top + tabH),
            Offset(r.left + tabW - w * 0.08, r.top + tabH),
          ], true),
        paint);
    canvas.drawRRect(RRect.fromLTRBR(r.left, r.top + tabH, r.right, r.bottom, rad), paint);
  }

  @override
  bool shouldRepaint(_OriginPainter old) => old.origin != origin || old.colour != colour;
}

/// Komga's K in a unit box: the outline of path824 in komga-tray/src/main/resources/icons/komga-gray-minimal.svg
/// (github.com/gotson/komga, MIT), with its group's slant applied.
const _komgaK = [
  Offset(0.7349, 0.0000), Offset(0.6658, 0.4068), Offset(0.9772, 0.7834), Offset(0.6684, 0.8752),
  Offset(0.4508, 0.5732), Offset(0.5477, 0.9111), Offset(0.2488, 1.0000), Offset(0.0228, 0.2117),
  Offset(0.3217, 0.1229), Offset(0.4095, 0.4291), Offset(0.4545, 0.0834),
];
