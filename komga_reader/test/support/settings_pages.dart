import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';

import 'status_server.dart';

/// Settings' pages as the side list names them, to move between pages: the app's own names (a copy here pinned the
/// wording - user, 2026-10-27, Reading renamed). One for app_settings_test, settings_remote_test and row_nav_keys_test.
String pageName(SettingsPage p) => p.label;

/// Two libraries, so Libraries has Komga's switches.
class TwoLibraries extends StatusServer {
  @override
  Future<List<dynamic>> libraries() async => [{'id': 'L1', 'name': 'Events'}, {'id': 'L2', 'name': 'Ongoing'}];
}

/// Every row on: night mode on a schedule (its times, Warmth). Put back when the test ends.
void everyRowShown() {
  final s = AppSettings.instance;
  s.setDisplay(const DisplayPrefs(night: true, nightSchedule: true));
  addTearDown(() => s.setDisplay(const DisplayPrefs()));
}

/// The focused node.
FocusNode focus() => FocusManager.instance.primaryFocus!;

/// A focused control, for messages: its text, else its tooltip.
String name(FocusNode n) {
  final texts = find.descendant(of: find.byWidget(n.context!.widget), matching: find.byType(Text));
  final t = texts.evaluate().isEmpty ? null : (texts.evaluate().first.widget as Text).data;
  return t ?? n.context!.findAncestorWidgetOfExactType<Tooltip>()?.message ?? n.toString();
}
