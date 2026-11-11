#include "open_with.h"

#include <shellapi.h>

#include <cwctype>
#include <functional>

namespace open_with {

namespace {

// what tells a file passed on from anything else sent to the window ("BDRO")
constexpr ULONG_PTR kTag = 0x4244524F;

bool first_ = false;  // this start is the first (it holds the name, and publishes its window)
HANDLE mutex_ = nullptr;
HANDLE window_map_ = nullptr;

// One name per exe (its path, any case): the Desktop's BeDeReader and BeDeReader-Exp are apps apart.
std::wstring Name() {
  wchar_t exe[MAX_PATH] = {};
  ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring path(exe);
  for (auto& c : path) c = static_cast<wchar_t>(std::towlower(c));
  return L"Local\\BeDeReader-open-with-" + std::to_wstring(std::hash<std::wstring>{}(path));
}

// The first start's window, as it published it; nullptr if there's none (yet).
HWND PublishedWindow(const std::wstring& name) {
  HANDLE map = ::OpenFileMappingW(FILE_MAP_READ, FALSE, (name + L"-window").c_str());
  if (!map) return nullptr;
  HWND window = nullptr;
  if (auto* view = static_cast<HWND*>(::MapViewOfFile(map, FILE_MAP_READ, 0, 0, sizeof(HWND)))) {
    window = *view;
    ::UnmapViewOfFile(view);
  }
  ::CloseHandle(map);
  return window && ::IsWindow(window) ? window : nullptr;
}

}  // namespace

std::wstring FileArgument() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  std::wstring file;
  for (int i = 1; argv && i < argc; i++) {
    if (argv[i][0] != L'-') {
      file = argv[i];
      break;
    }
  }
  if (argv) ::LocalFree(argv);
  return file;
}

bool HandOver(const std::wstring& file) {
  const std::wstring name = Name();
  mutex_ = ::CreateMutexW(nullptr, FALSE, name.c_str());
  first_ = mutex_ != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS;
  if (first_ || file.empty()) return false;
  // the first start's window - it may still be starting: waited for, up to 10 s
  HWND target = nullptr;
  for (int i = 0; i < 100 && !target; i++) {
    target = PublishedWindow(name);
    if (!target) ::Sleep(100);
  }
  if (!target) return false;  // (none: this start opens the file itself)
  DWORD pid = 0;
  ::GetWindowThreadProcessId(target, &pid);
  ::AllowSetForegroundWindow(pid);  // (this start was the user's: the window open may come to the front)
  COPYDATASTRUCT data{kTag, static_cast<DWORD>((file.size() + 1) * sizeof(wchar_t)),
                      const_cast<wchar_t*>(file.c_str())};
  DWORD_PTR taken = 0;
  return ::SendMessageTimeoutW(target, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 5000,
                               &taken) != 0 &&
         taken != 0;
}

void Publish(HWND window) {
  if (!first_ || window_map_) return;
  window_map_ = ::CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(HWND),
                                     (Name() + L"-window").c_str());
  if (!window_map_) return;
  if (auto* view = static_cast<HWND*>(::MapViewOfFile(window_map_, FILE_MAP_WRITE, 0, 0, sizeof(HWND)))) {
    *view = window;
    ::UnmapViewOfFile(view);
  }
}

std::optional<std::wstring> Received(LPARAM lparam) {
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (!data || data->dwData != kTag || !data->lpData || data->cbData < sizeof(wchar_t)) return std::nullopt;
  const auto* chars = static_cast<const wchar_t*>(data->lpData);
  size_t length = data->cbData / sizeof(wchar_t);
  while (length > 0 && chars[length - 1] == L'\0') length--;
  return std::wstring(chars, length);
}

}  // namespace open_with
