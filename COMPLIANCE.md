# LGPL compliance checklist

Wine is LGPL-2.1-or-later. CodeWeavers publishes the LGPL parts of CrossOver as
`crossover-sources-<version>.tar.gz`. Distributing binaries built from that
source carries obligations; this file is the release checklist, and a release
that fails any line does not ship.

## Every release must

1. **Ship the exact source.** Attach to the same GitHub Release:
   - the upstream `crossover-sources-<version>.tar.gz`, byte-identical to what
     was built (record its SHA-256 in the release notes);
   - `sommelier-engine-patches-<version>.tar.gz` — our patches, build scripts,
     and configure flags. Together these are the "complete corresponding
     source". A dead source link is the classic LGPL violation; hosting it
     beside the binary makes it impossible.
2. **Carry the license and notices in the bundle.** `assemble-bundle.sh` places
   `LICENSE.LGPL-2.1` and `NOTICE` inside `wswine.bundle/share/doc/`. The
   NOTICE text:

   > This engine contains Wine, © 1993–2026 the Wine project authors and
   > CodeWeavers, Inc., licensed under the GNU Lesser General Public License
   > v2.1 or later. Complete corresponding source:
   > https://github.com/<org>/Sommelier-engines/releases/tag/<tag>

3. **Preserve upstream copyright headers.** Building normally does; never strip.

## Naming and trademarks

- The engine carries Sommelier's own name and version: directory name
  `WS12WineSommelier<engine version>` (the `WS12Wine` prefix is the parser
  convention Sommelier inherits from the Wineskin lineage), display name
  "Sommelier <engine version>". The upstream sources version appears only in
  NOTICE, this file, and the release body — describing provenance there is
  nominative use; putting "CrossOver" in the product's name or version is
  not. No CodeWeavers logos anywhere. The LGPL itself imposes obligations on
  source availability and notices, none on naming.
- In-app credit (already in Sommelier's engines sheet): published engines are
  recommended; CrossOver import requires a valid license; CrossOver licenses
  fund Wine development.

## DXMT

The bundle ships DXMT (Metal-based D3D11/D3D10, github.com/3Shain/dxmt,
"Feifan He for CodeWeavers") fetched checksum-pinned from its upstream
release — never copied out of a CrossOver install. Version v0.80 is
MIT-licensed (the license text ships at `lib/dxmt/LICENSE`; releases after
v0.80 are LGPL 2.1+ — an upgrade moves DXMT into the same
complete-corresponding-source flow as Wine above, so re-read this section
before bumping `DXMT_VERSION` in assemble-bundle.sh). The bundled DXVK-derived
utility code inside DXMT is zlib/libpng-licensed.

## What is deliberately not included

The proprietary parts of CrossOver are not in the source tarball and must never
be copied in from an installed CrossOver.app: the compatibility database
(`share/crossover`), the `cx*` tools not present in the tarball, and their
bundled GPTK (`lib64/apple_gptk` — Apple's, non-redistributable, user-supplied
through Sommelier's separate GPTK import). If a build "needs" one of these, the
build is wrong, not the rule.
