# Moonlight Unlock - setup (als administrator uitvoeren, TIJDENS een Moonlight-stream of met een controller aan de pc)
# Slaat gebruikersnaam/wachtwoord en je knopcombo versleuteld op (DPAPI, machine-scope).
param([int]$Buttons = 8)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$dir = 'C:\ProgramData\MoonlightUnlock'

# Maakt de datamap veilig aan. (Deze functie staat identiek in setup.ps1 en install.ps1.)
# In ProgramData mogen gewone gebruikers bestanden en mappen aanmaken. Daarom:
#  - weigeren als de map een junction/symlink is of van een niet-beheerder is
#    (een gebruiker kan hem vooraf aangemaakt hebben om er later bestanden in te lezen of te vervangen);
#  - ACL in één keer zetten: SYSTEM en Administrators volledig, Users alleen lezen op de map zelf
#    (niet overgeërfd). Nieuwe bestanden zoals secret.bin zijn zo vanaf het eerste moment
#    alleen voor SYSTEM/Administrators;
#  - daarna alles verwijderen wat niet van een beheerder is of een reparse point is.
function Initialize-DataDir([string]$dir) {
    $sidSystem = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $sidAdmins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $sidUsers  = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $sidMe     = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $trusted   = @($sidSystem.Value, $sidAdmins.Value, $sidMe.Value)
    $ownerOf   = { param($p) (Get-Acl -LiteralPath $p).GetOwner([Security.Principal.SecurityIdentifier]).Value }

    if (Test-Path -LiteralPath $dir) {
        $item = Get-Item -LiteralPath $dir -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$dir is geen gewone map (junction/symlink?). Verwijder het en probeer opnieuw."
        }
        if ($trusted -notcontains (& $ownerOf $dir)) {
            throw "$dir is aangemaakt door een andere gebruiker en is niet te vertrouwen. Verwijder de map en probeer opnieuw."
        }
    } else {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none    = [Security.AccessControl.PropagationFlags]::None
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sidSystem, 'FullControl', $inherit, $none, 'Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sidAdmins, 'FullControl', $inherit, $none, 'Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sidUsers, 'ReadAndExecute', 'None', $none, 'Allow')))
    Set-Acl -LiteralPath $dir -AclObject $acl
    icacls $dir /setowner '*S-1-5-32-544' | Out-Null

    foreach ($child in Get-ChildItem -LiteralPath $dir -Force) {
        $isLink = [bool]($child.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($isLink -or $child.PSIsContainer -or ($trusted -notcontains (& $ownerOf $child.FullName))) {
            Write-Host "Onbekend item verwijderd: $($child.FullName)"
            if ($isLink) { $child.Delete() }                                       # alleen de link, niet het doel
            elseif ($child.PSIsContainer) { cmd /c rmdir /s /q "`"$($child.FullName)`"" }  # volgt geen junctions
            else { Remove-Item -LiteralPath $child.FullName -Force }
        } else {
            # Alleen nog de map-ACL erven (oudere versies gaven Users leesrechten op alles)
            icacls $child.FullName /reset | Out-Null
            icacls $child.FullName /setowner '*S-1-5-32-544' | Out-Null
        }
    }
}

Initialize-DataDir $dir

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
function Get-Plain([Security.SecureString]$s) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}
$p1 = Get-Plain $s1
$p2 = Get-Plain $s2
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
# De map geeft Users geen rechten op bestanden, dus het bestand is vanaf het aanmaken afgeschermd.
[IO.File]::WriteAllBytes($file, $blob)
icacls $file /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null

Write-Host "`nKlaar. Combo en wachtwoord zijn versleuteld opgeslagen in $file"
