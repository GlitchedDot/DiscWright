// launcher.cpp — the DiscWright standalone bootstrapper.
// (DiscWright v34, 2026-11-07.)
//
// WHAT THIS IS
//   The tiny native front half of DiscWright-standalone.exe,
//   the single double-clickable file the final build ships.
//   Its own PE image is followed, byte for byte, by:
//
//       [launcher PE][payload.zip][48-byte footer]
//
//   payload.zip holds the DiscWright app folder's CONTENTS as
//   stored entries (DiscWright.exe at the zip root, tools\
//   beside it). The footer is 48 bytes, little-endian:
//       bytes  0.. 7   magic "DWPAYLD1"
//       bytes  8..15   uint64 payloadSize
//       bytes 16..47   build stamp, 32 bytes, NUL-padded ASCII
//                      (e.g. "2026-11-07.v34")
//
// WHY IT EXISTS
//   WinUI 3 does not support .NET single-file publishing: the
//   app is an unpackaged, self-contained FOLDER (its own
//   Windows App SDK + .NET runtime + encoder tools), and that
//   folder must exist on disk for the app to run. Lola wanted
//   "no install, just a stand alone app anyone can run" — so
//   this launcher unpacks the folder per-user, under
//   %LOCALAPPDATA%\DiscWright\standalone-<stamp>, on first
//   run, then starts the real DiscWright.exe. No install, no
//   admin, nothing registered anywhere; deleting
//   %LOCALAPPDATA%\DiscWright removes it completely. A repeat
//   launch with the same stamp skips the unpack (the .dwstamp
//   fast path below), so later starts are instant; a newer
//   build (new stamp) unpacks into its own fresh folder.
//
// EXTRACTION
//   Via the system tar.exe: bsdtar has shipped with Windows 10
//   (1803+) and Windows 11 and reads zip archives natively —
//   no archiver code lives in this file.
//
// HARDENING (v34)
//   v32's launcher failed SILENTLY on Lola's machine: no
//   unpack folder ever appeared under %LOCALAPPDATA% and no
//   error box was seen, while every folder build launched.
//   v34 makes the wrapper testify instead:
//   - Every failure is a NAMED STAGE (S1–S11, listed at
//     Fail() below) whose message box also carries the Win32
//     error code when the failing call set one.
//   - The payload is SELF-CHECKED against its footer before
//     a byte is copied: the size must fit inside the file
//     and the bytes at the computed offset must start with
//     the zip signature "PK\x03\x04" (stage S4). A file the
//     build assembled wrong fails HERE, by name.
//   - The child app gets a command line BUILT for it —
//     "<exePath>" plus any arguments that followed the
//     launcher's own name — instead of the launcher's whole
//     command line passed through (v32's choice: the child's
//     argv[0] then named the launcher).
//   - A first run narrates itself in a watch console and in
//     unpack.log (see WATCHING below). No failure is silent
//     anymore: box, stage, code, console, log.
//
// WATCHING A FIRST RUN (v34)
//   The unpack path — and ONLY the unpack path — opens a
//   console: attached to the parent's when launched from a
//   terminal (the stages then scroll inline there), or
//   allocated fresh when double-clicked. Stage lines print
//   as they happen; tar runs verbose (-xvf) INHERITING that
//   console, so the parade of unpacked files scrolls by
//   live; the same stage lines are mirrored into unpack.log
//   in the unpack folder. The child app is started DETACHED
//   from the console, so the watch window belongs to the
//   launcher alone: on success it lingers a beat so "done"
//   can be seen, then closes (repeat launches on the fast
//   path never open a console at all); on failure it waits
//   for Enter after the message box, so the testimony stays
//   on screen for a screenshot. The console is a courtesy,
//   never a gate: if none can be had, the unpack carries on
//   exactly as before.
//
// Build (done by build-app.cmd with the machine's MSVC):
//   cl /O2 /W3 /DUNICODE /D_UNICODE launcher.cpp
//      /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib ole32.lib
// Links only Windows APIs. The import libraries are named on
// the build command line AND in the pragmas below: with the
// libraries only in the pragmas, Lola's machine resolved
// everything except MessageBoxW (LNK2019, 2026-11-07) — the
// MessageBoxW declaration itself is hidden by windows.h
// unless user32 is in the link. Naming the libraries on the
// command line makes that dependency explicit and unmissable.

#include <windows.h>
#include <shlobj.h>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

// The 48-byte footer at the very end of the standalone exe.
const long long kFooterSize = 48;
const char kMagic[8] = { 'D', 'W', 'P', 'A', 'Y', 'L', 'D', '1' };

// ---- the first-run watch console and unpack.log ----
// Globals because Say()/Fail() are reached from all over
// wWinMain. Every use is best-effort: when no console could
// be had, g_console stays INVALID_HANDLE_VALUE and the
// helpers below quietly do nothing — the console may never
// become the reason an unpack fails.
HANDLE g_console = INVALID_HANDLE_VALUE;  // CONOUT$ handle
HANDLE g_logFile = INVALID_HANDLE_VALUE;  // <dir>\unpack.log
bool g_weAllocated = false;  // true: the console is OURS
                             // (AllocConsole); false: attached
                             // to the parent's, or none.

// Append `text` to a NUL-terminated wide buffer, truncating
// silently if it would not fit. Diagnostics only: a clipped
// stage line is still a stage line.
void AppendText(wchar_t* buf, size_t count, const wchar_t* text)
{
    size_t len = (size_t)lstrlenW(buf);
    if (len >= count) return;
    size_t room = count - len - 1;
    size_t add = (size_t)lstrlenW(text);
    if (add > room) add = room;
    for (size_t i = 0; i < add; ++i) buf[len + i] = text[i];
    buf[len + add] = L'\0';
}

// Append a decimal number (hand-rolled: this file uses no
// CRT formatting, in keeping with its raw-Win32 style).
void AppendNumber(wchar_t* buf, size_t count,
                  unsigned long long value)
{
    wchar_t digits[24];
    int n = 0;
    if (value == 0) digits[n++] = L'0';
    while (value > 0 && n < 24)
    {
        digits[n++] = (wchar_t)(L'0' + (value % 10));
        value /= 10;
    }
    // digits were collected least-significant first.
    size_t len = (size_t)lstrlenW(buf);
    while (n > 0 && len + 1 < count) buf[len++] = digits[--n];
    buf[len] = L'\0';
}

// One line of first-run testimony: to the watch console
// (when one exists) and, once it has been opened, into
// unpack.log. The log copy is narrowed to plain bytes —
// stage lines are ASCII by construction; anything else
// becomes '?'.
void Say(const wchar_t* line)
{
    DWORD wrote = 0;
    if (g_console != INVALID_HANDLE_VALUE)
    {
        WriteConsoleW(g_console, line, (DWORD)lstrlenW(line),
                      &wrote, NULL);
        WriteConsoleW(g_console, L"\r\n", 2, &wrote, NULL);
    }
    if (g_logFile != INVALID_HANDLE_VALUE)
    {
        char narrow[1024];
        int n = 0;
        for (const wchar_t* p = line; *p && n < 1000; ++p)
            narrow[n++] = (*p < 128) ? (char)*p : '?';
        narrow[n++] = '\r';
        narrow[n++] = '\n';
        WriteFile(g_logFile, narrow, (DWORD)n, &wrote, NULL);
    }
}

// Every hard failure testifies. The stage list:
//   S1  finding our own file path        S7  creating payload.zip
//   S2  opening self / reading footer    S8  copying payload bytes
//   S3  footer magic mismatch            S9  starting tar.exe
//   S4  payload self-check               S10 tar exit / result
//   S5  app-data / unpack paths          S11 starting the app
//   S6  creating the unpack folder
// The message box shows the plain-language message, the
// stage tag, and the Win32 error code when `error` is
// nonzero. On the unpack path (a console is up) the same
// line is Said first, and after the box is dismissed the
// window waits for Enter, so the testimony stays on screen.
void Fail(int stage, const wchar_t* message, DWORD error)
{
    wchar_t text[1024];
    const size_t textCount = sizeof(text) / sizeof(text[0]);
    text[0] = L'\0';
    AppendText(text, textCount, message);
    AppendText(text, textCount, L" [stage S");
    AppendNumber(text, textCount, (unsigned long long)stage);
    AppendText(text, textCount, L"]");
    if (error != 0)
    {
        AppendText(text, textCount, L" (error ");
        AppendNumber(text, textCount, (unsigned long long)error);
        AppendText(text, textCount, L")");
    }
    if (g_console != INVALID_HANDLE_VALUE) Say(text);
    MessageBoxW(NULL, text, L"DiscWright", MB_OK | MB_ICONERROR);
    if (g_console != INVALID_HANDLE_VALUE)
    {
        Say(L"Press Enter to close this window...");
        HANDLE in = CreateFileW(L"CONIN$", GENERIC_READ,
                                FILE_SHARE_READ, NULL,
                                OPEN_EXISTING, 0, NULL);
        if (in != INVALID_HANDLE_VALUE)
        {
            wchar_t buf[16];
            DWORD got = 0;
            // Line-input mode: returns once Enter is pressed.
            ReadConsoleW(in, buf, 16, &got, NULL);
            CloseHandle(in);
        }
        // Free only a console we allocated; an attached
        // parent console (her terminal) is not ours to close.
        if (g_weAllocated) FreeConsole();
    }
}

// Give the unpack a visible console: the parent's when
// launched from a terminal (stages scroll inline in her
// PowerShell), our own fresh window otherwise. If both
// fail, carry on silently — see the globals' note above.
void OpenWatchConsole()
{
    if (!AttachConsole(ATTACH_PARENT_PROCESS))
    {
        if (AllocConsole()) g_weAllocated = true;
        else return; // no console to be had — courtesy declined
    }
    g_console = CreateFileW(L"CONOUT$", GENERIC_WRITE,
                            FILE_SHARE_WRITE, NULL,
                            OPEN_EXISTING, 0, NULL);
    if (g_console == INVALID_HANDLE_VALUE) return;
    SetConsoleTitleW(L"DiscWright - unpacking");
}

// Join two path fragments with a backslash (no doubling when
// `head` already ends with one).
bool JoinPath(wchar_t* out, size_t outCount,
              const wchar_t* head, const wchar_t* tail)
{
    size_t headLen = lstrlenW(head);
    size_t tailLen = lstrlenW(tail);
    bool slash = headLen > 0 && head[headLen - 1] != L'\\';
    if (headLen + (slash ? 1 : 0) + tailLen + 1 > outCount) return false;
    lstrcpyW(out, head);
    if (slash) lstrcatW(out, L"\\");
    lstrcatW(out, tail);
    return true;
}

// Create the directory chain for `dir` one level at a time
// (CreateDirectoryW alone refuses missing parents).
// Two traps, both learned from Lola's machine:
// - NEVER try to create the drive root itself: the first
//   truncation of "C:\Users\..." is "C:", and CreateDirectoryW
//   on it fails with ERROR_ACCESS_DENIED even though the root
//   obviously exists. That is exactly what stage S6 reported
//   on the standalone's first real run (2026-11-07, error 5).
// - A level that already exists AS A DIRECTORY is success,
//   whatever error CreateDirectoryW claimed — the attribute
//   check, not the error code, is the ground truth.
bool EnsureDirectory(const wchar_t* dir)
{
    wchar_t path[2048];
    if (lstrlenW(dir) >= (int)sizeof(path) / (int)sizeof(path[0])) return false;
    lstrcpyW(path, dir);
    for (wchar_t* p = path + 1; ; ++p)
    {
        if (*p == L'\\' || *p == L'\0')
        {
            bool isRoot = (p - path) <= 3 && path[1] == L':';
            wchar_t save = *p;
            *p = L'\0';
            if (!isRoot && !CreateDirectoryW(path, NULL))
            {
                DWORD err = GetLastError();
                DWORD attrs = GetFileAttributesW(path);
                bool existsAsDir =
                    attrs != INVALID_FILE_ATTRIBUTES &&
                    (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
                if (err != ERROR_ALREADY_EXISTS && !existsAsDir)
                {
                    *p = save;
                    SetLastError(err); // the caller's Fail wants it
                    return false;
                }
            }
            *p = save;
            if (save == L'\0') return true;
        }
    }
}

// The stamp as the extract folder sees it: only [A-Za-z0-9._-]
// survive, everything else becomes '_'.
void SanitizeStamp(const char* stamp, wchar_t* out, size_t outCount)
{
    size_t i = 0;
    for (; stamp[i] != '\0' && i + 1 < outCount; ++i)
    {
        char c = stamp[i];
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        out[i] = ok ? (wchar_t)c : L'_';
    }
    out[i] = L'\0';
}

bool FileExists(const wchar_t* path)
{
    DWORD attrs = GetFileAttributesW(path);
    return attrs != INVALID_FILE_ATTRIBUTES &&
           (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

// True when the file at `path` contains exactly `text`
// (the stamp comparison behind the fast path).
bool FileContentEquals(const wchar_t* path, const char* text)
{
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    char buffer[64];
    DWORD read = 0;
    BOOL ok = ReadFile(file, buffer, sizeof(buffer) - 1, &read, NULL);
    CloseHandle(file);
    if (!ok) return false;
    buffer[read] = '\0';
    return lstrcmpA(buffer, text) == 0;
}

// Build the child app's command line: "<exePath>" plus
// whatever followed the launcher's own first token on the
// original command line, verbatim (v32 passed the whole
// line through, so the child's argv[0] named the launcher
// — harmless for an app with no CLI surface, but sloppy;
// the child now gets its own name). The first token may be
// quoted; both forms are skipped the way the CRT would.
void BuildChildCommandLine(const wchar_t* exePath,
                           wchar_t* out, size_t outCount)
{
    const wchar_t* rest = GetCommandLineW();
    if (*rest == L'"')
    {
        ++rest; // opening quote
        while (*rest && *rest != L'"') ++rest;
        if (*rest == L'"') ++rest; // closing quote
    }
    else
    {
        while (*rest && *rest != L' ' && *rest != L'\t') ++rest;
    }
    // `rest` now sits on the separator whitespace (kept
    // verbatim — it is the argument string's own spacing)
    // or on the terminating NUL when there were no arguments.
    out[0] = L'\0';
    AppendText(out, outCount, L"\"");
    AppendText(out, outCount, exePath);
    AppendText(out, outCount, L"\"");
    AppendText(out, outCount, rest);
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int)
{
    // ---- S1: locate ourselves ----
    wchar_t selfPath[1024];
    if (GetModuleFileNameW(NULL, selfPath,
                           (DWORD)(sizeof(selfPath) / sizeof(selfPath[0]))) == 0)
    {
        DWORD err = GetLastError();
        Fail(1, L"DiscWright could not find its own file path.", err);
        return 1;
    }

    // ---- S2: open ourselves and read the footer ----
    HANDLE self = CreateFileW(selfPath, GENERIC_READ, FILE_SHARE_READ, NULL,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (self == INVALID_HANDLE_VALUE)
    {
        DWORD err = GetLastError();
        Fail(2, L"DiscWright could not open its own file to unpack.", err);
        return 1;
    }
    LARGE_INTEGER fileSize;
    bool sizeOk = GetFileSizeEx(self, &fileSize) != 0;
    DWORD sizeErr = sizeOk ? 0 : GetLastError();
    if (!sizeOk || fileSize.QuadPart < kFooterSize + 4)
    {
        CloseHandle(self);
        Fail(2, L"This DiscWright standalone file is damaged "
                L"(missing payload).", sizeErr);
        return 1;
    }
    unsigned char footer[kFooterSize];
    LARGE_INTEGER seekPos;
    seekPos.QuadPart = fileSize.QuadPart - kFooterSize;
    DWORD read = 0;
    bool readOk = SetFilePointerEx(self, seekPos, NULL, FILE_BEGIN) != 0;
    DWORD readErr = readOk ? 0 : GetLastError();
    if (readOk && !ReadFile(self, footer, (DWORD)kFooterSize, &read, NULL))
    {
        readOk = false;
        readErr = GetLastError();
    }
    if (readOk && read != (DWORD)kFooterSize) readOk = false;
    if (!readOk)
    {
        CloseHandle(self);
        Fail(2, L"This DiscWright standalone file is damaged "
                L"(missing payload).", readErr);
        return 1;
    }

    // ---- S3: the footer magic ----
    bool magicOk = true;
    for (int i = 0; i < 8; ++i)
        if (footer[i] != (unsigned char)kMagic[i]) magicOk = false;
    if (!magicOk)
    {
        CloseHandle(self);
        Fail(3, L"This DiscWright standalone file is damaged "
                L"(missing payload).", 0);
        return 1;
    }
    unsigned long long payloadSize = 0;
    for (int i = 0; i < 8; ++i)
        payloadSize |= (unsigned long long)footer[8 + i] << (8 * i);
    char stamp[33];
    for (int i = 0; i < 32; ++i) stamp[i] = (char)footer[16 + i];
    stamp[32] = '\0'; // belt and braces: the field itself is NUL-padded

    // ---- S4: payload self-check ----
    // The payload must lie strictly between the launcher PE
    // and the footer, and start with the zip signature. A
    // build that assembled the file wrong (copy /b order, a
    // bad size in the footer) fails HERE, by name, instead
    // of somewhere downstream with a shrug.
    unsigned long long fileBytes = (unsigned long long)fileSize.QuadPart;
    if (payloadSize == 0 ||
        payloadSize > fileBytes - (unsigned long long)kFooterSize)
    {
        CloseHandle(self);
        Fail(4, L"This DiscWright standalone file is damaged "
                L"(bad payload size in its footer).", 0);
        return 1;
    }
    unsigned long long payloadOffset =
        fileBytes - (unsigned long long)kFooterSize - payloadSize;
    if (payloadOffset == 0 ||
        payloadOffset >= fileBytes - (unsigned long long)kFooterSize)
    {
        CloseHandle(self);
        Fail(4, L"This DiscWright standalone file is damaged "
                L"(bad payload size in its footer).", 0);
        return 1;
    }
    unsigned char sig[4];
    DWORD sigRead = 0;
    seekPos.QuadPart = (long long)payloadOffset;
    bool sigOk = SetFilePointerEx(self, seekPos, NULL, FILE_BEGIN) != 0 &&
                 ReadFile(self, sig, 4, &sigRead, NULL) && sigRead == 4 &&
                 sig[0] == 'P' && sig[1] == 'K' && sig[2] == 3 && sig[3] == 4;
    if (!sigOk)
    {
        CloseHandle(self);
        Fail(4, L"This DiscWright standalone file is damaged "
                L"(its payload is not where the footer says, "
                L"or is not a zip).", 0);
        return 1;
    }

    // ---- S5: the per-user extract directory for this stamp ----
    wchar_t safeStamp[40];
    SanitizeStamp(stamp, safeStamp, sizeof(safeStamp) / sizeof(safeStamp[0]));

    PWSTR localAppData = NULL;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, NULL,
                                    &localAppData)) || localAppData == NULL)
    {
        CloseHandle(self);
        Fail(5, L"DiscWright could not find your local app data folder.", 0);
        return 1;
    }
    wchar_t folderName[64];
    lstrcpyW(folderName, L"standalone-");
    lstrcatW(folderName, safeStamp);
    wchar_t baseDir[1024], extractDir[1200], exePath[1400], stampPath[1400];
    bool pathsOk = JoinPath(baseDir, sizeof(baseDir) / sizeof(baseDir[0]),
                            localAppData, L"DiscWright") &&
                   JoinPath(extractDir,
                            sizeof(extractDir) / sizeof(extractDir[0]),
                            baseDir, folderName) &&
                   JoinPath(exePath, sizeof(exePath) / sizeof(exePath[0]),
                            extractDir, L"DiscWright.exe") &&
                   JoinPath(stampPath, sizeof(stampPath) / sizeof(stampPath[0]),
                            extractDir, L".dwstamp");
    CoTaskMemFree(localAppData);
    if (!pathsOk)
    {
        CloseHandle(self);
        Fail(5, L"DiscWright's unpack path would be too long.", 0);
        return 1;
    }

    // ---- fast path: this stamp is already unpacked ----
    if (!(FileExists(exePath) && FileContentEquals(stampPath, stamp)))
    {
        // ============ UNPACK PATH ============
        // The watch window opens here, and only here: a
        // repeat launch must stay as invisible as v32's was.
        OpenWatchConsole();
        Say(L"DiscWright standalone - first run: unpacking");

        // ---- S6: create the unpack folder ----
        if (!EnsureDirectory(extractDir))
        {
            DWORD err = GetLastError();
            CloseHandle(self);
            Fail(6, L"DiscWright could not create its unpack "
                    L"folder under your local app data.", err);
            return 1;
        }

        // unpack.log lives in the unpack folder; from here
        // on, Say() mirrors every line into it.
        wchar_t logPath[1400];
        if (JoinPath(logPath, sizeof(logPath) / sizeof(logPath[0]),
                     extractDir, L"unpack.log"))
        {
            g_logFile = CreateFileW(logPath, GENERIC_WRITE,
                                    FILE_SHARE_READ, NULL,
                                    CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL, NULL);
        }
        wchar_t line[1500];
        line[0] = L'\0';
        AppendText(line, sizeof(line) / sizeof(line[0]),
                   L"Unpack folder: ");
        AppendText(line, sizeof(line) / sizeof(line[0]), extractDir);
        Say(line);

        // ---- S7: create the payload file ----
        wchar_t zipPath[1400];
        if (!JoinPath(zipPath, sizeof(zipPath) / sizeof(zipPath[0]),
                      extractDir, L"payload.zip"))
        {
            CloseHandle(self);
            Fail(7, L"DiscWright's unpack path would be too long.", 0);
            return 1;
        }
        HANDLE zip = CreateFileW(zipPath, GENERIC_WRITE, 0, NULL,
                                 CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (zip == INVALID_HANDLE_VALUE)
        {
            DWORD err = GetLastError();
            CloseHandle(self);
            Fail(7, L"DiscWright could not write its payload "
                    L"while unpacking.", err);
            return 1;
        }

        // ---- S8: copy the payload bytes ----
        line[0] = L'\0';
        AppendText(line, sizeof(line) / sizeof(line[0]),
                   L"Copying payload... ");
        AppendNumber(line, sizeof(line) / sizeof(line[0]),
                     payloadSize / (1024 * 1024));
        AppendText(line, sizeof(line) / sizeof(line[0]), L" MB");
        Say(line);

        // Stream-copy the payload in 1 MiB chunks, from the
        // offset S4 verified to the footer's front door.
        seekPos.QuadPart = (long long)payloadOffset;
        bool copyOk = SetFilePointerEx(self, seekPos, NULL, FILE_BEGIN) != 0;
        DWORD copyErr = copyOk ? 0 : GetLastError();
        static unsigned char chunk[1024 * 1024];
        unsigned long long remaining = payloadSize;
        while (copyOk && remaining > 0)
        {
            DWORD want = remaining > sizeof(chunk)
                             ? (DWORD)sizeof(chunk)
                             : (DWORD)remaining;
            DWORD got = 0, wrote = 0;
            if (!ReadFile(self, chunk, want, &got, NULL))
            {
                copyOk = false;
                copyErr = GetLastError();
            }
            else if (got != want)
            {
                copyOk = false;
            }
            else if (!WriteFile(zip, chunk, got, &wrote, NULL))
            {
                copyOk = false;
                copyErr = GetLastError();
            }
            else if (wrote != got)
            {
                copyOk = false;
            }
            else
            {
                remaining -= got;
            }
        }
        CloseHandle(zip);
        CloseHandle(self);
        self = INVALID_HANDLE_VALUE;
        if (!copyOk)
        {
            Fail(8, L"DiscWright could not unpack its payload "
                    L"(the file may be damaged).", copyErr);
            return 1;
        }

        // ---- S9: start tar, verbose, inheriting the console ----
        // tar.exe -xvf "<dir>\payload.zip" -C "<dir>": the -v
        // file parade IS the show Lola asked to watch, and
        // with no CREATE_NO_WINDOW the child shares the watch
        // console, so its output (errors included) lands
        // there live. (v34 replaced an earlier plan to
        // redirect tar's output into unpack.log: inherited
        // and live beats captured and static.)
        Say(L"Extracting...");
        wchar_t command[4096];
        lstrcpyW(command, L"tar.exe -xvf \"");
        lstrcatW(command, zipPath);
        lstrcatW(command, L"\" -C \"");
        lstrcatW(command, extractDir);
        lstrcatW(command, L"\"");
        STARTUPINFOW startup = {};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process = {};
        if (!CreateProcessW(NULL, command, NULL, NULL, FALSE,
                            0, NULL, NULL,
                            &startup, &process))
        {
            DWORD err = GetLastError();
            Fail(9, L"DiscWright could not start tar.exe to "
                    L"unpack itself (Windows 10 1803 or later "
                    L"is required).", err);
            return 1;
        }
        WaitForSingleObject(process.hProcess, INFINITE);
        DWORD tarExit = 0;
        GetExitCodeProcess(process.hProcess, &tarExit);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);

        // ---- S10: tar's verdict ----
        if (tarExit != 0 || !FileExists(exePath))
        {
            // payload.zip stays in place on failure, for
            // inspection; it is deleted only on success.
            Fail(10, L"DiscWright could not unpack itself "
                     L"(tar.exe failed). The stage line above "
                     L"and unpack.log in the unpack folder "
                     L"have the record.", 0);
            return 1;
        }
        DeleteFileW(zipPath);

        // Mark this stamp unpacked, so the next launch takes
        // the fast path: the stamp text, no newline.
        HANDLE stampFile = CreateFileW(stampPath, GENERIC_WRITE, 0, NULL,
                                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                       NULL);
        if (stampFile != INVALID_HANDLE_VALUE)
        {
            DWORD stampLen = (DWORD)lstrlenA(stamp);
            DWORD stampWrote = 0;
            WriteFile(stampFile, stamp, stampLen, &stampWrote, NULL);
            CloseHandle(stampFile);
        }
        Say(L"Unpack complete - starting DiscWright");
    }
    if (self != INVALID_HANDLE_VALUE) CloseHandle(self);

    // ---- S11: launch the real app ----
    wchar_t childCmd[4096];
    BuildChildCommandLine(exePath, childCmd,
                          sizeof(childCmd) / sizeof(childCmd[0]));
    // When a watch console is up, start the app DETACHED
    // from it: the window is the launcher's alone to close,
    // and a GUI app has no use for a console anyway.
    DWORD childFlags = (g_console != INVALID_HANDLE_VALUE)
                           ? DETACHED_PROCESS : 0;
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    if (!CreateProcessW(exePath, childCmd, NULL, NULL, FALSE,
                        childFlags, NULL,
                        extractDir, &startup, &process))
    {
        DWORD err = GetLastError();
        Fail(11, L"DiscWright unpacked but could not start. "
                 L"Try deleting %LOCALAPPDATA%\\DiscWright and "
                 L"running it again.", err);
        return 1;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);

    // Success, unpack path: let the completion line land
    // before we leave, then close what is ours. (Fast path:
    // no console exists, and this is all skipped.)
    if (g_console != INVALID_HANDLE_VALUE)
    {
        Sleep(1200);
        if (g_logFile != INVALID_HANDLE_VALUE)
        {
            CloseHandle(g_logFile);
            g_logFile = INVALID_HANDLE_VALUE;
        }
        if (g_weAllocated) FreeConsole();
    }
    return 0;
}
