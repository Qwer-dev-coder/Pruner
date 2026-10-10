﻿﻿# =====================================================================
#  Pruner - очистка, урезка и настройка Windows 10/11
#  Запуск: Pruner.exe  (или: powershell -ExecutionPolicy Bypass -File Pruner.ps1)
#  Ключ -Auto: тихая автоочистка без окна (его использует планировщик)
# =====================================================================
param([switch]$Auto)

$script:AppName  = 'Pruner'
$script:Root     = $PSScriptRoot
$script:SelfPath = $PSCommandPath
$script:AppDir   = Join-Path $env:ProgramData 'Pruner'
$script:TaskName = 'Pruner - weekly cleanup'
if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

# ---------- права администратора ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $relaunch = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    if ($Auto) { $relaunch += ' -Auto' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunch
    exit
}

# =====================================================================
#  ДВИЖОК. Один код для окна (фоновый поток) и для тихого режима -Auto
# =====================================================================
$Engine = {
    param([string]$Mode, [string[]]$Keys, $Sync, $Opt)
    $ErrorActionPreference = 'SilentlyContinue'
    $LogFile = Join-Path $env:ProgramData 'Pruner\log.txt'
    $L = $env:LOCALAPPDATA

    function Put($type, $data) { if ($null -ne $Sync) { $Sync['Q'].Enqueue([pscustomobject]@{ T = $type; D = $data }) } }
    function Cancelled { ($null -ne $Sync) -and [bool]$Sync['Cancel'] }
    function Log([string]$m) {
        $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $m
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        Put 'log' $line
    }
    function Free { (Get-PSDrive -Name $env:SystemDrive.Substring(0, 1)).Free }

    # Запуск внешней программы; останавливается по флагу Cancel вместе с дочерними процессами
    function Run([string]$exe, [string]$arguments) {
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if ($null -ne $Sync) { $Sync['Pid'] = $p.Id }
        while (-not $p.HasExited) {
            if (Cancelled) {
                Start-Process -FilePath taskkill.exe -ArgumentList "/PID $($p.Id) /T /F" -WindowStyle Hidden -Wait
                break
            }
            Start-Sleep -Milliseconds 150
        }
        if ($null -ne $Sync) { $Sync['Pid'] = 0 }
        [void]$p.WaitForExit(2000)
        if ($p.HasExited) { $p.ExitCode } else { -1 }
    }

    function RegSet($path, $name, $value, $type = 'DWord') {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    }
    function RegGet($path, $name) { (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name }
    function RegDel($path, $name) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }

    # ------------------------------------------------------------------
    #  Задачи очистки
    # ------------------------------------------------------------------
    function New-CleanTask($Key, $Group, $Title, $Desc, $Default, $Badge = '', $Paths = $null, $Action = $null) {
        [pscustomobject]@{ Key = $Key; Group = $Group; Title = $Title; Desc = $Desc; Default = [bool]$Default; Badge = $Badge; Paths = $Paths; Action = $Action }
    }

    $browserPaths = @()
    foreach ($b in @("$L\Google\Chrome\User Data", "$L\Microsoft\Edge\User Data", "$L\BraveSoftware\Brave-Browser\User Data",
                     "$L\Yandex\YandexBrowser\User Data", "$L\Vivaldi\User Data")) {
        foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { $browserPaths += "$b\*\$c\*" }
    }
    foreach ($o in 'Opera Stable', 'Opera GX Stable') {
        foreach ($c in 'Cache', 'Code Cache', 'GPUCache') { $browserPaths += "$L\Opera Software\$o\$c\*" }
    }
    $browserPaths += "$L\Mozilla\Firefox\Profiles\*\cache2\*"

    $g1 = 'Системный мусор'; $g2 = 'Браузеры'; $g3 = 'Программы'; $g4 = 'Система'
    $T = @(
        (New-CleanTask 'temp' $g1 'Временные файлы' 'Папки Temp пользователя и Windows' $true -Paths @("$env:TEMP\*", "$env:windir\Temp\*")),

        (New-CleanTask 'wu' $g1 'Кэш обновлений Windows' 'Скачанные установщики обновлений и кэш оптимизации доставки' $true `
            -Paths @("$env:windir\SoftwareDistribution\Download\*", "$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*") `
            -Action {
                param($task)
                $svc = @('wuauserv', 'bits', 'dosvc') | ForEach-Object { Get-Service $_ } | Where-Object { $_.Status -eq 'Running' }
                try {
                    $svc | Stop-Service -Force
                    Clear-Paths $task.Paths
                } finally { $svc | Start-Service }
            }),

        (New-CleanTask 'dumps' $g1 'Отчёты об ошибках и дампы сбоев' 'Минидампы, MEMORY.DMP, очередь отправки отчётов' $true `
            -Paths @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive\*", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue\*",
                     "$L\CrashDumps\*", "$env:windir\Minidump\*", "$env:windir\MEMORY.DMP")),

        (New-CleanTask 'logs' $g1 'Журналы установки и обновления' 'CBS, DISM и Windows Update логи' $true `
            -Paths @("$env:windir\Logs\CBS\*", "$env:windir\Logs\DISM\*", "$env:windir\Logs\WindowsUpdate\*")),

        (New-CleanTask 'thumbs' $g1 'Кэш миниатюр и значков' 'Windows пересоздаст его сама' $true `
            -Paths @("$L\Microsoft\Windows\Explorer\thumbcache_*.db", "$L\Microsoft\Windows\Explorer\iconcache_*.db")),

        (New-CleanTask 'recycle' $g1 'Корзина' 'Удалённые файлы на всех дисках' $true `
            -Paths @(($env:SystemDrive + '\$Recycle.Bin\*')) `
            -Action { param($task) Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Clear-Paths $task.Paths }),

        (New-CleanTask 'dns' $g1 'Сброс DNS-кэша' 'Помогает, если сайты открываются странно' $true -Action { Clear-DnsClientCache }),

        (New-CleanTask 'browsers' $g2 'Кэш браузеров' 'Chrome, Edge, Brave, Opera, Яндекс, Vivaldi, Firefox. Пароли, куки и история не затрагиваются' $true -Paths $browserPaths),

        (New-CleanTask 'apps' $g3 'Кэш программ' 'Discord, Telegram, веб-часть Steam' $true `
            -Paths @("$env:APPDATA\discord\Cache\*", "$env:APPDATA\discord\Code Cache\*", "$env:APPDATA\discord\GPUCache\*",
                     "$env:APPDATA\Telegram Desktop\tdata\user_data\cache\*", "$env:APPDATA\Telegram Desktop\tdata\user_data\media_cache\*",
                     "$L\Steam\htmlcache\*")),

        (New-CleanTask 'shaders' $g3 'Кэш шейдеров видеокарты' 'DirectX, NVIDIA, AMD. Игры пересоберут его, в первый запуск возможны подлагивания' $false `
            -Paths @("$L\D3DSCache\*", "$L\NVIDIA\DXCache\*", "$L\NVIDIA\GLCache\*", "$env:ProgramData\NVIDIA Corporation\NV_Cache\*", "$L\AMD\DxCache\*", "$L\AMD\GLCache\*")),

        (New-CleanTask 'hiber' $g4 'Отключить гибернацию' 'Удаляет hiberfil.sys (несколько ГБ). Пропадут гибернация и быстрый запуск' $false -Badge 'изменяет систему' `
            -Paths @("$env:SystemDrive\hiberfil.sys") -Action { & powercfg.exe /h off }),

        (New-CleanTask 'winold' $g4 'Папка Windows.old' 'Прошлая версия Windows после обновления. Откатиться на неё станет невозможно' $false -Badge 'необратимо' `
            -Paths @("$env:SystemDrive\Windows.old") `
            -Action {
                param($task)
                $wo = "$env:SystemDrive\Windows.old"
                if (Test-Path $wo) {
                    [void](Run 'takeown.exe' "/F `"$wo`" /R /A /D Y")
                    [void](Run 'icacls.exe' "`"$wo`" /grant *S-1-5-32-544:F /T /C /Q")
                    Clear-Paths @("$wo\*")
                    [Cleaner]::Delete($wo, $Sync)
                }
            }),

        (New-CleanTask 'evtlogs' $g4 'Журналы событий Windows' 'Очищает все журналы событий. Диагностировать прошлые сбои будет нечем' $false -Badge 'необратимо' `
            -Action {
                foreach ($n in (& wevtutil.exe el)) { if (Cancelled) { break }; & wevtutil.exe cl $n 2>$null }
            }),

        (New-CleanTask 'dism' $g4 'Глубокая очистка хранилища компонентов (DISM)' 'Удаляет устаревшие версии компонентов системы' $false -Badge 'долго' `
            -Action { $c = Run 'dism.exe' '/Online /Cleanup-Image /StartComponentCleanup'; Log "   DISM, код: $c" }),

        (New-CleanTask 'optimize' $g4 'Оптимизация диска' 'TRIM для SSD или дефрагментация для HDD, Windows выберет сама' $false -Badge 'долго' `
            -Action { $c = Run 'defrag.exe' ($env:SystemDrive + ' /O'); Log "   Оптимизация, код: $c" }),

        (New-CleanTask 'sfc' $g4 'Проверка системных файлов (SFC)' 'Ищет и чинит повреждённые файлы Windows' $false -Badge 'долго' `
            -Action { $c = Run 'sfc.exe' '/scannow'; Log "   SFC, код: $c" }),

        (New-CleanTask 'winget' $g4 'Обновить программы (winget)' 'Обновляет всё, что умеет winget, в тихом режиме' $false -Badge 'долго' `
            -Action {
                if (Get-Command winget) {
                    $c = Run 'cmd.exe' '/c winget upgrade --all --silent --accept-source-agreements --accept-package-agreements'
                    Log "   winget, код: $c"
                } else { Log '   winget не найден, пропускаю' }
            })
    )

    if ($Mode -eq 'Meta') { return $T }

    # ------------------------------------------------------------------
    #  Быстрый файловый слой (C#): удаление и подсчёт с проверкой флага Cancel
    # ------------------------------------------------------------------
    $CleanerSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;

public static class Cleaner
{
    static bool Stop(Hashtable s) { return s != null && (s["Cancel"] is bool) && (bool)s["Cancel"]; }

    public static long Size(string path, Hashtable sync)
    {
        long total = 0;
        try
        {
            if (File.Exists(path)) return new FileInfo(path).Length;
            Stack<string> stack = new Stack<string>();
            stack.Push(path);
            while (stack.Count > 0)
            {
                if (Stop(sync)) break;
                DirectoryInfo di = new DirectoryInfo(stack.Pop());
                try
                {
                    foreach (FileInfo f in di.EnumerateFiles()) { try { total += f.Length; } catch { } }
                    foreach (DirectoryInfo d in di.EnumerateDirectories())
                    {
                        if ((d.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                        stack.Push(d.FullName);
                    }
                }
                catch { }
            }
        }
        catch { }
        return total;
    }

    public static void Delete(string path, Hashtable sync)
    {
        try
        {
            if (File.Exists(path)) { DelFile(path); return; }
            DirectoryInfo di = new DirectoryInfo(path);
            if ((di.Attributes & FileAttributes.ReparsePoint) != 0) { try { di.Delete(); } catch { } return; }
            DelDir(di, sync);
        }
        catch { }
    }

    static void DelFile(string p)
    {
        try { File.SetAttributes(p, FileAttributes.Normal); } catch { }
        try { File.Delete(p); } catch { }
    }

    static void DelDir(DirectoryInfo di, Hashtable sync)
    {
        if (Stop(sync)) return;
        try
        {
            foreach (FileInfo f in di.GetFiles()) { if (Stop(sync)) return; DelFile(f.FullName); }
            foreach (DirectoryInfo d in di.GetDirectories())
            {
                if (Stop(sync)) return;
                if ((d.Attributes & FileAttributes.ReparsePoint) != 0) { try { d.Delete(); } catch { } }
                else DelDir(d, sync);
            }
        }
        catch { }
        try { di.Delete(); } catch { }
    }

    public static List<KeyValuePair<long, string>> Big(string root, long minSize, int top, Hashtable sync)
    {
        List<KeyValuePair<long, string>> res = new List<KeyValuePair<long, string>>();
        Stack<string> stack = new Stack<string>();
        stack.Push(root);
        string win = Path.Combine(root, "Windows");
        while (stack.Count > 0)
        {
            if (Stop(sync)) break;
            DirectoryInfo di = new DirectoryInfo(stack.Pop());
            try
            {
                foreach (FileInfo f in di.EnumerateFiles())
                {
                    try
                    {
                        if (f.Length < minSize) continue;
                        int at = (int)f.Attributes;
                        if ((at & 0x1000) != 0 || (at & 0x400000) != 0 || (at & 0x40000) != 0) continue;
                        string n = f.Name.ToLowerInvariant();
                        if (n == "pagefile.sys" || n == "hiberfil.sys" || n == "swapfile.sys") continue;
                        res.Add(new KeyValuePair<long, string>(f.Length, f.FullName));
                    }
                    catch { }
                }
                foreach (DirectoryInfo d in di.EnumerateDirectories())
                {
                    if ((d.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                    if (string.Equals(d.FullName, win, StringComparison.OrdinalIgnoreCase)) continue;
                    if (d.Name == "$Recycle.Bin" || d.Name == "System Volume Information") continue;
                    stack.Push(d.FullName);
                }
            }
            catch { }
        }
        res.Sort(delegate (KeyValuePair<long, string> a, KeyValuePair<long, string> b) { return b.Key.CompareTo(a.Key); });
        if (res.Count > top) res.RemoveRange(top, res.Count - top);
        return res;
    }
}
'@
    function Ensure-Cleaner { if (-not ('Cleaner' -as [type])) { Add-Type -TypeDefinition $CleanerSource -Language CSharp } }

    function Clear-Paths([string[]]$Patterns) {
        foreach ($p in $Patterns) {
            foreach ($i in (Get-ChildItem -Path $p -Force)) {
                if (Cancelled) { return }
                [Cleaner]::Delete($i.FullName, $Sync)
            }
        }
    }
    function Get-Size([string[]]$Patterns) {
        $sum = [long]0
        foreach ($p in $Patterns) {
            foreach ($i in (Get-ChildItem -Path $p -Force)) {
                if (Cancelled) { return $sum }
                $sum += [Cleaner]::Size($i.FullName, $Sync)
            }
        }
        $sum
    }

    # ------------------------------------------------------------------
    #  Настройки Windows и урезка
    # ------------------------------------------------------------------
    function Ent($P, $N, $On, $Off = $null, $T = 'DWord') { @{ P = $P; N = $N; On = $On; Off = $Off; T = $T } }
    function Sv($N, $D) { @{ N = $N; D = $D } }
    function Tk($Path, $Name) { @{ Path = $Path; Name = $Name } }
    function Tw([hashtable]$h) {
        $d = @{ Badge = ''; Explorer = $false; Rec = $false; Data = $null; On = $null; Off = $null; Detect = $null }
        foreach ($k in $h.Keys) { $d[$k] = $h[$k] }
        [pscustomobject]$d
    }

    $gPriv = 'Приватность и телеметрия'; $gAds = 'Реклама и навязчивое'; $gSec = 'Защитник и безопасность'
    $gUpd = 'Обновления Windows'; $gSvc = 'Службы'; $gUi = 'Интерфейс'; $gPerf = 'Производительность'
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $cdmEntries = @()
    foreach ($n in 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled', 'SubscribedContent-310093Enabled',
                   'SubscribedContent-338393Enabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled',
                   'RotatingLockScreenOverlayEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
                   'SilentInstalledAppsEnabled', 'ContentDeliveryAllowed', 'FeatureManagementEnabled') {
        $cdmEntries += (Ent $cdm $n 0 1)
    }
    $cdmEntries += (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1)
    $cdmEntries += (Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0 1)
    $defRT = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
    $cls = '{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'

    $TW = @(
        (Tw @{ Id = 'telemetry'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Отключить телеметрию'
            Desc = 'Политика: минимальный уровень сбора данных, без запросов обратной связи'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1),
                     (Ent 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0)) }),
        (Tw @{ Id = 'diagsvc'; Group = $gPriv; Rec = $true; Kind = 'svc'; Title = 'Службы сбора данных'
            Desc = 'DiagTrack (Функциональные возможности для подключённых пользователей) и dmwappushservice'
            Data = @((Sv 'DiagTrack' 'auto'), (Sv 'dmwappushservice' 'demand')) }),
        (Tw @{ Id = 'telemetrytasks'; Group = $gPriv; Rec = $true; Kind = 'task'; Title = 'Задачи телеметрии в планировщике'
            Desc = 'Compatibility Appraiser, CEIP, обратная связь, диагностика дисков'
            Data = @((Tk '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'),
                     (Tk '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'),
                     (Tk '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'),
                     (Tk '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'),
                     (Tk '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'),
                     (Tk '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'),
                     (Tk '\Microsoft\Windows\DiskDiagnostic\' 'Microsoft-Windows-DiskDiagnosticDataCollector')) }),
        (Tw @{ Id = 'adid'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Рекламный идентификатор'
            Desc = 'Приложения не получают персональный рекламный ID'
            Data = @((Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1)) }),
        (Tw @{ Id = 'activity'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'История действий (Timeline)'
            Desc = 'Не собирать и не отправлять в Microsoft журнал действий'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0)) }),
        (Tw @{ Id = 'wer'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Отчёты об ошибках Windows'
            Desc = 'Не показывать окна и не отправлять отчёты о сбоях'
            Data = @((Ent 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1)) }),
        (Tw @{ Id = 'feedback'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Запросы отзывов'
            Desc = 'Убирает всплывающие «Как вам Windows?»'
            Data = @((Ent 'HKCU:\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0)) }),
        (Tw @{ Id = 'ai'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Copilot и Recall'
            Desc = 'Политики: отключить Copilot и анализ действий (Recall)'
            Data = @((Ent 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1)) }),
        (Tw @{ Id = 'bing'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Поиск Bing в меню «Пуск»'
            Desc = 'Поиск по компьютеру без интернет-подсказок и Cortana'
            Data = @((Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0 1),
                     (Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0 1),
                     (Ent 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0)) }),
        (Tw @{ Id = 'delivery'; Group = $gPriv; Rec = $true; Kind = 'reg'; Title = 'Раздача обновлений другим ПК (P2P)'
            Desc = 'Обновления только с серверов Microsoft, без раздачи вашего канала'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0)) }),
        (Tw @{ Id = 'location'; Group = $gPriv; Rec = $false; Kind = 'reg'; Title = 'Геолокация'
            Desc = 'Отключает определение местоположения. Погода и карты могут работать хуже'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1)) }),

        (Tw @{ Id = 'ads'; Group = $gAds; Rec = $true; Kind = 'reg'; Title = 'Реклама и «рекомендации»'
            Desc = 'В меню «Пуск», на экране блокировки, в уведомлениях и в Проводнике; автоустановка приложений'
            Data = $cdmEntries }),
        (Tw @{ Id = 'widgets'; Group = $gAds; Rec = $true; Kind = 'reg'; Title = 'Виджеты и «Новости и интересы»'
            Desc = 'Убирает панель виджетов с панели задач'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)) }),

        (Tw @{ Id = 'defender'; Group = $gSec; Rec = $false; Kind = 'custom'; Badge = 'осторожно'; Title = 'Отключить Защитник Windows (антивирус)'
            Desc = 'Защита в реальном времени, поведенческий анализ, облако, задачи. Нужен другой антивирус или осознанный риск'
            Detect = { $p = Get-MpPreference; [bool]($p -and $p.DisableRealtimeMonitoring) }
            On = {
                Set-MpPreference -DisableRealtimeMonitoring $true -DisableBehaviorMonitoring $true -DisableIOAVProtection $true -DisableScriptScanning $true -DisableBlockAtFirstSeen $true -MAPSReporting 0 -SubmitSamplesConsent 2
                RegSet $defRT 'DisableAntiSpyware' 1
                foreach ($n in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableIOAVProtection', 'DisableScriptScanning') { RegSet "$defRT\Real-Time Protection" $n 1 }
                RegSet "$defRT\Spynet" 'SpynetReporting' 0
                RegSet "$defRT\Spynet" 'SubmitSamplesConsent' 2
                Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' | Disable-ScheduledTask | Out-Null
            }
            Off = {
                Set-MpPreference -DisableRealtimeMonitoring $false -DisableBehaviorMonitoring $false -DisableIOAVProtection $false -DisableScriptScanning $false -DisableBlockAtFirstSeen $false -MAPSReporting 2 -SubmitSamplesConsent 1
                RegDel $defRT 'DisableAntiSpyware'
                foreach ($n in 'DisableRealtimeMonitoring', 'DisableBehaviorMonitoring', 'DisableOnAccessProtection', 'DisableIOAVProtection', 'DisableScriptScanning') { RegDel "$defRT\Real-Time Protection" $n }
                RegDel "$defRT\Spynet" 'SpynetReporting'
                RegDel "$defRT\Spynet" 'SubmitSamplesConsent'
                Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' | Enable-ScheduledTask | Out-Null
            } }),
        (Tw @{ Id = 'defcloud'; Group = $gSec; Rec = $false; Kind = 'reg'; Title = 'Облачная защита и отправка образцов'
            Desc = 'Защитник остаётся включённым, но ничего не отправляет в Microsoft'
            Data = @((Ent "$defRT\Spynet" 'SpynetReporting' 0), (Ent "$defRT\Spynet" 'SubmitSamplesConsent' 2)) }),
        (Tw @{ Id = 'smartscreen'; Group = $gSec; Rec = $false; Kind = 'reg'; Badge = 'осторожно'; Title = 'SmartScreen'
            Desc = 'Не проверять скачанные файлы и сайты через облако Microsoft'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0),
                     (Ent 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'Warn' 'String'),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 0)) }),

        (Tw @{ Id = 'noautoupdate'; Group = $gUpd; Rec = $false; Kind = 'reg'; Badge = 'осторожно'; Title = 'Автоматическая установка обновлений'
            Desc = 'Windows будет только уведомлять. Обновления безопасности придётся ставить вручную'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1)) }),
        (Tw @{ Id = 'nodrivers'; Group = $gUpd; Rec = $false; Kind = 'reg'; Title = 'Драйверы через Центр обновления'
            Desc = 'Windows не будет заменять драйверы видеокарты и устройств своими'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1)) }),

        (Tw @{ Id = 'xbox'; Group = $gSvc; Rec = $false; Kind = 'svc'; Title = 'Службы Xbox'
            Desc = 'Нужны для Xbox, Game Pass и входа в игры Microsoft Store'
            Data = @((Sv 'XblAuthManager' 'demand'), (Sv 'XblGameSave' 'demand'), (Sv 'XboxNetApiSvc' 'demand'), (Sv 'XboxGipSvc' 'demand')) }),
        (Tw @{ Id = 'miscsvc'; Group = $gSvc; Rec = $true; Kind = 'svc'; Title = 'Редко нужные службы'
            Desc = 'Факс, демо-режим магазина, карты, медиасервер, геолокация'
            Data = @((Sv 'Fax' 'demand'), (Sv 'RetailDemo' 'demand'), (Sv 'MapsBroker' 'delayed-auto'), (Sv 'WMPNetworkSvc' 'demand'), (Sv 'lfsvc' 'demand')) }),
        (Tw @{ Id = 'sysmain'; Group = $gSvc; Rec = $false; Kind = 'svc'; Title = 'SysMain (Superfetch)'
            Desc = 'Предзагрузка программ в память. Имеет смысл отключать на SSD'
            Data = @((Sv 'SysMain' 'auto')) }),
        (Tw @{ Id = 'wsearch'; Group = $gSvc; Rec = $false; Kind = 'svc'; Title = 'Индексация поиска'
            Desc = 'Снижает нагрузку на диск, но поиск файлов станет медленнее'
            Data = @((Sv 'WSearch' 'delayed-auto')) }),
        (Tw @{ Id = 'spooler'; Group = $gSvc; Rec = $false; Kind = 'svc'; Title = 'Диспетчер печати'
            Desc = 'Если принтеров нет: меньше служб и меньше поверхность атаки'
            Data = @((Sv 'Spooler' 'auto')) }),

        (Tw @{ Id = 'classicmenu'; Group = $gUi; Rec = $false; Kind = 'custom'; Badge = 'Win11'; Explorer = $true; Title = 'Классическое контекстное меню'
            Desc = 'Полное меню по правой кнопке без «Показать дополнительные параметры»'
            Detect = { Test-Path "HKCU:\Software\Classes\CLSID\$cls\InprocServer32" }
            On = { $k = "HKCU:\Software\Classes\CLSID\$cls\InprocServer32"; New-Item -Path $k -Force | Out-Null; Set-ItemProperty -Path $k -Name '(default)' -Value '' }
            Off = { Remove-Item -Path "HKCU:\Software\Classes\CLSID\$cls" -Recurse -Force } }),
        (Tw @{ Id = 'fileext'; Group = $gUi; Rec = $true; Kind = 'reg'; Explorer = $true; Title = 'Расширения файлов и скрытые файлы'
            Desc = 'Показывать расширения (.exe, .txt) и скрытые файлы в Проводнике'
            Data = @((Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0 1),
                     (Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1 2)) }),
        (Tw @{ Id = 'thispc'; Group = $gUi; Rec = $false; Kind = 'reg'; Explorer = $true; Title = 'Проводник открывается на «Этот компьютер»'
            Desc = 'Вместо «Главной» с недавними файлами'
            Data = @((Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1 2)) }),
        (Tw @{ Id = 'sticky'; Group = $gUi; Rec = $true; Kind = 'reg'; Title = 'Окна залипания клавиш'
            Desc = 'Не вылезает окно при пяти нажатиях Shift'
            Data = @((Ent 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' '510' 'String'),
                     (Ent 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' '126' 'String'),
                     (Ent 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' '62' 'String')) }),
        (Tw @{ Id = 'mouseaccel'; Group = $gUi; Rec = $false; Kind = 'reg'; Title = 'Ускорение мыши'
            Desc = 'Отключает «повышенную точность указателя». Действует после перезахода в систему'
            Data = @((Ent 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' '1' 'String'),
                     (Ent 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' '6' 'String'),
                     (Ent 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' '10' 'String')) }),

        (Tw @{ Id = 'gamedvr'; Group = $gPerf; Rec = $true; Kind = 'reg'; Title = 'Xbox Game Bar и запись игр (Game DVR)'
            Desc = 'Убирает фоновую запись и оверлей, немного разгружает систему в играх'
            Data = @((Ent 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 1),
                     (Ent 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 1),
                     (Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0)) }),
        (Tw @{ Id = 'power'; Group = $gPerf; Rec = $false; Kind = 'custom'; Title = 'Схема питания «Максимальная производительность»'
            Desc = 'Для настольных ПК. На ноутбуке заметно сократит время от батареи'
            Detect = { ((powercfg /getactivescheme) | Out-String) -match 'Ultimate|High performance|Максимальная|Высокая|8c5e7fda|e9a42b02' }
            On = {
                $o = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String)
                if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { powercfg /setactive $Matches[1] }
                else { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
            }
            Off = { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e } }),
        (Tw @{ Id = 'faststart'; Group = $gPerf; Rec = $false; Kind = 'reg'; Title = 'Быстрый запуск'
            Desc = 'Отключает гибридное выключение: завершение работы станет полным, лечит часть странных багов'
            Data = @((Ent 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 1)) }),
        (Tw @{ Id = 'bgapps'; Group = $gPerf; Rec = $false; Kind = 'reg'; Badge = 'осторожно'; Title = 'Фоновая работа приложений Store'
            Desc = 'Запрещает приложениям работать в фоне. Часть уведомлений перестанет приходить'
            Data = @((Ent 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2)) }),
        (Tw @{ Id = 'onedrive'; Group = $gPerf; Rec = $false; Kind = 'custom'; Badge = 'удаление'; Title = 'Удалить OneDrive'
            Desc = 'Удаляет программу, файлы в папке OneDrive остаются. Откат: повторная установка'
            Detect = { -not ((Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") -or (Test-Path "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe") -or (Test-Path "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")) }
            On = {
                Stop-Process -Name OneDrive -Force
                $s = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
                if (-not (Test-Path $s)) { $s = "$env:SystemRoot\System32\OneDriveSetup.exe" }
                [void](Run $s '/uninstall')
            }
            Off = { $s = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"; if (Test-Path $s) { [void](Run $s '') } } })
    )

    function Test-Tweak($t) {
        if ($t.Kind -eq 'reg') {
            foreach ($e in $t.Data) { if ("$(RegGet $e.P $e.N)" -ne "$($e.On)") { return $false } }
            return $true
        }
        if ($t.Kind -eq 'svc') {
            foreach ($s in $t.Data) { $sv = Get-Service -Name $s.N; if ($sv -and $sv.StartType -ne 'Disabled') { return $false } }
            return $true
        }
        if ($t.Kind -eq 'task') {
            foreach ($p in $t.Data) { $tk = Get-ScheduledTask -TaskPath $p.Path -TaskName $p.Name; if ($tk -and $tk.State -ne 'Disabled') { return $false } }
            return $true
        }
        return [bool](& $t.Detect)
    }
    function Set-Tweak($t, [bool]$on) {
        if ($t.Kind -eq 'reg') {
            foreach ($e in $t.Data) {
                if ($on) { RegSet $e.P $e.N $e.On $e.T }
                elseif ($null -eq $e.Off) { RegDel $e.P $e.N }
                else { RegSet $e.P $e.N $e.Off $e.T }
            }
        } elseif ($t.Kind -eq 'svc') {
            foreach ($s in $t.Data) {
                if ($on) { & sc.exe config $s.N start= disabled | Out-Null; Stop-Service -Name $s.N -Force }
                else { & sc.exe config $s.N start= $s.D | Out-Null }
            }
        } elseif ($t.Kind -eq 'task') {
            foreach ($p in $t.Data) {
                if ($on) { Disable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name | Out-Null }
                else { Enable-ScheduledTask -TaskPath $p.Path -TaskName $p.Name | Out-Null }
            }
        } else {
            if ($on) { & $t.On } else { & $t.Off }
        }
    }

    # ------------------------------------------------------------------
    #  Режимы работы
    # ------------------------------------------------------------------
    if ($Mode -eq 'Scan') {
        Ensure-Cleaner
        foreach ($t in @($T | Where-Object { $Keys -contains $_.Key })) {
            if (Cancelled) { break }
            if ($t.Paths) { Put 'size' @{ Key = $t.Key; Size = (Get-Size $t.Paths) } }
        }
        Put 'done' @{ Panel = 'clean'; Kind = 'scan' }
        return
    }

    if ($Mode -eq 'Clean') {
        Ensure-Cleaner
        $sel = @($T | Where-Object { $Keys -contains $_.Key })
        $free0 = Free
        Log ('Старт очистки. Свободно: {0:N2} ГБ' -f ($free0 / 1GB))
        $i = 0; $cancelled = $false
        foreach ($t in $sel) {
            if (Cancelled) { $cancelled = $true; Log 'Остановлено пользователем'; break }
            $i++
            Put 'task' @{ Panel = 'clean'; Key = $t.Key; State = 'run'; Index = $i; Total = $sel.Count; Freed = 0 }
            Log ">> $($t.Title)"
            $before = Free
            $state = 'ok'
            try {
                if ($t.Action) { & $t.Action $t } else { Clear-Paths $t.Paths }
            } catch {
                Log "   ошибка: $($_.Exception.Message)"
                $state = 'fail'
            }
            $freed = [math]::Max(0, (Free) - $before)
            Put 'task' @{ Panel = 'clean'; Key = $t.Key; State = $state; Index = $i; Total = $sel.Count; Freed = $freed }
        }
        $free1 = Free
        $total = [math]::Max(0, $free1 - $free0)
        Log ('Готово. Освобождено: {0:N0} МБ. Свободно: {1:N2} ГБ' -f ($total / 1MB), ($free1 / 1GB))
        Put 'done' @{ Panel = 'clean'; Kind = 'clean'; Freed = $total; Cancelled = $cancelled }
        return $total
    }

    if ($Mode -eq 'Big') {
        Ensure-Cleaner
        $res = [Cleaner]::Big($Keys[0], 200MB, 100, $Sync)
        $list = @($res | ForEach-Object { @{ Size = [double]$_.Key; Path = [string]$_.Value } })
        Put 'big' $list
        Put 'done' @{ Panel = 'big'; Kind = 'big'; Cancelled = (Cancelled) }
        return
    }

    if ($Mode -eq 'Apps') {
        $hide = 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
                'Microsoft.Windows.*', 'MicrosoftWindows.*', 'Microsoft.UI.*', 'Microsoft.VCLibs*', 'Microsoft.NET*', 'Microsoft.WindowsAppRuntime*',
                '*Extension*', 'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal', 'Microsoft.Paint',
                'Microsoft.ScreenSketch', 'Microsoft.WindowsCamera', 'Microsoft.MicrosoftEdge*', 'Microsoft.AAD.*', 'Microsoft.LockApp',
                'Microsoft.CredDialogHost', 'Microsoft.AccountsControl', 'Microsoft.BioEnrollment', 'Microsoft.ECApp',
                'Microsoft.AsyncTextService', 'NcsiUwpApp', 'Microsoft.Win32WebViewHost', 'Microsoft.XboxGameCallableUI', 'Windows.*'
        $bloat = '*549981C3F5F10*', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingSearch',
                 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.Microsoft3DViewer', 'Microsoft.MicrosoftOfficeHub',
                 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MixedReality.Portal', 'Microsoft.OneConnect', 'Microsoft.People',
                 'Microsoft.PowerAutomateDesktop', 'Microsoft.SkypeApp', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps',
                 'Microsoft.YourPhone', 'Microsoft.Clipchamp', 'MicrosoftTeams', 'MSTeams', 'Microsoft.GamingApp', 'Microsoft.Xbox*',
                 'Microsoft.Wallet', 'Microsoft.OutlookForWindows', 'king.com.*', 'SpotifyAB.*', '*Disney*', '*Netflix*', '*TikTok*',
                 '*Instagram*', '*Facebook*', '*Twitter*', '*LinkedIn*', '*AmazonAlexa*', '*Duolingo*', '*Flipboard*', '*Hulu*',
                 '*PandoraMedia*', '*AdobePhotoshopExpress*', '*Roblox*', '*EclipseManager*', '*ActiproSoftware*', '*HiddenCity*'
        $names = @{ 'Microsoft.549981C3F5F10' = 'Cortana'; 'Microsoft.YourPhone' = 'Phone Link (Ваш телефон)'; 'Microsoft.ZuneMusic' = 'Media Player / Groove'
                    'Microsoft.ZuneVideo' = 'Кино и ТВ'; 'Microsoft.GetHelp' = 'Техническая поддержка'; 'Microsoft.Getstarted' = 'Советы'
                    'Microsoft.MicrosoftOfficeHub' = 'Office (реклама)'; 'Microsoft.People' = 'Люди'; 'Microsoft.WindowsMaps' = 'Карты' }
        $seen = @{}; $list = @()
        foreach ($p in (Get-AppxPackage -AllUsers)) {
            if ($p.IsFramework -or $p.NonRemovable -or $p.SignatureKind -eq 'System') { continue }
            $n = $p.Name
            if ($seen.ContainsKey($n)) { continue }
            $skip = $false
            foreach ($h in $hide) { if ($n -like $h) { $skip = $true; break } }
            if ($skip) { continue }
            $seen[$n] = $true
            $rec = $false
            foreach ($b in $bloat) { if ($n -like $b) { $rec = $true; break } }
            if ($names.ContainsKey($n)) { $title = $names[$n] }
            else { $title = ($n -replace '^Microsoft\.', '') -creplace '([a-z0-9])([A-Z])', '$1 $2' }
            $list += @{ Name = $n; Title = $title; Rec = $rec }
        }
        $list = @($list | Sort-Object @{ Expression = { -not $_.Rec } }, @{ Expression = { $_.Title } })
        Put 'apps' $list
        Put 'done' @{ Panel = 'apps'; Kind = 'list' }
        return
    }

    if ($Mode -eq 'RemoveApps') {
        $i = 0; $okc = 0; $total = $Keys.Count
        foreach ($n in $Keys) {
            if (Cancelled) { Log 'Остановлено пользователем'; break }
            $i++
            Put 'task' @{ Panel = 'apps'; Key = $n; State = 'run'; Index = $i; Total = $total; Freed = 0 }
            Log ">> Удаляю приложение: $n"
            Get-AppxPackage -AllUsers -Name $n | Remove-AppxPackage -AllUsers
            if ($Opt -and $Opt.Deprov) {
                Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $n } | Remove-AppxProvisionedPackage -Online | Out-Null
            }
            if (-not (Get-AppxPackage -AllUsers -Name $n)) { $okc++; $st = 'ok' } else { $st = 'fail'; Log '   не удалось удалить' }
            Put 'task' @{ Panel = 'apps'; Key = $n; State = $st; Index = $i; Total = $total; Freed = 0 }
        }
        Put 'done' @{ Panel = 'apps'; Kind = 'remove'; Count = $okc; Total = $total }
        return
    }

    if ($Mode -eq 'TweaksMeta') {
        $out = foreach ($t in $TW) {
            [pscustomobject]@{ Id = $t.Id; Group = $t.Group; Title = $t.Title; Desc = $t.Desc; Rec = $t.Rec; Badge = $t.Badge; State = (Test-Tweak $t) }
        }
        Put 'tweaks' @($out)
        $ms = Get-MpComputerStatus
        Put 'def' @{ Known = [bool]$ms; Tamper = [bool]($ms -and $ms.IsTamperProtected); RealTime = [bool]($ms -and $ms.RealTimeProtectionEnabled) }
        Put 'done' @{ Panel = 'tweaks'; Kind = 'list' }
        return
    }

    if ($Mode -eq 'Tweaks') {
        if ($Opt -and $Opt.Restore) {
            try { Checkpoint-Computer -Description 'Pruner' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; Log 'Точка восстановления создана' }
            catch { Log ('Точка восстановления не создана: ' + $_.Exception.Message) }
        }
        $i = 0; $okc = 0; $total = $Keys.Count; $restartExplorer = $false
        foreach ($k in $Keys) {
            if (Cancelled) { Log 'Остановлено пользователем'; break }
            $i++
            $id, $flag = $k.Split('=')
            $t = $TW | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if (-not $t) { continue }
            $on = ($flag -eq '1')
            Put 'task' @{ Panel = 'tweaks'; Key = $id; State = 'run'; Index = $i; Total = $total; Freed = 0 }
            Log (">> " + $(if ($on) { 'Применяю' } else { 'Откатываю' }) + ": $($t.Title)")
            $st = 'ok'
            try { Set-Tweak $t $on } catch { Log "   ошибка: $($_.Exception.Message)"; $st = 'fail' }
            if ($st -eq 'ok' -and ((Test-Tweak $t) -ne $on)) {
                $st = 'fail'
                if ($id -eq 'defender') { Log '   Защитник остался включён. Выключи «Защиту от подделки» в Безопасности Windows и повтори' }
                else { Log '   изменение не закрепилось (возможно, блокирует политика или защита)' }
            }
            if ($st -eq 'ok') { $okc++; if ($t.Explorer) { $restartExplorer = $true } }
            Put 'task' @{ Panel = 'tweaks'; Key = $id; State = $st; Index = $i; Total = $total; Freed = 0 }
        }
        if ($restartExplorer) { Stop-Process -Name explorer -Force }
        Put 'done' @{ Panel = 'tweaks'; Kind = 'apply'; Count = $okc; Total = $total }
        return
    }
}
$script:EngineText = $Engine.ToString()

# =====================================================================
#  Тихий режим (запуск по расписанию)
# =====================================================================
if ($Auto) {
    $meta = @(& $Engine -Mode 'Meta' -Keys @() -Sync $null -Opt $null)
    $keys = @($meta | Where-Object { $_.Default } | ForEach-Object { $_.Key })
    $res  = @(& $Engine -Mode 'Clean' -Keys $keys -Sync $null -Opt $null)
    $freed = [double]($res | Select-Object -Last 1)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = [System.Drawing.SystemIcons]::Information
    $n.Visible = $true
    $n.ShowBalloonTip(6000, 'Pruner', ('Автоочистка завершена. Освобождено: {0:N0} МБ' -f ($freed / 1MB)), [System.Windows.Forms.ToolTipIcon]::Info)
    Start-Sleep -Seconds 7
    $n.Dispose()
    exit
}

# =====================================================================
#  ОКНО
# =====================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);'
} catch {}

# Если окно Pruner уже открыто - просто показываем его, вместо второго окна.
# Через именованный Mutex это делалось ненадёжно: если предыдущий запуск падал
# до создания окна, Mutex оставался занят и все следующие запуски молча завершались.
try {
    Add-Type -Namespace Native -Name Win32 -MemberDefinition '
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(System.IntPtr hWnd);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool IsIconic(System.IntPtr hWnd);
    '
    $existing = [Native.Win32]::FindWindow($null, 'Pruner')
    if ($existing -ne [IntPtr]::Zero) {
        if ([Native.Win32]::IsIconic($existing)) { [void][Native.Win32]::ShowWindow($existing, 9) }
        [void][Native.Win32]::SetForegroundWindow($existing)
        exit
    }
} catch {}

# Миграция со старой версии
Unregister-ScheduledTask -TaskName 'PC Helper - weekly cleanup' -Confirm:$false -ErrorAction SilentlyContinue

# С этой точки и до показа окна любая необработанная ошибка раньше приводила
# к тому, что процесс тихо завершался (окно запускается скрытым). Теперь при
# сбое пишем причину в файл и показываем её в окне, вместо полной тишины.
try {

$script:WallDir = Join-Path $script:Root 'assets\wallpapers'
$script:CfgDir  = Join-Path $env:APPDATA 'Pruner'
$script:CfgPath = Join-Path $script:CfgDir 'settings.json'
$script:CfgDefault = @{
    Theme = 'dark'; Wallpaper = ''; Dim = 55; Blur = 5; PanelAlpha = 80; Accent = 'auto'
    Font = 'Segoe UI'; FontSize = 13; Radius = 10; Compact = $false
    Restore = $true; Confirm = $true; SchedDay = 'Sunday'; SchedTime = '12:00'
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Pruner" Width="1100" Height="760" MinWidth="920" MinHeight="620" WindowStartupLocation="CenterScreen"
        Background="{DynamicResource Brush.Bg}" Foreground="{DynamicResource Brush.Text}" FontFamily="Segoe UI"
        FontSize="{DynamicResource FsBase}" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Brush.Bg" Color="#16171B"/>
    <SolidColorBrush x:Key="Brush.Text" Color="#E8EAF0"/>
    <SolidColorBrush x:Key="Brush.Muted" Color="#A5AAB8"/>
    <SolidColorBrush x:Key="Brush.Panel" Color="#CC1C1E23"/>
    <SolidColorBrush x:Key="Brush.Bar" Color="#B3181A1F"/>
    <SolidColorBrush x:Key="Brush.Hover" Color="#1CFFFFFF"/>
    <SolidColorBrush x:Key="Brush.Line" Color="#2AFFFFFF"/>
    <SolidColorBrush x:Key="Brush.Field" Color="#26FFFFFF"/>
    <SolidColorBrush x:Key="Brush.Accent" Color="#7FA8E8"/>
    <SolidColorBrush x:Key="Brush.OnAccent" Color="#101216"/>
    <SolidColorBrush x:Key="Brush.Ok" Color="#86C897"/>
    <SolidColorBrush x:Key="Brush.Warn" Color="#DBB56F"/>
    <SolidColorBrush x:Key="Brush.Err" Color="#E69A9A"/>
    <CornerRadius x:Key="Rad">10</CornerRadius>
    <CornerRadius x:Key="RadS">6</CornerRadius>
    <Thickness x:Key="RowPad">10,9,10,9</Thickness>
    <sys:Double x:Key="FsBase">13</sys:Double>
    <sys:Double x:Key="FsSmall">12</sys:Double>
    <sys:Double x:Key="FsTiny">10.5</sys:Double>
    <sys:Double x:Key="FsHead">20</sys:Double>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Brush.Line}" CornerRadius="4" Margin="1,0"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Brush.Text}"/>
      <Setter Property="Background" Value="{DynamicResource Brush.Field}"/>
      <Setter Property="Padding" Value="16,7,16,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid x:Name="g">
              <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="{DynamicResource RadS}" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <Border x:Name="ov" Background="{DynamicResource Brush.Hover}" CornerRadius="{DynamicResource RadS}" Opacity="0" IsHitTestVisible="False"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ov" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ov" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.15"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="g" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource Brush.OnAccent}"/>
      <Setter Property="Background" Value="{DynamicResource Brush.Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="{DynamicResource Brush.Err}"/>
      <Setter Property="Margin" Value="0"/>
    </Style>

    <Style x:Key="Chk" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{DynamicResource Brush.Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="18" Height="18" VerticalAlignment="Center">
                <Border x:Name="box" CornerRadius="5" BorderThickness="1.5" BorderBrush="{DynamicResource Brush.Muted}"/>
                <Border x:Name="fill" CornerRadius="5" Background="{DynamicResource Brush.Accent}" Opacity="0"/>
                <Path x:Name="mark" Data="M4.5,9.5 L7.5,12.5 L13.5,5.5" Stroke="{DynamicResource Brush.OnAccent}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Opacity="0"/>
              </Grid>
              <ContentPresenter x:Name="cp" Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="HasContent" Value="False"><Setter TargetName="cp" Property="Margin" Value="0"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="fill" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="mark" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="fill" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="mark" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Tab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Brush.Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,2,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="{DynamicResource RadS}" Padding="14,8,14,8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource Brush.Hover}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource Brush.Field}"/>
                <Setter Property="Foreground" Value="{DynamicResource Brush.Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Brush.Text}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" CornerRadius="{DynamicResource RadS}" Padding="12,6,12,6" Background="{DynamicResource Brush.Field}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="{DynamicResource Brush.Line}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource Brush.Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Brush.OnAccent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Slider">
      <Setter Property="Height" Value="22"/>
      <Setter Property="IsMoveToPointEnabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Background="Transparent">
              <Border Height="4" CornerRadius="2" Background="{DynamicResource Brush.Line}" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton><RepeatButton Command="Slider.DecreaseLarge" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Cursor="Hand"><Thumb.Template><ControlTemplate TargetType="Thumb"><Ellipse Width="16" Height="16" Fill="{DynamicResource Brush.Accent}"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Command="Slider.IncreaseLarge" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{DynamicResource Brush.Text}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Brush.Text}"/>
      <Setter Property="Padding" Value="8,5,8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{DynamicResource Brush.Field}" CornerRadius="{DynamicResource RadS}" Padding="{TemplateBinding Padding}">
              <ScrollViewer x:Name="PART_ContentHost"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Image x:Name="Wall" Stretch="UniformToFill" RenderTransformOrigin="0.5,0.5">
      <Image.RenderTransform><ScaleTransform ScaleX="1.05" ScaleY="1.05"/></Image.RenderTransform>
      <Image.Effect><BlurEffect x:Name="WallBlur" Radius="5" KernelType="Gaussian" RenderingBias="Performance"/></Image.Effect>
    </Image>
    <Rectangle x:Name="Tint" IsHitTestVisible="False"/>

    <Grid Margin="18,14,18,16">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="4,0,4,10">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Pruner" FontSize="{DynamicResource FsHead}" FontWeight="SemiBold"/>
          <TextBlock Text="очистка и настройка Windows" Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" VerticalAlignment="Bottom" Margin="12,0,0,3"/>
        </StackPanel>
        <StackPanel HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="DiskInfo" FontSize="{DynamicResource FsSmall}" Foreground="{DynamicResource Brush.Muted}" HorizontalAlignment="Right"/>
          <Border Width="200" Height="5" CornerRadius="2.5" Background="{DynamicResource Brush.Line}" Margin="0,5,0,0" HorizontalAlignment="Right">
            <Border x:Name="DiskFill" CornerRadius="2.5" Background="{DynamicResource Brush.Accent}" HorizontalAlignment="Left" Width="0"/>
          </Border>
        </StackPanel>
      </Grid>

      <Border Grid.Row="1" Background="{DynamicResource Brush.Bar}" CornerRadius="{DynamicResource Rad}" Padding="4" Margin="0,0,0,10">
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="TabClean" Content="Очистка" GroupName="tabs" IsChecked="True" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabApps" Content="Приложения" GroupName="tabs" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabTweaks" Content="Система" GroupName="tabs" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabStart" Content="Автозагрузка" GroupName="tabs" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabBig" Content="Большие файлы" GroupName="tabs" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabLog" Content="Журнал" GroupName="tabs" Style="{StaticResource Tab}"/>
          <RadioButton x:Name="TabSet" Content="Настройки" GroupName="tabs" Style="{StaticResource Tab}"/>
        </StackPanel>
      </Border>

      <Border Grid.Row="2" Background="{DynamicResource Brush.Panel}" CornerRadius="{DynamicResource Rad}" Padding="16,14,16,10">
        <Grid>
          <Grid x:Name="PanelClean">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Margin="0,0,0,10">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnClean" Content="Очистить" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnScan" Content="Анализ" Style="{StaticResource Btn}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <TextBlock Text="Можно освободить: " Foreground="{DynamicResource Brush.Muted}"/>
                <TextBlock x:Name="Reclaim" Text="—" FontWeight="SemiBold"/>
              </StackPanel>
            </Grid>
            <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="CleanList" Margin="0,0,10,0"/></ScrollViewer>
          </Grid>

          <Grid x:Name="PanelApps" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Margin="0,0,0,8">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnApps" Content="Удалить выбранные" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnAppsRec" Content="Выбрать лишнее" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnAppsNone" Content="Снять выбор" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnAppsRefresh" Content="Обновить список" Style="{StaticResource Btn}"/>
              </StackPanel>
              <CheckBox x:Name="AppsDeprov" Content="Убрать и из образа системы" IsChecked="True" Style="{StaticResource Chk}" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
            <TextBlock Grid.Row="1" Text="Системные компоненты Windows, Microsoft Store и нужные утилиты скрыты. Здесь только то, что можно удалять." Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" Margin="2,0,0,8" TextWrapping="Wrap"/>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="AppsList" Margin="0,0,10,0"/></ScrollViewer>
          </Grid>

          <Grid x:Name="PanelTweaks" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid Margin="0,0,0,8">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnTw" Content="Применить" Style="{StaticResource Primary}"/>
                <Button x:Name="BtnTwRec" Content="Рекомендуемое" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnTwMax" Content="Максимум" Style="{StaticResource Btn}"/>
                <Button x:Name="BtnTwReset" Content="Сбросить выбор" Style="{StaticResource Btn}"/>
              </StackPanel>
              <Button x:Name="BtnTamper" Content="Защита от подделки…" Style="{StaticResource Btn}" HorizontalAlignment="Right" Margin="0"/>
            </Grid>
            <TextBlock x:Name="TwHint" Grid.Row="1" Text="Галочка означает, что настройка включена. Снимешь её у применённой настройки, и она откатится. Применяются только изменённые пункты." Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" Margin="2,0,0,8" TextWrapping="Wrap"/>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="TwList" Margin="0,0,10,0"/></ScrollViewer>
          </Grid>

          <Grid x:Name="PanelStart" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8"><Button x:Name="BtnStartRefresh" Content="Обновить" Style="{StaticResource Btn}"/></StackPanel>
            <TextBlock Grid.Row="1" Text="Программы, которые запускаются вместе с Windows. Отключение обратимо: записи не удаляются, а только переключаются." Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" Margin="2,0,0,8" TextWrapping="Wrap"/>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="StartList" Margin="0,0,10,0"/></ScrollViewer>
          </Grid>

          <Grid x:Name="PanelBig" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8"><Button x:Name="BtnBig" Content="Сканировать диск" Style="{StaticResource Primary}"/></StackPanel>
            <TextBlock Grid.Row="1" Text="Файлы от 200 МБ на системном диске, без папки Windows. Удаление отправляет файл в корзину." Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" Margin="2,0,0,8" TextWrapping="Wrap"/>
            <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="BigList" Margin="0,0,10,0"/></ScrollViewer>
          </Grid>

          <Grid x:Name="PanelLog" Visibility="Collapsed">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <Button x:Name="BtnLogOpen" Content="Открыть файл журнала" Style="{StaticResource Btn}"/>
              <Button x:Name="BtnLogClear" Content="Очистить окно" Style="{StaticResource Btn}"/>
            </StackPanel>
            <TextBox x:Name="LogBox" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" FontFamily="Consolas" Padding="12"/>
          </Grid>

          <Grid x:Name="PanelSet" Visibility="Collapsed">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel x:Name="SetHost" Margin="2,0,12,12"/></ScrollViewer>
          </Grid>
        </Grid>
      </Border>

      <Border Grid.Row="3" Background="{DynamicResource Brush.Bar}" CornerRadius="{DynamicResource Rad}" Margin="0,10,0,0" ClipToBounds="True">
        <StackPanel>
          <Border Height="3" Background="{DynamicResource Brush.Line}">
            <Border x:Name="BarFill" Background="{DynamicResource Brush.Accent}" RenderTransformOrigin="0,0.5">
              <Border.RenderTransform><ScaleTransform ScaleX="0"/></Border.RenderTransform>
            </Border>
          </Border>
          <Grid Margin="14,8,14,9">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="Status" Text="Готов к работе" Foreground="{DynamicResource Brush.Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <CheckBox x:Name="SchedSwitch" Content="Автоочистка" Style="{StaticResource Chk}" Margin="0,0,18,0" VerticalAlignment="Center"/>
              <Button x:Name="BtnStop" Content="Остановить" Style="{StaticResource Danger}" IsEnabled="False"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$script:Win = [Windows.Markup.XamlReader]::Parse($xaml)
$script:UI = @{}
foreach ($n in 'Wall', 'WallBlur', 'Tint', 'DiskInfo', 'DiskFill', 'TabClean', 'TabApps', 'TabTweaks', 'TabStart', 'TabBig', 'TabLog', 'TabSet',
               'PanelClean', 'PanelApps', 'PanelTweaks', 'PanelStart', 'PanelBig', 'PanelLog', 'PanelSet',
               'BtnClean', 'BtnScan', 'Reclaim', 'CleanList', 'BtnApps', 'BtnAppsRec', 'BtnAppsNone', 'BtnAppsRefresh', 'AppsDeprov', 'AppsList',
               'BtnTw', 'BtnTwRec', 'BtnTwMax', 'BtnTwReset', 'BtnTamper', 'TwHint', 'TwList', 'BtnStartRefresh', 'StartList',
               'BtnBig', 'BigList', 'BtnLogOpen', 'BtnLogClear', 'LogBox', 'SetHost', 'BarFill', 'Status', 'SchedSwitch', 'BtnStop') {
    $script:UI[$n] = $script:Win.FindName($n)
}

# ---------- состояние ----------
$script:Cfg = $script:CfgDefault.Clone()
$script:Loading = $false
$script:Busy = $false
$script:Worker = $null
$script:Sync = $null
$script:LastMode = ''
$script:Pending = ''
$script:StatusBase = ''
$script:BusyStart = Get-Date
$script:Sizes = @{}
$script:Rows = @{ clean = @{}; apps = @{}; tweaks = @{} }
$script:AppsLoaded = $false
$script:TweaksLoaded = $false
$script:GotDone = $false
$script:FreeBefore = 0.0
$script:Hwnd = [IntPtr]::Zero
$script:BmpPath = $null; $script:Bmp = $null; $script:Cols = $null

# ---------- общие функции ----------
function B([string]$hex) { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)) }
function Say([string]$t) { $script:UI.Status.Text = $t }
function Busy-Say([string]$t) { $script:StatusBase = $t; $script:UI.Status.Text = $t }
function Add-Log([string]$t) { $script:UI.LogBox.AppendText($t + "`r`n"); $script:UI.LogBox.ScrollToEnd() }
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
function Dyn($el, $prop, [string]$key) { $el.SetResourceReference($prop, $key) }

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N2} ГБ' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} МБ' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} КБ' -f ($b / 1KB)) }
    return '0 КБ'
}

function Animate($Target, $Prop, [double]$To, [int]$Ms = 300) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $To
    $a.Duration = [TimeSpan]::FromMilliseconds($Ms)
    $a.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $Target.BeginAnimation($Prop, $a)
}
function Set-Bar([double]$p, [int]$ms = 350) {
    Animate $script:UI.BarFill.RenderTransform ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $p $ms
}
function Set-Pulse([bool]$on) {
    $bar = $script:UI.BarFill
    $bar.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $bar.Opacity = 1
    if ($on) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation
        $a.From = 0.35; $a.To = 1
        $a.Duration = [TimeSpan]::FromMilliseconds(700)
        $a.AutoReverse = $true
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $bar.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    }
}

function Confirm-Action([string]$text) {
    if (-not $script:Cfg['Confirm']) { return $true }
    ([System.Windows.MessageBox]::Show($script:Win, $text, 'Pruner', 'YesNo', 'Warning') -eq 'Yes')
}

function Update-Disk {
    $d = Get-PSDrive -Name $env:SystemDrive.Substring(0, 1)
    $total = $d.Used + $d.Free
    $pct = 0.0
    if ($total -gt 0) { $pct = $d.Used / $total }
    $script:UI.DiskInfo.Text = ('{0} свободно {1:N1} ГБ из {2:N0} ГБ' -f $env:SystemDrive, ($d.Free / 1GB), ($total / 1GB))
    if ($pct -gt 0.9) { Dyn $script:UI.DiskFill ([System.Windows.Controls.Border]::BackgroundProperty) 'Brush.Err' }
    else { Dyn $script:UI.DiskFill ([System.Windows.Controls.Border]::BackgroundProperty) 'Brush.Accent' }
    Animate $script:UI.DiskFill ([System.Windows.FrameworkElement]::WidthProperty) (200 * $pct) 500
}

# ---------- настройки ----------
function Load-Cfg {
    $c = $script:CfgDefault.Clone()
    if (Test-Path $script:CfgPath) {
        try {
            $j = Get-Content -Raw -Path $script:CfgPath -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($c.ContainsKey($p.Name)) { $c[$p.Name] = $p.Value } }
        } catch {}
    }
    $script:Cfg = $c
}
function Save-Cfg {
    try {
        if (-not (Test-Path $script:CfgDir)) { New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null }
        $script:Cfg | ConvertTo-Json | Set-Content -Path $script:CfgPath -Encoding UTF8
    } catch {}
}
$script:SaveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SaveTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:SaveTimer.Add_Tick({ $script:SaveTimer.Stop(); Save-Cfg })
function Save-Soon { $script:SaveTimer.Stop(); $script:SaveTimer.Start() }

# ---------- цвета и обои ----------
function Mix($a, $b, [double]$t) { @(($a[0] * (1 - $t) + $b[0] * $t), ($a[1] * (1 - $t) + $b[1] * $t), ($a[2] * (1 - $t) + $b[2] * $t)) }
function Hex2Rgb([string]$h) { @([Convert]::ToInt32($h.Substring(1, 2), 16), [Convert]::ToInt32($h.Substring(3, 2), 16), [Convert]::ToInt32($h.Substring(5, 2), 16)) }
function Clamp255([double]$x) { [byte][math]::Max(0, [math]::Min(255, [math]::Round($x))) }
function New-Col($rgb, [double]$alpha) { [System.Windows.Media.Color]::FromArgb((Clamp255 $alpha), (Clamp255 $rgb[0]), (Clamp255 $rgb[1]), (Clamp255 $rgb[2])) }
function New-Br($rgb, [double]$alpha) { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color](New-Col $rgb $alpha)) }

# Кладёт значение в словарь ресурсов окна как «голый» .NET-объект.
# Без этого WPF мог получить обёртку PSObject вместо кисти и отказаться применять её к Background.
function Set-Res([string]$key, $value) {
    $script:Win.Resources.set_Item($key, $value.psobject.BaseObject)
}

function Load-Bitmap([string]$path, [bool]$big) {
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = 'OnLoad'
    if ($big) { $bi.DecodePixelWidth = 1920 }
    $bi.UriSource = New-Object System.Uri($path)
    $bi.EndInit()
    $bi.Freeze()
    $bi
}

# Средние цвета верха, середины и низа картинки и «яркий» цвет для акцента
function Get-ImageColors($bmp) {
    $sx = 8 / [double]$bmp.PixelWidth; $sy = 8 / [double]$bmp.PixelHeight
    $small = New-Object System.Windows.Media.Imaging.TransformedBitmap($bmp, (New-Object System.Windows.Media.ScaleTransform($sx, $sy)))
    $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($small, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $pw = $conv.PixelWidth; $ph = $conv.PixelHeight
    $px = New-Object byte[] ($pw * $ph * 4)
    $conv.CopyPixels($px, $pw * 4, 0)
    $sum = @(@(0.0, 0.0, 0.0, 0.0), @(0.0, 0.0, 0.0, 0.0), @(0.0, 0.0, 0.0, 0.0))
    $best = @(120.0, 150.0, 200.0); $bestScore = -1.0
    for ($y = 0; $y -lt $ph; $y++) {
        $band = [math]::Min(2, [int][math]::Floor($y * 3 / $ph))
        for ($x = 0; $x -lt $pw; $x++) {
            $i = ($y * $pw + $x) * 4
            $bl = [double]$px[$i]; $gr = [double]$px[$i + 1]; $rd = [double]$px[$i + 2]
            $sum[$band][0] += $rd; $sum[$band][1] += $gr; $sum[$band][2] += $bl; $sum[$band][3] += 1
            $mx = [math]::Max($rd, [math]::Max($gr, $bl)); $mn = [math]::Min($rd, [math]::Min($gr, $bl))
            $score = ($mx - $mn) * ($mx / 255.0)
            if ($score -gt $bestScore) { $bestScore = $score; $best = @($rd, $gr, $bl) }
        }
    }
    $avg = @()
    foreach ($s in $sum) { $n = [math]::Max(1, $s[3]); $avg += , @(($s[0] / $n), ($s[1] / $n), ($s[2] / $n)) }
    $m = [math]::Max(1, [math]::Max($best[0], [math]::Max($best[1], $best[2])))
    $k = 215 / $m
    @{ Top = $avg[0]; Mid = $avg[1]; Bot = $avg[2]; Vivid = @([math]::Min(255, $best[0] * $k), [math]::Min(255, $best[1] * $k), [math]::Min(255, $best[2] * $k)) }
}

function Set-TitleBar([bool]$dark) {
    if ($script:Hwnd -eq [IntPtr]::Zero) { return }
    $v = [int]$dark
    try {
        [void][Win32.Dwm]::DwmSetWindowAttribute($script:Hwnd, 20, [ref]$v, 4)
        [void][Win32.Dwm]::DwmSetWindowAttribute($script:Hwnd, 19, [ref]$v, 4)
    } catch {}
}

# Применяет все настройки внешнего вида: палитру, обои с градиентом, шрифт, скругления
# Ошибка в оформлении не должна мешать запуску: пишем её в журнал и работаем со стандартными цветами.
function Apply-Look {
    try { Apply-LookCore }
    catch {
        $msg = $_.Exception.Message + ' | ' + $_.InvocationInfo.PositionMessage
        try { Add-Content -Path (Join-Path $script:AppDir 'crash.log') -Value ('[{0}] Apply-Look: {1}' -f (Get-Date), $msg) -Encoding UTF8 } catch {}
        try { Say ('Оформление применилось не полностью, подробности в crash.log') } catch {}
    }
}

function Apply-LookCore {
    $c = $script:Cfg
    $dark = ($c['Theme'] -ne 'light')
    $r = $script:Win.Resources

    $wall = [string]$c['Wallpaper']
    $path = $null; $big = $false
    if ($wall -like 'builtin:*') { $path = Join-Path $script:WallDir $wall.Substring(8) }
    elseif ($wall -like 'file:*') { $path = $wall.Substring(5); $big = $true }
    if ($path -and -not (Test-Path -LiteralPath $path)) { $path = $null }
    if ($path -ne $script:BmpPath) {
        $script:BmpPath = $path; $script:Bmp = $null; $script:Cols = $null
        if ($path) { try { $script:Bmp = Load-Bitmap $path $big; $script:Cols = Get-ImageColors $script:Bmp } catch {} }
    }
    $script:UI.Wall.Source = $script:Bmp
    $script:UI.WallBlur.Radius = [double]$c['Blur']

    if ($dark) { $base = @(14, 15, 18); $white = @(255, 255, 255) } else { $base = @(244, 245, 248); $white = @(0, 0, 0) }
    $cols = $script:Cols
    $d = [double]$c['Dim'] / 100
    $g = New-Object System.Windows.Media.LinearGradientBrush
    $g.StartPoint = New-Object System.Windows.Point(0.15, 0)
    $g.EndPoint = New-Object System.Windows.Point(0.85, 1)
    if ($cols) {
        $t1 = Mix $cols.Top $base 0.40; $t2 = Mix $cols.Mid $base 0.55; $t3 = Mix $cols.Bot $base 0.70
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Col $t1 (255 * (0.20 + 0.55 * $d))), 0.0)))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Col $t2 (255 * (0.30 + 0.55 * $d))), 0.55)))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Col $t3 (255 * (0.45 + 0.50 * $d))), 1.0)))
        $panelBase = Mix $base $cols.Mid 0.12
    } else {
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Col (Mix $base $white 0.06) 255), 0.0)))
        [void]$g.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Col $base 255), 1.0)))
        $panelBase = $base
    }
    $script:UI.Tint.Fill = $g

    $pa = 255 * [double]$c['PanelAlpha'] / 100
    Set-Res 'Brush.Bg' (New-Br $base 255)
    Set-Res 'Brush.Panel' (New-Br $panelBase $pa)
    Set-Res 'Brush.Bar' (New-Br $panelBase ($pa * 0.85))
    if ($dark) {
        Set-Res 'Brush.Text' (B '#E8EAF0'); Set-Res 'Brush.Muted' (B '#A8ADBB'); Set-Res 'Brush.Hover' (B '#1CFFFFFF')
        Set-Res 'Brush.Line' (B '#2AFFFFFF'); Set-Res 'Brush.Field' (B '#26FFFFFF')
        Set-Res 'Brush.Ok' (B '#86C897'); Set-Res 'Brush.Warn' (B '#DBB56F'); Set-Res 'Brush.Err' (B '#E69A9A')
    } else {
        Set-Res 'Brush.Text' (B '#1C1F26'); Set-Res 'Brush.Muted' (B '#586070'); Set-Res 'Brush.Hover' (B '#14000000')
        Set-Res 'Brush.Line' (B '#26000000'); Set-Res 'Brush.Field' (B '#14000000')
        Set-Res 'Brush.Ok' (B '#2E7D4B'); Set-Res 'Brush.Warn' (B '#9A6B10'); Set-Res 'Brush.Err' (B '#B33A3A')
    }

    $acc = @(127, 168, 232)
    $a = [string]$c['Accent']
    if ($a -match '^#[0-9A-Fa-f]{6}$') { $acc = Hex2Rgb $a } elseif ($cols) { $acc = $cols.Vivid }
    if (-not $dark) { $acc = @(($acc[0] * 0.78), ($acc[1] * 0.78), ($acc[2] * 0.78)) }
    $lum = 0.299 * $acc[0] + 0.587 * $acc[1] + 0.114 * $acc[2]
    Set-Res 'Brush.Accent' (New-Br $acc 255)
    if ($lum -gt 150) { Set-Res 'Brush.OnAccent' (B '#0F1114') } else { Set-Res 'Brush.OnAccent' (B '#FFFFFF') }

    try { $script:Win.FontFamily = New-Object System.Windows.Media.FontFamily([string]$c['Font']) } catch {}
    $fs = [double]$c['FontSize']
    Set-Res 'FsBase' ($fs); Set-Res 'FsSmall' ($fs - 1); Set-Res 'FsTiny' ($fs - 2.5); Set-Res 'FsHead' ($fs + 8)
    $rad = [double]$c['Radius']
    Set-Res 'Rad' ([System.Windows.CornerRadius]::new($rad))
    Set-Res 'RadS' ([System.Windows.CornerRadius]::new([math]::Round($rad * 0.6)))
    if ($c['Compact']) { Set-Res 'RowPad' ([System.Windows.Thickness]::new(10, 4, 10, 4)) } else { Set-Res 'RowPad' ([System.Windows.Thickness]::new(10, 9, 10, 9)) }
    Set-TitleBar $dark
}

# ---------- строки списков ----------
function New-Row([string]$Panel, [string]$Title, [string]$Desc, [string]$Badge, [bool]$Check, [string]$Size = '', [string]$State = '') {
    $t = Esc $Title; $d = Esc $Desc; $sz = Esc $Size; $st = Esc $State
    $badgeXaml = ''
    if ($Badge) {
        $badgeXaml = '<Border BorderBrush="{DynamicResource Brush.Line}" BorderThickness="1" CornerRadius="4" Padding="5,0,5,0" Margin="8,1,0,0" VerticalAlignment="Center"><TextBlock Text="' + (Esc $Badge) + '" FontSize="{DynamicResource FsTiny}" Foreground="{DynamicResource Brush.Muted}"/></Border>'
    }
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="Transparent" CornerRadius="{DynamicResource RadS}" Padding="{DynamicResource RowPad}" Margin="0,0,0,2" Cursor="Hand">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="96"/><ColumnDefinition Width="130"/>
    </Grid.ColumnDefinitions>
    <CheckBox x:Name="Chk" VerticalAlignment="Center"/>
    <StackPanel Grid.Column="1" Margin="4,0,12,0" VerticalAlignment="Center">
      <StackPanel Orientation="Horizontal"><TextBlock x:Name="Title" Text="$t" TextTrimming="CharacterEllipsis"/>$badgeXaml</StackPanel>
      <TextBlock Text="$d" Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" TextWrapping="Wrap" Margin="0,2,0,0"/>
    </StackPanel>
    <TextBlock x:Name="Size" Grid.Column="2" Text="$sz" TextAlignment="Right" VerticalAlignment="Center"/>
    <TextBlock x:Name="State" Grid.Column="3" Text="$st" TextAlignment="Right" VerticalAlignment="Center" Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}"/>
  </Grid>
</Border>
"@
    $row = [Windows.Markup.XamlReader]::Parse($x)
    $row.Uid = $Panel
    $chk = $row.FindName('Chk')
    $chk.Style = $script:Win.FindResource('Chk')
    $chk.IsChecked = $Check
    $chk.Tag = $row
    $chk.Add_Click({ param($s, $e) Row-Changed $s.Tag.Uid $s.Tag })
    $row.Add_MouseEnter({ param($s, $e) $s.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Brush.Hover') })
    $row.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
    $row.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($e.Source -is [System.Windows.Controls.Primitives.ToggleButton]) { return }
        $c = $s.FindName('Chk')
        $c.IsChecked = -not $c.IsChecked
        Row-Changed $s.Uid $s
    })
    $row
}

function New-Header([string]$text) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $text.ToUpper()
    $h.FontWeight = [System.Windows.FontWeights]::SemiBold
    $h.Margin = New-Object System.Windows.Thickness(10, 16, 0, 6)
    Dyn $h ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Brush.Muted'
    Dyn $h ([System.Windows.Controls.TextBlock]::FontSizeProperty) 'FsSmall'
    $h
}

function Set-State($row, [string]$text, [string]$brushKey = 'Brush.Muted') {
    $s = $row.FindName('State')
    $s.Text = $text
    Dyn $s ([System.Windows.Controls.TextBlock]::ForegroundProperty) $brushKey
}

function Row-Changed([string]$panel, $row) {
    if ($panel -eq 'clean') { Update-Reclaim }
    elseif ($panel -eq 'startup') { Apply-Startup $row }
}

# ---------- очистка ----------
function Update-Reclaim {
    if ($script:Sizes.Count -eq 0) { return }
    $sum = 0.0
    foreach ($m in $script:Meta) {
        if ($script:Sizes.ContainsKey($m.Key) -and $script:Rows.clean[$m.Key].FindName('Chk').IsChecked) { $sum += $script:Sizes[$m.Key] }
    }
    $script:UI.Reclaim.Text = Format-Size $sum
}

# ---------- автозагрузка ----------
function Get-Autoruns {
    $ap = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $defs = @(
        @{ Hive = 'HKCU'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run';             App = "$ap\Run" },
        @{ Hive = 'HKLM'; Run = 'Software\Microsoft\Windows\CurrentVersion\Run';             App = "$ap\Run" },
        @{ Hive = 'HKLM'; Run = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; App = "$ap\Run32" }
    )
    $out = @()
    foreach ($d in $defs) {
        $key = Get-Item -Path ('{0}:\{1}' -f $d.Hive, $d.Run) -ErrorAction SilentlyContinue
        if (-not $key) { continue }
        $appKey = Get-Item -Path ('{0}:\{1}' -f $d.Hive, $d.App) -ErrorAction SilentlyContinue
        foreach ($n in $key.GetValueNames()) {
            if (-not $n) { continue }
            $enabled = $true
            if ($appKey) {
                $b = $appKey.GetValue($n)
                if ($b -is [byte[]] -and $b.Length -gt 0 -and (($b[0] -band 1) -eq 1)) { $enabled = $false }
            }
            $out += [pscustomobject]@{ Name = $n; Cmd = [string]$key.GetValue($n); Hive = $d.Hive; App = $d.App; Enabled = $enabled }
        }
    }
    $folders = @(
        @{ Hive = 'HKCU'; Dir = [Environment]::GetFolderPath('Startup'); App = "$ap\StartupFolder" },
        @{ Hive = 'HKLM'; Dir = [Environment]::GetFolderPath('CommonStartup'); App = "$ap\StartupFolder" }
    )
    foreach ($f in $folders) {
        if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
        $appKey = Get-Item -Path ('{0}:\{1}' -f $f.Hive, $f.App) -ErrorAction SilentlyContinue
        foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $enabled = $true
            if ($appKey) {
                $b = $appKey.GetValue($file.Name)
                if ($b -is [byte[]] -and $b.Length -gt 0 -and (($b[0] -band 1) -eq 1)) { $enabled = $false }
            }
            $out += [pscustomobject]@{ Name = $file.Name; Cmd = $file.FullName; Hive = $f.Hive; App = $f.App; Enabled = $enabled }
        }
    }
    return $out
}

function Set-AutorunEnabled($item, [bool]$enabled) {
    $path = '{0}:\{1}' -f $item.Hive, $item.App
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    $bytes = New-Object byte[] 12
    if ($enabled) { $bytes[0] = 2 }
    else {
        $bytes[0] = 3
        [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($bytes, 4)
    }
    Set-ItemProperty -Path $path -Name $item.Name -Value $bytes -Type Binary -ErrorAction Stop
}

function Apply-Startup($row) {
    $item = $row.Tag
    $chk = $row.FindName('Chk')
    try {
        Set-AutorunEnabled $item ([bool]$chk.IsChecked)
        if ($chk.IsChecked) { Set-State $row 'в автозагрузке' 'Brush.Ok'; Say ('Включено в автозагрузке: ' + $item.Name) }
        else { Set-State $row 'отключено'; Say ('Убрано из автозагрузки: ' + $item.Name) }
    } catch {
        $chk.IsChecked = -not $chk.IsChecked
        Say 'Не удалось изменить запись'
    }
}

function Load-Startup {
    $list = $script:UI.StartList
    $list.Children.Clear()
    $items = @(Get-Autoruns)
    if ($items.Count -eq 0) { [void]$list.Children.Add((New-Header 'Записей автозагрузки не найдено')); return }
    foreach ($it in $items) {
        $row = New-Row 'startup' $it.Name $it.Cmd '' $it.Enabled
        $row.Tag = $it
        if ($it.Enabled) { Set-State $row 'в автозагрузке' 'Brush.Ok' } else { Set-State $row 'отключено' }
        [void]$list.Children.Add($row)
    }
}

# ---------- большие файлы ----------
function New-BigRow([string]$Path, [double]$Size) {
    $name = Esc ([IO.Path]::GetFileName($Path))
    $dir = Esc ([IO.Path]::GetDirectoryName($Path))
    $sz = Esc (Format-Size $Size)
    $x = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="{DynamicResource RadS}" Padding="{DynamicResource RowPad}" Margin="0,0,0,2" Background="Transparent">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock Text="$sz" FontWeight="SemiBold" VerticalAlignment="Center"/>
    <StackPanel Grid.Column="1" Margin="4,0,12,0" VerticalAlignment="Center">
      <TextBlock Text="$name" TextTrimming="CharacterEllipsis"/>
      <TextBlock Text="$dir" Foreground="{DynamicResource Brush.Muted}" FontSize="{DynamicResource FsSmall}" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
    <StackPanel Grid.Column="2" Orientation="Horizontal">
      <Button x:Name="BtnShow" Content="Показать"/>
      <Button x:Name="BtnDel" Content="В корзину"/>
    </StackPanel>
  </Grid>
</Border>
"@
    $row = [Windows.Markup.XamlReader]::Parse($x)
    $row.Tag = $Path
    foreach ($bn in 'BtnShow', 'BtnDel') {
        $b = $row.FindName($bn)
        $b.Style = $script:Win.FindResource('Btn')
        $b.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
        $b.Tag = $row
    }
    $row.FindName('BtnShow').Add_Click({
        param($s, $e)
        Start-Process explorer.exe -ArgumentList ('/select,"' + $s.Tag.Tag + '"')
    })
    $row.FindName('BtnDel').Add_Click({
        param($s, $e)
        $p = [string]$s.Tag.Tag
        if (-not (Confirm-Action ("Переместить в корзину?`n`n$p"))) { return }
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            $script:UI.BigList.Children.Remove($s.Tag)
            Say ('В корзине: ' + [IO.Path]::GetFileName($p))
            Update-Disk
        } catch { Say 'Не удалось удалить файл' }
    })
    $row
}

# ---------- расписание ----------
function Test-Scheduled { [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) }
function Update-SchedLabel {
    $days = @{ Monday = 'пн'; Tuesday = 'вт'; Wednesday = 'ср'; Thursday = 'чт'; Friday = 'пт'; Saturday = 'сб'; Sunday = 'вс' }
    $script:UI.SchedSwitch.Content = ('Автоочистка: {0} {1}' -f $days[[string]$script:Cfg['SchedDay']], $script:Cfg['SchedTime'])
}
function Register-Weekly {
    $dest = Join-Path $script:AppDir 'Pruner.ps1'
    if ($script:SelfPath -ne $dest) { Copy-Item -LiteralPath $script:SelfPath -Destination $dest -Force }
    $time = [string]$script:Cfg['SchedTime']
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$dest`" -Auto"
    $trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string]$script:Cfg['SchedDay']) -At $time
    $runAs    = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $runAs -Settings $settings -Force | Out-Null
}

# ---------- фоновые задачи ----------
function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    foreach ($n in 'BtnClean', 'BtnScan', 'BtnApps', 'BtnAppsRefresh', 'BtnTw', 'BtnBig', 'BtnStartRefresh') { $script:UI[$n].IsEnabled = -not $busy }
    $script:UI.BtnStop.IsEnabled = $busy
    if ($busy) { $script:BusyStart = Get-Date }
}

function Start-Worker([string]$Mode, [string[]]$Keys, $Opt) {
    $script:Sync = [hashtable]::Synchronized(@{ Q = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Cancel = $false; Pid = 0 })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:EngineText).AddArgument($Mode).AddArgument($Keys).AddArgument($script:Sync).AddArgument($Opt)
    $script:LastMode = $Mode
    $script:GotDone = $false
    $script:Worker = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Begin-Job([string]$Mode, [string[]]$Keys, $Opt, [string]$Text, [bool]$Pulse) {
    Set-Busy $true
    Busy-Say $Text
    if ($Pulse) { Set-Bar 0.35 300; Set-Pulse $true } else { Set-Bar 0 150 }
    Start-Worker $Mode $Keys $Opt
}

function Request-Load([string]$what) {
    if ($script:Busy) { $script:Pending = $what; return }
    switch ($what) {
        'apps'   { Begin-Job 'Apps' @() $null 'Читаю список приложений…' $true }
        'tweaks' { Begin-Job 'TweaksMeta' @() $null 'Читаю состояние настроек…' $true }
    }
}

function Start-Scan {
    if ($script:Busy) { return }
    $keys = @($script:Meta | Where-Object { $_.Paths } | ForEach-Object { $_.Key })
    foreach ($k in $keys) { $script:Rows.clean[$k].FindName('Size').Text = 'считаю…' }
    $script:Sizes = @{}
    $script:UI.Reclaim.Text = '…'
    Begin-Job 'Scan' $keys $null 'Анализ: считаю, сколько места можно освободить…' $true
}

function Start-Clean {
    if ($script:Busy) { return }
    $sel = @($script:Meta | Where-Object { $script:Rows.clean[$_.Key].FindName('Chk').IsChecked })
    if ($sel.Count -eq 0) { Say 'Ничего не отмечено'; return }
    $risky = @($sel | Where-Object { $_.Badge -in @('необратимо', 'изменяет систему') })
    if ($risky.Count -gt 0) {
        $names = ($risky | ForEach-Object { '• ' + $_.Title }) -join "`n"
        if (-not (Confirm-Action ("Среди выбранного есть действия, которые нельзя отменить:`n`n$names`n`nПродолжить?"))) { return }
    }
    foreach ($m in $sel) { Set-State $script:Rows.clean[$m.Key] 'в очереди' }
    $script:FreeBefore = (Get-PSDrive -Name $env:SystemDrive.Substring(0, 1)).Free
    Begin-Job 'Clean' @($sel | ForEach-Object { $_.Key }) $null 'Очистка…' $false
}

function Request-Stop {
    if (-not $script:Busy -or -not $script:Sync) { return }
    $script:Sync['Cancel'] = $true
    $script:UI.BtnStop.IsEnabled = $false
    Busy-Say 'Останавливаю…'
    # Если рабочий поток не успел остановиться сам, прерываем его принудительно
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(2500)
    $t.Add_Tick({
        param($s, $e)
        $s.Stop()
        $w = $script:Worker
        if ($w -and -not $w.Handle.IsCompleted) {
            $p = [int]$script:Sync['Pid']
            if ($p -gt 0) { Start-Process taskkill.exe -ArgumentList "/PID $p /T /F" -WindowStyle Hidden }
            [void]$w.PS.BeginStop($null, $null)
        }
    })
    $t.Start()
}

# ---------- приложения ----------
function Show-Apps($list) {
    $script:UI.AppsList.Children.Clear()
    $script:Rows.apps = @{}
    $script:AppsRec = @{}
    $lastRec = $null
    foreach ($a in $list) {
        if ($lastRec -ne $a.Rec) {
            if ($a.Rec) { [void]$script:UI.AppsList.Children.Add((New-Header 'Лишнее, рекомендуется удалить')) } else { [void]$script:UI.AppsList.Children.Add((New-Header 'Остальные приложения')) }
            $lastRec = $a.Rec
        }
        $row = New-Row 'apps' $a.Title $a.Name '' ([bool]$a.Rec)
        $row.Tag = $a.Name
        $script:AppsRec[$a.Name] = [bool]$a.Rec
        $script:Rows.apps[$a.Name] = $row
        [void]$script:UI.AppsList.Children.Add($row)
    }
    $script:AppsLoaded = $true
}

function Start-RemoveApps {
    if ($script:Busy) { return }
    $keys = @($script:Rows.apps.Keys | Where-Object { $script:Rows.apps[$_].FindName('Chk').IsChecked })
    if ($keys.Count -eq 0) { Say 'Ничего не отмечено'; return }
    if (-not (Confirm-Action ("Удалить приложений: $($keys.Count)?`nПереустановить их можно из Microsoft Store."))) { return }
    foreach ($k in $keys) { Set-State $script:Rows.apps[$k] 'в очереди' }
    Begin-Job 'RemoveApps' $keys @{ Deprov = [bool]$script:UI.AppsDeprov.IsChecked } 'Удаляю приложения…' $false
}

# ---------- настройки Windows ----------
function Show-Tweaks($list) {
    $script:UI.TwList.Children.Clear()
    $script:Rows.tweaks = @{}
    $lastGroup = ''
    foreach ($t in $list) {
        if ($t.Group -ne $lastGroup) { [void]$script:UI.TwList.Children.Add((New-Header $t.Group)); $lastGroup = $t.Group }
        $row = New-Row 'tweaks' $t.Title $t.Desc $t.Badge ([bool]$t.State)
        $row.Tag = @{ Id = $t.Id; Orig = [bool]$t.State; Rec = [bool]$t.Rec; Badge = $t.Badge; Title = $t.Title }
        if ($t.State) { Set-State $row 'включено' 'Brush.Ok' }
        $script:Rows.tweaks[$t.Id] = $row
        [void]$script:UI.TwList.Children.Add($row)
    }
    $script:TweaksLoaded = $true
}

function Start-Tweaks {
    if ($script:Busy) { return }
    $changes = @()
    foreach ($id in $script:Rows.tweaks.Keys) {
        $row = $script:Rows.tweaks[$id]
        $want = [bool]$row.FindName('Chk').IsChecked
        if ($want -ne $row.Tag.Orig) { $changes += ('{0}={1}' -f $id, [int]$want) }
    }
    if ($changes.Count -eq 0) { Say 'Нечего применять: изменённых пунктов нет'; return }
    $danger = @($script:Rows.tweaks.Values | Where-Object { $_.Tag.Badge -in @('осторожно', 'удаление') -and ([bool]$_.FindName('Chk').IsChecked -ne $_.Tag.Orig) })
    $msg = "Изменений: $($changes.Count)."
    if ($danger.Count -gt 0) { $msg += "`n`nОсторожно, затронуты чувствительные настройки:`n" + (($danger | ForEach-Object { '• ' + $_.Tag.Title }) -join "`n") }
    if ($script:Cfg['Restore']) { $msg += "`n`nПеред изменениями будет создана точка восстановления." }
    if (-not (Confirm-Action ($msg + "`n`nПрименить?"))) { return }
    foreach ($id in $script:Rows.tweaks.Keys) {
        $row = $script:Rows.tweaks[$id]
        if (([bool]$row.FindName('Chk').IsChecked) -ne $row.Tag.Orig) { Set-State $row 'в очереди' }
    }
    Begin-Job 'Tweaks' $changes @{ Restore = [bool]$script:Cfg['Restore'] } 'Применяю настройки…' $false
}

# ---------- разбор сообщений от рабочего потока ----------
function Handle-Msg($m) {
    switch ($m.T) {
        'log' { Add-Log $m.D }
        'size' {
            $k = $m.D['Key']
            $script:Sizes[$k] = [double]$m.D['Size']
            $script:Rows.clean[$k].FindName('Size').Text = Format-Size $m.D['Size']
            Update-Reclaim
        }
        'task' {
            $d = $m.D
            $row = $script:Rows[$d['Panel']][$d['Key']]
            if (-not $row) { return }
            if ($d['State'] -eq 'run') {
                Set-State $row 'выполняется…' 'Brush.Accent'
                Busy-Say ('Выполняю: ' + $row.FindName('Title').Text)
                Set-Bar (($d['Index'] - 0.6) / $d['Total'])
            } else {
                if ($d['State'] -eq 'ok') { Set-State $row 'готово' 'Brush.Ok' } else { Set-State $row 'ошибка' 'Brush.Err' }
                if ($d['Panel'] -eq 'clean' -and $d['Freed'] -gt 0) { $row.FindName('Size').Text = '−' + (Format-Size $d['Freed']) }
                Set-Bar ($d['Index'] / $d['Total'])
            }
        }
        'apps' { Show-Apps $m.D }
        'tweaks' { Show-Tweaks $m.D }
        'def' {
            if ($m.D['Known'] -and $m.D['Tamper']) {
                $script:UI.TwHint.Text = 'Включена «Защита от подделки»: чтобы отключить Защитник, сначала выключи её вручную (кнопка справа), потом повтори.'
            } else {
                $script:UI.TwHint.Text = 'Галочка означает, что настройка включена. Снимешь её у применённой настройки, и она откатится. Применяются только изменённые пункты.'
            }
        }
        'big' {
            $script:UI.BigList.Children.Clear()
            foreach ($f in $m.D) { [void]$script:UI.BigList.Children.Add((New-BigRow $f.Path $f.Size)) }
            Say ('Найдено файлов: ' + @($m.D).Count)
        }
        'done' {
            $script:GotDone = $true
            $d = $m.D
            $script:StatusBase = ''
            switch ($d['Kind']) {
                'scan'   { Say 'Анализ завершён. Отметь нужное и нажми «Очистить»' }
                'clean'  {
                    Set-Bar 1
                    $el = ((Get-Date) - $script:BusyStart).ToString('m\:ss')
                    if ($d['Cancelled']) { Say ('Остановлено. Освобождено: ' + (Format-Size $d['Freed'])) }
                    else { Say ('Готово. Освобождено: ' + (Format-Size $d['Freed']) + '  ·  ' + $el) }
                    Update-Disk
                }
                'remove' { Set-Bar 1; Say ("Удалено приложений: $($d['Count']) из $($d['Total'])"); $script:Pending = 'apps' }
                'apply'  { Set-Bar 1; Say ("Применено: $($d['Count']) из $($d['Total'])"); $script:Pending = 'tweaks' }
                'big'    { if ($d['Cancelled']) { Say 'Сканирование остановлено, показан частичный результат' } }
            }
        }
    }
}

function Finish-Worker {
    $w = $script:Worker
    $script:Worker = $null
    try { [void]$w.PS.EndInvoke($w.Handle) } catch {}
    foreach ($er in $w.PS.Streams.Error) { Add-Log ('[ошибка] ' + $er.ToString()) }
    try { $w.PS.Dispose(); $w.RS.Close(); $w.RS.Dispose() } catch {}
    $script:StatusBase = ''
    Set-Pulse $false
    Set-Busy $false
    if ($script:LastMode -in @('Scan', 'Apps', 'TweaksMeta', 'Big')) { Set-Bar 0 300 }
    if ($script:LastMode -eq 'Clean' -and -not $script:GotDone) {
        $now = (Get-PSDrive -Name $env:SystemDrive.Substring(0, 1)).Free
        Say ('Остановлено. Освобождено: ' + (Format-Size ([math]::Max(0, $now - $script:FreeBefore))))
        Update-Disk
    }
    if ($script:LastMode -in @('Clean', 'RemoveApps', 'Tweaks')) {
        $panel = @{ Clean = 'clean'; RemoveApps = 'apps'; Tweaks = 'tweaks' }[$script:LastMode]
        foreach ($row in @($script:Rows[$panel].Values)) {
            $s = $row.FindName('State').Text
            if ($s -eq 'выполняется…') { Set-State $row 'прервано' 'Brush.Warn' } elseif ($s -eq 'в очереди') { Set-State $row '' }
        }
    }
    if ($script:Pending) { $p = $script:Pending; $script:Pending = ''; Request-Load $p }
}

# ---------- вкладка «Настройки» ----------
function New-Label([string]$text, [bool]$muted = $false, [double]$top = 0) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text
    $t.TextWrapping = 'Wrap'
    $t.Margin = New-Object System.Windows.Thickness(0, $top, 0, 0)
    if ($muted) {
        Dyn $t ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'Brush.Muted'
        Dyn $t ([System.Windows.Controls.TextBlock]::FontSizeProperty) 'FsSmall'
    }
    $t
}
function New-Section([string]$text) {
    $t = New-Label $text $false 22
    $t.FontWeight = [System.Windows.FontWeights]::SemiBold
    $t.Margin = New-Object System.Windows.Thickness(0, 22, 0, 8)
    $t
}
function New-Pills([string]$Key, $Options, $Current) {
    $wp = New-Object System.Windows.Controls.WrapPanel
    foreach ($o in $Options) {
        $r = New-Object System.Windows.Controls.RadioButton
        $r.Content = $o.L; $r.Tag = $o.V; $r.Uid = $Key; $r.GroupName = $Key
        $r.Style = $script:Win.FindResource('Pill')
        $r.IsChecked = ([string]$o.V -eq [string]$Current)
        $r.Add_Checked({ param($s, $e) Set-Cfg $s.Uid $s.Tag })
        [void]$wp.Children.Add($r)
    }
    $wp
}
function New-SliderRow([string]$Key, [string]$Label, [double]$Min, [double]$Max, [double]$Value, [string]$Suffix = '') {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    foreach ($w in @(@(230, $false), @(1, $true), @(64, $false))) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($w[1]) { $unit = [System.Windows.GridUnitType]::Star } else { $unit = [System.Windows.GridUnitType]::Pixel }
        $cd.Width = New-Object System.Windows.GridLength($w[0], $unit)
        [void]$g.ColumnDefinitions.Add($cd)
    }
    $lbl = New-Label $Label; $lbl.VerticalAlignment = 'Center'
    $sl = New-Object System.Windows.Controls.Slider
    $sl.Minimum = $Min; $sl.Maximum = $Max; $sl.Value = $Value
    $sl.IsSnapToTickEnabled = $true; $sl.TickFrequency = 1
    $sl.Uid = $Key
    [System.Windows.Controls.Grid]::SetColumn($sl, 1)
    $val = New-Label ('{0:N0}{1}' -f $Value, $Suffix); $val.TextAlignment = 'Right'; $val.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($val, 2)
    $sl.Tag = @{ Txt = $val; Suf = $Suffix }
    $sl.Add_ValueChanged({
        param($s, $e)
        $s.Tag['Txt'].Text = ('{0:N0}{1}' -f $s.Value, $s.Tag['Suf'])
        Set-Cfg $s.Uid ([int]$s.Value)
    })
    [void]$g.Children.Add($lbl); [void]$g.Children.Add($sl); [void]$g.Children.Add($val)
    $g
}
function New-Check([string]$Key, [string]$Text, [bool]$Value) {
    $c = New-Object System.Windows.Controls.CheckBox
    $c.Content = $Text; $c.Uid = $Key; $c.IsChecked = $Value
    $c.Style = $script:Win.FindResource('Chk')
    $c.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $c.Add_Click({ param($s, $e) Set-Cfg $s.Uid ([bool]$s.IsChecked) })
    $c
}

function Refresh-WallSel {
    foreach ($b in $script:WallBorders) {
        if ([string]$b.Tag -eq [string]$script:Cfg['Wallpaper']) { Dyn $b ([System.Windows.Controls.Border]::BorderBrushProperty) 'Brush.Accent' }
        else { $b.BorderBrush = [System.Windows.Media.Brushes]::Transparent }
    }
}
function Refresh-FontSel {
    foreach ($b in $script:FontBorders) {
        if ([string]$b.Tag -eq [string]$script:Cfg['Font']) { Dyn $b ([System.Windows.Controls.Border]::BackgroundProperty) 'Brush.Field' }
        else { $b.Background = [System.Windows.Media.Brushes]::Transparent }
    }
}

function New-Thumb([string]$tag, [string]$imagePath, [string]$text) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 112; $b.Height = 64; $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
    $b.BorderThickness = New-Object System.Windows.Thickness(2)
    $b.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Tag = $tag
    $b.ClipToBounds = $true
    if ($imagePath) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = Load-Bitmap $imagePath $false
        $img.Stretch = 'UniformToFill'
        $b.Child = $img
    } else {
        $t = New-Label $text; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'; $t.TextAlignment = 'Center'
        $b.Background = (B '#22808080')
        $b.Child = $t
    }
    $b.Add_MouseLeftButtonUp({
        param($s, $e)
        if ($s.Tag -eq 'custom') { Pick-Wallpaper; return }
        Set-Cfg 'Wallpaper' ([string]$s.Tag)
        Refresh-WallSel
    })
    $script:WallBorders += $b
    $b
}

function Pick-Wallpaper {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Изображения|*.jpg;*.jpeg;*.png;*.bmp'
    $dlg.Title = 'Выбери картинку для фона'
    if ($dlg.ShowDialog() -eq $true) {
        try {
            if (-not (Test-Path $script:CfgDir)) { New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null }
            $dest = Join-Path $script:CfgDir ('wallpaper' + [IO.Path]::GetExtension($dlg.FileName).ToLower())
            Get-ChildItem -Path $script:CfgDir -Filter 'wallpaper.*' | Remove-Item -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $dlg.FileName -Destination $dest -Force
            $script:BmpPath = 'reload'
            Set-Cfg 'Wallpaper' ('file:' + $dest)
            Build-Settings
        } catch { Say 'Не удалось загрузить картинку' }
    }
}

function Build-Settings {
    $h = $script:UI.SetHost
    $h.Children.Clear()
    $script:Loading = $true
    $c = $script:Cfg
    $script:WallBorders = @(); $script:FontBorders = @()

    [void]$h.Children.Add((New-Section 'Тема'))
    [void]$h.Children.Add((New-Pills 'Theme' @(@{ L = 'Тёмная'; V = 'dark' }, @{ L = 'Светлая'; V = 'light' }) $c['Theme']))

    [void]$h.Children.Add((New-Section 'Фон'))
    $wp = New-Object System.Windows.Controls.WrapPanel
    if (Test-Path $script:WallDir) {
        foreach ($f in (Get-ChildItem -Path $script:WallDir -File | Where-Object { $_.Extension -match '\.(jpg|jpeg|png|bmp)$' } | Sort-Object Name)) {
            [void]$wp.Children.Add((New-Thumb ('builtin:' + $f.Name) $f.FullName ''))
        }
    }
    if ([string]$c['Wallpaper'] -like 'file:*' -and (Test-Path -LiteralPath ([string]$c['Wallpaper']).Substring(5))) {
        [void]$wp.Children.Add((New-Thumb ([string]$c['Wallpaper']) ([string]$c['Wallpaper']).Substring(5) ''))
    }
    [void]$wp.Children.Add((New-Thumb 'custom' '' 'Свой файл…'))
    [void]$wp.Children.Add((New-Thumb 'none' '' 'Без картинки'))
    [void]$h.Children.Add($wp)
    [void]$h.Children.Add((New-SliderRow 'Dim' 'Затемнение фона' 0 100 $c['Dim'] '%'))
    [void]$h.Children.Add((New-SliderRow 'Blur' 'Размытие фона' 0 30 $c['Blur'] ' px'))
    [void]$h.Children.Add((New-SliderRow 'PanelAlpha' 'Плотность панелей' 30 100 $c['PanelAlpha'] '%'))
    [void]$h.Children.Add((New-Label 'Градиент и цвет акцента берутся из картинки. Маленькие картинки лучше размывать: так не видно пикселей.' $true 2))

    [void]$h.Children.Add((New-Section 'Цвет акцента'))
    $sw = New-Object System.Windows.Controls.WrapPanel
    $accents = @(@{ T = 'auto'; X = 'Из обоев' }, @{ T = '#7FA8E8'; X = '' }, @{ T = '#6FC3A0'; X = '' }, @{ T = '#E0A458'; X = '' }, @{ T = '#E27D7D'; X = '' }, @{ T = '#B58DE0'; X = '' }, @{ T = '#5BC0DE'; X = '' }, @{ T = '#C8D26A'; X = '' })
    foreach ($a in $accents) {
        $b = New-Object System.Windows.Controls.Border
        $b.Tag = $a.T; $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 8, 8)
        $b.BorderThickness = New-Object System.Windows.Thickness(2)
        if ($a.T -eq 'auto') {
            $b.Padding = New-Object System.Windows.Thickness(12, 5, 12, 5)
            $b.CornerRadius = New-Object System.Windows.CornerRadius(14)
            $t = New-Label $a.X; $b.Child = $t
            Dyn $b ([System.Windows.Controls.Border]::BackgroundProperty) 'Brush.Field'
        } else {
            $b.Width = 28; $b.Height = 28; $b.CornerRadius = New-Object System.Windows.CornerRadius(14)
            $b.Background = (B $a.T)
        }
        if ([string]$c['Accent'] -eq [string]$a.T) { Dyn $b ([System.Windows.Controls.Border]::BorderBrushProperty) 'Brush.Text' } else { $b.BorderBrush = [System.Windows.Media.Brushes]::Transparent }
        $b.Add_MouseLeftButtonUp({
            param($s, $e)
            Set-Cfg 'Accent' ([string]$s.Tag)
            foreach ($o in $s.Parent.Children) {
                if ([string]$o.Tag -eq [string]$s.Tag) { Dyn $o ([System.Windows.Controls.Border]::BorderBrushProperty) 'Brush.Text' } else { $o.BorderBrush = [System.Windows.Media.Brushes]::Transparent }
            }
        })
        [void]$sw.Children.Add($b)
    }
    [void]$h.Children.Add($sw)

    [void]$h.Children.Add((New-Section 'Шрифт'))
    $curated = 'Segoe UI', 'Segoe UI Variable Text', 'Bahnschrift', 'Calibri', 'Cambria', 'Candara', 'Consolas', 'Corbel', 'Arial', 'Tahoma', 'Verdana', 'Trebuchet MS',
               'Georgia', 'Century Gothic', 'Franklin Gothic Medium', 'Lucida Sans Unicode', 'Palatino Linotype', 'Sitka Text', 'Yu Gothic UI', 'Comic Sans MS',
               'Cascadia Code', 'Cascadia Mono', 'JetBrains Mono', 'Fira Code', 'Inter', 'Roboto', 'Open Sans', 'Montserrat', 'Ubuntu', 'PT Sans'
    $installed = @{}
    foreach ($ff in [System.Windows.Media.Fonts]::SystemFontFamilies) { $installed[$ff.Source] = $true }
    $fontPanel = New-Object System.Windows.Controls.StackPanel
    foreach ($fn in $curated) {
        if (-not $installed.ContainsKey($fn)) { continue }
        $b = New-Object System.Windows.Controls.Border
        $b.Tag = $fn; $b.Padding = New-Object System.Windows.Thickness(10, 5, 10, 5); $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $t = New-Label ($fn + '   Съешь ещё этих мягких булок 123'); $t.FontFamily = New-Object System.Windows.Media.FontFamily($fn)
        $b.Child = $t
        $b.Add_MouseLeftButtonUp({ param($s, $e) Set-Cfg 'Font' ([string]$s.Tag); Refresh-FontSel })
        $script:FontBorders += $b
        [void]$fontPanel.Children.Add($b)
    }
    $fsv = New-Object System.Windows.Controls.ScrollViewer
    $fsv.Height = 190; $fsv.VerticalScrollBarVisibility = 'Auto'; $fsv.Content = $fontPanel
    [void]$h.Children.Add($fsv)
    $other = New-Object System.Windows.Controls.StackPanel; $other.Orientation = 'Horizontal'; $other.Margin = New-Object System.Windows.Thickness(0, 10, 0, 6)
    $tb = New-Object System.Windows.Controls.TextBox; $tb.Width = 220; $tb.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    $bt = New-Object System.Windows.Controls.Button; $bt.Content = 'Другой шрифт'; $bt.Style = $script:Win.FindResource('Btn'); $bt.Tag = $tb
    $bt.Add_Click({
        param($s, $e)
        $n = $s.Tag.Text.Trim()
        $ok = $false
        foreach ($ff in [System.Windows.Media.Fonts]::SystemFontFamilies) { if ($ff.Source -ieq $n) { $n = $ff.Source; $ok = $true; break } }
        if ($ok) { Set-Cfg 'Font' $n; Refresh-FontSel; Say ('Шрифт: ' + $n) } else { Say 'Такого шрифта в системе нет' }
    })
    [void]$other.Children.Add($tb); [void]$other.Children.Add($bt)
    [void]$h.Children.Add($other)
    [void]$h.Children.Add((New-SliderRow 'FontSize' 'Размер шрифта' 11 18 $c['FontSize'] ' pt'))

    [void]$h.Children.Add((New-Section 'Оформление'))
    [void]$h.Children.Add((New-SliderRow 'Radius' 'Скругление углов' 0 18 $c['Radius'] ' px'))
    [void]$h.Children.Add((New-Pills 'Compact' @(@{ L = 'Обычная плотность'; V = $false }, @{ L = 'Компактная'; V = $true }) $c['Compact']))

    [void]$h.Children.Add((New-Section 'Поведение'))
    [void]$h.Children.Add((New-Check 'Restore' 'Создавать точку восстановления перед изменением настроек Windows' ([bool]$c['Restore'])))
    [void]$h.Children.Add((New-Check 'Confirm' 'Спрашивать подтверждение перед опасными действиями' ([bool]$c['Confirm'])))

    [void]$h.Children.Add((New-Section 'Автоочистка'))
    [void]$h.Children.Add((New-Pills 'SchedDay' @(@{ L = 'Пн'; V = 'Monday' }, @{ L = 'Вт'; V = 'Tuesday' }, @{ L = 'Ср'; V = 'Wednesday' }, @{ L = 'Чт'; V = 'Thursday' },
                                                 @{ L = 'Пт'; V = 'Friday' }, @{ L = 'Сб'; V = 'Saturday' }, @{ L = 'Вс'; V = 'Sunday' }) $c['SchedDay']))
    $tp = New-Object System.Windows.Controls.StackPanel; $tp.Orientation = 'Horizontal'
    $tp.Children.Add((New-Label 'Время (ЧЧ:ММ)  ')) | Out-Null
    $tt = New-Object System.Windows.Controls.TextBox; $tt.Width = 80; $tt.Text = [string]$c['SchedTime']
    $tt.Add_LostFocus({
        param($s, $e)
        if ($s.Text -match '^([01]?\d|2[0-3]):[0-5]\d$') { Set-Cfg 'SchedTime' $s.Text } else { $s.Text = [string]$script:Cfg['SchedTime']; Say 'Время нужно в формате 21:30' }
    })
    [void]$tp.Children.Add($tt)
    [void]$h.Children.Add($tp)
    [void]$h.Children.Add((New-Label 'Включается галочкой «Автоочистка» внизу окна. Чистятся только пункты, отмеченные по умолчанию.' $true 8))

    $reset = New-Object System.Windows.Controls.Button
    $reset.Content = 'Сбросить оформление'; $reset.Style = $script:Win.FindResource('Btn'); $reset.Margin = New-Object System.Windows.Thickness(0, 24, 0, 0); $reset.HorizontalAlignment = 'Left'
    $reset.Add_Click({
        foreach ($k in 'Theme', 'Wallpaper', 'Dim', 'Blur', 'PanelAlpha', 'Accent', 'Font', 'FontSize', 'Radius', 'Compact') { $script:Cfg[$k] = $script:CfgDefault[$k] }
        if (-not $script:Cfg['Wallpaper']) { $script:Cfg['Wallpaper'] = $script:DefaultWall }
        Apply-Look; Save-Soon; Build-Settings
    })
    [void]$h.Children.Add($reset)

    $script:Loading = $false
    Refresh-WallSel; Refresh-FontSel
}

function Set-Cfg([string]$Key, $Value) {
    if ($script:Loading) { return }
    $script:Cfg[$Key] = $Value
    if ($Key -in @('SchedDay', 'SchedTime')) {
        Update-SchedLabel
        if (Test-Scheduled) { try { Register-Weekly } catch {} }
    } elseif ($Key -notin @('Restore', 'Confirm')) {
        Apply-Look
    }
    Save-Soon
}

# ---------- сборка интерфейса ----------
$script:Meta = @(& $Engine -Mode 'Meta' -Keys @() -Sync $null -Opt $null)
$lastGroup = ''
foreach ($m in $script:Meta) {
    if ($m.Group -ne $lastGroup) { [void]$script:UI.CleanList.Children.Add((New-Header $m.Group)); $lastGroup = $m.Group }
    $row = New-Row 'clean' $m.Title $m.Desc $m.Badge $m.Default
    $script:Rows.clean[$m.Key] = $row
    [void]$script:UI.CleanList.Children.Add($row)
}

Load-Cfg
$script:DefaultWall = ''
if (Test-Path $script:WallDir) {
    $first = Get-ChildItem -Path $script:WallDir -File | Where-Object { $_.Extension -match '\.(jpg|jpeg|png|bmp)$' } | Sort-Object Name | Select-Object -First 1
    if ($first) { $script:DefaultWall = 'builtin:' + $first.Name }
}
if (-not $script:Cfg['Wallpaper']) { $script:Cfg['Wallpaper'] = $script:DefaultWall }
$script:UI.AppsDeprov.Style = $script:Win.FindResource('Chk')
$script:UI.SchedSwitch.IsChecked = (Test-Scheduled)
Update-SchedLabel
Apply-Look

# ---------- события ----------
$panels = @{ TabClean = 'PanelClean'; TabApps = 'PanelApps'; TabTweaks = 'PanelTweaks'; TabStart = 'PanelStart'; TabBig = 'PanelBig'; TabLog = 'PanelLog'; TabSet = 'PanelSet' }
foreach ($tab in $panels.Keys) {
    $script:UI[$tab].Uid = $panels[$tab]
    $script:UI[$tab].Add_Checked({
        param($s, $e)
        foreach ($p in 'PanelClean', 'PanelApps', 'PanelTweaks', 'PanelStart', 'PanelBig', 'PanelLog', 'PanelSet') {
            if ($p -eq $s.Uid) { $script:UI[$p].Visibility = 'Visible' } else { $script:UI[$p].Visibility = 'Collapsed' }
        }
        if ($s.Uid -eq 'PanelApps' -and -not $script:AppsLoaded) { Request-Load 'apps' }
        if ($s.Uid -eq 'PanelTweaks' -and -not $script:TweaksLoaded) { Request-Load 'tweaks' }
        if ($s.Uid -eq 'PanelStart') { Load-Startup }
        if ($s.Uid -eq 'PanelSet' -and $script:UI.SetHost.Children.Count -eq 0) { Build-Settings }
    })
}

$script:UI.BtnScan.Add_Click({ Start-Scan })
$script:UI.BtnClean.Add_Click({ Start-Clean })
$script:UI.BtnStop.Add_Click({ Request-Stop })
$script:UI.BtnApps.Add_Click({ Start-RemoveApps })
$script:UI.BtnAppsRefresh.Add_Click({ Request-Load 'apps' })
$script:UI.BtnAppsRec.Add_Click({
    foreach ($m in $script:Rows.apps.Keys) { $row = $script:Rows.apps[$m]; $row.FindName('Chk').IsChecked = [bool]$script:AppsRec[$m] }
})
$script:UI.BtnAppsNone.Add_Click({ foreach ($row in $script:Rows.apps.Values) { $row.FindName('Chk').IsChecked = $false } })
$script:UI.BtnTw.Add_Click({ Start-Tweaks })
$script:UI.BtnTwRec.Add_Click({
    foreach ($row in $script:Rows.tweaks.Values) { if ($row.Tag.Rec -and $row.Tag.Badge -ne 'осторожно') { $row.FindName('Chk').IsChecked = $true } }
})
$script:UI.BtnTwMax.Add_Click({
    foreach ($row in $script:Rows.tweaks.Values) { if ($row.Tag.Badge -ne 'осторожно') { $row.FindName('Chk').IsChecked = $true } }
    Say 'Выбрано всё, кроме пунктов с пометкой «осторожно». Их отмечай вручную.'
})
$script:UI.BtnTwReset.Add_Click({ foreach ($row in $script:Rows.tweaks.Values) { $row.FindName('Chk').IsChecked = $row.Tag.Orig } })
$script:UI.BtnTamper.Add_Click({ try { Start-Process 'windowsdefender://threatsettings' } catch { Say 'Открой «Безопасность Windows» вручную' } })
$script:UI.BtnStartRefresh.Add_Click({ Load-Startup })
$script:UI.BtnBig.Add_Click({
    if ($script:Busy) { return }
    $script:UI.BigList.Children.Clear()
    Begin-Job 'Big' @($env:SystemDrive + '\') $null 'Сканирую диск…' $true
})
$script:UI.BtnLogOpen.Add_Click({ $lf = Join-Path $script:AppDir 'log.txt'; if (Test-Path $lf) { Start-Process notepad.exe -ArgumentList $lf } else { Say 'Журнал пока пуст' } })
$script:UI.BtnLogClear.Add_Click({ $script:UI.LogBox.Clear() })
$script:UI.SchedSwitch.Style = $script:Win.FindResource('Chk')
$script:UI.SchedSwitch.Add_Click({
    try {
        if ($script:UI.SchedSwitch.IsChecked) { Register-Weekly; Say ('Автоочистка включена. ' + $script:UI.SchedSwitch.Content) }
        else { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop; Say 'Автоочистка выключена' }
    } catch {
        $script:UI.SchedSwitch.IsChecked = -not $script:UI.SchedSwitch.IsChecked
        Say ('Не удалось изменить автоочистку: ' + $_.Exception.Message)
    }
})

# «Лишнее» для списка приложений приходит вместе со списком
$script:AppsRec = @{}
$script:Poll = New-Object System.Windows.Threading.DispatcherTimer
$script:Poll.Interval = [TimeSpan]::FromMilliseconds(80)
$script:Poll.Add_Tick({
    if ($script:Busy -and $script:StatusBase) {
        $script:UI.Status.Text = ('{0}  ·  {1}' -f $script:StatusBase, ((Get-Date) - $script:BusyStart).ToString('m\:ss'))
    }
    if (-not $script:Sync) { return }
    $item = $null
    while ($script:Sync['Q'].TryDequeue([ref]$item)) { Handle-Msg $item; $item = $null }
    if ($script:Worker -and $script:Worker.Handle.IsCompleted -and $script:Sync['Q'].IsEmpty) { Finish-Worker }
})
$script:Poll.Start()

$script:Win.Add_SourceInitialized({
    $script:Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:Win)).Handle
    Set-TitleBar ($script:Cfg['Theme'] -ne 'light')
})
$script:Win.Add_Loaded({ Update-Disk })
$script:Win.Add_ContentRendered({ if ($script:LastMode -eq '') { Start-Scan } })
$script:Win.Add_Closing({
    if ($script:Sync) { $script:Sync['Cancel'] = $true }
    if ($script:Worker) {
        $p = [int]$script:Sync['Pid']
        if ($p -gt 0) { Start-Process taskkill.exe -ArgumentList "/PID $p /T /F" -WindowStyle Hidden }
        [void]$script:Worker.PS.BeginStop($null, $null)
    }
})

    [void]$script:Win.ShowDialog()
} catch {
    $e = $_.Exception
    $where = $_.InvocationInfo.PositionMessage
    $details = $e.ToString()
    if ($e -is [System.Windows.Markup.XamlParseException]) {
        $details = ("строка {0}, позиция {1}: " -f $e.LineNumber, $e.LinePosition) + $details
    }
    $crashLog = Join-Path $script:AppDir 'crash.log'
    try {
        Add-Content -Path $crashLog -Value ('[{0}] {1}{2}{3}{2}{2}' -f (Get-Date), $details, "`r`n", $where) -Encoding UTF8
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Pruner не смог запуститься.`r`n`r`n$($e.Message)`r`n`r`n$where`r`n`r`nПодробности сохранены в:`r`n$crashLog",
            'Pruner - ошибка запуска', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}
