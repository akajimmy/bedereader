import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_log.dart';
import '../remote_log.dart';
import '../widgets/setting_rows.dart';

/// Settings > About > App log: what the app did, newest at the top (lib/app_log.dart), with Copy and Clear.
class AppLogScreen extends StatelessWidget {
  const AppLogScreen({super.key});

  static const _colours = {
    LogLevel.info: Color(0xFFBDBDBD),
    LogLevel.warn: Color(0xFFFACC15),
    LogLevel.error: Color(0xFFFF8A80),
    LogLevel.crash: Color(0xFFFF5252),
  };

  @override
  Widget build(BuildContext context) {
    final log = AppLog.instance;
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('App log'), actions: [
          IconButton(tooltip: 'Copy all', icon: const Icon(Icons.copy), onPressed: () {
            Clipboard.setData(ClipboardData(text: log.recent.map((l) => l.asText).join('\n')));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
          }),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.clear_all), onPressed: log.clear),
        ]),
        body: log.recent.isEmpty
            ? const Center(child: Text('Nothing logged yet', style: TextStyle(color: Color(0xFF6A6A6A))))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: log.recent.length,
                itemBuilder: (_, i) {
                  final l = log.recent[log.recent.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(l.asText,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: _colours[l.level])),
                  );
                },
              ),
      ),
    );
  }
}

/// Settings > About > Remote log: the app's log sent to a collector on your server (lib/remote_log.dart).
class RemoteLogGroup extends StatelessWidget {
  const RemoteLogGroup({super.key});

  @override
  Widget build(BuildContext context) {
    final r = RemoteLog.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([r, AppLog.instance]),
      builder: (context, _) => SettingsGroup(title: 'Remote log', children: [
        SwitchRow(
          title: 'Send the app log to a server',
          subtitle: 'For finding problems: what the app does, its errors and crashes, sent to a log collector of '
              'yours. Off: nothing leaves this device.',
          value: r.on,
          onChanged: (v) => r.set(on: v),
        ),
        ActionRow(
          title: 'Collector',
          subtitle: r.url.isEmpty ? 'Not set' : r.url,
          icon: Icons.dns_outlined,
          onTap: () async {
            final v = await _ask(context, 'Collector address', r.url, 'https://example.com/log/v1/lines');
            if (v != null) await r.set(url: v);
          },
        ),
        ActionRow(
          title: 'Key',
          subtitle: r.hasToken ? 'Set (kept encrypted on this device)' : 'Not set',
          icon: Icons.key_off,
          onTap: () async {
            final v = await _ask(context, 'Collector key', '', 'The key the collector was given', secret: true);
            if (v != null && v.trim().isNotEmpty) await r.set(token: v);
          },
        ),
        ActionRow(
          title: "This device's name in the log",
          subtitle: r.device,
          icon: Icons.edit_outlined,
          onTap: () async {
            final v = await _ask(context, "This device's name", r.device, 'ipad-air');
            if (v != null) await r.set(device: v);
          },
        ),
        ActionRow(
          title: 'Send now',
          subtitle: [
            '${AppLog.instance.outbox.length} line${AppLog.instance.outbox.length == 1 ? '' : 's'} waiting',
            if (r.status.isNotEmpty) r.status,
          ].join(' · '),
          icon: Icons.sync,
          button: TextButton(onPressed: r.on ? r.sendNow : null, child: const Text('Send')),
        ),
      ]),
    );
  }

  static Future<String?> _ask(BuildContext context, String title, String initial, String hint, {bool secret = false}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, obscureText: secret, autocorrect: false,
            enableSuggestions: false, decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    ).whenComplete(c.dispose);
  }
}
