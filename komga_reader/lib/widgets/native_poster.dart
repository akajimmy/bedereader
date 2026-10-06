import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The next book's poster on the readers' end cards (user, 2026-10-03; the EPUB reader's too, 2026-10-06): at its own
/// size, one poster pixel to one screen pixel, never enlarged; shrunk to fit [max] if it's bigger. Until it's in (or if there's none): an empty plate of the usual shape.
class NativePoster extends StatefulWidget {
  const NativePoster(this.provider, {super.key, required this.max});
  final ImageProvider provider;
  final Size max;
  @override
  State<NativePoster> createState() => _NativePosterState();
}

class _NativePosterState extends State<NativePoster> {
  ImageStream? _stream;
  ImageInfo? _info;
  late final _listener = ImageStreamListener(
    (info, _) { if (mounted) setState(() { _info?.dispose(); _info = info; }); },
    onError: (_, __) {}, // none to be had: the empty plate stays
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(NativePoster old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) _resolve();
  }

  void _resolve() {
    final s = widget.provider.resolve(createLocalImageConfiguration(context));
    if (s.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = s..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final max = widget.max;
    Size size;
    if (info == null) {
      size = Size(max.height * 0.66, max.height); // waiting: a plate of the usual shape
    } else {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      size = Size(info.image.width / dpr, info.image.height / dpr); // its own size, in logical pixels
      final shrink = math.min(1.0, math.min(max.width / size.width, max.height / size.height));
      size = size * shrink;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox.fromSize(
        key: const ValueKey('next-poster'),
        size: size,
        child: info == null
            ? const ColoredBox(color: Color(0xFF1C1C1F))
            : RawImage(image: info.image, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
      ),
    );
  }
}
