# Moonlight Unlock - lock-watcher (runs in your user session)
# If the PC was unlocked with the combo (unlocked.flag) and there has been no controller/stream for 10 s -> lock.
$dir  = 'C:\ProgramData\MoonlightUnlock'
$flag = Join-Path $dir 'unlocked.flag'
# The data folder is read-only for standard users; the watcher logs to your own profile.
# The credential provider (SYSTEM) deletes the flag as soon as the lock screen appears;
# the watcher only remembers which flag it has already handled.
$logDir = Join-Path $env:LOCALAPPDATA 'MoonlightUnlock'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logf = Join-Path $logDir 'watcher.log'
function Log($m) { Add-Content -Path $logf -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class XIW {
    [StructLayout(LayoutKind.Sequential)] public struct GP { public ushort Buttons; public byte LT; public byte RT; public short LX; public short LY; public short RX; public short RY; }
    [StructLayout(LayoutKind.Sequential)] public struct ST { public uint Packet; public GP Gamepad; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint index, out ST state);
    public static bool Any() { for (uint i = 0; i < 4; i++) { ST s; if (XInputGetState(i, out s) == 0) return true; } return false; }
}
"@

Log 'watcher started'
$noPadSince = $null
$handled = 0   # timestamp of the last flag that was handled
while ($true) {
    try {
        $set = 0
        if (Test-Path $flag) {
            try { $set = [int64](Get-Content $flag -ErrorAction Stop) } catch {}
        }
        if ($set -gt $handled) {
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $set
            $locked = [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)

            if ($age -gt 20 -and $locked) {
                # the PC has been locked manually since: stop doing anything automatically
                $handled = $set
                $noPadSince = $null
                Log 'locked manually, flag ignored'
            }
            elseif ([XIW]::Any()) {
                $noPadSince = $null
            }
            elseif (-not $noPadSince) {
                $noPadSince = Get-Date
            }
            elseif (((Get-Date) - $noPadSince).TotalSeconds -ge 10) {
                Log 'stream gone -> locking'
                $handled = $set
                $noPadSince = $null
                rundll32.exe user32.dll,LockWorkStation
            }
        } else {
            $noPadSince = $null
        }
    } catch { Log "error: $_" }
    Start-Sleep -Milliseconds 500
}
