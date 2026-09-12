#!/usr/bin/env bash
# E2E-103: `self doctor` and `self doctor --deep` must agree on the remedy
# for a broken payload (D1, 2026.9.12.1).
#
# Before D1, the coordinate probe that turns a broken payload into a printed
# `xlings install <pkg>@<version>` remedy ran only under `--deep`/`--fix`.
# The catalog build was gated on the SAME flag as the expensive payload
# WALK, so a plain `self doctor` paid none of the walk's cost but also lost
# the (cheap, local, non-network) catalog lookup with it -- and a broken
# payload the index plainly still provides came back as "no package in any
# index provides this entry". Measured on a real 111-subos home: 100 such
# entries (fd@10.4.2, go@1.26.2, ...) where `--deep` alone resolved a correct
# `xlings install` remedy in the same run.
#
# I8: install a fixture package, break its payload by removing the bin
# directory doctor checks, and assert `self doctor` and `self doctor --deep`
# print the identical `→ run` line(s) -- and that the plain report never
# says "no package in any index provides", which is exactly the false
# negative D1 exists to remove.
set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/doctor_remedy_mode_parity"
HOME_DIR="$RUNTIME_DIR/home"
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"

FIXTURE_PKG="$LOCAL_INDEX_DIR/pkgs/r/remedy-fixture.lua"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

RUN() {
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin XLINGS_HOME="$HOME_DIR" "$XLINGS_BIN" "$@" )
}

mkdir -p "$HOME_DIR"
cp -r "$FIXTURE_INDEX_DIR" "$LOCAL_INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$LOCAL_INDEX_DIR/xim-indexrepos.lua"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
mkdir -p "$(dirname "$FIXTURE_PKG")"

cat > "$FIXTURE_PKG" <<'LUA'
package = {
    spec = "1",
    name = "remedy-fixture",
    description = "Local fixture for tests/e2e/doctor_remedy_mode_parity_test.sh",
    authors = {"xlings-ci"},
    licenses = {"MIT"},
    type = "package",
    archs = {"x86_64"},
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
    io.writefile(path.join(bindir, "remedy-fixture"),
                 "#!/bin/sh\necho remedy-fixture@" .. pkginfo.version() .. "\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "remedy-fixture"))
    end
    return true
end

function config()
    xvm.add("remedy-fixture", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    xvm.remove("remedy-fixture")
    return true
end
LUA

mkdir -p "$HOME_DIR/subos/default/bin"
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

RUN install remedy-fixture@1.0.0 -y >/dev/null 2>&1 \
  || fail "setup: install failed"

PAYLOAD_BIN="$HOME_DIR/data/xpkgs/xim-x-remedy-fixture/1.0.0/bin"
[[ -d "$PAYLOAD_BIN" ]] || fail "setup: payload bin dir should exist"
rm -rf "$PAYLOAD_BIN"

remedy_lines() {
  echo "$1" | strip_ansi | grep -E '→ run' | sed 's/^[[:space:]]*//'
}

log "quick doctor and --deep doctor must print the same remedy"
quick_rc=0
quick_out="$(RUN self doctor 2>&1)" || quick_rc=$?
[[ $quick_rc -ne 0 ]] || fail "quick doctor should exit non-zero on the broken payload; got:\n$quick_out"

deep_rc=0
deep_out="$(RUN self doctor --deep 2>&1)" || deep_rc=$?
[[ $deep_rc -ne 0 ]] || fail "deep doctor should exit non-zero on the broken payload; got:\n$deep_out"

quick_remedy="$(remedy_lines "$quick_out")"
deep_remedy="$(remedy_lines "$deep_out")"

[[ -n "$quick_remedy" ]] \
  || fail "quick doctor printed no remedy at all; got:\n$quick_out"

diff_out="$(diff <(printf '%s\n' "$quick_remedy") <(printf '%s\n' "$deep_remedy") || true)"
[[ -z "$diff_out" ]] \
  || fail "quick and deep doctor disagree on the remedy:\n$diff_out\n---quick---\n$quick_out\n---deep---\n$deep_out"

echo "$quick_remedy" | grep -qE "xlings install (xim:)?remedy-fixture@1\.0\.0" \
  || fail "quick doctor's remedy should name the package; got:\n$quick_remedy"

# The false negative D1 removes: a plain report must never say the index has
# nothing to offer when it plainly does.
echo "$quick_out" | strip_ansi | grep -qi "no package in any index provides" \
  && fail "quick doctor still claims no package provides this entry; got:\n$quick_out"

log "PASS: doctor_remedy_mode_parity"
