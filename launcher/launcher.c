/*
 * Pruner launcher.
 * Unpacks the embedded PowerShell script and wallpapers into
 * %LOCALAPPDATA%\Pruner\app and starts the app through Windows PowerShell.
 * The executable requests administrator rights through its manifest.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define ID_FILELIST 100

static void die(const wchar_t *msg)
{
    MessageBoxW(NULL, msg, L"Pruner", MB_OK | MB_ICONERROR);
    ExitProcess(1);
}

static void make_dirs(const wchar_t *path)
{
    wchar_t buf[MAX_PATH * 2];
    size_t i, len = wcslen(path);
    if (len >= MAX_PATH * 2) return;
    wcscpy(buf, path);
    for (i = 3; i < len; i++) {
        if (buf[i] == L'\\') {
            buf[i] = 0;
            CreateDirectoryW(buf, NULL);
            buf[i] = L'\\';
        }
    }
    CreateDirectoryW(buf, NULL);
}

static int write_resource(int id, const wchar_t *dest)
{
    HRSRC r = FindResourceW(NULL, MAKEINTRESOURCEW(id), RT_RCDATA);
    HGLOBAL h;
    const void *data;
    DWORD size, written = 0;
    HANDLE f;
    BOOL ok;

    if (!r) return 0;
    size = SizeofResource(NULL, r);
    h = LoadResource(NULL, r);
    if (!h) return 0;
    data = LockResource(h);
    f = CreateFileW(dest, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(f, data, size, &written, NULL);
    CloseHandle(f);
    return ok && written == size;
}

static void unpack(const wchar_t *appdir)
{
    HRSRC r = FindResourceW(NULL, MAKEINTRESOURCEW(ID_FILELIST), RT_RCDATA);
    HGLOBAL h;
    DWORD size;
    char *list, *line, *next;

    if (!r) die(L"Повреждённый файл: нет списка ресурсов.");
    size = SizeofResource(NULL, r);
    h = LoadResource(NULL, r);
    list = (char *)malloc(size + 1);
    if (!h || !list) die(L"Не хватает памяти.");
    memcpy(list, LockResource(h), size);
    list[size] = 0;

    for (line = list; line && *line; line = next) {
        char *bar;
        wchar_t rel[MAX_PATH], dest[MAX_PATH * 2], dir[MAX_PATH * 2], *slash;
        int id, i;

        next = strchr(line, '\n');
        if (next) { *next = 0; next++; }
        if (*line && line[strlen(line) - 1] == '\r') line[strlen(line) - 1] = 0;
        bar = strchr(line, '|');
        if (!bar) continue;
        *bar = 0;
        id = atoi(line);
        if (!MultiByteToWideChar(CP_UTF8, 0, bar + 1, -1, rel, MAX_PATH)) continue;
        for (i = 0; rel[i]; i++) if (rel[i] == L'/') rel[i] = L'\\';

        wcscpy(dest, appdir);
        wcscat(dest, L"\\");
        wcscat(dest, rel);
        wcscpy(dir, dest);
        slash = wcsrchr(dir, L'\\');
        if (slash) { *slash = 0; make_dirs(dir); }
        /* A running instance may keep a file open: that is fine if an older copy already exists. */
        if (!write_resource(id, dest) && GetFileAttributesW(dest) == INVALID_FILE_ATTRIBUTES)
            die(L"Не удалось распаковать файлы приложения.");
    }
    free(list);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show)
{
    wchar_t local[MAX_PATH], appdir[MAX_PATH * 2], sysdir[MAX_PATH];
    wchar_t ps[MAX_PATH * 2], script[MAX_PATH * 2], cmdline[MAX_PATH * 6];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    int argc, i, autoMode = 0;
    wchar_t **argv;

    (void)inst; (void)prev; (void)cmd; (void)show;

    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH)) die(L"Не найдена папка LOCALAPPDATA.");
    wcscpy(appdir, local);
    wcscat(appdir, L"\\Pruner\\app");
    make_dirs(appdir);
    unpack(appdir);

    GetSystemDirectoryW(sysdir, MAX_PATH);
    wcscpy(ps, sysdir);
    wcscat(ps, L"\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (GetFileAttributesW(ps) == INVALID_FILE_ATTRIBUTES) die(L"Не найден Windows PowerShell 5.1.");

    wcscpy(script, appdir);
    wcscat(script, L"\\Pruner.ps1");

    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (i = 1; argv && i < argc; i++) {
        if (_wcsicmp(argv[i], L"/auto") == 0 || _wcsicmp(argv[i], L"-auto") == 0 || _wcsicmp(argv[i], L"--auto") == 0) autoMode = 1;
    }
    if (argv) LocalFree(argv);

    wcscpy(cmdline, L"\"");
    wcscat(cmdline, ps);
    wcscat(cmdline, L"\" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"");
    wcscat(cmdline, script);
    wcscat(cmdline, L"\"");
    if (autoMode) wcscat(cmdline, L" -Auto");

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, appdir, &si, &pi))
        die(L"Не удалось запустить PowerShell.");
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
