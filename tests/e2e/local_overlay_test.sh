#!/usr/bin/env bash
# E2E-101: the local index is an overlay with provenance, three verbs, and
# automatic GC of recipes byte-identical to the synced index.
#
# On a real machine 159 recipes had accumulated in the local overlay over
# time, 157 of them byte-identical to what the synced `xim` index now ships
# -- every one of them a bare name that resolves ambiguously and prints a
# namespace-priority warning, with no command to list, attribute, or clear
# any of it.
#
#   S1  `--add-xpkg` of a file byte-identical to a synced recipe is refused
#       ("identical to ..."), and nothing lands in the overlay
#   S2  a modified copy (same declared version, different bytes) is added,
#       and `--list-xpkg` reports it "modified"
#   S3  the synced index moving to a newer version turns that entry "behind"
#   S4  `--clear-xpkg stale` removes Behind (and Identical) entries
#   S5  `--remove-xpkg` deletes one Unique entry by name
#   S6  `xlings update` auto-GCs an entry that has become byte-identical to
#       the synced index, without being asked
#   S7  a recipe dropped straight into pkgs/ with NO add-xpkg and NO
#       .overlay.json entry (the 157-of-159 shape: everything a
#       pre-2026.9.12 build ever added) is still GC'd when identical, and
#       still shown -- as "untracked" -- when modified and surviving
#   I6  a same-VERSION local duplicate does not print "namespace priority"
#       on `info <bare-name>` (silenced by a parallel task in this round;
#       see below if it is not yet merged in this worktree)

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/local_overlay"
HOME_DIR="$RUNTIME_DIR/home"
INDEX_DIR="$RUNTIME_DIR/xim-index"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

# ABSOLUTE -- several checks below run from /tmp, where a relative binary
# path dies with `env: No such file or directory`.
XLINGS_BIN="$(cd "$(dirname "$(find_xlings_bin)")" && pwd)/$(basename "$(find_xlings_bin)")"

mkdir -p "$HOME_DIR"

# A private, mutable copy of the fixture index -- S3/S6 edit it in place, and
# the shared tests/fixtures/xim-pkgindex checkout must stay untouched for
# every other E2E that uses it.
cp -r "$FIXTURE_INDEX_DIR" "$INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$INDEX_DIR/xim-indexrepos.lua"
rm -f "$INDEX_DIR/.xlings-index-cache.json"

UPSTREAM_RECIPE="$INDEX_DIR/pkgs/m/make.lua"
[[ -f "$UPSTREAM_RECIPE" ]] || fail "fixture is missing pkgs/m/make.lua"

write_home_config "$HOME_DIR" "" "$INDEX_DIR" "xim"

run_x() {
    ( cd /tmp && env -u XLINGS_PROJECT_DIR XLINGS_HOME="$HOME_DIR" \
        XLINGS_NON_INTERACTIVE=1 "$XLINGS_BIN" "$@" )
}

out="$(run_x update 2>&1)" || { echo "$out"; fail "initial update failed"; }

echo "== S1: add-xpkg of a byte-identical file is refused =="
out="$(run_x config --add-xpkg "$UPSTREAM_RECIPE" 2>&1)"
if ! grep -qi "identical" <<<"$out"; then
    echo "$out"
    fail "S1: expected an 'identical' refusal"
fi
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]]; then
    fail "S1: an identical add must not create a file in the overlay"
fi
echo "   ok — refused, nothing added"

echo "== S2: a modified copy is added and reported 'modified' =="
LOCAL_SRC="$RUNTIME_DIR/local-src"
mkdir -p "$LOCAL_SRC"
cp "$UPSTREAM_RECIPE" "$LOCAL_SRC/make.lua"
# Same declared version (4.3), different bytes.
sed -i.bak 's/GNU Make —/GNU Make (local variant) —/' "$LOCAL_SRC/make.lua"
rm -f "$LOCAL_SRC/make.lua.bak"
out="$(run_x config --add-xpkg "$LOCAL_SRC/make.lua" 2>&1)"
grep -qi "add xpkg" <<<"$out" || { echo "$out"; fail "S2: add-xpkg of a modified copy should succeed"; }
[[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]] \
    || fail "S2: the modified copy should be on disk in the overlay"

out="$(run_x config --list-xpkg 2>&1)"
if ! grep -q "^make " <<<"$out"; then
    echo "$out"
    fail "S2: --list-xpkg should list 'make'"
fi
if ! grep "^make " <<<"$out" | grep -qi "modified"; then
    echo "$out"
    fail "S2: a same-version, byte-differing overlay recipe should report 'modified'"
fi
echo "   ok — added, listed as modified"

echo "== S3: a newer synced version turns the entry 'behind' =="
sed -i.bak 's/ref = "4.3"/ref = "4.4"/' "$UPSTREAM_RECIPE"
sed -i.bak 's/GNU Make —/GNU Make v4.4 —/' "$UPSTREAM_RECIPE"
rm -f "$UPSTREAM_RECIPE.bak"
out="$(run_x update 2>&1)" || { echo "$out"; fail "S3: update failed"; }

out="$(run_x config --list-xpkg 2>&1)"
if ! grep "^make " <<<"$out" | grep -qi "behind"; then
    echo "$out"
    fail "S3: an overlay recipe recording an older version than the synced index should report 'behind'"
fi
echo "   ok — reported behind"

echo "== S4: --clear-xpkg stale removes it =="
out="$(run_x config --clear-xpkg stale 2>&1)"
grep -qi "make" <<<"$out" || { echo "$out"; fail "S4: clear should name 'make'"; }
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]]; then
    fail "S4: --clear-xpkg stale should have deleted the file"
fi
out="$(run_x config --list-xpkg 2>&1)"
if grep -q "^make " <<<"$out"; then
    echo "$out"
    fail "S4: 'make' should no longer be listed after clearing stale"
fi
echo "   ok — stale entry cleared"

echo "== S5: --remove-xpkg deletes one Unique entry =="
cat > "$LOCAL_SRC/zz-uniquepkg.lua" <<'LUA'
package = {
    spec = "1",
    name = "zz-uniquepkg",
    description = "overlay e2e fixture: exists only locally",
    type = "config",
    archs = {"x86_64"},
    status = "dev",
    xpm = {
        linux   = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
        macosx  = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
        windows = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
    },
}
function install() return true end
function config() return true end
function uninstall() return true end
LUA
out="$(run_x config --add-xpkg "$LOCAL_SRC/zz-uniquepkg.lua" 2>&1)"
grep -qi "add xpkg" <<<"$out" || { echo "$out"; fail "S5: add-xpkg of a unique recipe should succeed"; }

out="$(run_x config --list-xpkg 2>&1)"
grep "^zz-uniquepkg " <<<"$out" | grep -qi "unique" \
    || { echo "$out"; fail "S5: zz-uniquepkg should list as 'unique'"; }

out="$(run_x config --remove-xpkg zz-uniquepkg 2>&1)"
grep -qi "zz-uniquepkg" <<<"$out" || { echo "$out"; fail "S5: remove should name the package"; }
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/z/zz-uniquepkg.lua" ]]; then
    fail "S5: --remove-xpkg should have deleted the file"
fi
echo "   ok — unique entry removed by name"

echo "== S5b: --remove-xpkg on an unknown name fails loudly =="
s5b_out="$RUNTIME_DIR/s5b.out"
if run_x config --remove-xpkg no-such-package >"$s5b_out" 2>&1; then
    cat "$s5b_out"
    fail "S5b: removing a name that was never added should exit non-zero"
fi
echo "   ok — refused"

echo "== S5c: --remove-xpkg reaches an UNTRACKED overlay recipe =="
# No add-xpkg, no .overlay.json entry -- dropped straight into pkgs/, the
# 157-of-159 shape a pre-2026.9.12 build leaves behind. --list-xpkg already
# shows this; --remove-xpkg must be able to delete it by the same name.
mkdir -p "$HOME_DIR/data/xim-pkgindex-local/pkgs/z"
cat > "$HOME_DIR/data/xim-pkgindex-local/pkgs/z/zz-untrackedpkg.lua" <<'LUA'
package = {
    spec = "1",
    name = "zz-untrackedpkg",
    description = "overlay e2e fixture: dropped in with no add-xpkg",
    type = "config",
    archs = {"x86_64"},
    status = "dev",
    xpm = {
        linux   = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
        macosx  = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
        windows = { ["latest"] = { ref = "1.0.0" }, ["1.0.0"] = {} },
    },
}
function install() return true end
function config() return true end
function uninstall() return true end
LUA

out="$(run_x config --list-xpkg 2>&1)"
grep "^zz-untrackedpkg " <<<"$out" | grep -qi "untracked" \
    || { echo "$out"; fail "S5c: zz-untrackedpkg should list with an 'untracked' source"; }

rc=0
out="$(run_x config --remove-xpkg zz-untrackedpkg 2>&1)" || rc=$?
if [[ $rc -ne 0 ]]; then
    echo "$out"
    fail "S5c: --remove-xpkg on an untracked recipe should exit 0"
fi
grep -qi "zz-untrackedpkg" <<<"$out" || { echo "$out"; fail "S5c: remove should name the package"; }
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/z/zz-untrackedpkg.lua" ]]; then
    fail "S5c: --remove-xpkg should have deleted the untracked file"
fi
echo "   ok — untracked entry removed by name"

echo "== S6: 'xlings update' auto-GCs an entry that becomes identical =="
cp "$UPSTREAM_RECIPE" "$LOCAL_SRC/make-again.lua"
sed -i.bak 's/GNU Make v4.4 —/GNU Make v4.4 (about to converge) —/' "$LOCAL_SRC/make-again.lua"
rm -f "$LOCAL_SRC/make-again.lua.bak"
# Give it the SAME name as upstream so `update`'s GC has a same-named
# candidate to compare against -- add-xpkg's own refusal is bypassed because
# the bytes still differ at add time.
mv "$LOCAL_SRC/make-again.lua" "$LOCAL_SRC/make.lua"
out="$(run_x config --add-xpkg "$LOCAL_SRC/make.lua" 2>&1)"
grep -qi "add xpkg" <<<"$out" || { echo "$out"; fail "S6: add-xpkg should have succeeded"; }

# Now make the overlay copy byte-identical to what's already synced, without
# going through add-xpkg (which would just refuse it) -- exactly the
# real-world shape: the index catches up to a recipe someone hand-added.
cp "$UPSTREAM_RECIPE" "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"

out="$(run_x update 2>&1)" || { echo "$out"; fail "S6: update failed"; }
if ! grep -qi "identical to the synced index were removed" <<<"$out"; then
    echo "$out"
    fail "S6: update should have announced the auto-GC"
fi
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]]; then
    fail "S6: the now-identical overlay recipe should have been removed"
fi
echo "   ok — update auto-GC'd the converged entry"

echo "== S7: an untracked recipe (no add-xpkg, no provenance) is GC'd when identical, and survives+lists when modified =="
mkdir -p "$HOME_DIR/data/xim-pkgindex-local/pkgs/m"
# Byte-identical to what's already synced, dropped straight into pkgs/ --
# bypassing add-xpkg entirely. No .overlay.json entry at all: exactly what a
# pre-2026.9.12 build left behind, and the shape 157 of a real overlay's 159
# recipes were in.
cp "$UPSTREAM_RECIPE" "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"

out="$(run_x config --list-xpkg 2>&1)"
if ! grep "^make " <<<"$out" | grep -qi "untracked"; then
    echo "$out"
    fail "S7: an untracked recipe should list with an 'untracked' source"
fi

out="$(run_x update 2>&1)" || { echo "$out"; fail "S7: update failed"; }
if ! grep -qi "identical to the synced index were removed" <<<"$out"; then
    echo "$out"
    fail "S7: update should auto-GC an untracked identical recipe, not just a tracked one"
fi
if [[ -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]]; then
    fail "S7: the untracked identical recipe should have been removed"
fi

# Same shape, but modified: same declared version, different bytes, still no
# provenance record. Must survive `update` (Modified, not Identical) and
# still be visible in --list-xpkg.
#
# `pkgs/m/` itself was just deleted above -- `remove_recipe_file` (and so
# the GC that just ran) removes a letter directory once it's the last file
# in it -- so it needs remaking before writing into it again.
mkdir -p "$HOME_DIR/data/xim-pkgindex-local/pkgs/m"
cp "$UPSTREAM_RECIPE" "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"
sed -i.bak 's/GNU Make v4.4 —/GNU Make v4.4 (untracked, hand-edited) —/' \
    "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"
rm -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua.bak"

out="$(run_x update 2>&1)" || { echo "$out"; fail "S7: second update failed"; }
if grep -qi "identical to the synced index were removed" <<<"$out"; then
    echo "$out"
    fail "S7: a modified untracked recipe must not be GC'd"
fi
if [[ ! -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua" ]]; then
    fail "S7: the modified untracked recipe should have survived update"
fi

out="$(run_x config --list-xpkg 2>&1)"
if ! grep "^make " <<<"$out" | grep -qi "modified"; then
    echo "$out"
    fail "S7: the surviving untracked recipe should list as 'modified'"
fi
if ! grep "^make " <<<"$out" | grep -qi "untracked"; then
    echo "$out"
    fail "S7: the surviving untracked recipe should still show an 'untracked' source"
fi
echo "   ok — untracked identical recipe GC'd by update; untracked modified recipe survives and lists"

# Reset before I6, which sets up its own pkgs/m/make.lua state from scratch.
run_x config --clear-xpkg all >/dev/null 2>&1 || true

echo "== I6: a same-version local duplicate does not shout 'namespace priority' =="
mkdir -p "$HOME_DIR/data/xim-pkgindex-local/pkgs/m"
cp "$UPSTREAM_RECIPE" "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"
sed -i.bak 's/GNU Make v4.4 —/GNU Make v4.4 (local, same version) —/' \
    "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua"
rm -f "$HOME_DIR/data/xim-pkgindex-local/pkgs/m/make.lua.bak"

out="$(run_x info make 2>&1)"
if grep -qi "namespace priority" <<<"$out"; then
    echo "$out"
    echo "[local-overlay-e2e] KNOWN DEPENDENCY: I6 expects the catalog's" >&2
    echo "[local-overlay-e2e] same-version demotion message to be silent —" >&2
    echo "[local-overlay-e2e] a parallel task in the 2026-09-12 round. If it" >&2
    echo "[local-overlay-e2e] has not landed in this worktree yet, this is" >&2
    echo "[local-overlay-e2e] the expected (reported, not silently ignored)" >&2
    echo "[local-overlay-e2e] failure — see task-4-report.md." >&2
    fail "I6: 'namespace priority' still printed for a same-version overlay duplicate"
fi
echo "   ok — no namespace-priority noise for a same-version duplicate"

echo
echo "[local-overlay-e2e] all scenarios passed"
