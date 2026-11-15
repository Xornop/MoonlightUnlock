# Moonlight Unlock - installeren (als administrator). Zet MoonlightUnlockCP.dll en lock-watcher.ps1 in dezelfde map.
$ErrorActionPreference = 'Stop'
$clsid = '{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir   = 'C:\ProgramData\MoonlightUnlock'

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $here 'MoonlightUnlockCP.dll') "$env:windir\System32\MoonlightUnlockCP.dll" -Force
Copy-Item (Join-Path $here 'lock-watcher.ps1') (Join-Path $dir 'lock-watcher.ps1') -Force

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
