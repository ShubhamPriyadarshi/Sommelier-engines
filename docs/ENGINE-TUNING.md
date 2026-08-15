# Engine tuning: what was investigated, what was found, what was ruled out

A review of CrossOver 26.3's LGPL sources, the MoltenVK/DXVK/vkd3d trees shipped
alongside them, and the surrounding patch ecosystem, looking for performance and
compatibility we are leaving on the table.

Reference machine: MacBookAir10,1 — M1, 4 performance + 4 efficiency cores,
7 GPU cores, 16 GB, fanless, macOS 27.0. Findings are labelled by whether they
generalise, because a fanless 7-core-GPU Air and a 40-core Studio want different
answers and this project has already been burned by assuming otherwise.

**Negative results are recorded deliberately.** Most of the value here is
knowing what *not* to spend a build on.

---

## 1. Applied

### GStreamer — the one real compatibility gap
Configure said it plainly:

    gstreamer-1.0 base plugins 64-bit development files not found,
    GStreamer won't be supported.

No media backend means any title with pre-rendered cutscenes skips or hangs on
video — the same failure class as Deep Rock Galactic's intro-movie hang, which
cost a whole debugging session. `gstreamer` and `gst-plugins-base` are now
installed for x86_64 and `--with-gstreamer` is explicit.

Because Wine *disables features with a warning and carries on*, the build now
**fails** if GStreamer ends up disabled, and prints the full disabled list
either way. A silent absence surfaces months later inside a game; a failed
build surfaces in four minutes.

### libusb
`libusb-1.0 not found, USB devices won't be supported`. Cheap to add. Note this
is **not** ordinary controller support — see the negative results.

### Processor-count limit (`WINENCPU`)
Shipped in the app as `GameTweaks.processorCountLimit`. CrossOver hack 24711,
macOS-only, clamped so it can only lower the count. Windows cannot tell a
performance core from an efficiency one, so a job-system engine spawns
`NumberOfProcessors` workers and then waits on whichever landed on a slow core.

**Measured: Kenshi 55 fps against 54, about 2%.** Directionally right and free,
but not the win the mechanism suggests — Kenshi's Ogre renderer is largely
single-threaded, so there is no worker pool to trim. Expect this to matter on
job-system engines (Unreal, Unity, modern in-house) and nowhere else.

Machine-dependent by construction: offered only when
`MacHardware.hasMeaningfulEfficiencyCores`, so an 8+2 Max never sees a control
that would only cost it throughput.

### Rosetta AVX advertisement — the best find of the review
Rosetta 2 **can** translate AVX and AVX2 — its runtime carries
`translate_avx_low`, `guest_avx_state_from_host_state` and an
`X86MachineContextAvx64` — but it does not tell the guest so unless asked.
Verified with a CPUID probe in a translated process on macOS 27:

    default:                    AVX=0  AVX2=0
    ROSETTA_ADVERTISE_AVX=1:    AVX=1  AVX2=1

The symptom is a game refusing to start over CPU requirements, or silently
taking a slower non-AVX path, on a machine that could run the AVX one. Shipped
as `GameTweaks.advertiseAVX`. Off by default because Apple made it opt-in: a
title that then takes an AVX path exercises translation the default
configuration never runs, so per-game reversibility matters.

This one came from combining a web lead with an empirical check — the search
mentioned the variable, the CPUID probe proved it does something. Neither half
would have been enough.

### D3DMetal shader bounds checking is on by default
The full `D3DM_*` inventory, with defaults read from the disassembly rather
than assumed. All are parsed with `atoi`; the ones marked *default on* preload
their register with 1 and let the variable override it, so those can only ever
be written to turn a feature **off**:

| Variable | Default | Effect |
| --- | --- | --- |
| `D3DM_BOUNDS_CHECK` | **on** | bounds-tests every translated resource access |
| `D3DM_MIN_LOD_CLAMP` | on | clamps minimum mip level |
| `D3DM_LOD_BIAS` | on | LOD bias support (a toggle, not a value) |
| `D3DM_POSITION_INVARIANCE` | on | consistent vertex positions across passes |
| `D3DM_FLUSH_POS_INF_TO_NAN` | on | float edge-case handling |
| `D3DM_IGNORE_D3D11_RENDER_BARRIERS` | from device caps | skips render-to-UAV barriers |
| `D3DM_SUPPORT_DXR` | from device caps | ray tracing |
| `D3DM_MTL4` | capability probe | Metal 4 backend (macOS 27+) |

`D3DM_BOUNDS_CHECK` is the interesting one: a bounds test on every resource
access is GPU work inside the inner loop of every shader. Shipped as
`GameTweaks.disableBoundsChecking`, off by default and D3DMetal-only.

The failure mode is why it stays opt-in: without the check an out-of-bounds
read returns undefined data instead of a clamped result, and on a GPU that is a
hang or corruption rather than a tidy error. Apple did not leave this on by
accident. Unmeasured — worth an A/B on a shader-heavy title.

`D3DM_IGNORE_D3D11_RENDER_BARRIERS` is the second candidate, but it defaults
from device capability rather than a constant, so overriding it means
contradicting what the driver reported. Not shipped.

### GTA 5 must never see an NVIDIA adapter — and the guard is backend-specific
`CW HACK 19355` in `dlls/wined3d/directx.c` rewrites the adapter identity to an
AMD Radeon RX 480 when the executable is `GTA5.exe` and the vendor reads as
NVIDIA, because the game crashes on launch trying to initialise NVAPI.

**The hack lives in wined3d only.** A game running on D3DMetal never passes
through it, so Sommelier's NVIDIA adapter override
(`D3DM_VENDOR_ID`/`D3DM_DEVICE_ID`, currently scoped to Jurassic World
Evolution 2) would crash GTA 5 with no protection. The existing per-app guard
already prevents this; the rule is that the spoof stays opt-in per title and is
never made general. Deep Rock Galactic independently confirms the danger — it
hangs when given the same identity.

---

## 2. Ruled out — already correct, do not "fix" these

### App Nap is already handled
`winemac.drv` defaults `enable_app_nap = false` and calls
`beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep` at
startup (`cocoa_app.m`). macOS is already told not to throttle the process.
Nothing to gain.

### Mach thread policy is already sophisticated
`server/thread.c` maps Windows thread priorities onto Mach policies — latency
and throughput QoS tiers, timeshare off above priority 14, precedence
importance, and promotion into the realtime band (96–127) with a time-constraint
policy for time-critical threads. This is better than most Wine-on-macOS
assumptions. There is no cheap win here.

### Controllers already work
`checking for SDL.h... yes`, `-lSDL2` found, and both `bus_iohid.c` (macOS HID)
and `bus_sdl.c` compile into `winebus.sys`. Gamepad support needs nothing added.
This one would have been easy to guess wrong.

### Rewriting Wine subsystems in C++/Rust
Considered and rejected. Wine is C and compiles to the same machine code; there
is no language tax to reclaim. The measurement that settles it: The Witcher 3's
main menu runs at **300 fps — 3.3 ms** through the entire stack, so the
translation layer is a rounding error when there is little to draw. In-world
cost is the game's own x86 code under Rosetta, D3DMetal's command translation,
and raw GPU work — none of which is Wine's C.

The real CPU win on Apple Silicon is architectural: an **ARM64-native engine**,
which removes Rosetta from Wine itself. That arrives with CrossOver 27's
sources, not from patching 26.

---

## 3. Open — investigated, not resolved

### Vulkan library resolution
`checking for -lvulkan... not found`. MoltenVK ships `libMoltenVK.dylib`, not
`libvulkan`. CrossOver solves this with a `CX_LIBVULKAN` environment knob (found
in the source's env-var inventory), and Sommelier already ships
`libMoltenVK.dylib` in `Runtimes/Frameworks`, which is on
`DYLD_FALLBACK_LIBRARY_PATH`.

So DXVK and VKD3D on this engine most likely need `CX_LIBVULKAN` pointed at it.
**Unverified** — do not assume it works until a DXVK title runs on this engine.

### libinotify
`filesystem change notifications won't be supported`. Not in Homebrew; macOS
needs libinotify-kqueue built from source. CrossOver links
`@rpath/libinotify.0.dylib` and Sommelier already ships that dylib — only the
headers are missing at build time. Affects `ReadDirectoryChangesW`, which
launchers and mod managers use more than games do. Low priority, bounded work.

### "Composited" in the Metal HUD, and what display capture actually needs
The HUD has read `Composited` (orange) in every capture this session, which
means the WindowServer is compositing the game rather than scanning its layer
out directly — a full-screen composite per frame that direct scanout would
skip.

`CaptureDisplaysForFullscreen` is already `"y"` in the prefix, and the driver's
condition for using it is exact (`cocoa_window.m`):

    nowFullscreen = !(styleMask & NSWindowStyleMaskFullScreen)
                    && screen_covered_by_rect(contentRect, [NSScreen screens])

so the window must cover a screen and must *not* be in macOS-native fullscreen;
only then does `updateFullscreenWindows` call `CGCaptureAllDisplays()`.

Both conditions appear satisfied in the sessions measured, so capture is
presumably happening and the compositing has another cause. The most plausible
remaining one is scaling: a 1440x900 drawable on a 2880x1800 panel has to be
resampled by the WindowServer, and that alone forbids direct scanout. If that is
right the "fix" is to render at the native backing resolution — four times the
pixels to save one composite, which is a bad trade on a 7-core GPU and explains
nothing worth changing.

**Unresolved.** Distinguishing "capture failed", "the HUD forces compositing"
and "scaling forbids it" needs controlled launches with the HUD toggled and the
resolution matched to the panel. Worth doing only if someone wants to chase the
last composite; the mechanism above is written down so the next attempt starts
from the condition rather than from guesswork.

### MoltenVK tunables
The MoltenVK tree ships performance-relevant knobs worth an A/B if DXVK ever
becomes the interesting backend here:

- `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS` — deferred vs immediate encoding;
  a real CPU-overhead trade
- `MVK_CONFIG_FAST_MATH_ENABLED` — on-demand by default
- `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS` — descriptor overhead
- `MVK_CONFIG_PERFORMANCE_TRACKING` — measurement, not tuning

Untested. Only worth pursuing for a DXVK/VKD3D title, since D3DMetal does not
go through Vulkan at all.

### PE compiler choice is runtime behavior, not just build machinery

The first engines used llvm-mingw/Clang for the PE side. Steam painted but its
CM coroutine repeatedly scheduled a 50 ms connection and never entered
`YieldingConnect`. Focused condition-variable, address-wait, fiber/FLS and
clock probes all passed, so this looked like a Unix scheduler failure.

A binary boundary bisect proved otherwise: substituting only CrossOver 26.3's
`kernelbase.dll` made the unchanged Sommelier engine fetch and connect to the
CM list immediately. That DLL identifies its compiler as GCC 13.2; ours was
Clang-built. Engine 1.0.2 now uses MinGW GCC 16.1 for all PE modules and keeps
their flags at `-O2 -g0`; its untouched CI artifact passed the real Steam CM
test (`YieldingConnect`, CM list fetch, then WebSocket `ConnectionCompleted`).
Do not reintroduce `-march=x86-64-v2` without another Steam CM A/B—the earlier
primitive probes were not sufficient to catch this class of code-generation
failure.

---

## 4. Where the search stopped paying

The surfaces reviewed: CrossOver's full LGPL tree (env inventory, `CW HACK`
inventory, `winemac.drv` registry keys, `server/thread.c`, wined3d settings),
D3DMetal's complete `D3DM_*` inventory with disassembled defaults, Rosetta's
runtime strings, MoltenVK's `MVK_CONFIG_*` set, DXVK's options, and the
community patch repositories.

What that yielded, in order of value: Rosetta AVX advertisement (verified by
CPUID probe), D3DMetal bounds checking (default read from disassembly),
GStreamer (a real missing dependency), `WINENCPU` (~2% on the wrong engine
type), and a set of negative results that are worth as much — App Nap, thread
QoS and controller support are all already correct.

Later passes returned progressively less: DXVK's options do not apply to a
D3DMetal setup, MoltenVK's do not either, and wined3d's registry settings
(`csmt`, `VideoMemorySize`, shader model caps) only affect the WineD3D backend
that games here do not use. **Further searching of these surfaces is unlikely to
pay.** The remaining large win is architectural — an ARM64-native engine — not
another flag.

## 5. Patch ecosystem

Catalogued in `patches/CANDIDATES.md` with provenance. The two class fixes worth
carrying are the Endfield project's Rosetta signal corrections (multi-byte NOP
fault and CR3 exception type — affects every VMProtect-protected title on Apple
Silicon) and the PEAK project's `EnableMouseInPointer` implementation (Unity 6
mouse input). The first is staged and approved, pending baseline verification.

`marzent/wine-msync` is already in CrossOver's tree — it is what `WINEMSYNC=1`
uses. NTSync is Linux-only. wine-tkg is Linux-centric. Nothing there to take.

Sommelier already ships **newer** translation layers than CrossOver 26 does
(DXMT 0.80 against their 0.72, vkd3d-proton 3.0.1), which is where
translation-layer performance actually moves.
