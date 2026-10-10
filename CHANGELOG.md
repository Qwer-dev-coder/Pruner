# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-10

First public release.

### Added
- Cleanup of temp files, update cache, browser and app caches, shader caches, crash dumps, logs and the Recycle Bin, with a scan that shows the space each item will free.
- Removal of preinstalled Windows apps with a protected list of system components.
- 33 reversible system tweaks: telemetry, ads, Copilot and Recall, search, services, interface and performance. Defender, SmartScreen and Windows Update settings are in separate marked groups.
- Startup manager that toggles entries without deleting them.
- Large file finder (200 MB and up) that deletes to the Recycle Bin.
- Settings: light and dark theme, custom wallpaper with gradient and accent colour taken from the image, font, font size, corner radius and row density.
- Scheduled cleanup through Task Scheduler.
- Stop button that interrupts file operations and external tools such as DISM and SFC.
- Optional restore point before system tweaks.
- `Pruner.exe` launcher with embedded script and wallpapers, built with mingw-w64.

[1.0.0]: https://github.com/YOUR_USER/Pruner/releases/tag/v1.0.0
