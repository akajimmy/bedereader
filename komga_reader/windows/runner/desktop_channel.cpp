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

void DesktopChannel::SaveWindow() {
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  if (fullscreen_) {
    wp = saved_placement_;
  } else if (!GetWindowPlacement(window_, &wp)) {
    return;
  }
  const double scale = GetDpiForWindow(window_) / 96.0;
  const RECT& r = wp.rcNormalPosition;
  std::wstring file = WindowFile();
  if (file.empty()) return;
  std::ofstream out(file, std::ios::trunc);
  // logical x y width height maximized, then the physical rect (used to check it is still on a screen)
  out << static_cast<int>(r.left / scale) << ' ' << static_cast<int>(r.top / scale) << ' '
      << static_cast<int>((r.right - r.left) / scale) << ' ' << static_cast<int>((r.bottom - r.top) / scale) << ' '
      << (wp.showCmd == SW_SHOWMAXIMIZED ? 1 : 0) << ' ' << r.left << ' ' << r.top << ' ' << r.right << ' '
      << r.bottom << '\n';
}

bool LoadSavedWindow(SavedWindow* out) {
  std::wstring file = WindowFile();
  if (file.empty()) return false;
  std::ifstream in(file);
  int x, y, w, h, max;
  RECT phys{};
  if (!(in >> x >> y >> w >> h >> max >> phys.left >> phys.top >> phys.right >> phys.bottom)) return false;
  if (w < 400 || h < 300) return false;
  // only restore if that spot is still on a connected monitor (a screen may have been unplugged)
  if (!MonitorFromRect(&phys, MONITOR_DEFAULTTONULL)) return false;
  *out = SavedWindow{x, y, w, h, max == 1};
  return true;
}
