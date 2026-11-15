# Moonlight Unlock - lock-watcher (draait in jouw gebruikerssessie)
# Als de pc via de combo is ontgrendeld (unlocked.flag) en er 10 s geen controller/stream meer is -> vergrendelen.
$dir  = 'C:\ProgramData\MoonlightUnlock'
$flag = Join-Path $dir 'unlocked.flag'
$logf = Join-Path $dir 'watcher.log'
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
while ($true) {
    try {
        if (Test-Path $flag) {
            $set = 0
            try { $set = [int64](Get-Content $flag -ErrorAction Stop) } catch {}
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $set
            $locked = [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)

            if ($age -gt 20 -and $locked) {
                # pc is sindsdien handmatig vergrendeld: niets meer automatisch doen
                Remove-Item $flag -Force
                $noPadSince = $null
                Log 'handmatig vergrendeld, flag gewist'
            }
            elseif ([XIW]::Any()) {
                $noPadSince = $null
            }
            elseif (-not $noPadSince) {
                $noPadSince = Get-Date
            }
            elseif (((Get-Date) - $noPadSince).TotalSeconds -ge 10) {
                Log 'stream weg -> vergrendelen'
                Remove-Item $flag -Force
                $noPadSince = $null
                rundll32.exe user32.dll,LockWorkStation
            }
        } else {
            $noPadSince = $null
        }
    } catch { Log "fout: $_" }
    Start-Sleep -Milliseconds 500
}
