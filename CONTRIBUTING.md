# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Run from source

```powershell
powershell -ExecutionPolicy Bypass -File .\Pruner.ps1
```

You need Windows 10 or 11 and an administrator account. Use a virtual machine or create a restore point before testing tweaks.

## Project layout

| Path | Purpose |
| --- | --- |
| `Pruner.ps1` | The whole application. |
| `assets/wallpapers/` | Built-in wallpapers. |
| `launcher/` | C source, manifest, icon and version info for `Pruner.exe`. |
| `build.sh` | Builds `dist/Pruner.exe` with mingw-w64. |
| `.github/workflows/build.yml` | CI: syntax check, build, release on tags. |

Inside `Pruner.ps1`:

- **`$Engine`** is a script block with all the work: cleanup tasks, the tweak table, app removal, the C# file layer. It runs in a background runspace for the window and directly for `-Auto`. It reports progress through a queue and checks a cancel flag, so every long operation must stay stoppable.
- **The window section** holds the XAML, the theme code (`Apply-Look`), list builders and message handling.

## Adding a cleanup task

Add a `New-CleanTask` entry in `$Engine`. Give it `-Paths` (so the scan can measure it) and an `-Action` only when plain deletion is not enough. Mark risky tasks with `-Badge 'необратимо'` so the user is asked to confirm.

## Adding a tweak

Add a `Tw @{ ... }` entry. Prefer the declarative kinds (`reg`, `svc`, `task`) because they roll back automatically. Use `custom` with `Detect`, `On` and `Off` blocks only when needed. Every tweak must be reversible and must say honestly what it affects. Anything that lowers security gets the `осторожно` badge and stays out of the presets.

## Before opening a pull request

- The file must stay UTF-8 with BOM and CRLF line endings (Windows PowerShell 5.1 needs the BOM for Cyrillic text).
- Check that the script parses:

  ```powershell
  $e = $null; [System.Management.Automation.Language.Parser]::ParseFile("$PWD\Pruner.ps1", [ref]$null, [ref]$e) | Out-Null; $e
  ```

- Describe what you tested and on which Windows version.
- Keep the interface plain: no emoji icons, no decorative effects.
- Add a line to `CHANGELOG.md` under `Unreleased`.
