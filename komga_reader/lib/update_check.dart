import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'screen.dart';

/// A newer BeDeReader on GitHub (user, 2026-10-22: "a 'version check' to the app ... that links to github if a newer
/// version than installed is available" - automatic, no switch; the README says the app asks GitHub). Android and
/// Windows - the builds GitHub's releases carry; iOS updates through TestFlight. At most once a day, at start: the
/// latest release (GitHub leaves pre-releases out), newer when its build number - in its files' names, "-b123-" - is
/// higher than this one's (or, with none, its version). Offline or GitHub down: nothing, and again at the next start.
class UpdateCheck extends ChangeNotifier {
  UpdateCheck._();
  static final instance = UpdateCheck._();

  static const latestUrl = 'https://api.github.com/repos/akajimmy/bedereader/releases/latest';
  static const _lastKey = 'update.lastCheck', _foundKey = 'update.found', _dismissedKey = 'update.dismissed';

  @visibleForTesting
  static http.Client Function() client = http.Client.new;
  @visibleForTesting
  static Future<(String, int)?> Function() installed = appVersionInfo;

  /// The newer release, if there is one and it wasn't put away (×) - for Home's line.
  NewRelease? get available => _found != null && _found!.version != _dismissed ? _found : null;
  NewRelease? _found;
  String? _dismissed;

  /// Off in the experiment's app (BeDeReader Exp): a BeDeReader release isn't an update to it (user, 2026-10-26: "1.5.0
  /// is not an update to exp"). Not to go to 1.6 (EXPERIMENT.md).
  @visibleForTesting
  static bool inThisApp = false;

  static bool get applies =>
      inThisApp && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.windows);

  /// Asks GitHub - unless it was asked less than a day ago (then the last answer stands).
  Future<void> check({DateTime? now}) async {
    if (!applies) return;
    final p = await SharedPreferences.getInstance();
    final at = now ?? DateTime.now();
    _dismissed = p.getString(_dismissedKey);
    final mine = await installed();
    final kept = NewRelease.fromSaved(p.getString(_foundKey));
    _found = kept != null && mine != null && kept.newerThan(mine) ? kept : null; // (installed since: gone)
    final last = p.getInt(_lastKey);
    if (last != null && at.difference(DateTime.fromMillisecondsSinceEpoch(last)) < const Duration(days: 1)) {
      notifyListeners();
      return;
    }
    try {
      final c = client();
      final r = await c.get(Uri.parse(latestUrl),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'BeDeReader'}).timeout(const Duration(seconds: 10));
      c.close();
      if (r.statusCode != 200) return;
      await p.setInt(_lastKey, at.millisecondsSinceEpoch);
      final latest = NewRelease.fromGitHub(jsonDecode(r.body) as Map<String, dynamic>);
      _found = latest != null && mine != null && latest.newerThan(mine) ? latest : null;
      if (_found == null) {
        await p.remove(_foundKey);
      } else {
        await p.setString(_foundKey, jsonEncode(_found!.toJson()));
      }
    } catch (_) {
      // offline, GitHub unreachable or changed: nothing to say - again at the next start
    } finally {
      notifyListeners();
    }
  }

  /// The line put away for this version (×): back for the next one.
  Future<void> dismiss() async {
    final f = _found;
    if (f == null) return;
    _dismissed = f.version;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_dismissedKey, f.version);
  }
}

/// A release on GitHub: its version ("1.5.0"), its page, its build number (from its files' names; null if none).
@immutable
class NewRelease {
  const NewRelease(this.version, this.url, this.build);
  final String version, url;
  final int? build;

  static NewRelease? fromGitHub(Map<String, dynamic> j) {
    final tag = j['tag_name'], url = j['html_url'];
    if (tag is! String || url is! String) return null;
    int? build;
    for (final a in (j['assets'] as List?) ?? const []) {
      final m = RegExp(r'-b(\d+)-').firstMatch(a is Map ? '${a['name']}' : '');
      if (m != null) build = int.parse(m.group(1)!);
    }
    return NewRelease(tag.startsWith('v') ? tag.substring(1) : tag, url, build);
  }

  static NewRelease? fromSaved(String? s) {
    if (s == null) return null;
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      return NewRelease(j['version'] as String, j['url'] as String, j['build'] as int?);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {'version': version, 'url': url, 'build': build};

  /// Newer than the installed (version, build).
  bool newerThan((String, int) mine) => build != null ? build! > mine.$2 : compareVersions(version, mine.$1) > 0;
}

/// "1.10.0" against "1.9.2", part by part as numbers (a part that isn't one counts as 0).
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split(RegExp(r'[.\-+]'))) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// Home's line when there's a newer release: "BeDeReader 1.5.0 is available", the release page, and × (not for this
/// version).
class UpdateNotice extends StatelessWidget {
  const UpdateNotice({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: UpdateCheck.instance,
        builder: (context, _) {
          final r = UpdateCheck.instance.available;
          if (r == null) return const SizedBox.shrink();
          final accent = Theme.of(context).colorScheme.primary;
          return Container(
            key: const ValueKey('update-notice'),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.5)),
            ),
            child: Row(children: [
              Icon(Icons.system_update, color: accent),
              const SizedBox(width: 10),
              Expanded(child: Text('BeDeReader ${r.version} is available')),
              TextButton(onPressed: () => openUrl(r.url), child: const Text('Get it')),
              IconButton(tooltip: 'Not now', icon: const Icon(Icons.close, size: 18),
                  onPressed: UpdateCheck.instance.dismiss),
            ]),
          );
        },
      );
}
