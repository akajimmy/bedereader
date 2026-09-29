import 'package:flutter/material.dart';

import '../api.dart';
import '../offline/offline_komga.dart';

enum ServerState { checking, ok, warning, down }

/// The server's traffic light with Retry (Settings > Server & connection). Green: answered and the API key
/// is accepted. Amber: answered but refused the key, took over 3 s, or offline mode. Red: no answer.
class ServerStatus extends StatefulWidget {
  const ServerStatus({super.key, required this.api, this.autofocus = false});
  final Komga api;
  final bool autofocus;
  @override
  State<ServerStatus> createState() => _ServerStatusState();
}

class _ServerStatusState extends State<ServerStatus> {
  ServerState _state = ServerState.checking;
  String _detail = 'Checking…';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (widget.api is OfflineKomga) {
      setState(() { _state = ServerState.warning; _detail = 'Offline mode - showing downloaded books'; });
      return;
    }
    setState(() { _state = ServerState.checking; _detail = 'Checking…'; });
    final watch = Stopwatch()..start();
    ServerState state;
    String detail;
    try {
      final me = await widget.api.me();
      final secs = watch.elapsedMilliseconds / 1000;
      final who = me?['email'] as String?;
      if (secs > 3) {
        state = ServerState.warning;
        detail = 'Connected, but slow (${secs.toStringAsFixed(1)} s)';
      } else {
        state = ServerState.ok;
        detail = who == null ? 'Connected' : 'Connected as $who';
      }
    } on KomgaError catch (e) {
      state = e.status == 401 || e.status == 403 ? ServerState.warning : ServerState.down;
      detail = e.status == 401 || e.status == 403 ? 'Reachable, but the API key was refused' : '$e';
    } catch (e) {
      state = ServerState.down;
      detail = '$e';
    }
    if (mounted) setState(() { _state = state; _detail = detail; });
  }

  @override
  Widget build(BuildContext context) {
    final colour = switch (_state) {
      ServerState.ok => const Color(0xFF22C55E),
      ServerState.warning => const Color(0xFFFACC15),
      ServerState.down => const Color(0xFFEF4444),
      ServerState.checking => const Color(0xFF6B7280),
    };
    return Row(children: [
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colour.withValues(alpha: 0.5)),
          ),
          child: Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: colour,
                boxShadow: [BoxShadow(color: colour.withValues(alpha: 0.6), blurRadius: 8)])),
            const SizedBox(width: 10),
            Expanded(child: Text(_detail)),
          ]),
        ),
      ),
      const SizedBox(width: 10),
      FilledButton.tonalIcon(
        autofocus: widget.autofocus,
        onPressed: _state == ServerState.checking ? null : _check,
        icon: const Icon(Icons.refresh),
        label: const Text('Retry'),
      ),
    ]);
  }
}
