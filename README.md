<div align="center">

<img src="launcher/icon.png" width="96" alt="Pruner icon">

# Pruner

**Clean, debloat and tune Windows 10/11 in one window.**

[![Release](https://img.shields.io/github/v/release/YOUR_USER/Pruner?style=flat-square)](https://github.com/YOUR_USER/Pruner/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/YOUR_USER/Pruner/build.yml?style=flat-square)](https://github.com/YOUR_USER/Pruner/actions)
[![License](https://img.shields.io/github/license/YOUR_USER/Pruner?style=flat-square)](LICENSE)

English | [Русский](README.ru.md)

</div>

<!-- Add a real screenshot of the app, then uncomment:
<p align="center"><img src="docs/screenshot.png" width="860" alt="Pruner main window"></p>
-->

Pruner is a small open-source tool that frees disk space, removes preinstalled junk and switches off telemetry and ads. It is a single `.exe`, needs no installer, shows exactly what it is going to do, and every long operation can be stopped.

## Features

| Section | What it does |
| --- | --- |
| **Cleanup** | Temp files, Windows Update cache, browser caches (Chrome, Edge, Brave, Opera, Yandex, Vivaldi, Firefox), Discord / Telegram / Steam caches, shader caches, crash dumps, logs, Recycle Bin. A scan shows how much space each item will free before anything is deleted. |
| **Apps** | Removes preinstalled apps (Xbox, Clipchamp, Solitaire, News, Weather, Teams and others). System components and Microsoft Store are hidden and cannot be removed here. |
| **System** | 33 tweaks with rollback: telemetry, ads, Copilot and Recall, Bing in search, services, OneDrive, Fast Startup, power plan, classic context menu on Windows 11. Defender, SmartScreen and update settings live in separate, clearly marked groups. |
| **Startup** | Turn startup entries and shortcuts on or off. Nothing is deleted. |
| **Large files** | Finds files over 200 MB. Deleting sends them to the Recycle Bin. |
| **Settings** | Light or dark theme, your own wallpaper with a gradient and accent colour taken from the picture, font and size, corner radius, row density, scheduled cleanup. |

Other details:

- Scheduled cleanup through Windows Task Scheduler (weekly, day and time are configurable).
- A restore point can be created before system tweaks.
- Irreversible actions (Windows.old, event logs, hibernation) always ask for confirmation.
- No network access, no analytics, no accounts. The only thing that talks to the internet is `winget`, and only if you tick that task.

## Install

1. Download `Pruner.exe` from the [latest release](https://github.com/YOUR_USER/Pruner/releases/latest).
2. Run it and accept the administrator prompt.

Requirements: Windows 10 or 11 (x64) and Windows PowerShell 5.1, which ships with the system.

Verify the download with the `Pruner.exe.sha256` file from the same release:

```powershell
(Get-FileHash .\Pruner.exe -Algorithm SHA256).Hash
```

## Run from source

```powershell
powershell -ExecutionPolicy Bypass -File .\Pruner.ps1
```

If something goes wrong on startup, an error window appears and the details are written to `C:\ProgramData\Pruner\crash.log`.

## Build the exe

On Linux or macOS with mingw-w64:

```sh
sudo apt install gcc-mingw-w64-x86-64 binutils-mingw-w64-x86-64
./build.sh
```

The result is `dist/Pruner.exe`. It is a tiny launcher that embeds `Pruner.ps1` and `assets/`, unpacks them to `%LOCALAPPDATA%\Pruner\app` and starts the script through PowerShell. The same build runs in GitHub Actions for every tag.

## Safety notes

- **Defender.** Pruner can turn off Windows Defender using official policies and commands. If Tamper Protection is on, Windows will block the change and Pruner will not try to bypass it: switch Tamper Protection off yourself in Windows Security first. Turning off your antivirus is your decision and your risk.
- **Unsigned binary.** The exe is not code-signed, so SmartScreen may warn about an unknown publisher, and some antivirus products may flag tools that change system settings. The full source is in this repository: read it or build it yourself.
- **Back up first.** Use the restore point option and review the list before pressing Apply.
- This project is not affiliated with Microsoft.

## Where things are stored

| What | Where |
| --- | --- |
| Appearance settings | `%APPDATA%\Pruner\settings.json` |
| Log | `%ProgramData%\Pruner\log.txt` |
| Startup errors | `%ProgramData%\Pruner\crash.log` |
| Unpacked app | `%LOCALAPPDATA%\Pruner\app` |

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
