# Moonlight Unlock - setup (run as administrator, DURING a Moonlight stream or with a controller connected to the PC)
# Stores your username/password and your button combo encrypted (DPAPI, machine scope).
param([int]$Buttons = 8)

# Started without administrator rights (e.g. from the Start menu shortcut)? Restart elevated,
# in a window that stays open so you can read the result.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Buttons', $Buttons)
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$dir = 'C:\ProgramData\MoonlightUnlock'

# Creates the data folder securely. (This function is identical in setup.ps1 and install.ps1.)
# Standard users may create files and folders in ProgramData. Therefore:
#  - refuse if the folder is a junction/symlink or is owned by a non-administrator
#    (a user could have created it in advance to later read or replace files in it);
#  - set the ACL in one go: SYSTEM and Administrators full control, Users read on the folder itself
#    only (not inherited). New files such as secret.bin are then SYSTEM/Administrators-only
#    from the moment they are created;
#  - then remove anything that isn't owned by an administrator or is a reparse point.
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
            throw "$dir is not a regular folder (junction/symlink?). Remove it and try again."
        }
        if ($trusted -notcontains (& $ownerOf $dir)) {
            throw "$dir was created by another user and cannot be trusted. Remove the folder and try again."
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
            Write-Host "Removed unknown item: $($child.FullName)"
            if ($isLink) { $child.Delete() }                                       # only the link, not its target
            elseif ($child.PSIsContainer) { cmd /c rmdir /s /q "`"$($child.FullName)`"" }  # does not follow junctions
            else { Remove-Item -LiteralPath $child.FullName -Force }
        } else {
            # Inherit only the folder ACL (older versions gave Users read access to everything)
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
            Write-Host ("  button {0}/{1} recorded" -f $presses.Count, $n)
        }
        $prev = $m
        Start-Sleep -Milliseconds 15
    }
    # wait until all buttons are released
    while ([XI]::Buttons() -gt 0) { Start-Sleep -Milliseconds 50 }
    return $presses
}

if ([XI]::Buttons() -lt 0) { throw 'No controller found. Start a Moonlight stream (or connect a controller) and try again.' }

$user   = Read-Host "Windows username (Enter = $env:USERNAME)"
if (-not $user) { $user = $env:USERNAME }
$domain = Read-Host "Domain (Enter = $env:COMPUTERNAME)"
if (-not $domain) { $domain = $env:COMPUTERNAME }

$s1 = Read-Host 'Password (your Microsoft account password, not your PIN)' -AsSecureString
$s2 = Read-Host 'Password again' -AsSecureString
function Get-Plain([Security.SecureString]$s) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}
$p1 = Get-Plain $s1
$p2 = Get-Plain $s2
if ($p1 -ne $p2 -or -not $p1) { throw 'Passwords do not match.' }

while ($true) {
    Write-Host "`nNow press $Buttons buttons in a row (D-pad, A/B/X/Y, LB/RB, Start/Back), one button at a time."
    $c1 = Read-Combo $Buttons
    Write-Host "`nRepeat the same combo to confirm:"
    $c2 = Read-Combo $Buttons
    if (($c1 -join ',') -eq ($c2 -join ',')) { break }
    Write-Host "`nThe combos did not match, try again."
}
$combo = ($c1 | ForEach-Object { '{0:X}' -f $_ }) -join ','

$text  = "$domain`n$user`n$p1`n$combo"
$bytes = [Text.Encoding]::UTF8.GetBytes($text)
$blob  = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
$file  = Join-Path $dir 'secret.bin'
# The folder gives Users no access to files, so this file is protected from the moment it is created.
[IO.File]::WriteAllBytes($file, $blob)
icacls $file /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null

Write-Host "`nDone. Combo and password are stored encrypted in $file"
