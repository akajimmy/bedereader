#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "open_with.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_ = std::make_unique<DesktopChannel>(flutter_controller_->engine()->messenger(), GetHandle());
  open_with_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "komga_reader/open_with",
      &flutter::StandardMethodCodec::GetInstance());
  open_with::Publish(GetHandle());  // (later starts hand their files to this window)
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (start_maximized_) {
      ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    } else {
      this->Show();
    }
    if (desktop_) desktop_->WindowShown();  // a full screen asked for meanwhile, now the window is up
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  desktop_ = nullptr;
  open_with_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      if (desktop_) desktop_->SaveWindow();  // remember size/position for next time
      break;
    case WM_COPYDATA:
      // a file opened with the app, handed over by a later start: the window to the front, the file to the app
      if (auto file = open_with::Received(lparam); file && open_with_) {
        if (::IsIconic(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
        ::SetForegroundWindow(hwnd);
        open_with_->InvokeMethod("open", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                                              {flutter::EncodableValue("path"),
                                               flutter::EncodableValue(Utf8FromUtf16(file->c_str()))}}));
        return TRUE;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
