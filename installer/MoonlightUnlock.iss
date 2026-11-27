; Moonlight Unlock - Inno Setup installer script
; Built by the GitHub workflow:  ISCC /DAppVersion=1.0.0 installer\MoonlightUnlock.iss
; The DLL is expected at build\Release\MoonlightUnlockCP.dll (relative to the repository root).

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{2F0C8E4A-6B1D-4E7A-9C3F-8D5B1A7E2C64}
AppName=Moonlight Unlock
AppVersion={#AppVersion}
AppPublisher=Xornop
AppPublisherURL=https://github.com/Xornop/MoonlightUnlock
DefaultDirName={autopf}\Moonlight Unlock
DefaultGroupName=Moonlight Unlock
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=MoonlightUnlock-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Moonlight Unlock
CloseApplications=no

[Files]
; install.ps1 copies the DLL to System32 and lock-watcher.ps1 to ProgramData, so they sit next to it.
Source: "..\build\Release\MoonlightUnlockCP.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\install.ps1";      DestDir: "{app}"; Flags: ignoreversion
Source: "..\setup.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\uninstall.ps1";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\lock-watcher.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";        DestDir: "{app}"; Flags: ignoreversion isreadme

[Icons]
; setup.ps1 asks for administrator rights itself when started from this shortcut.
Name: "{group}\Configure Moonlight Unlock"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\setup.ps1"""; WorkingDir: "{app}"
Name: "{group}\Moonlight Unlock README"; Filename: "{app}\README.md"

[Run]
; Optional last step: set up your password and button combo (needs a controller / running stream).
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -NoExit -ExecutionPolicy Bypass -File ""{app}\setup.ps1"""; WorkingDir: "{app}"; \
  Description: "Configure password and button combo now (a controller or Moonlight stream is required)"; \
  Flags: postinstall skipifsilent unchecked

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\uninstall.ps1"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "MoonlightUnlockUninstall"

[UninstallDelete]
; Remove the stored (encrypted) password and logs as well.
Type: filesandordirs; Name: "{commonappdata}\MoonlightUnlock"

[Code]
// Run install.ps1 (registers the credential provider and the lock-watcher task) and tell the
// user clearly if that fails, instead of silently finishing with an unregistered provider.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
                '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\install.ps1') + '"',
                ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
    begin
      MsgBox('Registering Moonlight Unlock failed (exit code ' + IntToStr(ResultCode) + ').' + #13#10 +
             'Run install.ps1 from ' + ExpandConstant('{app}') + ' in an administrator PowerShell to see the error.',
             mbError, MB_OK);
    end;
  end;
end;
