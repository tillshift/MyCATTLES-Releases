; MyCATTLES per-user installer with Chrome Web Store Native Messaging Host.
#ifndef MyAppVersion
  #error MyAppVersion must be passed
#endif
#ifndef ReleaseDir
  #error ReleaseDir must be passed
#endif
#ifndef ChromeExtensionId
  #define ChromeExtensionId ""
#endif
#ifndef GitHubExtensionId
  #define GitHubExtensionId ""
#endif
#if (Len(ChromeExtensionId) > 0) && (Len(ChromeExtensionId) != 32)
  #error ChromeExtensionId must be 32 characters
#endif
#if (Len(GitHubExtensionId) > 0) && (Len(GitHubExtensionId) != 32)
  #error GitHubExtensionId must be 32 characters
#endif
#define MyAppName "MyCATTLES"
#define MyAppExeName "mycattles.exe"
#ifndef HostExe
  #error HostExe must be passed with /DHostExe=...
#endif
#if !FileExists(HostExe)
  #error Build host/mycattles_host.exe before packaging
#endif
[Setup]
AppId={{048563B8-ED4A-5F1A-9D0F-AA14ACD34457}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=TILLSHIFT
SetupIconFile=..\windows\runner\resources\app_icon.ico
DefaultDirName={localappdata}\Programs\MyCATTLES
DefaultGroupName=MyCATTLES
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=..\dist
OutputBaseFilename=MyCATTLES-Setup-{#MyAppVersion}-win-x64-unsigned
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#HostExe}"; DestDir: "{app}\host"; Flags: ignoreversion
Source: "..\host\install_host.ps1"; DestDir: "{app}\host"; Flags: ignoreversion
Source: "..\host\uninstall_host.ps1"; DestDir: "{app}\host"; Flags: ignoreversion
Source: "..\host\register_github_extension.ps1"; DestDir: "{app}\host"; Flags: ignoreversion
[Icons]
Name: "{autoprograms}\MyCATTLES"; Filename: "{app}\{#MyAppExeName}"
[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch MyCATTLES"; Flags: nowait postinstall skipifsilent
[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"
[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Cmd: String;
begin
  if CurStep = ssPostInstall then begin
    Cmd := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\host\install_host.ps1') + '" -WebStoreExtensionId "{#ChromeExtensionId}" -GitHubExtensionId "{#GitHubExtensionId}"';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Native Messaging registration could not start')
    else if ResultCode <> 0 then
      RaiseException('Native Messaging registration failed (exit code ' + IntToStr(ResultCode) + ')');
  end;
end;
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  Cmd: String;
begin
  if CurUninstallStep = usUninstall then begin
    Cmd := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\host\uninstall_host.ps1') + '"';
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      Log('WARNING: Could not start Native Messaging unregister')
    else if ResultCode <> 0 then
      Log('WARNING: Native Messaging unregister failed: ' + IntToStr(ResultCode));
  end;
end;
