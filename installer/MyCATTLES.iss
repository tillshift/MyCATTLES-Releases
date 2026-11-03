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
procedure RunHostCleanup(StopOnly: Boolean);
var
  ResultCode: Integer;
  Cmd: String;
  ScriptPath: String;
begin
  ScriptPath := ExpandConstant('{app}\host\uninstall_host.ps1');
  if not FileExists(ScriptPath) then
    Exit;

  Cmd := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '"';
  if StopOnly then
    Cmd := Cmd + ' -StopOnly';

  if not Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode
  ) then
    RaiseException('Could not start Native Host cleanup')
  else if ResultCode <> 0 then
    RaiseException('Native Host cleanup failed: ' + IntToStr(ResultCode));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  try
    RunHostCleanup(True);
  except
    Result := GetExceptionMessage;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  Cmd: String;
begin
  if CurStep = ssPostInstall then
  begin
    Cmd :=
      '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\host\install_host.ps1') +
      '" -WebStoreExtensionId "{#ChromeExtensionId}"' +
      ' -GitHubExtensionId "{#GitHubExtensionId}"';

    if not Exec(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Cmd, '', SW_HIDE, ewWaitUntilTerminated, ResultCode
    ) then
      RaiseException('Native Messaging registration could not start')
    else if ResultCode <> 0 then
      RaiseException('Native Messaging registration failed: ' + IntToStr(ResultCode));
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RunHostCleanup(False);
end;
