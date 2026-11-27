# Moonlight Unlock - lock-watcher (draait in jouw gebruikerssessie)
# Als de pc via de combo is ontgrendeld (unlocked.flag) en er 10 s geen controller/stream meer is -> vergrendelen.
$dir  = 'C:\ProgramData\MoonlightUnlock'
$flag = Join-Path $dir 'unlocked.flag'
# De datamap is alleen-lezen voor gewone gebruikers; de watcher logt in je eigen profiel.
# De flag wordt door de credential provider (SYSTEM) gewist zodra het vergrendelscherm verschijnt;
# de watcher onthoudt alleen welke flag hij al heeft afgehandeld.
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

Log 'watcher gestart'
$noPadSince = $null
$handled = 0   # tijdstempel van de laatst afgehandelde flag
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
                # pc is sindsdien handmatig vergrendeld: niets meer automatisch doen
                $handled = $set
                $noPadSince = $null
                Log 'handmatig vergrendeld, flag genegeerd'
            }
            elseif ([XIW]::Any()) {
                $noPadSince = $null
            }
            elseif (-not $noPadSince) {
                $noPadSince = Get-Date
            }
            elseif (((Get-Date) - $noPadSince).TotalSeconds -ge 10) {
                Log 'stream weg -> vergrendelen'
                $handled = $set
                $noPadSince = $null
                rundll32.exe user32.dll,LockWorkStation
            }
        } else {
            $noPadSince = $null
        }
    } catch { Log "fout: $_" }
    Start-Sleep -Milliseconds 500
}
