#!/usr/bin/env bash
# E2E-109: the CURRENT subos itself being unreadable must be survivable
# (2026.9.12, F10).
#
# Every other "unreadable subos" test in this suite corrupts a SIBLING --
# `other`, `other2`, `broken` -- and asks the CURRENT subos to notice and
# route around it. This one corrupts the subos every command below is
# ACTUALLY running in. Nothing before this exercised that shape at all:
# `Config::save_workspace()` (the writer of the CURRENT subos's own
# `.xlings.json`, reached from ordinary install/remove/use) used to read a
# file that failed to parse, silently fall back to an EMPTY `nlohmann::json`
# object, and then write that object straight back out -- turning a
# corrupted-but-otherwise-intact subos manifest (subos_info, envs, whatever
# else lived beside `workspace`) into a blank one on the very first
# `install`/`remove` run against it. `profile::save_subos_workspace`
# (the writer doctor's cross-subos repairs use for every OTHER subos) has
# always refused this instead; this test is what makes the CURRENT subos's
# own writer keep the same promise.
#
# Assertions, for `list`, `install <good> -y`, `remove <good> -y`,
# `self doctor`, and `self doctor --fix --dry-run -y`, each run with the
# corrupted subos active:
#   - exit code in {0,1,2} -- no crash
#   - no `terminate called` / `Segmentation` / `Aborted` in the output
#   - every OTHER subos's `.xlings.json` is byte-for-byte unchanged
#     (sha256 before vs. after each command)
#   - `self doctor` names the corrupted subos as unreadable

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/current_subos_unreadable"
HOME_DIR="$RUNTIME_DIR/home"
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

RUN() {
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      XLINGS_HOME="$HOME_DIR" XLINGS_ACTIVE_SUBOS=default \
      "$XLINGS_BIN" "$@" </dev/null )
}

# No `terminate called`, no `Segmentation`, no `Aborted` -- and an exit code
# a wrapping script can act on (0 clean, 1 issues found, 2 a refusal) rather
# than a raw signal. Same contract broken_home_isolation_test.sh's
# assert_survives uses.
assert_survives() {
  local label="$1" rc="$2" out="$3"
  case "$rc" in
    0|1|2) ;;
    *) fail "$label: exit code $rc is not in {0,1,2} -- looks like a crash:
$out" ;;
  esac
  echo "$out" | grep -qE "terminate called|Segmentation|Aborted" \
    && fail "$label: crash signature in output:
$out"
  return 0
}

mkdir -p "$HOME_DIR"
cp -r "$FIXTURE_INDEX_DIR" "$LOCAL_INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$LOCAL_INDEX_DIR/xim-indexrepos.lua"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
mkdir -p "$LOCAL_INDEX_DIR/pkgs/g"

cat > "$LOCAL_INDEX_DIR/pkgs/g/csugood.lua" <<'LUA'
package = {
    spec = "1",
    name = "csugood",
    description = "Local fixture for current_subos_unreadable_test.sh",
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
    local bindir = path.join(pkginfo.install_dir(), "bin")
    os.tryrm(pkginfo.install_dir())
    os.mkdir(bindir)
    io.writefile(path.join(bindir, "csugood"), "#!/bin/sh\necho csugood\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "csugood"))
    end
    return true
end

function config()
    xvm.add("csugood", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    xvm.remove("csugood")
    return true
end
LUA

# A SECOND, unrelated fixture for the "safe" subos -- deliberately not
# "csugood" installed twice. `remove csugood -y` with no explicit
# `--subos`/`--all-subos` implicitly reaches any OTHER subos that
# references the target when it is absent here and `-y` was given (F5,
# 2026.9.12) -- if "safe" also had csugood, this test's own `remove` step
# would legitimately detach it there once "default" reads as empty
# (its corrupted file parses to nothing, not to "still has csugood"),
# which is a real, correct feature interacting with this scenario rather
# than the property this test is about. Giving "safe" a package by a
# different name keeps the two concerns apart.
cat > "$LOCAL_INDEX_DIR/pkgs/g/csusafe.lua" <<'LUA'
package = {
    spec = "1",
    name = "csusafe",
    description = "Local fixture for current_subos_unreadable_test.sh (installed only in 'safe')",
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
    local bindir = path.join(pkginfo.install_dir(), "bin")
    os.tryrm(pkginfo.install_dir())
    os.mkdir(bindir)
    io.writefile(path.join(bindir, "csusafe"), "#!/bin/sh\necho csusafe\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "csusafe"))
    end
    return true
end

function config()
    xvm.add("csusafe", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    xvm.remove("csusafe")
    return true
end
LUA

cp "$XLINGS_BIN" "$HOME_DIR/xlings"
cat > "$HOME_DIR/.xlings.json" <<EOF
{
  "mirror": "GLOBAL",
  "index_repos": [
    { "name": "xim", "url": "$LOCAL_INDEX_DIR" }
  ]
}
EOF

log "Initializing sandbox XLINGS_HOME at $HOME_DIR"
RUN self init >/dev/null 2>&1 || fail "self init failed"
mkdir -p "$HOME_DIR/data/xim-index-repos"
printf '{}\n' > "$HOME_DIR/data/xim-index-repos/xim-indexrepos.json"

# A second, healthy subos -- what "no OTHER subos's state changes" is
# checked against. Installing a DIFFERENT package into it (see the
# csusafe comment above) so it has something a stray write could
# plausibly disturb, without overlapping csugood's own name.
log "subos new safe, and install csugood into default / csusafe into safe"
RUN subos new safe >/dev/null 2>&1 || fail "setup: subos new safe failed"
RUN install csugood@1.0.0 -y >/dev/null 2>&1 \
  || fail "setup: install csugood into default failed"
( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin XLINGS_HOME="$HOME_DIR" \
    XLINGS_ACTIVE_SUBOS=safe "$XLINGS_BIN" install csusafe@1.0.0 -y \
    >/dev/null 2>&1 ) || fail "setup: install csusafe into safe failed"

SAFE_WS="$HOME_DIR/subos/safe/.xlings.json"
[[ -f "$SAFE_WS" ]] || fail "setup: safe subos should have its own .xlings.json"

DEFAULT_WS="$HOME_DIR/subos/default/.xlings.json"
[[ -f "$DEFAULT_WS" ]] || fail "setup: default subos should have its own .xlings.json"

log "Corrupting the CURRENT (default) subos's own .xlings.json"
printf '{garbage' > "$DEFAULT_WS"

safe_before="$(sha256sum "$SAFE_WS" | awk '{print $1}')"

# The home root's OWN `.xlings.json` (the versions DB, mirror, index_repos
# -- a different file from any subos's own workspace) is legitimately still
# written by an ordinary install/remove even when the CURRENT subos's own
# manifest cannot be. That is not the invariant this test is about; what
# must not move is a SIBLING subos's file.
run_and_check() {
  local label="$1"; shift
  local rc=0 out
  out="$(RUN "$@" 2>&1)" || rc=$?
  assert_survives "$label" "$rc" "$out"

  local safe_after
  safe_after="$(sha256sum "$SAFE_WS" | awk '{print $1}')"
  [[ "$safe_after" == "$safe_before" ]] \
    || fail "$label: 'safe' subos's .xlings.json changed just from a
command run against the corrupted CURRENT subos:
$out"
  echo "$out"
}

log "list"
run_and_check "list" list >/dev/null

log "install csugood -y (again, against the corrupted current subos)"
run_and_check "install csugood" install csugood@1.0.0 -y >/dev/null

log "remove csugood -y (against the corrupted current subos)"
run_and_check "remove csugood" remove csugood -y >/dev/null

log "self doctor"
doctor_out="$(run_and_check "self doctor" self doctor)"
echo "$doctor_out" | strip_ansi | grep -qi "unreadable" \
  || fail "self doctor: expected the CURRENT subos to be reported as
unreadable; got:
$doctor_out"
echo "$doctor_out" | strip_ansi | grep -q "default" \
  || fail "self doctor: expected 'default' named as the unreadable subos;
got:
$doctor_out"

log "self doctor --fix --dry-run -y"
run_and_check "self doctor --fix --dry-run" self doctor --fix --dry-run -y >/dev/null

# The corruption itself must still be exactly what was written -- nothing
# above should have "fixed" it by blanking it into valid-but-empty JSON,
# which would look like a repair in a diff but is actually the same
# destructive replace this test exists to catch, just laundered through a
# dry-run path instead of an ordinary write.
[[ "$(cat "$DEFAULT_WS")" == '{garbage' ]] \
  || fail "the corrupted file's content changed even though nothing above
was supposed to write to it (dry-run, or a refusal):
$(cat "$DEFAULT_WS")"

log "all scenarios passed -- a corrupted CURRENT subos does not crash, does not spread, and is reported"
