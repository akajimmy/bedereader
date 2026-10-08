import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:komga_reader/screens/app_settings.dart';
import 'package:komga_reader/settings.dart';

import 'status_server.dart';

/// Settings' pages as the side list names them, to move between pages (a switch: a new page doesn't compile here
/// until it's added). One table for app_settings_test, settings_remote_test and row_nav_keys_test (test audit,
/// 2026-10-07: it was kept twice).
String pageName(SettingsPage p) => switch (p) {
      SettingsPage.reading => 'Reading',
      SettingsPage.comics => 'Comics',
      SettingsPage.ebooks => 'eBooks',
      SettingsPage.keys => 'Remote and keys',
      SettingsPage.server => 'Server and sync',
      SettingsPage.library => 'Library & Home',
      SettingsPage.downloads => 'Downloads',
      SettingsPage.look => 'Look',
      SettingsPage.about => 'About',
    };

/// Two libraries, so Library & Home has its switches.
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
