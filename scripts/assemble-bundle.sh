#!/bin/bash
# Lays the build output into the wswine.bundle shape Sommelier expects, bakes
# in the injection entitlement, signs, and produces the release archive.
#
# The layout is the contract with Sommelier's WineInstallation/LaunchEnvironment:
#   wswine.bundle/
#     bin/wine64, bin/wineserver, bin/wineloader (symlink or copy of wine64)
#     lib/wine/x86_64-unix/*.so   (incl. the re-exec target `wine`)
#     lib/wine/x86_64-windows/*.dll
#     lib/wine/i386-windows/*.dll
#     share/wine/...
#     share/doc/LICENSE.LGPL-2.1, share/doc/NOTICE
#
# Entitlements are baked here — at build time, on every loader — because the
# alternative (re-signing an imported engine later) is exactly the step whose
# omission once cost a day: dyld silently strips DYLD_INSERT_LIBRARIES from a
# hardened binary without com.apple.security.cs.allow-dyld-environment-variables,
# and Wine re-executes into lib/wine/x86_64-unix/wine, so THAT binary needs the
# entitlement as much as bin/wine64 does.
set -euo pipefail

# Two versions, deliberately distinct. SOURCE_VERSION identifies the upstream
# tarball this engine is built from — a provenance fact that lives in NOTICE
# and beside the binaries as complete corresponding source. VERSION is the
# engine's own identity and names everything user-visible; LGPL obliges
# source correspondence and notices, never naming.
SOURCE_VERSION="${CX_VERSION:-26.3.0}"
VERSION="${ENGINE_VERSION:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/work}"
PREFIX="$WORK/out"
BUNDLE="$WORK/WS12WineSommelier$VERSION/wswine.bundle"
ENTITLEMENTS="$ROOT/resources/loader-entitlements.plist"

rm -rf "$WORK/WS12WineSommelier$VERSION"
mkdir -p "$BUNDLE"

cp -R "$PREFIX/bin"   "$BUNDLE/bin"
cp -R "$PREFIX/lib"   "$BUNDLE/lib"
cp -R "$PREFIX/share" "$BUNDLE/share"

# ---- Runtime dependency closure --------------------------------------------
# The engine links against x86_64 Homebrew dylibs that users do not have.
# CrossOver's answer, which Sommelier's launch environment already expects, is
# lib/external: DYLD_FALLBACK_LIBRARY_PATH searches it by leaf name when the
# recorded /usr/local install name resolves to nothing on the user's machine —
# which is exactly why a plain copy of the closure works with no
# install_name_tool surgery. Walk otool -L transitively from every built
# binary and copy in everything that lives under /usr/local.
mkdir -p "$BUNDLE/lib/external"

# Seed the closure with the dlopen'd sonames first. The transitive walk below
# reads otool -L, which only sees link-time dependencies — anything Wine
# dlopens by soname (configure's SONAME_LIB* mechanism) appears in no load
# command and is invisible to it. That is how the first bundle shipped without
# FreeType (no fonts), gnutls (no schannel TLS, so no Steam login), MoltenVK
# (no Vulkan) or SDL2 (no controllers) while looking complete. The list is
# what `strings` finds as bare dylib names across the built unix .so files;
# cups and dbus resolve from macOS or degrade gracefully, so brew absence is
# not fatal for them.
for soname in libfreetype.6.dylib libgnutls.30.dylib libMoltenVK.dylib \
              libSDL2-2.0.0.dylib libodbc.dylib libdbus-1.3.dylib; do
    [ -f "$BUNDLE/lib/external/$soname" ] && continue
    # find -L: /usr/local/opt/* are symlinks into the Cellar, and plain find
    # refuses to descend through them — every seed silently "skipped" on the
    # first attempt. The same artifact already burned the run-14 diagnostics.
    src="$(find -L /usr/local/opt -name "$soname" -type f 2>/dev/null | head -1)"
    if [ -n "$src" ]; then
        cp "$src" "$BUNDLE/lib/external/$soname"
        chmod u+w "$BUNDLE/lib/external/$soname"
        echo "  seeded: $soname"
    else
        echo "  no brew copy of $soname (skipped)"
    fi
done
# Wine cannot work without fonts or TLS; fail the build rather than ship that.
for must in libfreetype.6.dylib libgnutls.30.dylib libMoltenVK.dylib; do
    [ -f "$BUNDLE/lib/external/$must" ] \
        || { echo "FATAL: $must not bundled"; exit 1; }
done

copied=1
while [ "$copied" -eq 1 ]; do
    copied=0
    while IFS= read -r -d '' macho; do
        for dep in $(otool -L "$macho" 2>/dev/null | awk '/\/usr\/local\//{print $1}'); do
            leaf="$(basename "$dep")"
            if [ -f "$dep" ] && [ ! -f "$BUNDLE/lib/external/$leaf" ]; then
                cp "$dep" "$BUNDLE/lib/external/$leaf"
                chmod u+w "$BUNDLE/lib/external/$leaf"
                copied=1
            fi
        done
    done < <(find "$BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -print0)
done
echo "Bundled $(ls "$BUNDLE/lib/external" | wc -l | tr -d ' ') external dylibs"

# ---- DXMT (D3D11/D3D10 on Metal) --------------------------------------------
# Steam's UI cannot paint without a working D3D11 backend, and only DXMT's is
# both open source and runnable on this engine: its winemetal bridge carries a
# self-contained unixlib ABI, so upstream builds work here unmodified
# (verified FL 11_0). GPTK's D3D11 needs CrossOver-private dispatch and
# crashes on this engine; wined3d GL tops out below what CEF's ANGLE needs.
# v0.80 is the last MIT-licensed release; later versions are LGPL 2.1+ and
# on upgrade move under the same compliance flow as Wine itself.
# Layout mirrors CrossOver's: PE dlls stay in lib/dxmt for installers to copy
# into a prefix's system32 (DXVK-style); winemetal's halves live where Wine
# loads builtins from. docs/STEAM-HOSTING.md has the full recipe.
DXMT_VERSION=v0.80
DXMT_SHA256=8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d
DXMT_TAR="$WORK/downloads/dxmt-$DXMT_VERSION-builtin.tar.gz"
mkdir -p "$WORK/downloads"
if [ ! -f "$DXMT_TAR" ]; then
    curl -fsSL --retry 3 -o "$DXMT_TAR" \
        "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz"
fi
echo "$DXMT_SHA256  $DXMT_TAR" | shasum -a 256 -c - \
    || { echo "FATAL: dxmt tarball checksum mismatch"; exit 1; }
DXMT_TMP="$WORK/dxmt-extract"
rm -rf "$DXMT_TMP" && mkdir -p "$DXMT_TMP"
tar -xzf "$DXMT_TAR" -C "$DXMT_TMP"
mkdir -p "$BUNDLE/lib/dxmt"
cp -R "$DXMT_TMP/$DXMT_VERSION/x86_64-windows" "$DXMT_TMP/$DXMT_VERSION/i386-windows" \
      "$DXMT_TMP/$DXMT_VERSION/x86_64-unix" "$BUNDLE/lib/dxmt/"
# winemetal is DXMT's Unix-call bridge and belongs with Wine's own builtins
# in every build. The d3d11/dxgi/d3d10core modules stay in lib/dxmt: the app
# deploys them per bottle when DXMT is the selected renderer, since they
# displace wined3d's for every title on the engine.
cp "$DXMT_TMP/$DXMT_VERSION/x86_64-unix/winemetal.so" "$BUNDLE/lib/wine/x86_64-unix/"
cp "$DXMT_TMP/$DXMT_VERSION/x86_64-windows/winemetal.dll" "$BUNDLE/lib/wine/x86_64-windows/"
cp "$DXMT_TMP/$DXMT_VERSION/i386-windows/winemetal.dll" "$BUNDLE/lib/wine/i386-windows/"
cp "$ROOT/resources/dxmt.LICENSE" "$BUNDLE/lib/dxmt/LICENSE"
echo "Bundled DXMT $DXMT_VERSION"

mkdir -p "$BUNDLE/share/doc"
cp "$ROOT/resources/LICENSE.LGPL-2.1" "$BUNDLE/share/doc/"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SOURCE_VERSION@/$SOURCE_VERSION/" \
    "$ROOT/resources/NOTICE.template" \
    > "$BUNDLE/share/doc/NOTICE"

# Every Mach-O that can become the game process gets the entitlement. The list
# mirrors EngineInjectionSupport.loaders() in Sommelier.
# Wine 11 with new WOW64 builds a single `bin/wine`; CrossOver's tree also
# ships `wine64` and `wineloader`, and Sommelier's re-signing looks for those
# names. Provide them as hard links so every consumer finds a loader under the
# name it expects, and so all three are one inode carrying one signature.
if [ -f "$BUNDLE/bin/wine" ]; then
    for alias in wine64 wineloader; do
        [ -e "$BUNDLE/bin/$alias" ] || ln "$BUNDLE/bin/wine" "$BUNDLE/bin/$alias"
    done
fi

# Sign everything else FIRST. The entitled loaders must come last: a blanket
# `codesign --force` without --entitlements silently strips them, which is
# exactly what happened on the first green build — the loaders were entitled
# and then re-signed blank a line later, and the interposer would have been
# stripped at runtime with no error anywhere.
find "$BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
    -exec codesign --force --sign "${SIGN_IDENTITY:--}" {} \; 2>/dev/null || true

LOADERS=(
    "$BUNDLE/bin/wine"
    "$BUNDLE/bin/wine64"
    "$BUNDLE/bin/wineloader"
    "$BUNDLE/lib/wine/x86_64-unix/wine"
)
for loader in "${LOADERS[@]}"; do
    [ -f "$loader" ] || continue
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "${SIGN_IDENTITY:--}" "$loader"
done

# Asserted rather than assumed: without this entitlement dyld strips
# DYLD_INSERT_LIBRARIES and the interposer never loads, with no error to see.
for loader in "${LOADERS[@]}"; do
    [ -f "$loader" ] || continue
    codesign -d --entitlements - "$loader" 2>/dev/null \
        | grep -q "allow-dyld-environment-variables" \
        || { echo "FATAL: $loader lost its entitlement"; exit 1; }
done
echo "Entitlements verified on $(ls "$BUNDLE/bin" | tr '\n' ' ')" 

# ---- Release artifacts -----------------------------------------------------
cd "$WORK"
tar -cJf "WS12WineSommelier$VERSION.tar.xz" "WS12WineSommelier$VERSION"
tar -czf "sommelier-engine-patches-$VERSION.tar.gz" \
    -C "$ROOT" patches scripts resources
echo "Artifacts:"
ls -lh "$WORK/WS12WineSommelier$VERSION.tar.xz" "$WORK/sommelier-engine-patches-$VERSION.tar.gz"
