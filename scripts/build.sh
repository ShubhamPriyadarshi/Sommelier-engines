#!/bin/bash
# Builds Wine from CodeWeavers' published CrossOver sources on macOS.
#
# Shape of the build (CrossOver 26 / Wine 11, new WOW64):
#   - ONE Unix-side build, x86_64 (runs under Rosetta on Apple Silicon; an
#     arm64ec build is a later phase once CrossOver 27's approach is public)
#   - PE modules cross-compiled for x86_64 and i386 with llvm-mingw
#
# STATUS: scaffold. Every flag below is the known-good shape from public
# CrossOver-source pipelines (Gcenx/winecx, GabLeRoux's cloud builder), but this
# script has not yet survived CI end to end. Iterate here; keep the flags and
# the reasons in comments as they settle.
set -euo pipefail

VERSION="${CX_VERSION:-26.3.0}"
JOBS="$(sysctl -n hw.ncpu)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/work}"
SOURCES="$WORK/sources"
BUILD="$WORK/build"
PREFIX="$WORK/out"          # picked up by assemble-bundle.sh

SOURCE_TARBALL="crossover-sources-$VERSION.tar.gz"
SOURCE_URL="https://media.codeweavers.com/pub/crossover/source/$SOURCE_TARBALL"

mkdir -p "$WORK" "$SOURCES" "$BUILD" "$PREFIX"

# ---- 1. Sources ------------------------------------------------------------
if [ ! -f "$WORK/$SOURCE_TARBALL" ]; then
    curl -fL -o "$WORK/$SOURCE_TARBALL" "$SOURCE_URL"
fi
shasum -a 256 "$WORK/$SOURCE_TARBALL" | tee "$WORK/source-sha256.txt"
if [ ! -d "$SOURCES/wine" ]; then
    tar -xf "$WORK/$SOURCE_TARBALL" -C "$SOURCES" --strip-components=1
fi

# Our patches, applied in lexical order. The tarball of patches/ ships with
# every release as part of the corresponding source.
for patch in "$ROOT"/patches/*.patch; do
    [ -e "$patch" ] || continue
    patch -d "$SOURCES/wine" -p1 --forward < "$patch"
done

# ---- 2. Toolchain ----------------------------------------------------------
# llvm-mingw supplies the PE cross-compilers. It is not a Homebrew formula
# (verified: the first CI run died on exactly that), so fetch the official
# macOS-universal release instead — pinned, because a floating "latest" makes
# builds unreproducible and the toolchain is part of the corresponding source
# story. bison comes from brew; macOS's own is too old for Wine.
LLVM_MINGW_VERSION="20260616"
LLVM_MINGW="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
if [ ! -d "$WORK/$LLVM_MINGW" ]; then
    curl -fL -o "$WORK/$LLVM_MINGW.tar.xz" \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW.tar.xz"
    tar -xf "$WORK/$LLVM_MINGW.tar.xz" -C "$WORK"
fi
# llvm-mingw goes at the END of PATH and never the front: it ships a bare
# `clang` beside its prefixed cross tools, and at the front it shadowed Apple's
# clang — configure then died on `ld: library 'System' not found`, upstream
# clang having no macOS SDK default. That one line was runs 2-4's only failure.
# The compilers are passed by absolute path below so PATH order cannot decide
# which compiler builds what; PATH only serves the prefixed helper tools.
export PATH="$(brew --prefix bison)/bin:$PATH:$WORK/$LLVM_MINGW/bin"
LLVM_BIN="$WORK/$LLVM_MINGW/bin"
CROSS_CLANG="$LLVM_BIN/x86_64-w64-mingw32-clang"
# Named explicitly because configure would otherwise find these by name and
# use them unwrapped; assert they exist rather than silently falling back.
for tool in i686-w64-mingw32-gcc x86_64-w64-mingw32-gcc; do
    [ -x "$LLVM_BIN/$tool" ] || { echo "llvm-mingw has no $tool"; exit 1; }
done
[ -x "$CROSS_CLANG" ] || { echo "llvm-mingw extraction failed"; exit 1; }

# The Unix side is x86_64. `arch -x86_64` alone is NOT enough: clang keys its
# default target off more than the process architecture — verified locally,
# where clang under `arch -x86_64` still emitted arm64 ("unsupported option for
# target 'arm64-apple-darwin'"). The target is therefore pinned with an
# explicit -arch on the compiler, and `arch -x86_64` remains only so the build
# can RUN the x86_64 tools it just built (through Rosetta).
ARCH_PREFIX=""
if [ "$(uname -m)" = "arm64" ]; then ARCH_PREFIX="arch -x86_64"; fi

# ---- 3. Configure + make ---------------------------------------------------
# Notes on flags, kept because they are the part that costs the time:
#   --enable-archs=i386,x86_64  new-WOW64: PE DLLs for both, one Unix binary
#   --without-x                 the Mac driver, not X11
#   --with-metal / moltenvk     vulkan loader comes from MoltenVK at runtime
#   --disable-winedbg           trims the bundle; revisit if debugging needs it
# ---- Optimization ----------------------------------------------------------
# Target: Apple Silicon running the result through Rosetta 2. Honest framing:
# flags here buy low single digits — the engine's hot paths are the game's own
# code and the graphics backend, not Wine — but the right set still matters:
#
#   -O3 on the Unix side       Wine's default is -O2; the Unix side carries the
#                              server round-trips and msync paths.
#   -O2 on the PE side         the builtin DLLs; kept a notch conservative
#                              because a miscompiled d3d/ntdll PE is the
#                              hardest failure in this stack to diagnose.
#   -march=x86-64-v2           SSE4.2/POPCNT everywhere. Rosetta translates v2
#                              cleanly on every macOS this can run on. v3 (AVX2)
#                              is deliberately NOT used: Rosetta only gained
#                              AVX2 recently and a v3 engine would crash on
#                              older systems for a gain Wine itself barely sees.
#   -g0                        no debug info; smaller bundle, faster cold load.
#
# OPTIMIZE=0 rebuilds with Wine's own defaults, for bisecting a suspected
# flag-induced miscompile before blaming the source.
# Apple clang rejects -march=x86-64-v2 (the microarch level names are
# upstream-LLVM only; verified locally, it fails in one second) — the Unix
# side uses feature flags instead. The PE side keeps the level name: llvm-mingw
# IS upstream clang and accepts it.
if [ "${OPTIMIZE:-1}" = "1" ]; then
    UNIX_CFLAGS="-O3 -g0 -msse4.2 -mpopcnt"
    PE_CFLAGS="-O2 -g0 -march=x86-64-v2"
else
    UNIX_CFLAGS=""
    PE_CFLAGS=""
fi

# Dependencies come from the x86_64 Homebrew at /usr/local (see workflow);
# the arm64 one at /opt/homebrew must never leak into the link. Pinning
# PKG_CONFIG_LIBDIR (not just PATH) is what guarantees that.
X86_BREW="/usr/local"
# The binary is `pkg-config` or `pkgconf` depending on the formula era; run 6
# proved that guessing the name silently breaks every package whose headers
# are not directly under include/ — gnutls passed while freetype's
# include/freetype2/ft2build.h was invisible. Resolve whichever exists, and
# fail loudly if neither does.
PKG_CONFIG=""
for candidate in "$X86_BREW/bin/pkg-config" "$X86_BREW/bin/pkgconf"; do
    [ -x "$candidate" ] && PKG_CONFIG="$candidate" && break
done
[ -n "$PKG_CONFIG" ] || { echo "no x86_64 pkg-config in $X86_BREW/bin"; exit 1; }
export PKG_CONFIG
# PKG_CONFIG_LIBDIR replaces pkgconf's entire search path, and that is exactly
# why it is used: nothing under /opt/homebrew (arm64) may leak into an x86_64
# link. But a single directory is too narrow. Homebrew deliberately does not
# symlink keg-only formulas (icu4c, openssl@3, expat, readline, sqlite) into
# lib/pkgconfig, so their .pc files are invisible there — and a package whose
# own .pc *is* in that directory still fails to resolve when a transitive
# Requires: lands on one of them. That is how gstreamer-1.0.pc managed to be
# present and unusable at the same time. Enumerate every keg under the x86_64
# prefix; all of them live under /usr/local, so the arm64 guarantee holds.
#
# gnutls failed this check a run earlier and was dismissed as over-strict.
# Half right: configure does find gnutls by link test and never reads its .pc,
# so the check is not required — but it is a cheap canary for search-path
# completeness, and it went on to catch the missing system directory below
# that would have taken GStreamer down too. Worth keeping for that alone.
PC_DIRS="$X86_BREW/lib/pkgconfig:$X86_BREW/share/pkgconfig"
for pc_dir in "$X86_BREW"/opt/*/lib/pkgconfig "$X86_BREW"/opt/*/share/pkgconfig; do
    [ -d "$pc_dir" ] && PC_DIRS="$PC_DIRS:$pc_dir"
done
# macOS's own pkgconfig directory, last so Homebrew always wins a name
# collision. Replacing the default path dropped this too, and that is what
# "Package 'zlib', required by 'gnutls', not found" was: zlib ships with the
# system, not from brew, and zlib.pc lives only here. The .pc files are plain
# text describing universal system libraries, so this is arch-neutral.
[ -d /usr/lib/pkgconfig ] && PC_DIRS="$PC_DIRS:/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PC_DIRS"

# Resolve the packages configure will need, with --print-errors so a failure
# names the unresolvable dependency instead of costing a run to diagnose.
# Collected, not fail-fast: stopping at the first unresolved package meant a
# CI run bought exactly one name and the next hid behind it.
pc_failed=""
for pc in glib-2.0 gobject-2.0 gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0; do
    if "$PKG_CONFIG" --print-errors --exists "$pc"; then
        echo "  ok: $pc $("$PKG_CONFIG" --modversion "$pc")"
    else
        pc_failed="$pc_failed $pc"
    fi
done
[ -z "$pc_failed" ] || {
    echo "FATAL: unresolved:$pc_failed — configure would disable GStreamer"
    exit 1
}
# freetype2 on CPPFLAGS as well, so the build does not depend on pkg-config
# behaving for the one library whose headers hide a directory down.
DEP_CPPFLAGS="-I$X86_BREW/include -I$X86_BREW/include/freetype2"
DEP_LDFLAGS="-L$X86_BREW/lib"

# ccache turns a retry into "recompile only past the failure point": objects
# are keyed on preprocessed content, so dependency and flag changes invalidate
# only what they actually touch. The wrappers prefix the real compilers.
# Looked up in the known install locations as well as PATH: a PATH lookup
# alone silently returned nothing on CI, and "no ccache" is indistinguishable
# from "cache miss" once the build is running.
CCACHE="$(command -v ccache || true)"
for candidate in /usr/local/bin/ccache /opt/homebrew/bin/ccache; do
    [ -n "$CCACHE" ] && break
    [ -x "$candidate" ] && CCACHE="$candidate"
done
if [ -n "$CCACHE" ]; then
    echo "ccache: $CCACHE ($("$CCACHE" --version 2>/dev/null | head -1))"
    export CCACHE_DIR="$WORK/ccache"
    # Created up front so the workflow's save step always has a path to
    # archive. Its absence is what made every save report a validation error
    # rather than an empty cache.
    mkdir -p "$CCACHE_DIR"
    export CCACHE_MAXSIZE=3G
    # Without these the hit rate on a CI runner is far lower than it looks:
    #   BASEDIR      the tree is re-extracted under an absolute path each run;
    #                rewriting paths relative to it keeps hashes stable.
    #   time_macros  Wine compiles files using __DATE__/__TIME__, which ccache
    #                refuses to cache at all unless told they do not matter.
    #   file_stat_matches + include_file_mtime/ctime
    #                a fresh tar gives every file a new mtime, so identical
    #                content would otherwise miss on metadata alone.
    #   COMPILERCHECK=content
    #                the cross compiler lives under $WORK, so its path changes
    #                meaning; hash what it *is* rather than where it sits.
    export CCACHE_BASEDIR="$WORK"
    export CCACHE_SLOPPINESS="time_macros,file_stat_matches,include_file_mtime,include_file_ctime"
    export CCACHE_COMPILERCHECK=content
    HOST_CC="$CCACHE /usr/bin/clang -arch x86_64"
    HOST_CXX="$CCACHE /usr/bin/clang++ -arch x86_64"
    CROSS_CC="$CCACHE $CROSS_CLANG"
    # The PE side is 97% of the build and does not go through CROSSCC.
    # Measured: 8621 compiles, of which 4214 were i686-w64-mingw32-gcc and
    # 4143 x86_64-w64-mingw32-gcc, against only 264 through the wrapped host
    # compiler. Wine 11 with --enable-archs takes a compiler per architecture
    # in `<arch>_CC`, and leaving those empty lets configure discover the cross
    # tools by name — unwrapped, and therefore uncached.
    PE_CC_I386="$CCACHE $LLVM_BIN/i686-w64-mingw32-gcc"
    PE_CC_X86_64="$CCACHE $LLVM_BIN/x86_64-w64-mingw32-gcc"
else
    echo "::warning::ccache not found — this build will not be checkpointed"
    PE_CC_I386="$LLVM_BIN/i686-w64-mingw32-gcc"
    PE_CC_X86_64="$LLVM_BIN/x86_64-w64-mingw32-gcc"
    HOST_CC="/usr/bin/clang -arch x86_64"
    HOST_CXX="/usr/bin/clang++ -arch x86_64"
    CROSS_CC="$CROSS_CLANG"
fi

cd "$BUILD"
$ARCH_PREFIX "$SOURCES/wine/configure" \
    --prefix="$PREFIX" \
    --enable-archs=i386,x86_64 \
    --without-x \
    --without-alsa --without-pulse \
    --with-gstreamer \
    --with-freetype --with-gnutls \
    --disable-tests \
    --host=x86_64-apple-darwin \
    CC="$HOST_CC" CXX="$HOST_CXX" \
    CROSSCC="$CROSS_CC" \
    i386_CC="$PE_CC_I386" \
    x86_64_CC="$PE_CC_X86_64" \
    CPPFLAGS="$DEP_CPPFLAGS" LDFLAGS="$DEP_LDFLAGS" \
    ${UNIX_CFLAGS:+CFLAGS="$UNIX_CFLAGS"} \
    ${PE_CFLAGS:+CROSSCFLAGS="$PE_CFLAGS"}

$ARCH_PREFIX make -j"$JOBS"
$ARCH_PREFIX make install-lib

# Printed rather than assumed: "the cache should make this fast" was a guess,
# and the hit rate is the only thing that settles whether it did.
if [ -n "$CCACHE" ]; then
    echo "=== ccache statistics ==="
    "$CCACHE" --show-stats 2>/dev/null || "$CCACHE" -s 2>/dev/null || true
fi

# Wine disables silently: a missing dependency is a warning during configure
# and an absent feature at runtime, months later, in a game that will not play
# its cutscene. Fail here instead, for the ones a game launcher actually needs.
for required in gstreamer; do
    if grep -qi "$required.*won't be supported" "$BUILD/config.log" 2>/dev/null; then
        echo "FATAL: configure disabled $required — the dependency is missing"
        exit 1
    fi
done

echo "Build complete: $PREFIX"
echo "=== features configure disabled (informational) ==="
grep -i "won't be supported" "$BUILD/config.log" 2>/dev/null | sed 's/^/  /' || true
