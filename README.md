# Sommelier Engines

Build pipeline for Sommelier's own Wine engines, compiled from CodeWeavers'
openly published LGPL sources. Producing these ourselves removes the app's
dependence on importing a user's CrossOver installation: the engine users get
by default is built from source we publish, with compliance handled at release
time by construction.

## How it fits together

```
crossover-sources-<v>.tar.gz  (CodeWeavers, LGPL parts of CrossOver)
        │  scripts/build.sh          — configure + make, Unix side and PE side
        ▼
build output
        │  scripts/assemble-bundle.sh — wswine.bundle layout, entitlements, signing
        ▼
WS12WineSommelier<v>.tar.xz            (GitHub Release asset)
        +  crossover-sources-<v>.tar.gz   ← republished beside the binaries
        +  patches/ + scripts/ tarball    ← the rest of "complete corresponding source"
        ▼
feed/EngineList.txt            — one engine name per line; Sommelier's
                                 EngineInstaller consumes this via a third
                                 EngineFeed (archiveExtension: "tar.xz")
```

The app parses `EngineList.txt` as one engine name per line, and **only parses names matching `WS<n>Wine<flavour><version>`** — anything else is silently ignored, which made the first build invisible in the app. `Sommelier` is a registered flavour, so `WS12WineSommelier1.0.0` parses and displays correctly and downloads
`<downloadBase>/<name>.<archiveExtension>`. Keep names in the `WS12WineSommelier1.0.0`
shape — the `WS<n>Wine…` prefix belongs to Wineskin's feed; ours differs so the
origin of an engine is never ambiguous.

## Status

The CI pipeline produces installable, LGPL-compliant macOS engines from
CodeWeavers' published sources (new-WOW64: one x86_64 Unix binary, PE DLLs for
x86_64 and i386 via MinGW GCC). Draft releases remain unpublished until the
artifact passes the real-machine gate below. Reference pipelines used while
bringing the build up:

- https://github.com/Gcenx/winecx (the source tree, mirrored, with build hints)
- https://github.com/GabLeRoux/macos-crossover-wine-cloud-builder (Actions workflow)
- Whisky's WhiskyWineFiles workflows (same problem, solved)

## Verification gate

A built engine is not "done" when it compiles. Before it goes in the feed it
must pass, on a real machine, the checklist in Sommelier's AGENTS.md:

1. prefix boot (wineboot exits 0; needs the shared support frameworks)
2. msync on, RetinaMode honoured
3. Steam client starts and logs in
4. interposer injection (loaders carry the dyld entitlement — baked in here at
   assemble time, not re-signed after the fact)
5. GPTK attach: `D3DMETALPATH` + D3DMetal renders in a real game
   (the `apple_gptk` hooks are in the published Wine source; verify, don't assume)

Kenshi (D3D11, CPU-bound) and The Witcher 3 (D3D12, GPU-bound) are the
regression pair.

## Tuning

`docs/ENGINE-TUNING.md` records the review of CrossOver's sources for
performance and compatibility: what was applied, what was **ruled out as
already correct** (App Nap, Mach thread policy, controller support — all fine
as shipped), and what remains open. Read the negative results before spending a
50-minute build on an idea; several obvious-looking wins are already in the
tree.

## Licensing

See COMPLIANCE.md. The short version: every release ships the exact source it
was built from beside the binaries, the LGPL text travels with the bundle, and
nothing here is named CrossOver.
