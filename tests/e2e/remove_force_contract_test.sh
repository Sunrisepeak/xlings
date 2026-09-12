#!/usr/bin/env bash
# E2E: `xlings remove` withdraws state BEFORE the recipe says goodbye, and
# `--force` means "no matter what, make it gone" -- a failing uninstall hook
# or a recipe that has left the index must not leave a zombie behind.
#
# Task 5 of the 2026-09-12 robustness/usability plan. Scenarios:
#
#   S1  uninstall() hook throws, no --force: exit 1, but the DB/workspace/
#       shim/store are ALL already clean (state withdrawn before the hook
#       ran, per the maintainer's ask -- see the diagnostic actions)
#   S2  same hook, --force: exit 0
#   S3  the recipe has left the index entirely: `remove --force` still
#       works from the version record alone (recipeUnavailable path)
#   S4  the payload was already deleted by hand: `remove` still cleans the
#       DB/workspace/shim and exits 0
#   S5  #578: a version DB record with NO active workspace binding is still
#       found and removed by `remove <name>` (DB-first resolution)
#   S6  `remove <name> --all-subos` removes it from every subos that has it
#   S7  `remove <name> --all` removes every version, highest first
#   S8  a sibling subos whose `.xlings.json` cannot be read blocks a full
#       removal (detach-only instead), names the subos, and is NOT
#       overridden by `--force`; fixing the file lets removal proceed
#       (2026.9.12, Item A)
#
# Every scenario ends with assert_gone, which checks all four places state
# can hide: the version DB, every subos workspace, every subos's program
# shim, and the on-disk payload directory.

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/remove_force_contract"
HOME_DIR="$RUNTIME_DIR/home"
# Private copy of the shared fixture index -- same convention as
# remove_multi_version_test.sh and friends -- so the two fixture recipes
# added below never touch the fixture other e2e tests share.
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"

PLAIN_PKG="$LOCAL_INDEX_DIR/pkgs/p/plain.lua"
HOOKFAIL_PKG="$LOCAL_INDEX_DIR/pkgs/h/hookfail.lua"
PLAIN_MARKER="$RUNTIME_DIR/plain-uninstall.marker"
HOOKFAIL_MARKER="$RUNTIME_DIR/hookfail-uninstall.marker"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

RUN() {
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin XLINGS_HOME="$HOME_DIR" \
      "$XLINGS_BIN" "$@" )
}
RUN_IN() {
  local subos="$1"; shift
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin XLINGS_HOME="$HOME_DIR" \
      XLINGS_ACTIVE_SUBOS="$subos" "$XLINGS_BIN" "$@" )
}

mkdir -p "$RUNTIME_DIR"
cp -r "$FIXTURE_INDEX_DIR" "$LOCAL_INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$LOCAL_INDEX_DIR/xim-indexrepos.lua"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
mkdir -p "$(dirname "$PLAIN_PKG")" "$(dirname "$HOOKFAIL_PKG")"

# ── Fixture: "plain", two versions, ordinary install/config/uninstall ──────
cat > "$PLAIN_PKG" <<LUA
package = {
    spec = "1",
    name = "plain",
    description = "Local fixture for tests/e2e/remove_force_contract_test.sh",
    authors = {"xlings-ci"},
    licenses = {"MIT"},
    type = "package",
    archs = {"x86_64", "aarch64"},
    status = "stable",
    categories = {"test-fixture"},
    xpm = {
        linux   = { ["1.0.0"] = {}, ["2.0.0"] = {} },
        macosx  = { ["1.0.0"] = {}, ["2.0.0"] = {} },
        windows = { ["1.0.0"] = {}, ["2.0.0"] = {} },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.xvm")

function install()
    local dir = pkginfo.install_dir()
    os.tryrm(dir)
    local bindir = path.join(dir, "bin")
    os.mkdir(bindir)
    io.writefile(path.join(bindir, "plain"), "#!/bin/sh\necho plain\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "plain"))
    end
    return true
end

function config()
    xvm.add("plain", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    io.writefile("$PLAIN_MARKER", "ran")
    xvm.remove("plain")
    return true
end
LUA

# ── Fixture: "hookfail", one version, uninstall() always throws ───────────
cat > "$HOOKFAIL_PKG" <<LUA
package = {
    spec = "1",
    name = "hookfail",
    description = "Local fixture for tests/e2e/remove_force_contract_test.sh",
    authors = {"xlings-ci"},
    licenses = {"MIT"},
    type = "package",
    archs = {"x86_64", "aarch64"},
    status = "stable",
    categories = {"test-fixture"},
    xpm = {
        linux   = { ["1.0.0"] = {} },
        macosx  = { ["1.0.0"] = {} },
        windows = { ["1.0.0"] = {} },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.xvm")

function install()
    local dir = pkginfo.install_dir()
    os.tryrm(dir)
    local bindir = path.join(dir, "bin")
    os.mkdir(bindir)
    io.writefile(path.join(bindir, "hookfail"), "#!/bin/sh\necho hookfail\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "hookfail"))
    end
    return true
end

function config()
    xvm.add("hookfail", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    io.writefile("$HOOKFAIL_MARKER", "ran")
    error("boom")
end
LUA

mkdir -p "$HOME_DIR/subos/default/bin" "$HOME_DIR/data/xim-index-repos"
cp "$XLINGS_BIN" "$HOME_DIR/xlings"
cat > "$HOME_DIR/.xlings.json" <<JSON
{
  "mirror": "GLOBAL",
  "index_repos": [
    { "name": "xim", "url": "$LOCAL_INDEX_DIR" }
  ]
}
JSON

log "Initializing sandbox XLINGS_HOME at $HOME_DIR"
RUN self init >"$RUNTIME_DIR/self-init.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/self-init.out" >&2; fail "self init failed"; }
printf '{}\n' > "$HOME_DIR/data/xim-index-repos/xim-indexrepos.json"

# Every reference to this name across the whole home must be gone: the
# version DB, every subos's workspace binding, every subos's program shim,
# and the on-disk payload directory.
assert_gone() {
  local name="$1" ver="$2" label="$3"

  python3 - "$HOME_DIR/.xlings.json" "$name" "$ver" <<'PY' \
    || fail "$label: still present in the version DB"
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
versions = ((data.get("versions") or {}).get(sys.argv[2], {}) or {}).get("versions", {})
assert sys.argv[3] not in versions, versions
PY

  local ws
  for ws in "$HOME_DIR"/subos/*/.xlings.json; do
    [[ -f "$ws" ]] || continue
    python3 - "$ws" "$name" "$ver" <<'PY' \
      || fail "$label: still referenced in $(basename "$(dirname "$ws")")'s workspace"
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
entry = (data.get("workspace") or {}).get(sys.argv[2])
if entry is None:
    sys.exit(0)
if isinstance(entry, dict):
    assert entry.get("active") != sys.argv[3], entry
    assert sys.argv[3] not in (entry.get("installed") or []), entry
else:
    assert entry != sys.argv[3], entry
PY
  done

  local bindir
  for bindir in "$HOME_DIR"/subos/*/bin; do
    [[ -e "$bindir/$name" ]] && fail "$label: shim still present at $bindir/$name"
  done

  local store
  store="$(find "$HOME_DIR/data/xpkgs" -maxdepth 1 -type d -name "*-x-$name" 2>/dev/null | head -1)"
  if [[ -n "$store" ]]; then
    [[ ! -d "$store/$ver" ]] || fail "$label: payload still at $store/$ver"
  fi
}

# ── S1: hook throws, no --force -- state withdrawn anyway, exit 1 ─────────
log "S1: uninstall() throws, no --force"
RUN install hookfail@1.0.0 -y >/dev/null 2>&1 || fail "S1 setup: install failed"
rm -f "$HOOKFAIL_MARKER"
set +e
OUT="$(RUN remove hookfail -y 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT" | sed 's/^/    | /'
[[ "$RC" -eq 1 ]] || fail "S1: expected exit 1, got $RC"
[[ -f "$HOOKFAIL_MARKER" ]] || fail "S1: uninstall() hook never ran"
assert_contains "$OUT" "boom" "S1: hook error should surface in the output"
assert_gone hookfail 1.0.0 "S1"
log "  PASS: state withdrawn even though the hook failed and exit was non-zero"

# ── S2: same hook, --force -- exit 0 ───────────────────────────────────────
log "S2: uninstall() throws, --force"
RUN install hookfail@1.0.0 -y >/dev/null 2>&1 || fail "S2 setup: install failed"
rm -f "$HOOKFAIL_MARKER"
RUN remove hookfail --force -y >"$RUNTIME_DIR/s2.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s2.out" >&2; fail "S2: remove --force should exit 0"; }
[[ -f "$HOOKFAIL_MARKER" ]] || fail "S2: uninstall() hook never ran"
assert_gone hookfail 1.0.0 "S2"
log "  PASS: --force turns the same failure into a clean exit 0"

# ── S4: payload already deleted by hand -- remove still cleans up ─────────
log "S4: payload deleted by hand before remove"
RUN install plain@1.0.0 -y >/dev/null 2>&1 || fail "S4 setup: install failed"
PLAIN_STORE="$(find "$HOME_DIR/data/xpkgs" -maxdepth 1 -type d -name '*-x-plain' | head -1)"
[[ -n "$PLAIN_STORE" ]] || fail "S4 setup: could not find plain's store dir"
rm -rf "${PLAIN_STORE:?}/1.0.0"
RUN remove plain -y >"$RUNTIME_DIR/s4.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s4.out" >&2; fail "S4: remove should exit 0"; }
assert_gone plain 1.0.0 "S4"
log "  PASS: a payload deleted out from under the DB does not block removal"

# ── S5: #578 -- a DB record with no active workspace binding ──────────────
log "S5: version DB has a record, workspace has no active binding (#578)"
RUN install plain@1.0.0 -y >/dev/null 2>&1 || fail "S5 setup: install failed"
python3 - "$HOME_DIR/subos/default/.xlings.json" <<'PY' \
  || fail "S5 setup: could not clear the workspace binding"
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data.get("workspace", {}).pop("plain", None)
p.write_text(json.dumps(data))
PY
RUN remove plain -y >"$RUNTIME_DIR/s5.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s5.out" >&2; fail "S5: remove should exit 0"; }
assert_gone plain 1.0.0 "S5"
log "  PASS: DB-first resolution finds it even with no active binding"

# ── S6: --all-subos removes it everywhere it is installed ─────────────────
log "S6: remove <name> --all-subos across two subos"
RUN subos new other >/dev/null 2>&1 || fail "S6 setup: subos new failed"
RUN_IN default install plain@1.0.0 -y >/dev/null 2>&1 || fail "S6 setup: default install failed"
RUN_IN other   install plain@1.0.0 -y >/dev/null 2>&1 || fail "S6 setup: other install failed"
RUN remove plain --all-subos -y >"$RUNTIME_DIR/s6.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s6.out" >&2; fail "S6: remove --all-subos should exit 0"; }
assert_gone plain 1.0.0 "S6"
log "  PASS: both subos and the shared store are clean"

# ── S7: --all removes every version, highest first ─────────────────────────
log "S7: remove <name> --all across two versions"
RUN install plain@1.0.0 -y >/dev/null 2>&1 || fail "S7 setup: install 1.0.0 failed"
RUN install plain@2.0.0 -y >/dev/null 2>&1 || fail "S7 setup: install 2.0.0 failed"
RUN remove plain --all -y >"$RUNTIME_DIR/s7.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s7.out" >&2; fail "S7: remove --all should exit 0"; }
assert_gone plain 1.0.0 "S7 (1.0.0)"
assert_gone plain 2.0.0 "S7 (2.0.0)"
log "  PASS: --all cleared every version"

# ── S8: an unreadable sibling subos is treated as "might still use this
#        payload" (2026.9.12, Item A controller ruling) ──────────────────
#
# Before this, a subos whose `.xlings.json` could not be read was simply
# invisible to every cross-subos scan -- `remove` read that as "nobody else
# uses this" and did a FULL removal (payload deleted) even though the
# unreadable subos might still be actively using the exact version being
# removed. Now it is read the other way: unreadable means "cannot rule out
# still in use", so `remove` detaches only, keeps the payload, names the
# subos it could not check, and points at the repair command -- and
# `--force` does NOT override this, because deleting a payload a DIFFERENT
# subos may need is not "force removing this package", it is damaging that
# other subos.
log "S8: unreadable sibling subos blocks a full removal, --force does not override it"
RUN subos new other2 >/dev/null 2>&1 || fail "S8 setup: subos new other2 failed"
RUN_IN default install plain@1.0.0 -y >/dev/null 2>&1 || fail "S8 setup: default install failed"
RUN_IN other2  install plain@1.0.0 -y >/dev/null 2>&1 || fail "S8 setup: other2 install failed"
WS_OTHER2="$HOME_DIR/subos/other2/.xlings.json"
cp "$WS_OTHER2" "$RUNTIME_DIR/other2-ws.bak"
printf '{garbage' > "$WS_OTHER2"

PLAIN_STORE8="$(find "$HOME_DIR/data/xpkgs" -maxdepth 1 -type d -name '*-x-plain' | head -1)"
[[ -n "$PLAIN_STORE8" ]] || fail "S8 setup: could not find plain's store dir"

RUN_IN default remove plain -y >"$RUNTIME_DIR/s8a.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s8a.out" >&2; fail "S8a: remove should exit 0 (detach-only)"; }
[[ -d "$PLAIN_STORE8/1.0.0" ]] \
  || fail "S8a: payload must still be on disk -- an unreadable subos might still use it"
assert_contains "$(cat "$RUNTIME_DIR/s8a.out")" "other2" \
  "S8a: stderr must name the unreadable subos"

RUN_IN default remove plain --force -y >"$RUNTIME_DIR/s8b.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s8b.out" >&2; fail "S8b: remove --force should exit 0 (still detach-only)"; }
[[ -d "$PLAIN_STORE8/1.0.0" ]] \
  || fail "S8b: --force must not delete a payload another (unreadable) subos may need"
assert_contains "$(cat "$RUNTIME_DIR/s8b.out")" "does not override" \
  "S8b: stderr must say --force does not override this"

cp "$RUNTIME_DIR/other2-ws.bak" "$WS_OTHER2"
RUN_IN other2 remove plain -y >"$RUNTIME_DIR/s8c.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s8c.out" >&2; fail "S8c: remove in other2 (fixed) should exit 0"; }
assert_gone plain 1.0.0 "S8c"
log "  PASS: an unreadable subos is treated as a user of the payload, and --force does not override that"

# ── S3: the recipe has left the index entirely -- run last, it deletes it ──
log "S3: recipe removed from the index, then remove --force"
RUN install plain@1.0.0 -y >/dev/null 2>&1 || fail "S3 setup: install failed"
rm -f "$PLAIN_PKG"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
RUN remove plain --force -y >"$RUNTIME_DIR/s3.out" 2>&1 \
  || { sed 's/^/    | /' "$RUNTIME_DIR/s3.out" >&2; fail "S3: remove --force should exit 0"; }
assert_contains "$(cat "$RUNTIME_DIR/s3.out")" "no index provides" \
  "S3: expected the recipe-unavailable diagnostic"
assert_gone plain 1.0.0 "S3"
log "  PASS: a version record survives its recipe, and --force can still clear it"

log "PASS: remove --force / --all / --all-subos contract (S1-S8)"
