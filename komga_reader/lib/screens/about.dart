import 'package:flutter/material.dart';

import '../api.dart';
import '../app_identity.dart';
import '../licences.dart';
import '../screen.dart';
import '../widgets/fullscreen_exit.dart';
import 'document.dart';

export '../app_identity.dart' show appName; // the display name (lib/app_identity.dart)
const appAuthor = 'Nick Perusse 🍁';
const appLicense = 'MIT licence - free to use, change and share, keeping the copyright notice'; // LICENSE

/// About (side menu, Settings > About): the app's name, version, author, licence, What's new / Read me /
/// Third-party software, the AI usage disclosure, and credits and links for Komga. The server's status is in
/// Settings > Server & connection.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, required this.api});
  final Komga api;
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
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
      appBar: AppBar(title: const Text('About'), actions: const [FullscreenExit()]),
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
            _Card(title: 'This app', icon: Icons.person_outline, children: [
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
