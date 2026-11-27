# Moonlight Unlock - install (run as administrator). Put MoonlightUnlockCP.dll and lock-watcher.ps1 in the same folder.
$ErrorActionPreference = 'Stop'
$clsid = '{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir   = 'C:\ProgramData\MoonlightUnlock'

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
Copy-Item (Join-Path $here 'MoonlightUnlockCP.dll') "$env:windir\System32\MoonlightUnlockCP.dll" -Force
Copy-Item (Join-Path $here 'lock-watcher.ps1') (Join-Path $dir 'lock-watcher.ps1') -Force
# Users may read the script (the watcher runs as you), not change it
icacls (Join-Path $dir 'lock-watcher.ps1') /grant '*S-1-5-32-545:(RX)' | Out-Null

$k1 = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"
New-Item -Path $k1 -Force | Out-Null
Set-ItemProperty -Path $k1 -Name '(default)' -Value 'MoonlightUnlock'
New-Item -Path "$k1\InprocServer32" -Force | Out-Null
Set-ItemProperty -Path "$k1\InprocServer32" -Name '(default)' -Value "$env:windir\System32\MoonlightUnlockCP.dll"
Set-ItemProperty -Path "$k1\InprocServer32" -Name 'ThreadingModel' -Value 'Both'

$k2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$clsid"
New-Item -Path $k2 -Force | Out-Null
Set-ItemProperty -Path $k2 -Name '(default)' -Value 'MoonlightUnlock'

# lock-watcher: runs in your session, locks 10 s after the stream is lost (only after a combo unlock)
$me   = "$env:USERDOMAIN\$env:USERNAME"
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\lock-watcher.ps1`""
$trg  = New-ScheduledTaskTrigger -AtLogOn -User $me
$prn  = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'MoonlightUnlockWatcher' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName 'MoonlightUnlockWatcher'

Write-Host 'Installed. Emergency route: Safe Mode does not load the provider; or delete its registry key under Credential Providers.'
