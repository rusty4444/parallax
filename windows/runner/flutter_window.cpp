#include "flutter_window.h"

#include <shellapi.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  platform_ = std::make_unique<ParallaxPlatform>(
      GetHandle(), this, flutter_controller_->engine());
  // Cold-start intents (Open with, matrix: links, jump-list chats) queue
  // before Dart listens; drag-and-drop sharing arrives as WM_DROPFILES.
  platform_->HandleCommandLine(GetCommandLineW());
  DragAcceptFiles(GetHandle(), TRUE);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Release the channels before the engine they speak through.
  platform_ = nullptr;
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

  // Explorer restarts and taskbar button creation arrive as registered
  // (runtime) messages, so they cannot be switch cases.
  if (platform_ && message >= 0xC000 && platform_->HandleShellMessage(message)) {
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_DROPFILES:
      if (platform_) {
        platform_->HandleDrop(reinterpret_cast<HDROP>(wparam));
      }
      return 0;
    case WM_COPYDATA: {
      // A second launch forwards its full command line here.
      auto* data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (platform_ && data && data->dwData == 1 && data->lpData) {
        std::wstring line(static_cast<wchar_t*>(data->lpData),
                          data->cbData / sizeof(wchar_t));
        platform_->HandleCommandLine(line);
        platform_->ShowMainWindow();
      }
      return TRUE;
    }
    case kParallaxTrayMessage:
      if (platform_) {
        platform_->HandleTrayMessage(wparam, lparam);
      }
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
