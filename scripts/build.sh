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
export PATH="$WORK/$LLVM_MINGW/bin:$(brew --prefix bison)/bin:$PATH"
command -v x86_64-w64-mingw32-clang >/dev/null \
    || { echo "llvm-mingw extraction failed"; exit 1; }

# The Unix side is x86_64: build under Rosetta on arm64 runners.
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
if [ "${OPTIMIZE:-1}" = "1" ]; then
    UNIX_CFLAGS="-O3 -g0 -march=x86-64-v2"
    PE_CFLAGS="-O2 -g0 -march=x86-64-v2"
else
    UNIX_CFLAGS=""
    PE_CFLAGS=""
fi

cd "$BUILD"
$ARCH_PREFIX "$SOURCES/wine/configure" \
    --prefix="$PREFIX" \
    --enable-archs=i386,x86_64 \
    --without-x \
    --without-alsa --without-pulse \
    --with-freetype --with-gnutls \
    --disable-tests \
    CC="clang" CXX="clang++" \
    CROSSCC="x86_64-w64-mingw32-clang" \
    ${UNIX_CFLAGS:+CFLAGS="$UNIX_CFLAGS"} \
    ${PE_CFLAGS:+CROSSCFLAGS="$PE_CFLAGS"}

$ARCH_PREFIX make -j"$JOBS"
$ARCH_PREFIX make install-lib

echo "Build complete: $PREFIX"
