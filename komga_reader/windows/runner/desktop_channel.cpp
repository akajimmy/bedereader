#include "desktop_channel.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>

#include <fstream>
#include <string>

namespace {

// %LOCALAPPDATA%\KomgaReader (created if missing): window memory and downloaded books
std::wstring AppDir() {
  PWSTR base = nullptr;
  std::wstring path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base))) {
    // internal and fixed, whatever the app is called: renaming it would strand people's downloads
    path = std::wstring(base) + L"\\KomgaReader";
    CreateDirectoryW(path.c_str(), nullptr);
  }
  CoTaskMemFree(base);
  return path;
}

// %LOCALAPPDATA%\KomgaReader\window.txt
std::wstring WindowFile() {
  std::wstring dir = AppDir();
  return dir.empty() ? dir : dir + L"\\window.txt";
}

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

}  // namespace

DesktopChannel::DesktopChannel(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  saved_placement_.length = sizeof(WINDOWPLACEMENT);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "komga_reader/screen", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<flutter::EncodableValue>& call,
                                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& m = call.method_name();
    const auto* args = call.arguments();
    if (m == "keepOn") {
      // keep the display (and PC) awake while a book is open
      bool on = args && std::holds_alternative<bool>(*args) && std::get<bool>(*args);
      SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED) : ES_CONTINUOUS);
      result->Success();
    } else if (m == "brightness" || m == "getBrightness") {
      result->Success();  // no backlight control on a desktop monitor
    } else if (m == "appVersion") {
      flutter::EncodableMap v;
      v[flutter::EncodableValue("name")] = flutter::EncodableValue(
          std::to_string(FLUTTER_VERSION_MAJOR) + "." + std::to_string(FLUTTER_VERSION_MINOR) + "." +
          std::to_string(FLUTTER_VERSION_PATCH));
      v[flutter::EncodableValue("code")] = flutter::EncodableValue(static_cast<int64_t>(FLUTTER_VERSION_BUILD));
      result->Success(flutter::EncodableValue(v));
    } else if (m == "openUrl") {
      bool ok = false;
      if (args && std::holds_alternative<std::string>(*args)) {
        auto r = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", Widen(std::get<std::string>(*args)).c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        ok = r > 32;
      }
      result->Success(flutter::EncodableValue(ok));
    } else if (m == "fullscreen") {
      if (args && std::holds_alternative<bool>(*args)) SetFullscreen(std::get<bool>(*args));
      result->Success(flutter::EncodableValue(fullscreen_));
    } else if (m == "storageDir") {
      std::wstring dir = AppDir();
      if (dir.empty()) {
        result->Success();
      } else {
        result->Success(flutter::EncodableValue(Narrow(dir)));
      }
    } else if (m == "isFullscreen") {
      result->Success(flutter::EncodableValue(fullscreen_));
    } else if (m == "battery") {
      // for the reader's clock: level 0..100 and charging; nothing on a PC without a battery
      SYSTEM_POWER_STATUS s;
      if (GetSystemPowerStatus(&s) && s.BatteryLifePercent <= 100 && !(s.BatteryFlag & 128)) {
        flutter::EncodableMap v;
        v[flutter::EncodableValue("level")] = flutter::EncodableValue(static_cast<int32_t>(s.BatteryLifePercent));
        v[flutter::EncodableValue("charging")] = flutter::EncodableValue(s.ACLineStatus == 1);
        result->Success(flutter::EncodableValue(v));
      } else {
        result->Success();
      }
    } else {
      result->NotImplemented();
    }
  });
}

// Borderless window covering the whole monitor; leaving restores the previous style and placement.
void DesktopChannel::SetFullscreen(bool on) {
  if (on == fullscreen_) return;
  if (on) {
    saved_style_ = GetWindowLong(window_, GWL_STYLE);
    GetWindowPlacement(window_, &saved_placement_);
    MONITORINFO mi{sizeof(mi)};
    GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &mi);
    SetWindowLong(window_, GWL_STYLE, saved_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(window_, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLong(window_, GWL_STYLE, saved_style_);
    SetWindowPlacement(window_, &saved_placement_);
    SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
}

// Remembered in physical screen pixels, restored as they are (code review, 2026-09-30): saving divided by this
// monitor's scaling while opening picked the monitor from the divided point - with two monitors at different scaling
// the window came back on the other one, at the wrong size - and the normal-size rectangle Windows keeps is in
// "workspace" coordinates, so with the taskbar at the top or left the window crept by its height every time.
void DesktopChannel::SaveWindow() {
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  if (fullscreen_) {
    wp = saved_placement_;
  } else if (!GetWindowPlacement(window_, &wp)) {
    return;
  }
  const bool maximized = wp.showCmd == SW_SHOWMAXIMIZED;
  RECT r{};
  if (!fullscreen_ && !maximized && GetWindowRect(window_, &r)) {
    // as it is on screen (screen coordinates already)
  } else {
    // its normal size (maximized / full screen): workspace -> screen coordinates, by its monitor's work-area offset
    r = wp.rcNormalPosition;
    MONITORINFO mi{sizeof(mi)};
    if (GetMonitorInfo(MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST), &mi)) {
      OffsetRect(&r, mi.rcWork.left - mi.rcMonitor.left, mi.rcWork.top - mi.rcMonitor.top);
    }
  }
  std::wstring file = WindowFile();
  if (file.empty()) return;
  std::ofstream out(file, std::ios::trunc);
  out << "v2 " << r.left << ' ' << r.top << ' ' << r.right << ' ' << r.bottom << ' ' << (maximized ? 1 : 0) << '\n';
}

bool LoadSavedWindow(SavedWindow* out) {
  std::wstring file = WindowFile();
  if (file.empty()) return false;
  std::ifstream in(file);
  std::string first;
  if (!(in >> first)) return false;
  RECT r{};
  int max = 0;
  if (first == "v2") {
    if (!(in >> r.left >> r.top >> r.right >> r.bottom >> max)) return false;
  } else {
    // saved by an earlier build: logical x y w h, maximized, then the physical rectangle - that's the one used
    int y, w, h;
    if (!(in >> y >> w >> h >> max >> r.left >> r.top >> r.right >> r.bottom)) return false;
  }
  if (r.right - r.left < 400 || r.bottom - r.top < 300) return false;
  // only restore if that spot is still on a connected monitor (a screen may have been unplugged): else the default
  if (!MonitorFromRect(&r, MONITOR_DEFAULTTONULL)) return false;
  *out = SavedWindow{r, max == 1};
  return true;
}
