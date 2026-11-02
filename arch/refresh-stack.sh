#!/usr/bin/env bash
# Regenerate the stack series the PKGBUILD builds from (patches/BASE, TIP, VERSION, TREE and
# basalt-stack.patch), then prove the series reproduces the stack tip from a clean upstream clone.
#
# Run this after re-resolving the stack in packaging/src/basalt (branch `makepkg`), before makepkg.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$HERE/src/basalt}
REF=${REF:-makepkg}
BASE_REF=${BASE_REF:-876e47e8}
CHECK=${CHECK:-/tmp/basalt-patchcheck}
SERIES=${SERIES:-0.2.0}   # the upstream series the pinned BASE belongs to (v0.2.0 is the .basalt version 2 release)

say() { printf '%s\n' "$*"; }

[[ -d $SRC/.git ]] || { say "no git tree at $SRC"; exit 1; }

BASE=$(git -C "$SRC" rev-parse "$BASE_REF")
TIP=$(git -C "$SRC" rev-parse "$REF")
TREE=$(git -C "$SRC" rev-parse "$REF^{tree}")
VER=$(printf '%s.r%s.g%s' "$SERIES" "$(git -C "$SRC" rev-list --count "$REF")" "$(git -C "$SRC" rev-parse --short "$REF")")

mkdir -p "$HERE/patches"
# --binary, not plain `git diff`: the stack adds a binary file (data/profiles/*.prof), and without it
# git writes the stub line `Binary files ... differ`, which `git apply` refuses ("cannot apply binary
# patch without full index line") - so neither this check nor the PKGBUILD's prepare() could reproduce
# the stack from a clean clone.  --binary implies --full-index, which makes the patch self-contained.
git -C "$SRC" diff --binary "$BASE" "$TIP" > "$HERE/patches/basalt-stack.patch"
printf '%s\n' "$BASE" > "$HERE/patches/BASE"
printf '%s\n' "$TIP"   > "$HERE/patches/TIP"
printf '%s\n' "$TREE"  > "$HERE/patches/TREE"
printf '%s\n' "$VER"   > "$HERE/patches/VERSION"
say "series: $(basename "$SRC") $BASE_REF -> $REF ($VER)"
say "  $(grep -c '^diff --git' "$HERE/patches/basalt-stack.patch") files, $(wc -l < "$HERE/patches/basalt-stack.patch") patch lines"

# Prove it: a clean clone of upstream, checked out at BASE, gets the patch, and must land on TREE.
rm -rf "$CHECK"
git clone --quiet https://github.com/jesdga95/basalt "$CHECK"
cd "$CHECK"
git checkout -q "$BASE"
git apply --index "$HERE/patches/basalt-stack.patch"
git add -A
GOT=$(git write-tree)
[[ $GOT == "$TREE" ]] || { say "TREE MISMATCH: patch produced $GOT, recorded $TREE"; exit 1; }
say "verified: clean upstream clone + basalt-stack.patch -> tree $GOT, identical to $REF"
