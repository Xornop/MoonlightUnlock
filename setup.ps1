# Moonlight Unlock - setup (als administrator uitvoeren, TIJDENS een Moonlight-stream of met een controller aan de pc)
# Slaat gebruikersnaam/wachtwoord en je knopcombo versleuteld op (DPAPI, machine-scope).
param([int]$Buttons = 8)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$dir = 'C:\ProgramData\MoonlightUnlock'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class XI {
    [StructLayout(LayoutKind.Sequential)] public struct GP { public ushort Buttons; public byte LT; public byte RT; public short LX; public short LY; public short RX; public short RY; }
    [StructLayout(LayoutKind.Sequential)] public struct ST { public uint Packet; public GP Gamepad; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint index, out ST state);
    public static int Buttons() {
        int m = -1;
        for (uint i = 0; i < 4; i++) { ST s; if (XInputGetState(i, out s) == 0) { if (m < 0) m = 0; m |= s.Gamepad.Buttons; } }
        return m;
    }
}
"@

function Read-Combo([int]$n) {
    $presses = @()
    $prev = 0
    while ($presses.Count -lt $n) {
        $m = [XI]::Buttons()
        if ($m -lt 0) { Start-Sleep -Milliseconds 200; continue }
        if ($prev -eq 0 -and $m -ne 0) {
            $presses += $m
            Write-Host ("  knop {0}/{1} geregistreerd" -f $presses.Count, $n)
        }
        $prev = $m
        Start-Sleep -Milliseconds 15
    }
    # wacht tot alles losgelaten is
    while ([XI]::Buttons() -gt 0) { Start-Sleep -Milliseconds 50 }
    return $presses
}

if ([XI]::Buttons() -lt 0) { throw 'Geen controller gevonden. Start een Moonlight-stream (of sluit een controller aan) en probeer opnieuw.' }

$user   = Read-Host "Windows-gebruikersnaam (Enter = $env:USERNAME)"
if (-not $user) { $user = $env:USERNAME }
$domain = Read-Host "Domein (Enter = $env:COMPUTERNAME)"
if (-not $domain) { $domain = $env:COMPUTERNAME }

$s1 = Read-Host 'Wachtwoord (Microsoft-account wachtwoord)' -AsSecureString
$s2 = Read-Host 'Wachtwoord nogmaals' -AsSecureString
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s1))
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s2))
if ($p1 -ne $p2 -or -not $p1) { throw 'Wachtwoorden komen niet overeen.' }

while ($true) {
    Write-Host "`nDruk nu $Buttons knoppen achter elkaar (D-pad, A/B/X/Y, LB/RB, Start/Back). Druk één knop per keer."
    $c1 = Read-Combo $Buttons
    Write-Host "`nHerhaal dezelfde combo ter bevestiging:"
    $c2 = Read-Combo $Buttons
    if (($c1 -join ',') -eq ($c2 -join ',')) { break }
    Write-Host "`nCombo's kwamen niet overeen, opnieuw."
}
$combo = ($c1 | ForEach-Object { '{0:X}' -f $_ }) -join ','

$text  = "$domain`n$user`n$p1`n$combo"
$bytes = [Text.Encoding]::UTF8.GetBytes($text)
$blob  = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
$file  = Join-Path $dir 'secret.bin'
[IO.File]::WriteAllBytes($file, $blob)
icacls $file /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null

Write-Host "`nKlaar. Combo en wachtwoord zijn versleuteld opgeslagen in $file"
