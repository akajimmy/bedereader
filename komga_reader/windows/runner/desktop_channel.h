#ifndef RUNNER_DESKTOP_CHANNEL_H_
#define RUNNER_DESKTOP_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// The Windows side of the "komga_reader/screen" channel (lib/screen.dart); the Android side is MainActivity.kt.
// keepOn, appVersion, openUrl and fullscreen do real work here; brightness/getBrightness are no-ops because a
// monitor's backlight can't be set (the app dims with an overlay instead).
class DesktopChannel {
 public:
  DesktopChannel(flutter::BinaryMessenger* messenger, HWND window);

  // Called when the window closes: remembers its size/position (the pre-fullscreen one if in fullscreen).
  void SaveWindow();

 private:
  void SetFullscreen(bool on);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  bool fullscreen_ = false;
  LONG saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_{};
};

// Window size/position between runs: its normal-size rectangle in physical screen pixels (Win32Window::CreateAt).
struct SavedWindow {
  RECT screen;
  bool maximized;
};
bool LoadSavedWindow(SavedWindow* out);

#endif  // RUNNER_DESKTOP_CHANNEL_H_
