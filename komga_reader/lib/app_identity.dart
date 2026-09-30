/// The app's name as people see it - set here once for all the Dart code (title, side menu, About, licences page).
/// BeDeReader (user, 2026-09-29; "BéDé" is Québec French for comics, bande dessinée). Plain ASCII on purpose: the
/// same spelling to display, type, search and use in file names. Renaming is a display-only change - see README >
/// For developers > Renaming the app. (Until 2026-09-29 the app was called "Komga Reader".)
const appName = 'BeDeReader';

/// Under the name wherever there's room (sign-in, About, store listings): what it is, and what it works with.
const appTagline = 'A library and reader for Komga';

// Internal identifiers - they stay the same whatever the app is called (changing them would cut people off from their
// data or updates):
// - Android application ID and Kotlin package: com.nickp.komga_reader
// - Dart package: komga_reader
// - Windows: the settings folder %APPDATA%\com.nickp\Komga Reader (from Runner.rc's CompanyName + ProductName) and the
//   data folder %LOCALAPPDATA%\KomgaReader (downloads, window position - desktop_channel.cpp) - the old name, kept
// - the Dart class names KomgaReaderApp / _KomgaReaderAppState (main.dart) - code only, never shown
// - Settings synced through Komga: the client-setting keys komgareader.readerprefs / .pins / .ondeckhidden
