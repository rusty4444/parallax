#include "parallax_platform.h"

#include <flutter/flutter_engine.h>
#include <gdiplus.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <shobjidl.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <map>

#include "resource.h"
#include "win32_window.h"

namespace {

namespace fs = std::filesystem;
using EV = flutter::EncodableValue;
using EM = flutter::EncodableMap;
using EL = flutter::EncodableList;

constexpr const wchar_t kAppId[] = L"net.samrussell.parallax";
constexpr int64_t kMaxSharedFileBytes = 20 * 1024 * 1024;
constexpr size_t kMaxSharedFiles = 10;
constexpr size_t kMaxJumpListItems = 7;
constexpr UINT kTrayIconId = 1;

// Same caps as lib/features/platform/platform_intents.dart.
std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(),
                                nullptr, 0, nullptr, nullptr);
  std::string out(len, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), out.data(),
                      len, nullptr, nullptr);
  return out;
}

std::wstring Utf16(const std::string& utf8) {
  if (utf8.empty()) return L"";
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(),
                                nullptr, 0);
  std::wstring out(len, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), out.data(),
                      len);
  return out;
}

std::string MapString(const EM& map, const char* key) {
  auto it = map.find(EV(key));
  if (it == map.end()) return "";
  if (const auto* value = std::get_if<std::string>(&it->second)) return *value;
  return "";
}

bool MapBool(const EM& map, const char* key) {
  auto it = map.find(EV(key));
  if (it == map.end()) return false;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return false;
}

int64_t MapInt(const EM& map, const char* key, int64_t fallback) {
  auto it = map.find(EV(key));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) return *value;
  return fallback;
}

// A room ID as Dart validates it: '!' prefix, bounded, no control characters.
bool ValidRoomId(const std::wstring& room) {
  if (room.size() < 2 || room.size() > 255 || room[0] != L'!') return false;
  for (wchar_t c : room) {
    if (c <= 0x20 || c == 0x7f) return false;
  }
  return true;
}

bool IsMatrixLink(const std::wstring& value) {
  if (value.empty() || value.size() > 2048) return false;
  return _wcsnicmp(value.c_str(), L"matrix:", 7) == 0 ||
         _wcsnicmp(value.c_str(), L"https://matrix.to/", 18) == 0;
}

// Display name without path separators or control characters (Dart's
// sanitiseSharedName keeps the last 128 characters).
std::wstring SanitiseName(const std::wstring& path) {
  auto slash = path.find_last_of(L"\\/");
  std::wstring name =
      slash == std::wstring::npos ? path : path.substr(slash + 1);
  std::wstring clean;
  for (wchar_t c : name) {
    if (c > 0x1f && c != 0x7f) clean.push_back(c);
  }
  // Trim.
  size_t start = clean.find_first_not_of(L" \t");
  size_t end = clean.find_last_not_of(L" \t");
  if (start == std::wstring::npos) return L"shared-file";
  clean = clean.substr(start, end - start + 1);
  if (clean.empty() || clean == L"." || clean == L"..") return L"shared-file";
  return clean.size() > 128 ? clean.substr(clean.size() - 128) : clean;
}

std::string MimeForName(const std::wstring& name) {
  static const std::map<std::wstring, std::string> kMimes = {
      {L".jpg", "image/jpeg"},      {L".jpeg", "image/jpeg"},
      {L".png", "image/png"},       {L".gif", "image/gif"},
      {L".webp", "image/webp"},     {L".bmp", "image/bmp"},
      {L".heic", "image/heic"},     {L".mp4", "video/mp4"},
      {L".m4v", "video/mp4"},       {L".mov", "video/quicktime"},
      {L".webm", "video/webm"},     {L".mkv", "video/x-matroska"},
      {L".avi", "video/x-msvideo"}, {L".mp3", "audio/mpeg"},
      {L".m4a", "audio/mp4"},       {L".aac", "audio/aac"},
      {L".ogg", "audio/ogg"},       {L".opus", "audio/ogg"},
      {L".wav", "audio/wav"},       {L".flac", "audio/flac"},
      {L".pdf", "application/pdf"}, {L".txt", "text/plain"},
      {L".md", "text/markdown"},    {L".csv", "text/csv"},
      {L".zip", "application/zip"},
      {L".docx",
       "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
      {L".xlsx",
       "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
      {L".pptx",
       "application/vnd.openxmlformats-officedocument.presentationml.presentation"},
  };
  auto dot = name.find_last_of(L'.');
  if (dot == std::wstring::npos) return "application/octet-stream";
  std::wstring ext = name.substr(dot);
  std::transform(ext.begin(), ext.end(), ext.begin(), towlower);
  auto it = kMimes.find(ext);
  return it == kMimes.end() ? "application/octet-stream" : it->second;
}

uint64_t Fnv1a(const void* data, size_t size, uint64_t hash) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  for (size_t i = 0; i < size; i++) {
    hash ^= bytes[i];
    hash *= 0x100000001b3ULL;
  }
  return hash;
}

bool FindPngEncoder(CLSID* clsid) {
  UINT size = 0, count = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) return false;
  std::vector<uint8_t> buffer(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  Gdiplus::GetImageEncoders(count, size, codecs);
  for (UINT i = 0; i < count; i++) {
    if (wcscmp(codecs[i].MimeType, L"image/png") == 0) {
      *clsid = codecs[i].Clsid;
      return true;
    }
  }
  return false;
}

// PKEY_Title, defined here to avoid SDK library ambiguity.
const PROPERTYKEY kPKeyTitle = {
    {0x9F4C2855, 0x9F79, 0x4B39,
     {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}},
    5};

// Reads the clipboard as PNG bytes: the raw "PNG" format when present
// (browsers, Snipping Tool), otherwise CF_DIB / CF_DIBV5 converted through
// GDI+. Empty when the clipboard holds no image.
std::vector<uint8_t> ReadClipboardImage(HWND hwnd) {
  std::vector<uint8_t> result;
  if (!OpenClipboard(hwnd)) return result;
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  HANDLE data = GetClipboardData(png_format);
  if (data) {
    const SIZE_T size = GlobalSize(data);
    void* ptr = GlobalLock(data);
    if (ptr && size > 0) {
      const auto* bytes = static_cast<const uint8_t*>(ptr);
      result.assign(bytes, bytes + size);
    }
    if (ptr) GlobalUnlock(data);
  }
  if (result.empty()) {
    HANDLE dib = GetClipboardData(CF_DIB);
    if (!dib) dib = GetClipboardData(CF_DIBV5);
    if (dib) {
      void* ptr = GlobalLock(dib);
      if (ptr) {
        auto* header = reinterpret_cast<BITMAPINFOHEADER*>(ptr);
        const int colors =
            header->biClrUsed
                ? static_cast<int>(header->biClrUsed)
                : (header->biBitCount <= 8 ? (1 << header->biBitCount) : 0);
        const auto* pixels = reinterpret_cast<const uint8_t*>(ptr) +
                             header->biSize + colors * sizeof(RGBQUAD);
        HDC dc = GetDC(nullptr);
        HBITMAP bitmap = CreateDIBitmap(
            dc, header, CBM_INIT, pixels,
            reinterpret_cast<BITMAPINFO*>(ptr), DIB_RGB_COLORS);
        ReleaseDC(nullptr, dc);
        if (bitmap) {
          Gdiplus::Bitmap image(bitmap, nullptr);
          DeleteObject(bitmap);
          CLSID png_clsid;
          IStream* stream = SHCreateMemStream(nullptr, 0);
          if (stream && FindPngEncoder(&png_clsid) &&
              image.Save(stream, &png_clsid, nullptr) == Gdiplus::Ok) {
            STATSTG stat{};
            stream->Stat(&stat, STATFLAG_NONAME);
            result.resize(stat.cbSize.LowPart);
            LARGE_INTEGER zero{};
            stream->Seek(zero, STREAM_SEEK_SET, nullptr);
            ULONG read = 0;
            stream->Read(result.data(), static_cast<ULONG>(result.size()),
                         &read);
            if (read != result.size()) result.clear();
          }
          if (stream) stream->Release();
        }
      }
      GlobalUnlock(dib);
    }
  }
  CloseClipboard();
  return result;
}

}  // namespace

ParallaxPlatform::ParallaxPlatform(HWND window, Win32Window* owner,
                                   flutter::FlutterEngine* engine)
    : window_(window), owner_(owner) {
  wchar_t buffer[MAX_PATH];
  GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  exe_path_ = buffer;
  GetTempPathW(MAX_PATH, buffer);
  shared_root_ = std::wstring(buffer) + L"parallax\\shared_intents";
  DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  icons_dir_ = (len > 0 && len < MAX_PATH)
                   ? std::wstring(buffer, len) + L"\\Parallax\\jump_icons"
                   : shared_root_ + L"\\icons";
  Gdiplus::GdiplusStartupInput gdiplus_input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &gdiplus_input, nullptr);
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  taskbar_button_created_message_ =
      RegisterWindowMessageW(L"TaskbarButtonCreated");
  PruneOldSharedCopies();
  RegisterChannels(engine);
  // The tray icon is there whenever Parallax runs: it is how the window is
  // found again after closing it to the tray, and it shows unread messages.
  AddTrayIcon();
}

ParallaxPlatform::~ParallaxPlatform() {
  RemoveTrayIcon();
  if (taskbar_) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  if (overlay_icon_) DestroyIcon(overlay_icon_);
  if (tray_icon_) DestroyIcon(tray_icon_);
  intents_ = nullptr;
  shortcuts_ = nullptr;
  secure_ = nullptr;
  permissions_ = nullptr;
  connection_ = nullptr;
  clipboard_ = nullptr;
  desktop_ = nullptr;
  if (gdiplus_token_) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

void ParallaxPlatform::RegisterChannels(flutter::FlutterEngine* engine) {
  auto messenger = engine->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();

  intents_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/platform_intents", codec);
  intents_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        if (call.method_name() == "takePending") {
          EL list(pending_.begin(), pending_.end());
          pending_.clear();
          result->Success(EV(list));
        } else if (call.method_name() == "discard") {
          const auto* map = std::get_if<EM>(call.arguments());
          if (map) {
            auto it = map->find(EV("paths"));
            const auto* paths =
                it == map->end() ? nullptr : std::get_if<EL>(&it->second);
            if (paths) {
              for (const auto& entry : *paths) {
                const auto* text = std::get_if<std::string>(&entry);
                if (!text) continue;
                std::wstring path = Utf16(*text);
                // Only ever delete copies inside the share cache.
                if (path.find(L"\\shared_intents\\") == std::wstring::npos &&
                    path.find(L"/shared_intents/") == std::wstring::npos) {
                  continue;
                }
                DeleteFileW(path.c_str());
                std::error_code ec;
                auto parent = fs::path(path).parent_path();
                if (fs::is_empty(parent, ec)) fs::remove(parent, ec);
              }
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  shortcuts_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/share_shortcuts", codec);
  shortcuts_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        if (call.method_name() == "publish") {
          const auto* map = std::get_if<EM>(call.arguments());
          const EL* list = nullptr;
          if (map) {
            auto it = map->find(EV("shortcuts"));
            if (it != map->end()) list = std::get_if<EL>(&it->second);
          }
          int added = list ? BuildJumpList(*list) : -1;
          result->Success(EV(added));
        } else if (call.method_name() == "clear") {
          ClearJumpList();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  secure_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/secure_window", codec);
  secure_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        if (call.method_name() != "setSecure") {
          result->NotImplemented();
          return;
        }
        const auto* map = std::get_if<EM>(call.arguments());
        bool enabled = map && MapBool(*map, "enabled");
        // The desktop counterpart of FLAG_SECURE: exclude the window from
        // screen capture while a recovery secret is on screen.
        if (SetWindowDisplayAffinity(
                window_, enabled ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE)) {
          result->Success();
        } else {
          result->Error("UNAVAILABLE", "Display affinity is not supported");
        }
      });

  permissions_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/permissions", codec);
  permissions_->SetMethodCallHandler(
      [](const flutter::MethodCall<EV>& call,
         std::unique_ptr<flutter::MethodResult<EV>> result) {
        if (call.method_name() != "check" && call.method_name() != "request") {
          result->NotImplemented();
          return;
        }
        // Unpackaged desktop apps are not subject to the per-app camera and
        // microphone privacy gates; the devices are available when present.
        EM grants;
        const auto* map = std::get_if<EM>(call.arguments());
        if (map) {
          auto it = map->find(EV("permissions"));
          const auto* list =
              it == map->end() ? nullptr : std::get_if<EL>(&it->second);
          if (list) {
            for (const auto& entry : *list) {
              if (const auto* name = std::get_if<std::string>(&entry)) {
                grants[EV(*name)] = EV(true);
              }
            }
          }
        }
        result->Success(EV(grants));
      });

  connection_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/background_connection", codec);
  connection_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        const auto& method = call.method_name();
        if (method == "start") {
          SetKeepAlive(true);
          result->Success(EV(true));
        } else if (method == "stop") {
          SetKeepAlive(false);
          result->Success();
        } else if (method == "isIgnoringBatteryOptimizations" ||
                   method == "requestIgnoreBatteryOptimizations") {
          // A desktop has no battery optimisation to exempt from.
          result->Success(EV(true));
        } else {
          result->NotImplemented();
        }
      });

  desktop_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/desktop", codec);
  desktop_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        const auto& method = call.method_name();
        if (method == "setBadgeCount") {
          int count = 0;
          if (const auto* map = std::get_if<EM>(call.arguments())) {
            count = static_cast<int>(MapInt(*map, "count", 0));
          }
          SetBadgeCount(count);
          result->Success();
        } else if (method == "showWindow") {
          ShowMainWindow();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  clipboard_ = std::make_unique<flutter::MethodChannel<EV>>(
      messenger, "parallax/clipboard", codec);
  clipboard_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EV>& call,
             std::unique_ptr<flutter::MethodResult<EV>> result) {
        if (call.method_name() != "readImage") {
          result->NotImplemented();
          return;
        }
        auto bytes = ReadClipboardImage(window_);
        if (bytes.empty()) {
          result->Success();
        } else {
          result->Success(EV(bytes));
        }
      });
}

void ParallaxPlatform::SignalPending() {
  if (intents_) intents_->InvokeMethod("pending", nullptr);
}

void ParallaxPlatform::HandleCommandLine(const std::wstring& command_line) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(command_line.c_str(), &argc);
  if (!argv) return;
  std::vector<std::wstring> files;
  bool queued = false;
  for (int i = 1; i < argc; i++) {
    std::wstring arg = argv[i];
    if (arg.rfind(L"--room=", 0) == 0) {
      std::wstring room = arg.substr(7);
      if (ValidRoomId(room)) {
        pending_.push_back(EV(EM{
            {EV("kind"), EV("room")}, {EV("roomId"), EV(Utf8(room))}}));
        queued = true;
      }
    } else if (IsMatrixLink(arg)) {
      pending_.push_back(EV(EM{
          {EV("kind"), EV("link")}, {EV("uri"), EV(Utf8(arg))}}));
      queued = true;
    } else {
      WIN32_FILE_ATTRIBUTE_DATA attrs{};
      if (GetFileAttributesExW(arg.c_str(), GetFileExInfoStandard, &attrs) &&
          !(attrs.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        files.push_back(arg);
      }
    }
  }
  LocalFree(argv);
  if (!files.empty()) {
    QueueShare(files);
    queued = true;
  }
  if (queued) SignalPending();
}

void ParallaxPlatform::HandleDrop(HDROP drop) {
  UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  std::vector<std::wstring> paths;
  for (UINT i = 0; i < count; i++) {
    UINT len = DragQueryFileW(drop, i, nullptr, 0);
    std::wstring path(len, L'\0');
    DragQueryFileW(drop, i, path.data(), len + 1);
    paths.push_back(path);
  }
  DragFinish(drop);
  if (paths.empty()) return;
  QueueShare(paths);
  SignalPending();
  ShowMainWindow();
}

void ParallaxPlatform::QueueShare(const std::vector<std::wstring>& paths) {
  std::error_code ec;
  fs::create_directories(shared_root_, ec);
  std::wstring dir =
      shared_root_ + L"\\" + std::to_wstring(GetTickCount64());
  fs::create_directories(dir, ec);
  EL files;
  int skipped = 0, too_large = 0;
  int index = 0;
  for (const auto& path : paths) {
    if (files.size() >= kMaxSharedFiles) {
      skipped++;
      continue;
    }
    WIN32_FILE_ATTRIBUTE_DATA attrs{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attrs) ||
        (attrs.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
      skipped++;
      continue;
    }
    LARGE_INTEGER size;
    size.HighPart = attrs.nFileSizeHigh;
    size.LowPart = attrs.nFileSizeLow;
    if (size.QuadPart <= 0 || size.QuadPart > kMaxSharedFileBytes) {
      too_large++;
      continue;
    }
    std::wstring name = SanitiseName(path);
    std::wstring dest =
        dir + L"\\" + std::to_wstring(index++) + L"_" + name;
    if (!CopyFileW(path.c_str(), dest.c_str(), FALSE)) {
      skipped++;
      continue;
    }
    files.push_back(EV(EM{
        {EV("path"), EV(Utf8(dest))},
        {EV("name"), EV(Utf8(name))},
        {EV("mimeType"), EV(MimeForName(name))},
        {EV("size"), EV(static_cast<int64_t>(size.QuadPart))},
    }));
  }
  if (files.empty() && skipped == 0 && too_large == 0) return;
  pending_.push_back(EV(EM{
      {EV("kind"), EV("share")},
      {EV("files"), EV(files)},
      {EV("skipped"), EV(skipped)},
      {EV("tooLarge"), EV(too_large)},
  }));
}

void ParallaxPlatform::PruneOldSharedCopies() {
  std::error_code ec;
  if (!fs::exists(shared_root_, ec)) return;
  auto cutoff = fs::file_time_type::clock::now() - std::chrono::hours(24);
  for (auto& entry : fs::directory_iterator(shared_root_, ec)) {
    std::error_code ignore;
    if (entry.last_write_time(ignore) < cutoff) {
      fs::remove_all(entry.path(), ignore);
    }
  }
}

void ParallaxPlatform::SetKeepAlive(bool keep_alive) {
  keep_alive_ = keep_alive;
  // While the connection runs, closing the window hides it to the tray and
  // the Matrix sync keeps going — the desktop counterpart of Android's
  // foreground service. Stopping it makes the next close quit. The tray
  // icon itself stays while Parallax runs.
  owner_->SetQuitOnClose(!keep_alive);
  if (!tray_visible_) AddTrayIcon();
}

void ParallaxPlatform::FillTrayIcon(NOTIFYICONDATAW* nid) {
  if (tray_icon_) DestroyIcon(tray_icon_);
  const int size = GetSystemMetrics(SM_CXSMICON);
  tray_icon_ = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr),
      MAKEINTRESOURCEW(badge_count_ > 0 ? IDI_APP_ICON_UNREAD : IDI_APP_ICON),
      IMAGE_ICON, size, size, LR_DEFAULTCOLOR));
  nid->hIcon = tray_icon_ ? tray_icon_
                          : LoadIconW(GetModuleHandleW(nullptr),
                                      MAKEINTRESOURCEW(IDI_APP_ICON));
  if (badge_count_ <= 0) {
    wcscpy_s(nid->szTip, L"Parallax");
  } else if (badge_count_ == 1) {
    wcscpy_s(nid->szTip, L"Parallax \u2013 1 unread message");
  } else {
    swprintf_s(nid->szTip, L"Parallax \u2013 %d unread messages",
               badge_count_);
  }
}

void ParallaxPlatform::AddTrayIcon() {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kParallaxTrayMessage;
  FillTrayIcon(&nid);
  if (Shell_NotifyIconW(NIM_ADD, &nid)) tray_visible_ = true;
}

void ParallaxPlatform::UpdateTrayIcon() {
  if (!tray_visible_) {
    AddTrayIcon();
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_ICON | NIF_TIP;
  FillTrayIcon(&nid);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

bool ParallaxPlatform::HandleShellMessage(UINT message) {
  if (message == 0) return false;
  if (message == taskbar_created_message_) {
    // Explorer restarted and forgot every tray icon.
    tray_visible_ = false;
    AddTrayIcon();
    return true;
  }
  if (message == taskbar_button_created_message_) {
    ApplyTaskbarBadge();
    return true;
  }
  return false;
}

void ParallaxPlatform::SetBadgeCount(int count) {
  if (count < 0) count = 0;
  if (count == badge_count_) return;
  badge_count_ = count;
  UpdateTrayIcon();
  ApplyTaskbarBadge();
}

void ParallaxPlatform::ApplyTaskbarBadge() {
  if (!window_) return;
  if (!taskbar_) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      taskbar_ = nullptr;
      return;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_->Release();
      taskbar_ = nullptr;
      return;
    }
  }
  if (overlay_icon_) {
    DestroyIcon(overlay_icon_);
    overlay_icon_ = nullptr;
  }
  if (badge_count_ <= 0) {
    taskbar_->SetOverlayIcon(window_, nullptr, nullptr);
    return;
  }
  overlay_icon_ = CreateBadgeIcon(badge_count_);
  wchar_t description[64];
  if (badge_count_ == 1) {
    wcscpy_s(description, L"1 unread message");
  } else {
    swprintf_s(description, L"%d unread messages", badge_count_);
  }
  taskbar_->SetOverlayIcon(window_, overlay_icon_, description);
}

// A red disc with the unread count in white ("9+" above nine): the
// taskbar shows it over the bottom-right of the app's button.
HICON ParallaxPlatform::CreateBadgeIcon(int count) {
  UINT dpi = GetDpiForWindow(window_);
  if (dpi == 0) dpi = 96;
  const int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
  Gdiplus::Bitmap bitmap(size, size, PixelFormat32bppARGB);
  {
    Gdiplus::Graphics graphics(&bitmap);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
    Gdiplus::SolidBrush red(Gdiplus::Color(255, 232, 17, 35));
    graphics.FillEllipse(&red, 0.0f, 0.0f, static_cast<Gdiplus::REAL>(size),
                         static_cast<Gdiplus::REAL>(size));
    const std::wstring label = count > 9 ? L"9+" : std::to_wstring(count);
    const Gdiplus::REAL font_size =
        static_cast<Gdiplus::REAL>(size) * (label.size() > 1 ? 0.56f : 0.7f);
    Gdiplus::Font font(L"Segoe UI", font_size, Gdiplus::FontStyleBold,
                       Gdiplus::UnitPixel);
    Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
    Gdiplus::StringFormat format;
    format.SetAlignment(Gdiplus::StringAlignmentCenter);
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::RectF box(0.0f, 0.0f, static_cast<Gdiplus::REAL>(size),
                       static_cast<Gdiplus::REAL>(size));
    graphics.DrawString(label.c_str(), -1, &font, box, &format, &white);
  }
  HICON icon = nullptr;
  bitmap.GetHICON(&icon);
  return icon;
}

void ParallaxPlatform::RemoveTrayIcon() {
  if (!tray_visible_) return;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_visible_ = false;
}

void ParallaxPlatform::ShowMainWindow() {
  if (!window_) return;
  ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void ParallaxPlatform::HandleTrayMessage(WPARAM wparam, LPARAM lparam) {
  if (wparam != kTrayIconId) return;
  switch (LOWORD(lparam)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      ShowMainWindow();
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowTrayMenu();
      break;
  }
}

void ParallaxPlatform::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, 1, L"Open Parallax");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 2, L"Quit");
  POINT point;
  GetCursorPos(&point);
  SetForegroundWindow(window_);
  int command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, point.x,
                               point.y, 0, window_, nullptr);
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == 1) {
    ShowMainWindow();
  } else if (command == 2) {
    QuitApp();
  }
}

void ParallaxPlatform::QuitApp() {
  RemoveTrayIcon();
  owner_->SetQuitOnClose(true);
  if (window_) DestroyWindow(window_);
}

int ParallaxPlatform::BuildJumpList(const EL& shortcuts) {
  ICustomDestinationList* list = nullptr;
  if (FAILED(CoCreateInstance(CLSID_DestinationList, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list)))) {
    return -1;
  }
  list->SetAppID(kAppId);
  UINT max_slots = 0;
  IObjectArray* removed = nullptr;
  if (FAILED(list->BeginList(&max_slots, IID_PPV_ARGS(&removed)))) {
    list->Release();
    return -1;
  }
  if (removed) removed->Release();
  IObjectCollection* collection = nullptr;
  CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr,
                   CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&collection));
  if (!collection) {
    list->AbortList();
    list->Release();
    return -1;
  }
  std::error_code ec;
  fs::create_directories(icons_dir_, ec);
  for (auto& entry : fs::directory_iterator(icons_dir_, ec)) {
    fs::remove(entry.path(), ec);
  }
  size_t added = 0;
  size_t cap = std::min({static_cast<size_t>(max_slots), kMaxJumpListItems,
                         shortcuts.size()});
  for (const auto& item : shortcuts) {
    if (added >= cap) break;
    const auto* map = std::get_if<EM>(&item);
    if (!map) continue;
    std::string room = MapString(*map, "roomId");
    std::string label = MapString(*map, "label");
    if (room.empty() || label.empty() || room[0] != '!') continue;
    std::wstring icon_path;
    if (!WriteShortcutIcon(*map, Utf16(room), &icon_path)) continue;
    IShellLinkW* link = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)))) {
      continue;
    }
    link->SetPath(exe_path_.c_str());
    std::wstring arguments = L"--room=\"" + Utf16(room) + L"\"";
    link->SetArguments(arguments.c_str());
    link->SetDescription(Utf16(label).c_str());
    link->SetIconLocation(icon_path.c_str(), 0);
    IPropertyStore* store = nullptr;
    if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&store)))) {
      PROPVARIANT variant;
      if (SUCCEEDED(InitPropVariantFromString(Utf16(label).c_str(), &variant))) {
        store->SetValue(kPKeyTitle, variant);
        PropVariantClear(&variant);
      }
      store->Commit();
      store->Release();
    }
    collection->AddObject(link);
    link->Release();
    added++;
  }
  IObjectArray* array = nullptr;
  collection->QueryInterface(IID_PPV_ARGS(&array));
  if (array) {
    list->AppendCategory(L"Recent chats", array);
    array->Release();
  }
  collection->Release();
  list->CommitList();
  list->Release();
  return static_cast<int>(added);
}

void ParallaxPlatform::ClearJumpList() {
  ICustomDestinationList* list = nullptr;
  if (FAILED(CoCreateInstance(CLSID_DestinationList, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&list)))) {
    return;
  }
  list->SetAppID(kAppId);
  UINT max_slots = 0;
  IObjectArray* removed = nullptr;
  if (SUCCEEDED(list->BeginList(&max_slots, IID_PPV_ARGS(&removed)))) {
    list->CommitList();
  }
  if (removed) removed->Release();
  list->Release();
}

bool ParallaxPlatform::WriteShortcutIcon(const EM& shortcut,
                                         const std::wstring& room_id,
                                         std::wstring* icon_path) {
  // The chat's picture when there is one, otherwise its initial drawn on
  // the room colour — the same fallback Android's share shortcuts use.
  Gdiplus::Bitmap* source = nullptr;
  IStream* source_stream = nullptr;
  auto it = shortcut.find(EV("icon"));
  const auto* icon =
      it == shortcut.end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
  if (icon && !icon->empty()) {
    source_stream = SHCreateMemStream(icon->data(), static_cast<UINT>(icon->size()));
    if (source_stream) {
      source = Gdiplus::Bitmap::FromStream(source_stream);
      if (source && source->GetLastStatus() != Gdiplus::Ok) {
        delete source;
        source = nullptr;
      }
    }
  }
  if (!source) {
    source = new Gdiplus::Bitmap(256, 256, PixelFormat32bppARGB);
    Gdiplus::Graphics graphics(source);
    Gdiplus::SolidBrush background(
        Gdiplus::Color(static_cast<Gdiplus::ARGB>(MapInt(shortcut, "background", 0xFF202020))));
    graphics.FillRectangle(&background, 0, 0, 256, 256);
    std::string initial = MapString(shortcut, "initial");
    std::wstring text = Utf16(initial.empty() ? "?" : initial);
    Gdiplus::Font font(L"Segoe UI", 120, Gdiplus::FontStyleRegular,
                       Gdiplus::UnitPixel);
    Gdiplus::SolidBrush foreground(
        Gdiplus::Color(static_cast<Gdiplus::ARGB>(MapInt(shortcut, "foreground", 0xFFFFFFFF))));
    Gdiplus::StringFormat format;
    format.SetAlignment(Gdiplus::StringAlignmentCenter);
    format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    graphics.DrawString(text.c_str(), -1, &font, Gdiplus::RectF(0, 0, 256, 256),
                        &format, &foreground);
  }
  Gdiplus::Bitmap scaled(256, 256, PixelFormat32bppARGB);
  {
    Gdiplus::Graphics graphics(&scaled);
    graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    graphics.DrawImage(source, 0, 0, 256, 256);
  }
  delete source;
  if (source_stream) source_stream->Release();

  CLSID png_clsid;
  if (!FindPngEncoder(&png_clsid)) return false;
  IStream* out = SHCreateMemStream(nullptr, 0);
  if (!out) return false;
  if (scaled.Save(out, &png_clsid, nullptr) != Gdiplus::Ok) {
    out->Release();
    return false;
  }
  STATSTG stat{};
  out->Stat(&stat, STATFLAG_NONAME);
  std::vector<uint8_t> png(stat.cbSize.LowPart);
  LARGE_INTEGER zero{};
  out->Seek(zero, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  out->Read(png.data(), static_cast<ULONG>(png.size()), &read);
  out->Release();
  if (read != png.size() || png.empty()) return false;

  // ICO container with one PNG-compressed entry (Windows Vista and later).
  std::vector<uint8_t> ico;
  ico.reserve(22 + png.size());
  const uint16_t header[3] = {0, 1, 1};
  const auto* header_bytes = reinterpret_cast<const uint8_t*>(header);
  ico.insert(ico.end(), header_bytes, header_bytes + 6);
  uint8_t entry[16] = {0, 0, 0, 0};  // 0x0 means 256 px
  const uint16_t planes = 1, bpp = 32;
  const uint32_t png_size = static_cast<uint32_t>(png.size()), offset = 22;
  memcpy(entry + 4, &planes, 2);
  memcpy(entry + 6, &bpp, 2);
  memcpy(entry + 8, &png_size, 4);
  memcpy(entry + 12, &offset, 4);
  ico.insert(ico.end(), entry, entry + 16);
  ico.insert(ico.end(), png.begin(), png.end());

  uint64_t hash = Fnv1a(room_id.data(), room_id.size() * sizeof(wchar_t),
                        0xcbf29ce484222325ULL);
  hash = Fnv1a(png.data(), png.size(), hash);
  wchar_t name[32];
  swprintf_s(name, L"%016llx.ico", static_cast<unsigned long long>(hash));
  *icon_path = icons_dir_ + L"\\" + name;
  std::ofstream file(*icon_path, std::ios::binary | std::ios::trunc);
  if (!file.good()) return false;
  file.write(reinterpret_cast<const char*>(ico.data()), ico.size());
  return file.good();
}

void RegisterMatrixProtocol() {
  wchar_t exe[MAX_PATH];
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  HKEY root;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\matrix", 0,
                      nullptr, 0, KEY_SET_VALUE, nullptr, &root,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  const wchar_t* description = L"URL:Matrix Protocol";
  RegSetValueExW(root, nullptr, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(description),
                 static_cast<DWORD>((wcslen(description) + 1) * sizeof(wchar_t)));
  const wchar_t* empty = L"";
  RegSetValueExW(root, L"URL Protocol", 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(empty), sizeof(wchar_t));
  HKEY command;
  if (RegCreateKeyExW(root, L"shell\\open\\command", 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &command,
                      nullptr) == ERROR_SUCCESS) {
    std::wstring value = std::wstring(L"\"") + exe + L"\" \"%1\"";
    RegSetValueExW(command, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(command);
  }
  RegCloseKey(root);
}