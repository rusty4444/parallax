; Parallax for Windows — Inno Setup installer script.
; Build (on Windows, after `flutter build windows --release`):
;   ISCC.exe windows\installer\parallax.iss
; Output: build\windows\installer\Parallax-<version>-windows-x64-setup.exe
;
; Per-user install (no admin needed). The Microsoft Store route uses the
; MSIX package instead (see docs/windows-port.md); this installer is for
; direct distribution.

#define MyAppName "Parallax"
#define MyAppVersion "1.8.0"
#define MyAppPublisher "Sam Russell"
#define MyAppURL "https://samrusselltech.net/apps/parallax/"
#define MyAppExeName "parallax.exe"

[Setup]
; Stable AppId: keep across versions so upgrades replace the same install.
AppId={{38AAD5BF-47F7-42D3-A140-F6510301698E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
OutputDir=..\..\build\windows\installer
OutputBaseFilename=Parallax-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
; Update-in-place: reuse the previous install directory and skip the dir
; prompt when an existing installation is detected (stable AppId above).
UsePreviousAppDir=yes
DisableDirPage=auto
; The [Code] PrepareToInstall closes the running app itself; don't let
; Restart Manager pop a separate close-apps dialog or relaunch afterwards.
CloseApplications=no
RestartApplications=no
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} for Windows
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoVersion=1.8.0.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole portable Release folder: engine, Dart AOT, plugin DLLs, the
; Rust encryption DLL, sqlite3, pdfium and the FFmpeg helpers.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; matrix: URL protocol, per-user. The app also self-registers at runtime
; when unpackaged; declaring it here makes links work before first launch.
Root: HKCU; Subkey: "Software\Classes\matrix"; ValueType: string; ValueName: ""; ValueData: "URL:Matrix Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\matrix"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\matrix\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; Uninstall keeps %APPDATA%\parallax (Matrix session, keys, caches) and the
; secure-storage entries: removing the app must not destroy encryption keys.

[Code]
const
  UninstallKey =
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\' +
    '{38AAD5BF-47F7-42D3-A140-F6510301698E}_is1';

function IsUpgrade(): Boolean;
var
  Uninstall: String;
begin
  Result :=
    RegQueryStringValue(HKCU, UninstallKey, 'UninstallString', Uninstall);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if IsUpgrade() and (CurPageID = wpReady) then
  begin
    WizardForm.PageNameLabel.Caption := 'Ready to Update';
    WizardForm.PageDescriptionLabel.Caption :=
      'Setup is now ready to begin updating Parallax on your computer.';
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  NeedsRestart := False;
  // Close the running app so its files can be replaced in place. User data
  // (Matrix session, keys, caches) lives in %APPDATA%\parallax and is not
  // touched. The tray keep-alive intercepts a graceful WM_CLOSE (it only
  // hides the window), so a forced close is required to release the files.
  if Exec('taskkill.exe', '/IM {#MyAppExeName} /T /F', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode) then
    Sleep(500);
end;