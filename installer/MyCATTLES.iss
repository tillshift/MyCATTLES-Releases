; MyCATTLES per-user Windows installer (unsigned test package)
#ifndef MyAppVersion
  #error MyAppVersion must be passed with /DMyAppVersion=...
#endif
#ifndef ReleaseDir
  #error ReleaseDir must be passed with /DReleaseDir=...
#endif

#define MyAppName "MyCATTLES"
#define MyAppExeName "mycattles.exe"

[Setup]
AppId={{048563B8-ED4A-5F1A-9D0F-AA14ACD34457}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=TILLSHIFT
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

[Icons]
Name: "{autoprograms}\MyCATTLES"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "MyCATTLESを起動"; Flags: nowait postinstall skipifsilent
