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

### Optimization flags are unproven
`-O3 -g0 -msse4.2 -mpopcnt` (Unix side), `-O2 -march=x86-64-v2` (PE side).
Reasonable bets, **not measured** against a stock build. `OPTIMIZE=0` restores
Wine's defaults so a suspected miscompile can be bisected in one rebuild. AVX2
(`x86-64-v3`) is deliberately excluded: Rosetta only gained it recently and a v3
engine would crash on older systems for a gain Wine barely sees.

---

## 4. Patch ecosystem

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
