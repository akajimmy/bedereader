import 'client_settings.dart';
import 'home_server.dart';

/// Home with On deck of two books (B1 of series S1 "Hidden Series", B2 of S2 "Shown Series"); Komga's client settings
/// kept in memory, or unreachable. Build with `noNetwork(DeckKomga.new)`.
///
/// Was ondeck_hidden_test's, imported from there by synced_refresh_test (test audit, 2026-10-07).
class DeckKomga extends HomeServer with ClientSettingsStore {
  DeckKomga() : super(onDeckBooks: [
          {'id': 'B1', 'seriesId': 'S1', 'seriesTitle': 'Hidden Series', 'name': 'b1', 'metadata': {'number': '4'}},
          {'id': 'B2', 'seriesId': 'S2', 'seriesTitle': 'Shown Series', 'name': 'b2', 'metadata': {'number': '7'}},
        ]);
}
