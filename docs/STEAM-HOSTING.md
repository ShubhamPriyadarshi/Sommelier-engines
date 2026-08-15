# Hosting the Steam client on the Sommelier engine

Status 2026-08-15: the client boots, paints its UI, and renders a live
sign-in form (animating QR) on the self-built engine. One bug still blocks
login — see "Open bug" at the end. Direct-launch games never needed any of
this.

## Why Steam was black

Steam's UI composer creates D3D swapchains across process boundaries — a
GPU helper process creating surfaces for windows owned by other processes.
On macOS only CodeWeavers' proprietary D3DMetal supports that. DXMT states
it plainly at runtime ("CreateSwapChain: cross-process swapchain not
supported yet", upstream issue 141), Apple's GPTK D3D11 crashes outright on
a non-CrossOver engine, and wined3d's GL tops out below what CEF's ANGLE
needs. Every one of those failures looks identical from the outside: a
black window with a living DOM behind it.

## The three pieces that fix it

1. **DXMT in the engine.** The engine bundles DXMT (Metal-based D3D11/D3D10
   for Wine — CodeWeavers' own open-source project; v0.80 is MIT-licensed,
   later versions LGPL 2.1+). The PE dlls install into a prefix DXVK-style:
   `dxgi.dll`, `d3d11.dll`, `d3d10core.dll` copied into
   `drive_c/windows/system32/` plus `winemetal.dll` beside them, and
   `winemetal.so` lives in the engine's `lib/wine/x86_64-unix/`. winemetal's
   unixlib ABI is self-contained, so DXMT built by CodeWeavers runs on this
   engine unmodified — verified at feature level 11_0, windowed and
   offscreen presents both clean.

2. **The webhelper wrapper** (`tools/steamwebhelper-wrapper/`). Forces
   CrossOver-production's exact CEF flag trio
   (`--no-sandbox --in-process-gpu --disable-gpu`). Install notes, the
   size-padding requirement, and the build line are in the source header.

3. **`steam.cfg`** next to steam.exe containing
   `BootStrapperInhibitAll=enable`, or Steam's updater silently restores
   the original webhelper even when the padded size matches.

Steam's own Interface setting "Enable GPU accelerated rendering of web
views" arms the same trio when disabled — but it is stored per-user in
userdata, so it cannot help before the first login. The wrapper is the
pre-login equivalent.

## Diagnostic tricks that earned their keep

- Steam's file verification is **size-only** on routine launches; a fresh
  install may verify checksums once. Pad replacements to the byte.
- A stale `HKCU\Software\Valve\Steam\ActiveProcess` registry key makes a
  relaunched steam.exe silently exit ~3 minutes in: the recorded wine PID
  gets reused by a fresh wineserver session. Delete the key before
  relaunching across wineserver restarts.
- Stale `winetemp-*` staging dirs (keyed on ntdll.so's inode) under
  `$TMPDIR` cause "could not load ntdll.so" after swapping engine bundles
  at the same path. Remove them.
- CEF 126 on Wine 11 additionally has a cross-process *software* present
  bug (community-documented); `--single-process` sidesteps it but degrades
  the network service. With DXMT installed the trio suffices.

## Open bug: CM connection stall

steamclient's `CCMInterface::YieldingConnect` coroutine never runs on this
engine — "EConnect called - scheduling connection for 50ms" repeats
indefinitely with zero `GetCMListForConnect` calls, zero outbound sockets,
zero errors. The identical Steam install and prefix on the CrossOver engine
fetches the CM list immediately. Eliminated: msync (off makes no
difference), TLS (a winhttp/SChannel probe fetches the CM directory over
HTTPS fine on this engine), sockets/DNS (Steam's own connectivity tests
pass), CEF process mode, steam.cfg. Do not mix ntdll.so across builds when
bisecting — unix and PE ntdll are a matched pair; winemac.so and win32u.so
swapped cleanly. Next leads: WINEDEBUG sync/timer tracing around the 50ms
scheduler, Steam console CM verbosity, CROSSOVER-conditional scheduler code
in the source tree, and steam's `-tcp` flag.
