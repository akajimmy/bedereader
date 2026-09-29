/// The app's name as people see it - set here once for all the Dart code (title, side menu, About, licences page).
/// "Komga Reader" is a placeholder; renaming is a display-only change - see README > For developers > Renaming the app.
const appName = 'Komga Reader';

// Internal identifiers - they stay the same whatever the app is called (changing them would cut people off from their
// data or updates):
// - Android application ID and Kotlin package: com.nickp.komga_reader
// - Dart package: komga_reader
// - Windows: the settings folder %APPDATA%\com.nickp\Komga Reader (from Runner.rc's CompanyName + ProductName) and the
//   data folder %LOCALAPPDATA%\KomgaReader (downloads, window position - desktop_channel.cpp)
// - Settings synced through Komga: the client-setting keys komgareader.readerprefs / .pins / .ondeckhidden
