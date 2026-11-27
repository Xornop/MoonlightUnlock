# Moonlight Unlock - installeren (als administrator). Zet MoonlightUnlockCP.dll en lock-watcher.ps1 in dezelfde map.
$ErrorActionPreference = 'Stop'
$clsid = '{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir   = 'C:\ProgramData\MoonlightUnlock'

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
Copy-Item (Join-Path $here 'MoonlightUnlockCP.dll') "$env:windir\System32\MoonlightUnlockCP.dll" -Force
Copy-Item (Join-Path $here 'lock-watcher.ps1') (Join-Path $dir 'lock-watcher.ps1') -Force
# Users mogen het script lezen (de watcher draait als jij), niet wijzigen
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

# lock-watcher: draait in jouw sessie, vergrendelt 10 s na streamverlies (alleen na combo-ontgrendeling)
$me   = "$env:USERDOMAIN\$env:USERNAME"
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\lock-watcher.ps1`""
$trg  = New-ScheduledTaskTrigger -AtLogOn -User $me
$prn  = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'MoonlightUnlockWatcher' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName 'MoonlightUnlockWatcher'

Write-Host 'Geïnstalleerd. Noodroute: Veilige modus laadt de provider niet; of verwijder de registersleutel onder Credential Providers.'
