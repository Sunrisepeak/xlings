#!/usr/bin/env bash
# E2E-108: a removed-but-not-reinstalled package must fail `--fix` and
# block the `verifiedBy` stamp (2026.9.12, F1).
#
# `repair_one`'s R3 rung (src/core/xself/repair.cpp) has one outcome worse
# than any other: `xlings remove --force` actually drops the registration
# (records gone) and the reinstall meant to put it back fails too. Before
# this test's fix, `RepairReport::failedEntries` was only counted as
# `outstanding` when the (target, version) it names is STILL a finding
# after re-detection (`stillFound`) -- and a fully removed registration is,
# by construction, never a finding again. `outstanding` read 0, `--fix`
# stamped `verifiedBy`, and exited 0, having taken the package out and
# left it out.
#
# The fixture: a package that installs SUCCESSFULLY once via its real
# install()/config() hooks -- so the version DB entry carries the full
# bindingGroup bookkeeping a genuine install writes (a hand-crafted,
# minimal DB entry does NOT, and `xlings remove <ns>:<pkg>@<ver>` --
# exactly the coordinate shape the repair ladder uses -- silently no-ops
# on one of those instead of removing it, which was measured while
# building this fixture and would otherwise make this test exercise
# nothing). Its install() hook is then made to fail FOREVER (an external
# marker file, never touched by `remove`, that the hook checks on every
# call -- the same "always fails" trigger shape as `brokenpkg` in
# install_silent_failure_test.sh, just delayed by one successful call).
#
# The payload directory is then deleted WHOLESALE (not just the binary
# inside it): a directory that still exists, even emptied, reads as
# "already installed, nothing to do" to the installer's own on-disk
# shortcut, which would make R2's `install` skip the hook (and its
# guaranteed failure) entirely. A directory that is gone outright forces
# a real hook invocation on every attempt, and is unconditionally a
# BrokenPayload finding (L4 in doctor.cpp) -- no "release anchor"
# reclassification to route around, since that only applies once L4's
# directory-must-exist check has already passed.
#
#   R2 (`install`) fails (the marker says "never again")
#   R3 removes the registration (`remove --force` -- it is the only
#      claimant, so this is a full removal, not a detach) and reinstalls,
#      which fails the same way
#
# The package is now GENUINELY GONE and cannot come back on its own.

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/doctor_removed_not_reinstalled"
HOME_DIR="$RUNTIME_DIR/home"
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"
MARKER="$RUNTIME_DIR/unfixable-installed-once.marker"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

RUN() {
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      XLINGS_HOME="$HOME_DIR" XLINGS_ACTIVE_SUBOS=default \
      "$XLINGS_BIN" "$@" </dev/null )
}

mkdir -p "$HOME_DIR/subos/default/bin" "$RUNTIME_DIR"
cp -r "$FIXTURE_INDEX_DIR" "$LOCAL_INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$LOCAL_INDEX_DIR/xim-indexrepos.lua"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
mkdir -p "$LOCAL_INDEX_DIR/pkgs/u"

cat > "$LOCAL_INDEX_DIR/pkgs/u/unfixable.lua" <<LUA
package = {
    spec = "1",
    name = "unfixable",
    description = "Local fixture: installs once, then fails forever, for doctor_removed_not_reinstalled_test.sh",
    authors = {"xlings-ci"},
    licenses = {"MIT"},
    type = "package",
    archs = {"x86_64", "aarch64"},
    status = "stable",
    categories = {"test-fixture"},
    programs = {"unfixable"},
    xpm = {
        linux   = { ["1.0.0"] = {} },
        macosx  = { ["1.0.0"] = {} },
        windows = { ["1.0.0"] = {} },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.xvm")

-- Outside the payload -- \`remove\` never touches this, which is the whole
-- point: once it exists, install() can never succeed again, no matter how
-- many times the ladder or a human retries it.
local MARKER = "$MARKER"

function install()
    if os.isfile(MARKER) then
        return false
    end
    local bindir = path.join(pkginfo.install_dir(), "bin")
    os.tryrm(pkginfo.install_dir())
    os.mkdir(bindir)
    io.writefile(path.join(bindir, "unfixable"), "#!/bin/sh\necho unfixable\n")
    if os.host() ~= "windows" then
        os.exec("chmod +x " .. path.join(bindir, "unfixable"))
    end
    io.writefile(MARKER, "installed once\n")
    return true
end

function config()
    xvm.add("unfixable", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end

function uninstall()
    xvm.remove("unfixable")
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

log "init sandbox"
RUN self init >/dev/null 2>&1 || fail "self init failed"
mkdir -p "$HOME_DIR/data/xim-index-repos"
printf '{}\n' > "$HOME_DIR/data/xim-index-repos/xim-indexrepos.json"

log "install unfixable@1.0.0 -y (succeeds -- the marker does not exist yet)"
RUN install unfixable@1.0.0 -y >/dev/null 2>&1 \
  || fail "setup: the FIRST install must succeed (no marker yet)"
[[ -f "$MARKER" ]] || fail "setup: install() should have written the marker"

UNFIXABLE_PAYLOAD="$HOME_DIR/data/xpkgs/xim-x-unfixable/1.0.0"
[[ -x "$UNFIXABLE_PAYLOAD/bin/unfixable" ]] \
  || fail "setup: the real binary should exist after a successful install"

log "breaking the payload: delete the WHOLE payload directory"
rm -rf "$UNFIXABLE_PAYLOAD"
# Deliberately the whole directory, not just the binary inside it:
#   - doctor's own "payload directory must exist" check (L4) makes this
#     unconditionally a BrokenPayload finding -- no "release anchor"
#     reclassification to route around (that check is only reached once
#     L4 has already passed).
#   - the installer's own "is this already installed" shortcut checks
#     `is_directory(...) && payload_has_content(...)`; with the directory
#     itself gone, that is false unconditionally, so `install` is
#     guaranteed to invoke the real hook (and its guaranteed failure) on
#     every attempt, rather than skipping straight to a trivial "already
#     installed" success that leaves the finding un-repaired but reports
#     healed.

log "self doctor reports the broken payload"
rc=0; out="$(RUN self doctor --deep 2>&1)" || rc=$?
[[ $rc -ne 0 ]] \
  || fail "a broken payload must fail plain doctor; got rc=$rc:\n$out"
echo "$out" | strip_ansi | grep -q "unfixable" \
  || fail "the broken payload finding must name unfixable; got:\n$out"

log "self doctor --fix -y: R2 and R3 both fail (the marker says never again) -- the package must come out GONE, and the run must say so"
rc=0; fixout="$(RUN self doctor --fix -y 2>&1)" || rc=$?
echo "$fixout" | tail -25 | sed 's/^/    | /'

[[ $rc -ne 0 ]] \
  || fail "a removed-but-not-reinstalled package must fail --fix; got rc=0:\n$fixout"

echo "$fixout" | strip_ansi | grep -qi "REMOVED but could not reinstall" \
  || fail "the report must say the package was removed and could not be put back; got:\n$fixout"
echo "$fixout" | strip_ansi | grep -qE "xlings install (xim:)?unfixable@1\.0\.0" \
  || fail "the report must hand back the exact, runnable command to finish the job; got:\n$fixout"

verified="$(python3 -c "
import json, pathlib
print(json.loads(pathlib.Path('$HOME_DIR/.xlings.json').read_text()).get('verifiedBy', ''))
")"
[[ -z "$verified" ]] \
  || fail "verifiedBy must not be stamped while a removal was never undone; got '$verified'"
log "  ✓ --fix exited $rc and did not stamp verifiedBy"

log "the registration is genuinely gone -- re-running install is what the report told the user to do"
current="$(python3 -c "
import json, pathlib
d = json.loads(pathlib.Path('$HOME_DIR/.xlings.json').read_text())
print('unfixable' in d.get('versions', {}) and '1.0.0' in d['versions'].get('unfixable', {}).get('versions', {}))
")"
[[ "$current" == "False" ]] \
  || fail "expected the registration to have actually been removed by R3; versions DB still has it"

# The registration is gone from the home entirely now -- there is no
# finding left for a SECOND run to re-detect, so `--fix` reporting the home
# clean from here is correct, not a regression: it is the first run's exit
# code that had to catch the loss, at the moment it happened, and it did.
# This is the no-crash / no-relapse check, not a re-assertion of F1 itself.
log "a second --fix -y does not crash and does not re-fail on a package that is simply gone"
rc2=0; fixout2="$(RUN self doctor --fix -y 2>&1)" || rc2=$?
echo "$fixout2" | grep -qE "terminate called|Segmentation|Aborted" \
  && fail "a second --fix -y crashed:\n$fixout2"
echo "$fixout2" | strip_ansi | grep -qi "REMOVED but could not reinstall" \
  && fail "unfixable is gone from the versions DB; a second run has nothing left to blame it for:\n$fixout2"

log "all scenarios passed"
