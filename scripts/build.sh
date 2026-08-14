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
# llvm-mingw supplies the PE cross-compilers; bison in macOS is too old.
# CI installs these via homebrew (see workflow); locally: brew install
# llvm-mingw bison mingw-w64 freetype gnutls sdl2 || true
export PATH="$(brew --prefix bison)/bin:$PATH"
command -v x86_64-w64-mingw32-clang >/dev/null \
    || { echo "llvm-mingw not on PATH (brew install llvm-mingw)"; exit 1; }

# The Unix side is x86_64: build under Rosetta on arm64 runners.
ARCH_PREFIX=""
if [ "$(uname -m)" = "arm64" ]; then ARCH_PREFIX="arch -x86_64"; fi

# ---- 3. Configure + make ---------------------------------------------------
# Notes on flags, kept because they are the part that costs the time:
#   --enable-archs=i386,x86_64  new-WOW64: PE DLLs for both, one Unix binary
#   --without-x                 the Mac driver, not X11
#   --with-metal / moltenvk     vulkan loader comes from MoltenVK at runtime
#   --disable-winedbg           trims the bundle; revisit if debugging needs it
cd "$BUILD"
$ARCH_PREFIX "$SOURCES/wine/configure" \
    --prefix="$PREFIX" \
    --enable-archs=i386,x86_64 \
    --without-x \
    --without-alsa --without-pulse \
    --with-freetype --with-gnutls \
    --disable-tests \
    CC="clang" CXX="clang++" \
    CROSSCC="x86_64-w64-mingw32-clang"

$ARCH_PREFIX make -j"$JOBS"
$ARCH_PREFIX make install-lib

echo "Build complete: $PREFIX"
