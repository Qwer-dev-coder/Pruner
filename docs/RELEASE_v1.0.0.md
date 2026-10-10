## Pruner 1.0.0

First public release: clean, debloat and tune Windows 10/11 in one window.

### Highlights

- **Cleanup** with a scan that shows how much space each item frees.
- **Apps**: remove preinstalled junk, system components are protected.
- **System**: 33 reversible tweaks (telemetry, ads, Copilot and Recall, services, OneDrive, power plan and more).
- **Startup manager**, **large file finder** (deletes to the Recycle Bin), **scheduled cleanup**.
- **Settings**: light and dark theme, your own wallpaper with a gradient and accent colour from the picture, font, size, corner radius.
- Every long operation can be stopped.

### Download

`Pruner.exe` below. Run it and accept the administrator prompt. Requires Windows 10/11 (x64) and Windows PowerShell 5.1.

Check the download against `Pruner.exe.sha256`:

```powershell
(Get-FileHash .\Pruner.exe -Algorithm SHA256).Hash
```

### Good to know

- The exe is not code-signed. SmartScreen may warn about an unknown publisher and some antivirus products may flag tools that change system settings. The source is in the repository.
- Pruner can switch off Windows Defender if you choose that option. With Tamper Protection on, Windows blocks it and Pruner does not bypass it.
- Create a restore point (enabled by default) before applying system tweaks.

Full list of changes: [CHANGELOG.md](https://github.com/YOUR_USER/Pruner/blob/main/CHANGELOG.md)
