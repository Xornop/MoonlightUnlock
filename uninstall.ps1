# Moonlight Unlock - verwijderen (als administrator)
$clsid = '{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}'
Unregister-ScheduledTask -TaskName 'MoonlightUnlockWatcher' -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*lock-watcher.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\$clsid" -Force -ErrorAction SilentlyContinue
Remove-Item "HKLM:\SOFTWARE\Classes\CLSID\$clsid" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:windir\System32\MoonlightUnlockCP.dll" -Force -ErrorAction SilentlyContinue
Write-Host 'Verwijderd (de DLL kan pas weg na een herstart als hij nog geladen is). Data staat nog in C:\ProgramData\MoonlightUnlock.'
