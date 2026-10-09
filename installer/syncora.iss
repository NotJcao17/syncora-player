; Instalador de Windows de Syncora Player (Inno Setup 6).
;
; No se compila a mano: lo hace installer\build_release.ps1, que pasa la
; version leida de pubspec.yaml (/DMyAppVersion=...). Si se abre este archivo
; directo en Inno Setup, usa la version de respaldo de abajo.
;
; AppId NO se cambia nunca: es lo que hace que una version nueva se instale
; encima de la anterior en vez de aparecer como otra app.

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "Syncora Player"
#define MyAppExeName "syncora_player.exe"
#define MyAppURL "https://github.com/NotJcao17/syncora-player"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6165AB59-2349-4A56-ABAF-16AA45E1043A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
VersionInfoVersion={#MyAppVersion}
AppPublisher=NotJcao17
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\Syncora Player
DisableProgramGroupPage=yes
; Instala en la carpeta del usuario: no pide permiso de administrador.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\installer
OutputBaseFilename=SyncoraSetup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
LicenseFile=..\LICENSE
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Si la app esta abierta al actualizar, el instalador la cierra.
CloseApplications=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Las DLL de Visual C++ (msvcp140, vcruntime140, vcruntime140_1) entran con la
; linea de arriba: build_release.ps1 las copia a la carpeta Release antes de
; compilar. No se leen de System32 desde aqui porque Inno Setup es de 32 bits y
; Windows le daria las versiones de 32 bits.

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Esquema syncoraplayer:// (enlaces de playlists compartidas desde la web).
; Instalacion por usuario, asi que va en HKCU; se borra al desinstalar.
; Si la app ya esta abierta, el runner de Windows (main.cpp) le reenvia el enlace.
Root: HKCU; Subkey: "Software\Classes\syncoraplayer"; ValueType: string; ValueName: ""; ValueData: "URL:Syncora Player"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\syncoraplayer"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\syncoraplayer\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCU; Subkey: "Software\Classes\syncoraplayer\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
