#!/usr/bin/env bash
# E2E-107: installing a payload that is already on disk (installed in some
# OTHER subos) into a second subos must register it into THAT subos too --
# not just try to activate a target it never wrote into that subos's own
# `installed[]` (task-7-report.md, "surfaced defect", 2026.9.12).
#
# The reported shape: `xlings install <target>@<version>` in a second subos,
# for a payload some other subos already has on disk, takes a shortcut
# straight to `xvm cmd_use` for activation -- and that activation refuses
# with "<target> is not installed in this subos" because the shortcut never
# wrote the target into the CURRENT subos's own `installed[]` first. Filed
# against the codebase at that point in this same round; re-run against HEAD
# here, it does not reproduce -- the install plan's "pending" detection is
# per-subos-aware, so a target this subos does not yet have is still a
# pending node even when its payload is on disk, and executing it (skipping
# only the install() hook, since the payload exists) re-runs config() for
# THIS subos exactly as a fresh install would: registration, shim, and
# sysroot links all land here, not just an activation attempt. This test
# exists as the regression guard for that path, not as a bug reproduction --
# see the "Item C" section of the final-wave report for what was actually
# found and why no code change accompanies this file.
#
#   S1  install `libfixture@1.0.0` in `default` (full path: creates the
#       shared payload, registers into default's workspace)
#   S2  `xlings subos new other`, then install the SAME coordinate in
#       `other` -- must exit 0, must NOT just be a bare "already installed"
#       activation attempt that leaves `other` unregistered
#   S3  `other`'s own workspace must list `libfixture@1.0.0` (active AND
#       installed[]) -- not just default's
#   S4  `other`'s bin/ shim and sysroot (lib symlink + header) must exist,
#       proving config() actually ran for `other` and not only `default`

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/second_subos_install"
HOME_DIR="$RUNTIME_DIR/home"
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"
FIXTURE_PKG="$LOCAL_INDEX_DIR/pkgs/l/libfixture.lua"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

RUN_IN() {
  local subos="$1"; shift
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      XLINGS_HOME="$HOME_DIR" XLINGS_ACTIVE_SUBOS="$subos" \
      "$XLINGS_BIN" "$@" )
}

mkdir -p "$(dirname "$FIXTURE_PKG")"

# A program with a real bindir, a library, and a header -- so a successful
# `config()` re-run for `other` is observable in three independent places
# (shim, lib symlink, usr/include), not just a workspace JSON entry.
cat > "$FIXTURE_PKG" <<'LUA'
package = {
    spec = "1",
    name = "libfixture",
    description = "Local fixture for tests/e2e/second_subos_install_test.sh",
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

local SONAME = "libfixture.so.1"

function install()
    local dir = pkginfo.install_dir()
    os.tryrm(dir)
    os.mkdir(path.join(dir, "bin"))
    os.mkdir(path.join(dir, "lib"))
    os.mkdir(path.join(dir, "include"))
    io.writefile(path.join(dir, "bin", "libfixture"),
                 "#!/bin/sh\necho libfixture\n")
    io.writefile(path.join(dir, "lib", SONAME), "GEN 1\n")
    io.writefile(path.join(dir, "include", "fixture.h"),
                 "#define FIXTURE_GEN \"1\"\n")
    return true
end

function config()
    local dir = pkginfo.install_dir()
    xvm.add("libfixture", { bindir = path.join(dir, "bin") })
    xvm.add(SONAME, {
        type = "lib",
        bindir = path.join(dir, "lib"),
        filename = SONAME,
        alias = SONAME,
        binding = "libfixture@" .. pkginfo.version(),
    })
    table.insert(_XVM_OPS, {
        op = "headers",
        includedir = path.join(dir, "include"),
    })
    return true
end

function uninstall()
    return true
end
LUA

mkdir -p "$HOME_DIR"
cp "$XLINGS_BIN" "$HOME_DIR/xlings"
cat > "$HOME_DIR/.xlings.json" <<JSON
{ "mirror": "GLOBAL",
  "index_repos": [{ "name": "xim", "url": "$LOCAL_INDEX_DIR" }] }
JSON

log "S1: install libfixture@1.0.0 in default"
RUN_IN default self init >/dev/null 2>&1 || fail "S1: self init failed"
mkdir -p "$HOME_DIR/data/xim-index-repos"
printf '{}\n' > "$HOME_DIR/data/xim-index-repos/xim-indexrepos.json"
RUN_IN default install libfixture@1.0.0 -y >/dev/null 2>&1 \
  || fail "S1: install in default failed"

PAYLOAD="$HOME_DIR/data/xpkgs/xim-x-libfixture/1.0.0"
[[ -d "$PAYLOAD" ]] || fail "S1: payload should exist after install"

log "S2: subos new other, install the same coordinate there"
RUN_IN default subos new other >/dev/null 2>&1 || fail "S2: subos new other failed"
S2_OUT="$RUNTIME_DIR/s2.out"
RUN_IN other install libfixture@1.0.0 -y >"$S2_OUT" 2>&1 \
  || { sed 's/^/    | /' "$S2_OUT"; fail "S2: install in 'other' must exit 0"; }
if grep -qi "is not installed in this subos" "$S2_OUT"; then
  fail "S2: install refused activation instead of registering into 'other' -- got:\n$(cat "$S2_OUT")"
fi

log "S3: other's own workspace must list libfixture@1.0.0"
WS_OTHER="$HOME_DIR/subos/other/.xlings.json"
python3 - "$WS_OTHER" <<'PY' || fail "S3: 'other's workspace must have libfixture active=1.0.0, installed includes 1.0.0"
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
entry = (data.get("workspace") or {}).get("libfixture")
active = entry.get("active") if isinstance(entry, dict) else entry
installed = entry.get("installed") if isinstance(entry, dict) else ([entry] if entry else [])
ok = bool(active == "1.0.0" and installed and "1.0.0" in installed)
sys.exit(0 if ok else 1)
PY

log "S4: other's shim and sysroot links must exist"
[[ -e "$HOME_DIR/subos/other/bin/libfixture" ]] \
  || fail "S4: no shim for libfixture in other/bin -- config() did not run for 'other'"
[[ -e "$HOME_DIR/subos/other/lib/libfixture.so.1" ]] \
  || fail "S4: no library symlink in other/lib -- config() did not run for 'other'"
[[ -e "$HOME_DIR/subos/other/usr/include/fixture.h" ]] \
  || fail "S4: no header in other/usr/include -- the headers op did not run for 'other'"

log "PASS: second_subos_install (installing an on-disk payload into a second subos registers it there)"
