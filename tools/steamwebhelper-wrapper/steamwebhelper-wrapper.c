/* steamwebhelper wrapper — prepend CEF flags and delegate to the renamed
 * real binary. This is what makes Steam's UI paint on the Sommelier engine.
 *
 * Why it exists (established 2026-08-15 on an M1 Air, macOS 27):
 * Steam's UI composer creates its D3D swapchain in one process for a window
 * owned by another. CodeWeavers' proprietary D3DMetal supports that
 * cross-process arrangement; DXMT reports "CreateSwapChain: cross-process
 * swapchain not supported yet" and every open backend fails some other way —
 * the visible symptom is a login window that stays black while its DOM runs.
 * Production CrossOver avoids the broken paths with exactly these flags,
 * armed there by the per-user "GPU accelerated rendering in web views"
 * setting, which lives in userdata and therefore does not exist before the
 * first login. The wrapper arms them unconditionally:
 *
 *   --no-sandbox --in-process-gpu --disable-gpu
 *
 * Install (per Steam directory, in bin/cef/cef.win64 AND cef.win7x64):
 *   1. Rename steamwebhelper.exe -> steamwebhelper_real.exe
 *   2. Drop this wrapper in as steamwebhelper.exe, ZERO-PADDED to the exact
 *      byte size of the original — Steam's routine verification is
 *      size-only, and a size mismatch gets the wrapper silently replaced.
 *   3. Write "BootStrapperInhibitAll=enable" into steam.cfg next to
 *      steam.exe — the updater's package repair restores the original even
 *      when sizes match; this disables it. (Trade-off: client self-update
 *      is off; the wrapper must be reapplied after a manual update.)
 *
 * Build:
 *   x86_64-w64-mingw32-clang -municode -O2 steamwebhelper-wrapper.c \
 *       -o steamwebhelper.exe -Wl,-subsystem,console
 *   The console subsystem is deliberate: the -mwindows/wWinMain variant
 *   hung under Wine (llvm-mingw entry-point quirk); wmain works.
 *
 * A --disable-gpu --single-process variant also paints and additionally
 * dodges CEF 126's cross-process software present bug, but leaves
 * Chromium's network service degraded; prefer the production-parity trio.
 */
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>

int wmain(void)
{
    WCHAR self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    WCHAR *slash = wcsrchr(self, L'\\');
    if (slash) *(slash + 1) = 0;

    /* Original command line with argv[0] (quoted or bare) stripped. */
    WCHAR *orig = GetCommandLineW();
    if (*orig == L'"') { orig++; while (*orig && *orig != L'"') orig++; if (*orig) orig++; }
    else { while (*orig && *orig != L' ') orig++; }
    while (*orig == L' ') orig++;

    static WCHAR cmd[65536];
    lstrcpyW(cmd, L"\"");
    lstrcatW(cmd, self);
    lstrcatW(cmd, L"steamwebhelper_real.exe\" --no-sandbox --in-process-gpu --disable-gpu ");
    lstrcatW(cmd, orig);

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 127;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
