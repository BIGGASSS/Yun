; Compiled by package-windows.ps1 with Inno Setup 6.3+ (preinstalled on windows-2022).
; No SignTool or signing credentials: both Setup and its uninstaller are unsigned.
#ifndef AppVersion
  #error AppVersion must come from pubspec.yaml via package-windows.ps1
#endif
#ifndef FileVersion
  #error FileVersion must be a four-component Windows version
#endif
#ifndef BundleDir
  #error BundleDir must contain the complete staged Flutter bundle and release inventory
#endif
#ifndef InstallerOutputDir
  #error InstallerOutputDir is required
#endif

#define YunAppName "Yun"
; Stable across versions: changing this GUID breaks in-place upgrades/uninstall identity.
#define YunAppId "{{7E108AAF-AB6F-4DA1-99CC-72234C9AE25D}"

[Setup]
AppId={#YunAppId}
AppName={#YunAppName}
AppVersion={#AppVersion}
AppPublisher=Yun contributors
AppVerName={#YunAppName} {#AppVersion}
VersionInfoVersion={#FileVersion}
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription={#YunAppName} Setup (unsigned)
DefaultDirName={localappdata}\Programs\{#YunAppName}
DefaultGroupName={#YunAppName}
DisableProgramGroupPage=yes
; Never request elevation, even when launched by an administrator.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
OutputDir={#InstallerOutputDir}
OutputBaseFilename=yun-windows-x64-unsigned
Compression=lzma2
SolidCompression=yes
SignedUninstaller=no
UninstallDisplayIcon={app}\yun.exe
UninstallDisplayName={#YunAppName}
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Do not filter by extensions: media runtimes, plugins, assets, and notices travel together.
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#YunAppName}"; Filename: "{app}\yun.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\{#YunAppName}"; Filename: "{app}\yun.exe"; WorkingDir: "{app}"; Tasks: desktopicon

; No postinstall launch: silent installs and packaging tests must never execute the payload.
; Inno's uninstall log removes installed files/shortcuts, not unrelated user data/credentials.
