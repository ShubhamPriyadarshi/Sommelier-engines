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

VERSION="${CX_VERSION:-26.3.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-$ROOT/work}"
PREFIX="$WORK/out"
BUNDLE="$WORK/SOMWineCX$VERSION/wswine.bundle"
ENTITLEMENTS="$ROOT/resources/loader-entitlements.plist"

rm -rf "$WORK/SOMWineCX$VERSION"
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

mkdir -p "$BUNDLE/share/doc"
cp "$ROOT/resources/LICENSE.LGPL-2.1" "$BUNDLE/share/doc/"
sed -e "s/@VERSION@/$VERSION/" "$ROOT/resources/NOTICE.template" \
    > "$BUNDLE/share/doc/NOTICE"

# Every Mach-O that can become the game process gets the entitlement. The list
# mirrors EngineInjectionSupport.loaders() in Sommelier.
LOADERS=(
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
# Everything else: plain ad-hoc so Gatekeeper sees a consistent bundle.
find "$BUNDLE" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
    -exec codesign --force --sign "${SIGN_IDENTITY:--}" {} \; 2>/dev/null || true

# ---- Release artifacts -----------------------------------------------------
cd "$WORK"
tar -cJf "SOMWineCX$VERSION.tar.xz" "SOMWineCX$VERSION"
tar -czf "sommelier-engine-patches-$VERSION.tar.gz" \
    -C "$ROOT" patches scripts resources
echo "Artifacts:"
ls -lh "$WORK/SOMWineCX$VERSION.tar.xz" "$WORK/sommelier-engine-patches-$VERSION.tar.gz"
