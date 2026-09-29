import 'package:flutter/material.dart';

import '../api.dart';
import '../licences.dart';
import '../offline/offline_komga.dart';
import '../screen.dart';
import '../widgets/fullscreen_exit.dart';
import 'document.dart';

const appName = 'Komga Reader';
const appAuthor = 'Nick';
const appLicense = 'MIT licence - free to use, change and share, keeping the copyright notice'; // LICENSE

/// App name, version, author, licence; the Komga server's address and a traffic-light status with Retry;
/// credits and links for Komga.
class InfoScreen extends StatefulWidget {
  const InfoScreen({super.key, required this.api});
  final Komga api;
  @override
  State<InfoScreen> createState() => _InfoScreenState();
}

enum ServerState { checking, ok, warning, down }

class _InfoScreenState extends State<InfoScreen> {
  String? _version;

  @override
  void initState() {
    super.initState();
    getAppVersion().then((v) { if (mounted) setState(() => _version = v); });
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Info'), actions: const [FullscreenExit()]),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 40), children: [
            // hero: the icon, big, with a soft glow; name; version badge
            Center(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.22), blurRadius: 40, spreadRadius: 2)],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(34),
                  child: Image.asset('assets/icon.png', width: 152, height: 152,
                      errorBuilder: (_, __, ___) => const SizedBox(width: 152, height: 152)),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Center(child: Text(appName, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600))),
            const SizedBox(height: 10),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: accent.withValues(alpha: 0.4)),
                ),
                child: Text(_version == null ? 'Version unknown' : 'Version $_version',
                    style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w500)),
              ),
            ),
            const SizedBox(height: 28),
            _Card(title: 'About', icon: Icons.person_outline, children: [
              _row('Author', appAuthor),
              _row('Licence', appLicense),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => showLicensePage(context: context, applicationName: appName,
                      applicationVersion: _version, applicationLegalese: '$appCopyright. $appLicenceName.'),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('Licences of included open-source software'),
                ),
              ),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.whatsNew())),
                  icon: const Icon(Icons.new_releases_outlined, size: 18),
                  label: const Text("What's new"),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.readMe())),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('Read me'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DocumentScreen.thirdParty())),
                  icon: const Icon(Icons.extension_outlined, size: 18),
                  label: const Text('Third-party software'),
                ),
              ]),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.smart_toy_outlined, size: 18, color: Color(0xFF9A9A9A)),
                const SizedBox(width: 8),
                const Expanded(child: Text(aiDisclosure, style: TextStyle(color: Color(0xFFBDBDBD), height: 1.4))),
              ]),
            ]),
            _Card(title: 'Server', icon: Icons.dns_outlined, children: [
              _row('Address', widget.api.baseUrl),
              const SizedBox(height: 6),
              ServerStatus(api: widget.api, autofocus: true),
            ]),
            _Card(title: 'Komga', icon: Icons.favorite_outline, children: [
              const Text('This app reads your library from a Komga server. Komga is a free and open-source media '
                  'server for comics, manga and books, created by Gauthier Roebroeck (gotson) and its contributors. '
                  'This app is not affiliated with the Komga project.',
                  style: TextStyle(height: 1.45, color: Color(0xFFCFCFCF))),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _link('komga.org', 'https://komga.org'),
                _link('Komga on GitHub', 'https://github.com/gotson/komga'),
              ]),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _link(String label, String url) => OutlinedButton.icon(
        onPressed: () async {
          final ok = await openUrl(url);
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(url)));
          }
        },
        icon: const Icon(Icons.open_in_new, size: 18),
        label: Text(label),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(color: Color(0xFF9A9A9A)))),
          Expanded(child: SelectableText(value)),
        ]),
      );
}

/// A rounded section card with a small icon + title header.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF15161A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF26282E)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 18, color: const Color(0xFF9A9A9A)),
            const SizedBox(width: 8),
            Text(title.toUpperCase(),
                style: const TextStyle(fontSize: 12, letterSpacing: 1.2, color: Color(0xFF9A9A9A), fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      );
}

/// The server's traffic light with Retry (Info, App settings > Server & connection). Green: answered and the API key
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
