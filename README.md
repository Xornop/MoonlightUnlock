# Moonlight Unlock

Ontgrendel je Windows-pc met een knopcombinatie op je controller terwijl je via
[Moonlight](https://moonlight-stream.org/) naar hem streamt. Typen op het
vergrendelscherm is dan niet meer nodig.

Moonlight Unlock is een **Windows Credential Provider**: een DLL die het
vergrendel- en aanmeldscherm van Windows laadt. Op dat scherm leest hij de
controller (XInput). Druk je binnen 10 seconden de juiste reeks knoppen, dan
geeft hij je opgeslagen wachtwoord aan Windows en word je aangemeld of
ontgrendeld. Valt de stream (de controller) daarna 10 seconden weg, dan
vergrendelt de pc zich weer.

## Vereisten

- Windows 10 of 11, 64-bit
- Een streaming-host zoals Sunshine, met Moonlight en een controller op het
  apparaat waarmee je streamt
- Een Windows-account met wachtwoord. Bij een Microsoft-account is dat het
  wachtwoord van het Microsoft-account, niet je pincode.
- Beheerdersrechten om te installeren

## Installeren

1. Download `MoonlightUnlock-<versie>.zip` van de
   [Releases](../../releases)-pagina en pak hem uit in een map.
2. Open PowerShell **als administrator** in die map en voer uit:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
   Dit kopieert de DLL naar `C:\Windows\System32`, registreert de credential
   provider en maakt een geplande taak voor de lock-watcher.
3. Start een Moonlight-stream (of sluit een controller aan op de pc) en voer
   in dezelfde PowerShell uit:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1
   ```
   Je geeft je gebruikersnaam, domein en wachtwoord op. Daarna druk je de
   knopcombinatie twee keer. Standaard zijn dat 8 knoppen; een ander aantal
   kies je met `-Buttons 10`. Het minimum is 4, maar kies minstens 8: zie
   [Beveiliging](#beveiliging).
4. Vergrendel de pc (Win+L). Op het vergrendelscherm staat een tegel
   **Moonlight**. Druk je combo en de pc ontgrendelt.

Heb je je wachtwoord of je combo veranderd? Voer `setup.ps1` dan opnieuw uit.

## Hoe het werkt

| Onderdeel | Wat het doet |
|---|---|
| `MoonlightUnlockCP.dll` | Credential provider die Windows (LogonUI) als SYSTEM laadt. Herkent de combo en geeft de opgeslagen inloggegevens door. |
| `setup.ps1` | Slaat domein, gebruiker, wachtwoord en combo versleuteld op in `C:\ProgramData\MoonlightUnlock\secret.bin` (DPAPI, machine-scope). |
| `install.ps1` | Installeert de DLL en registreert hem, plus de geplande taak `MoonlightUnlockWatcher`. |
| `lock-watcher.ps1` | Draait bij aanmelden in jouw sessie. Na een ontgrendeling via de combo vergrendelt hij de pc als er 10 s geen controller meer is. |
| `uninstall.ps1` | Verwijdert de credential provider, de DLL en de geplande taak. |

Logbestanden:
- `C:\ProgramData\MoonlightUnlock\cp.log` (credential provider)
- `%LOCALAPPDATA%\MoonlightUnlock\watcher.log` (lock-watcher)

## Beveiliging

- **Iedereen met de combo en een controller komt binnen.** De DLL kan niet
  zien of de controller via Moonlight komt of fysiek is aangesloten. Wie bij
  de pc kan en de combo kent, kan dus ontgrendelen. Kies een lange combo en
  gebruik het niet op een pc waar anderen fysiek bij kunnen als dat een
  probleem is.
- Er is geen limiet op het aantal pogingen. Met 8 knoppen zijn er zoveel
  mogelijke combinaties dat raden onhaalbaar is; met 4 niet.
- Je wachtwoord staat versleuteld met DPAPI in machine-scope. Elk proces op de
  pc kan dat ontsleutelen, dus de bescherming zit in de bestandsrechten:
  alleen SYSTEM en Administrators kunnen `secret.bin` lezen. `setup.ps1` en
  `install.ps1` zetten de map daarom dicht en weigeren een map die door een
  andere gebruiker is aangemaakt.
- Beheerders van de pc kunnen je wachtwoord wel uitlezen.

## Noodroute en verwijderen

- Werkt het aanmeldscherm niet meer? Start Windows in **Veilige modus**: die
  laadt geen credential providers van derden. Verwijder daar de registersleutel
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers\{7B1A3E2C-4F5D-4C8A-9E21-5A6D0B831CF4}`.
- Gewoon verwijderen, als administrator:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
  ```
  De DLL kan pas na een herstart weg als hij nog geladen is. Je gegevens
  blijven in `C:\ProgramData\MoonlightUnlock` staan; verwijder die map zelf
  als je ze niet meer nodig hebt.

## Zelf bouwen

GitHub Actions bouwt de DLL bij elke push; je vindt hem als artifact
`MoonlightUnlockCP` bij de run. Lokaal kan het met Visual Studio en CMake:

```powershell
cmake -B build -A x64
cmake --build build --config Release
```

Een release maak je door een tag te pushen die met `v` begint, bijvoorbeeld
`git tag v1.0.1` en daarna `git push origin v1.0.1`. De workflow bouwt dan de
zip met de DLL, de scripts en deze README, en zet die bij een nieuwe release.
