# Patch candidates — mined 2026-08-14

Curated from the per-game fix ecosystem. **None are applied**: the first engine
is a faithful build (see README.md in this directory), and every candidate
lands as its own A/B experiment against that baseline, measured, one at a time.

Ordered by breadth of impact, not by the game that prompted them — the games
themselves (PEAK, Cities Skylines 2, Endfield) are not in the reference
library, but two of these fix *classes* of titles that are.

## 1. Rosetta signal fixes — the VMProtect class
**Source:** stoicswe/Endfield_FineWine, `patches/stage1-macos`
(~40 lines in `dlls/ntdll/unix/signal_x86_64.c`)

Two Rosetta 2 misbehaviours, found via Arknights: Endfield but generic:
- Rosetta raises illegal-instruction on multi-byte `0F 1F` NOPs, which
  VMProtect emits by the hundred thousand → crash loops in *any*
  VMProtect/TenProtect-protected title (cf. WineHQ bug 45083).
- `mov rbx, cr3` arrives as invalid-opcode instead of `#GP`, so anti-VM
  probes get the wrong exception.

Class: every protected Windows game on Apple Silicon. Compatibility, not
performance. Small, reviewable, engine-level. **Strongest candidate.**

**Status: APPROVED (2026-08-14), staged, awaiting baseline verification.**
The patch is fetched and reviewed in `staged-rosetta-vmprotect/` — the NOP
length decode is a correct modrm/SIB/disp walk hooked into Wine's existing
`handle_cet_nop` skip path (41 added lines, MIT-licensed, applies to
`dlls/ntdll/unix/signal_x86_64.c`). Upstream tested against CX 26.2; ours is
26.3, so expect clean-or-fuzzed apply. To activate once the faithful baseline
passes the AGENTS checklist:

    git mv patches/staged-rosetta-vmprotect/0001-*.patch patches/
    # dispatch a build — ccache makes the delta minutes, not hours —
    # then A/B a VMProtect-protected title against the baseline engine.

Their `0000` build-fix patch is deliberately not staged: it works around the
same SONAME_LIBVULKAN error our pipeline hit in run 7, which we solved
properly by building against MoltenVK (Vulkan support is wanted, not
avoided).

The repo's `stage2-dwproton` set (ntoskrnl backports + dispatcher spoofs for
ACE anti-cheat) is deliberately NOT a candidate: it is per-anti-cheat work
with ToS exposure, and belongs to a user's own decision, not a default engine.

## 2. EnableMouseInPointer — the Unity 6 class
**Source:** kiku-jw/peak-crossover-mouse-fix, `patches/`
(user32.dll / win32u.dll / win32u.so)

Wine's `EnableMouseInPointer` returns "Call not implemented"; Unity 6's new
input path calls it and loses mouse clicks — cursor moves, nothing reacts.
Found via PEAK, applies to Unity 6 titles generally, and the library this
engine serves contains many Unity games that will migrate to Unity 6.
Signature to watch in any misbehaving Unity title's `Player.log`:
`EnableMouseInPointer failed with the following error: Call not implemented`.

## 3. CoreAudio SysEx truncation
**Source:** yoshimodular/wine-coreaudio-sysex-fix
(`dlls/winecoreaudio.drv/coremidi.c`, `midi_send`: fixed 512-byte
`MIDIPacketList` silently drops any SysEx over 498 bytes; unfixed upstream
since 2015)

Class: MIDI software, not games. Tiny and obviously correct; low priority for
a game launcher, worth carrying because it costs nothing.

## Catalogued, not engine material
- **alexqzd/cs2-crossover-patcher** — patches the game's own .NET assemblies
  (PDX.SDK.dll lock deadlock under Wine). Right shape for Sommelier's
  per-game compatibility layer (`SteamGameCompatibility`), wrong shape for an
  engine; ship only if/when the game is owned and verified.
- **cbusillo/macos-game-patches** — VR research harness, out of scope.

## Process
Baseline first. Then one patch per experiment: apply → build (ccache makes
this cheap) → verify the AGENTS checklist still passes → measure the claimed
fix against a title that exhibits the problem. A patch whose effect cannot be
demonstrated on a real title stays out of the default engine regardless of how
good it looks.
