# Patches

Applied to the extracted `wine/` tree in lexical order by `scripts/build.sh`
(`patch -p1`). Every patch here ships in the corresponding-source tarball of
each release — a patch that exists but is not released is a compliance bug.

Currently empty on purpose: the first engine should be a faithful build of the
published sources, so that any behavioural difference from an imported
CrossOver engine is attributable to the build, not to our changes.
