# Moonlight Unlock

Unlock your Windows PC with a button combo on your controller while you stream
to it with [Moonlight](https://moonlight-stream.org/), with no typing on the
lock screen.

Moonlight Unlock is a **Windows Credential Provider**: a DLL that the Windows
lock and sign-in screen loads. On that screen it reads the controller
(XInput). If you press the right sequence of buttons within 10 seconds, it
hands your stored password to Windows and you are signed in or unlocked. If
the stream (the controller) then disappears for 10 seconds, the PC locks
itself again.

## Requirements

- Windows 10 or 11, 64-bit
- A streaming host such as Sunshine, with Moonlight and a controller on the
  device you stream from
- A Windows account with a password. For a Microsoft account this is the
  Microsoft account password, not your PIN.
- Administrator rights to install

## Installation

1. Download `MoonlightUnlock-Setup-<version>.exe` from the
   [Releases](../../releases) page and run it. It asks for administrator
   rights. Windows SmartScreen may warn because the installer isn't signed:
   choose **More info** > **Run anyway**.

   The installer copies the DLL to `C:\Windows\System32`, registers the
   credential provider and creates a scheduled task for the lock-watcher for
   the user who runs the installer.
2. Configure your password and button combo. Tick the option at the end of
   the installer, or later start **Configure Moonlight Unlock** from the Start
   menu. A controller has to be connected, so do this during a Moonlight
   stream or with a controller plugged into the PC.

   Enter your username, domain and password, then press your button combo
   twice. The default is 8 buttons. The minimum is 4, but use at least 8: see
   [Security](#security).
3. Lock the PC (Win+L). The lock screen shows a **Moonlight** tile. Press your
   combo and the PC unlocks.

Changed your password or want a different combo? Run **Configure Moonlight
Unlock** again.

To uninstall, use **Settings > Apps > Installed apps > Moonlight Unlock**. This
also deletes your stored password from `C:\ProgramData\MoonlightUnlock`.

### Manual installation (zip)

Prefer scripts? Download `MoonlightUnlock-<version>.zip`, extract it and run in
an administrator PowerShell in that folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

Use `setup.ps1 -Buttons 10` for a different combo length.

## How it works

| Part | What it does |
|---|---|
| `MoonlightUnlockCP.dll` | Credential provider that Windows (LogonUI) loads as SYSTEM. Recognises the combo and passes on the stored credentials. |
| `setup.ps1` | Stores domain, user, password and combo encrypted in `C:\ProgramData\MoonlightUnlock\secret.bin` (DPAPI, machine scope). |
| `install.ps1` | Installs and registers the DLL, plus the scheduled task `MoonlightUnlockWatcher`. |
| `lock-watcher.ps1` | Runs in your session when you sign in. After a combo unlock it locks the PC once there has been no controller for 10 s. |
| `uninstall.ps1` | Removes the credential provider, the DLL and the scheduled task. |

Log files:
- `C:\ProgramData\MoonlightUnlock\cp.log` (credential provider)
- `%LOCALAPPDATA%\MoonlightUnlock\watcher.log` (lock-watcher)

## Security

- **Anyone with the combo and a controller gets in.** The DLL can't tell
  whether the controller comes through Moonlight or is plugged in. Someone
  with physical access who knows the combo can unlock the PC. Use a long
  combo, and don't use this on a PC that others can physically reach if that
  is a concern.
- There is no limit on attempts. With 8 buttons there are so many possible
  combos that guessing isn't feasible; with 4 it is.
- Your password is encrypted with DPAPI in machine scope. Any process on the PC
  can decrypt that, so the protection comes from file permissions: only SYSTEM
  and Administrators can read `secret.bin`. That's why `setup.ps1` and
  `install.ps1` lock down the folder and refuse a folder created by another
  user.
- Administrators of the PC can read your password.

## Emergency route and uninstalling

- If the sign-in screen stops working, start Windows in **Safe Mode**: it
  doesn't load third-party credential providers. Then delete the registry key
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}`.
- With the manual (zip) installation, uninstall by running `uninstall.ps1` as
  administrator. If the DLL is still loaded, it can only be deleted after a
  restart. Your data stays in `C:\ProgramData\MoonlightUnlock`; delete that
  folder yourself if you no longer need it.

## Building

GitHub Actions builds the DLL, the installer and the zip on every push; you'll
find them as the `MoonlightUnlock` artifact of the run. To build the DLL
locally, use Visual Studio and CMake:

```powershell
cmake -B build -A x64
cmake --build build --config Release
```

The installer is built with [Inno Setup](https://jrsoftware.org/isinfo.php)
from `installer/MoonlightUnlock.iss`:
`ISCC /DAppVersion=1.0.0 installer\MoonlightUnlock.iss` (after building the DLL).

To make a release, publish a release on GitHub with a new tag in the form
`v1.2.3`. The workflow then builds the installer and the zip from that tag and
attaches both to the release.
