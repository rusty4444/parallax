#ifndef RUNNER_PARALLAX_PLATFORM_H_
#define RUNNER_PARALLAX_PLATFORM_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <memory>
#include <string>
#include <vector>

class Win32Window;

namespace flutter {
class FlutterEngine;
}

// Tray callback message (wparam = icon id, lparam = mouse message).
constexpr UINT kParallaxTrayMessage = WM_APP + 42;

// The Win32 half of Parallax's platform channels: the counterparts of
// MainActivity.kt, BackgroundConnection.kt, ShareShortcuts.kt and the
// secure-window flag. Incoming shares arrive as command-line files (Open
// with / second instance), drag-and-drop, or matrix: protocol links; the
// background connection is a tray keep-alive instead of a foreground
// service; Direct Share suggestions are the taskbar jump list.
class ParallaxPlatform {
 public:
  ParallaxPlatform(HWND window, Win32Window* owner, flutter::FlutterEngine* engine);
  ~ParallaxPlatform();

  // Queues intents from a full command line (first start or a second
  // instance forwarded over WM_COPYDATA) and signals Dart.
  void HandleCommandLine(const std::wstring& command_line);

  // Queues files dropped on the window (drag-and-drop sharing).
  void HandleDrop(HDROP drop);

  // Tray icon callbacks.
  void HandleTrayMessage(WPARAM wparam, LPARAM lparam);

  // Shell broadcasts registered at runtime: Explorer restarted (the tray
  // icon must be added again) or the taskbar button was (re)created (the
  // unread badge must be applied again). True when [message] was one.
  bool HandleShellMessage(UINT message);

  // Restores and focuses the main window.
  void ShowMainWindow();

 private:
  void RegisterChannels(flutter::FlutterEngine* engine);
  void SignalPending();
  void QueueShare(const std::vector<std::wstring>& paths);
  void SetKeepAlive(bool keep_alive);
  void AddTrayIcon();
  void RemoveTrayIcon();
  void UpdateTrayIcon();
  void FillTrayIcon(NOTIFYICONDATAW* nid);
  void ShowTrayMenu();
  // Unread count on the taskbar button (overlay icon) and tray icon.
  void SetBadgeCount(int count);
  void ApplyTaskbarBadge();
  HICON CreateBadgeIcon(int count);
  void QuitApp();
  int BuildJumpList(const flutter::EncodableList& shortcuts);
  void ClearJumpList();
  bool WriteShortcutIcon(const flutter::EncodableMap& shortcut,
                         const std::wstring& room_id,
                         std::wstring* icon_path);
  void PruneOldSharedCopies();

  HWND window_;
  Win32Window* owner_;
  std::wstring exe_path_;
  std::wstring shared_root_;
  std::wstring icons_dir_;
  bool keep_alive_ = false;
  bool tray_visible_ = false;
  int badge_count_ = 0;
  HICON tray_icon_ = nullptr;
  HICON overlay_icon_ = nullptr;
  ITaskbarList3* taskbar_ = nullptr;
  UINT taskbar_created_message_ = 0;
  UINT taskbar_button_created_message_ = 0;
  ULONG_PTR gdiplus_token_ = 0;
  std::vector<flutter::EncodableValue> pending_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> intents_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shortcuts_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> secure_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> permissions_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> connection_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_;
};

// Registers the per-user matrix: URL protocol so matrix: links open here.
void RegisterMatrixProtocol();

#endif  // RUNNER_PARALLAX_PLATFORM_H_