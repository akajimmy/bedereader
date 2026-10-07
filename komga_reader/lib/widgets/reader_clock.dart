import 'dart:async';

import 'package:flutter/material.dart';

import '../screen.dart';

/// The time and the battery for the reader (Settings > Comics > Clock and battery): the reader hides the system's
/// status bar, so this is the only way to see them while reading. The time follows the device's 12/24-hour choice;
/// the battery is left out where it can't be read (a PC without one).
class ReaderClock extends StatefulWidget {
  const ReaderClock({super.key, this.colour = Colors.white70, this.fontSize = 13});
  final Color colour;
  final double fontSize;

  @override
  State<ReaderClock> createState() => _ReaderClockState();
}

class _ReaderClockState extends State<ReaderClock> {
  DateTime _now = DateTime.now();
  (int, bool)? _battery;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _readBattery();
    _schedule();
  }

  /// Wakes on the next minute, so the time changes when the minute does; the battery is read then too.
  void _schedule() {
    final now = DateTime.now();
    _tick = Timer(Duration(seconds: 60 - now.second, milliseconds: -now.millisecond + 50), () {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _readBattery();
      _schedule();
    });
  }

  Future<void> _readBattery() async {
    final b = await batteryState();
    if (mounted && b != _battery) setState(() => _battery = b);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static IconData _batteryIcon(int level, bool charging) {
    if (charging) return Icons.battery_charging_full;
    if (level >= 90) return Icons.battery_full;
    if (level >= 70) return Icons.battery_5_bar;
    if (level >= 50) return Icons.battery_4_bar;
    if (level >= 30) return Icons.battery_3_bar;
    if (level >= 15) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: widget.colour, fontSize: widget.fontSize, fontFeatures: const [FontFeature.tabularFigures()]);
    final time = TimeOfDay.fromDateTime(_now).format(context);
    final b = _battery;
    return Semantics(
      label: b == null ? time : '$time, battery ${b.$1} percent',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(time, style: style),
        if (b != null) ...[
          const SizedBox(width: 8),
          Icon(_batteryIcon(b.$1, b.$2), size: widget.fontSize + 3,
              color: b.$1 < 15 && !b.$2 ? const Color(0xFFFF8A80) : widget.colour),
          Text('${b.$1}%', style: style),
        ],
      ]),
    );
  }
}
