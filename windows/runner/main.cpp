#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include "flutter_window.h"
#include "parallax_platform.h"
#include "utils.h"
#include "win32_window.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // One Matrix client per user: a second launch hands its command line
  // (shared files, matrix: links, jump-list chats) to the running window.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Parallax.net.samrussell.single-instance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(Win32Window::kClassName, nullptr);
    if (existing) {
      std::wstring line = ::GetCommandLineW();
      COPYDATASTRUCT data{};
      data.dwData = 1;
      data.cbData = static_cast<DWORD>((line.size() + 1) * sizeof(wchar_t));
      data.lpData = const_cast<wchar_t*>(line.c_str());
      ::SendMessageW(existing, WM_COPYDATA, 0,
                     reinterpret_cast<LPARAM>(&data));
    }
    if (single_instance) ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Group the taskbar button (and its jump list) under one app identity,
  // matching the notification AppUserModelId.
  ::SetCurrentProcessExplicitAppUserModelID(L"net.samrussell.parallax");
  RegisterMatrixProtocol();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Parallax", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}