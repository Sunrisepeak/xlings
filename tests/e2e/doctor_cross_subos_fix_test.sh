#!/usr/bin/env bash
# E2E-104: `self doctor --fix` walks every subos that owns a finding,
# without the user first running `xlings subos use <name>` by hand
# (2026.9.12.1).
#
# Before this, a broken payload owned by another subos carried the remedy
# `xlings subos use <name> && xlings self doctor --fix` -- 38 such findings
# on a measured 111-subos home. `--fix` from the CURRENT subos now walks
# every subos a ForeignPayload/OtherSubos finding names, in its own
# subprocess (`self doctor --fix --subos <name>`), so one `--fix` call
# repairs the whole home.
#
#   I3  from `default`, a broken payload `other` owns is reported (not
#       repaired) by plain `self doctor`; `self doctor --fix` (no
#       `subos use` first) repairs it via the cross-subos walk and exits 0;
#       a second `--fix --dry-run` has nothing left to plan.
#   I9  an UNCLAIMED registration -- no subos anywhere references it, and
#       its payload is gone -- is pruned by `--fix --dry-run`, not queued
#       for reinstall (D2): the plan says `prune`, never `would run ...
#       install` for that entry.
#   I5  a cross-subos child that genuinely FAILS (`self doctor --fix
#       --subos <name>` exits non-zero) must be visible in the PARENT's
#       verdict, not swallowed as a note nobody's exit code reflects: the
#       parent exits 1, `verifiedBy` is not written, and the report names
#       the failed subos and the exact command to re-run it directly.
set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

require_fixture_index

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/doctor_cross_subos_fix"
HOME_DIR="$RUNTIME_DIR/home"
LOCAL_INDEX_DIR="$RUNTIME_DIR/xim-pkgindex"

cleanup() { chmod -R u+w "$RUNTIME_DIR" 2>/dev/null || true; rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

XLINGS_BIN="$(find_xlings_bin)"

# Every command names the subos it runs in, the same convention
# self_doctor_multi_subos_test.sh uses -- this whole test is about which
# subos a repair happens in.
RUN_IN() {
  local subos="$1"; shift
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      XLINGS_HOME="$HOME_DIR" XLINGS_ACTIVE_SUBOS="$subos" \
      "$XLINGS_BIN" "$@" )
}

OUT_FILE="$RUNTIME_DIR/last-output.txt"
run_capture() {
  local subos="$1"; shift
  rc=0
  RUN_IN "$subos" "$@" >"$OUT_FILE" 2>&1 || rc=$?
  out=$(tr -d '\0' < "$OUT_FILE")
}

mkdir -p "$HOME_DIR/subos/default/bin" "$RUNTIME_DIR"
cp -r "$FIXTURE_INDEX_DIR" "$LOCAL_INDEX_DIR"
printf 'xim_indexrepos = {}\n' > "$LOCAL_INDEX_DIR/xim-indexrepos.lua"
rm -f "$LOCAL_INDEX_DIR/.xlings-index-cache.json"
mkdir -p "$LOCAL_INDEX_DIR/pkgs/x"

cat > "$LOCAL_INDEX_DIR/pkgs/x/xsf-plain.lua" <<'LUA'
package = {
    spec = "1", name = "xsf-plain",
    description = "cross-subos doctor fixture",
    authors = {"xlings-ci"}, licenses = {"MIT"}, type = "package",
    archs = {"x86_64"}, status = "stable", categories = {"test-fixture"},
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
    io.writefile(path.join(bindir, "xsf-plain"),
                 "#!/bin/sh\necho xsf-plain@" .. pkginfo.version() .. "\n")
    return true
end
function config()
    xvm.add("xsf-plain", { bindir = path.join(pkginfo.install_dir(), "bin") })
    return true
end
function uninstall()
    xvm.remove("xsf-plain")
    return true
end
LUA

cp "$XLINGS_BIN" "$HOME_DIR/xlings"
cat > "$HOME_DIR/.xlings.json" <<JSON
{ "mirror": "GLOBAL",
  "index_repos": [{ "name": "xim", "url": "$LOCAL_INDEX_DIR" }] }
JSON

log "init sandbox"
RUN_IN default self init >/dev/null 2>&1 || fail "self init failed"
mkdir -p "$HOME_DIR/data/xim-index-repos"
printf '{}\n' > "$HOME_DIR/data/xim-index-repos/xim-indexrepos.json"
RUN_IN default subos new other >/dev/null 2>&1 || fail "subos new other failed"

RUN_IN other install xsf-plain@1.0.0 -y >/dev/null 2>&1 \
  || fail "setup: other install xsf-plain failed"

PAYLOAD="$HOME_DIR/data/xpkgs/xim-x-xsf-plain/1.0.0"
WS_OTHER="$HOME_DIR/subos/other/.xlings.json"
[[ -d "$PAYLOAD" ]] || fail "setup: payload should exist"

has_ws_entry() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
ws = data.get("workspace") or {}
sys.exit(0 if sys.argv[2] in ws else 1)
PY
}

# ── I3: a broken payload owned by 'other' → reported from 'default',
#        repaired by --fix WITHOUT `subos use` first ─────────────────────
log "I3: break the payload owned by 'other'"
rm -rf "$PAYLOAD"

run_capture default self doctor
[[ $rc -eq 0 ]] \
  || fail "I3: another subos's broken payload must not fail this subos (rc=$rc):\n$out"
grep -q "broken payload \[subos: other\]" <<<"$out" \
  || fail "I3: default's report must attribute the finding to 'other'; got:\n$out"

log "I3: self doctor --fix from 'default' repairs it — no 'subos use' needed"
run_capture default self doctor --fix
[[ $rc -eq 0 ]] || fail "I3: default's --fix should exit 0; got $rc:\n$out"
[[ -f "$PAYLOAD/bin/xsf-plain" ]] \
  || fail "I3: --fix should have repaired the payload via the cross-subos walk:\n$out"
has_ws_entry "$WS_OTHER" "xsf-plain" \
  || fail "I3: the repair must land in 'other's own workspace"

log "I3: a second --fix --dry-run has nothing left to plan for this entry"
run_capture default self doctor --fix --dry-run
[[ $rc -eq 0 ]] || fail "I3: converged home's --fix --dry-run should exit 0; got $rc:\n$out"
grep -qi "would run" <<<"$out" \
  && fail "I3: nothing should be left to plan after convergence; got:\n$out"

# ── I9: an unclaimed registration is pruned, not queued for reinstall ────
#
# A version no subos anywhere references (not active, not in any
# workspace's installed[]) and whose payload is gone. The index can still
# resolve the coordinate (the fixture package is right there), so before D2
# the ladder would have reinstalled it; D2 prunes it instead, because
# nothing will ever use it again.
log "I9: an unclaimed registration is pruned by --fix --dry-run, not reinstalled"
python3 - "$HOME_DIR" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
state = home / ".xlings.json"
d = json.loads(state.read_text())
d["versions"]["xsf-plain"]["versions"]["9.9.9"] = {
    "kind": "program",
    "path": str(home / "data" / "xpkgs" / "xim-x-xsf-plain" / "9.9.9" / "bin"),
}
state.write_text(json.dumps(d, indent=2))
PY
# No workspace anywhere lists 9.9.9 (default has nothing; other has 1.0.0
# active), and its payload directory was never created -- unclaimed and
# unreachable from the moment it was written.

run_capture default self doctor --fix --dry-run
[[ $rc -ne 0 ]] \
  || fail "I9: the unclaimed broken entry should still count as an issue; got:\n$out"
grep -q "prune xsf-plain@9\.9\.9" <<<"$out" \
  || fail "I9: the plan must prune the unclaimed entry; got:\n$out"
grep -qE "would run .*install xsf-plain@9\.9\.9" <<<"$out" \
  && fail "I9: the unclaimed entry must not be queued for reinstall; got:\n$out"

# ── I5: a genuinely FAILING cross-subos child fails the whole run ────────
#
# Its own home, separate from I3/I9's -- this scenario is designed to end
# with 'other' still broken (the child never gets a chance to succeed), and
# must not leave that behind for the scenarios above to trip over.
#
# 'other's subos directory is made read-only, so when `default`'s --fix
# shells into it (`self doctor --fix --subos other`), that child's own
# reinstall of xsf-plain can create the payload file (install() writes
# under data/, untouched by the read-only directory) but cannot write its
# own workspace to register it (config()'s `xvm.add` targets
# subos/other/.xlings.json) -- so the child's `xlings install` genuinely
# fails (non-zero), not "succeeds but didn't really fix it": a real,
# observable subprocess failure the child's own re-detect still finds
# broken afterward, which is what makes this deterministic rather than a
# race against however fast some prune or ladder rung reacts.
#
# Two mechanisms were tried and rejected before this one: a recipe absent
# from the index (or present only for another platform) makes
# owning_coordinate_ return no remedy, which repair_payloads_ prunes
# unconditionally regardless of subos ownership -- converges cleanly, no
# failure to observe. A recipe whose install() hook always returns false
# DOES make `xlings install` exit non-zero, but the installer tags that
# payload's `.xpkg-install.json` `incomplete: true`, which reclassifies the
# finding from BrokenPayload to IncompletePayload on re-detect --
# `stillFound` (below, and the pre-existing analogous check inside the
# CHILD's own cmd_doctor) only looks at BrokenPayload/ForeignPayload, so the
# child's OWN outstanding count comes out 0 and it stamps verifiedBy anyway
# despite returning 1. That is a real, separate gap (IncompletePayload does
# not gate `outstanding`), not something this scenario is testing -- if this
# mechanism ever needs to change, keep re-detection landing on BrokenPayload,
# not IncompletePayload, or this assertion block will need it fixed first.
log "I5: a failing cross-subos child fails the whole run and withholds the stamp"
HOME5="$RUNTIME_DIR/i5-home"
mkdir -p "$HOME5/subos/default/bin"
cp "$XLINGS_BIN" "$HOME5/xlings"
cat > "$HOME5/.xlings.json" <<JSON
{ "mirror": "GLOBAL",
  "index_repos": [{ "name": "xim", "url": "$LOCAL_INDEX_DIR" }] }
JSON
RUN5() {
  local subos="$1"; shift
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \
      XLINGS_HOME="$HOME5" XLINGS_ACTIVE_SUBOS="$subos" \
      "$XLINGS_BIN" "$@" )
}
RUN5 default self init >/dev/null 2>&1 || fail "I5 setup: self init failed"
mkdir -p "$HOME5/data/xim-index-repos"
printf '{}\n' > "$HOME5/data/xim-index-repos/xim-indexrepos.json"
RUN5 default subos new other >/dev/null 2>&1 || fail "I5 setup: subos new other failed"
RUN5 other install xsf-plain@1.0.0 -y >/dev/null 2>&1 \
  || fail "I5 setup: other install xsf-plain failed"

PAYLOAD5="$HOME5/data/xpkgs/xim-x-xsf-plain/1.0.0"
[[ -d "$PAYLOAD5" ]] || fail "I5 setup: payload should exist before breaking it"
rm -rf "$PAYLOAD5"
chmod -R a-w "$HOME5/subos/other"

i5_rc=0
i5_out=$(RUN5 default self doctor --fix 2>&1) || i5_rc=$?
chmod -R u+w "$HOME5/subos/other"

[[ $i5_rc -eq 1 ]] \
  || fail "I5: a failed cross-subos child must fail the parent's run; got rc=$i5_rc:\n$i5_out"
grep -q "subos 'other'" <<<"$i5_out" \
  || fail "I5: the report must name the failed subos; got:\n$i5_out"
grep -qE "self doctor --fix --subos other.*exited [1-9][0-9]*" <<<"$i5_out" \
  || fail "I5: the report must show the exact child command and that it failed; got:\n$i5_out"

i5_verified=$(python3 -c "
import json, pathlib
print(json.loads(pathlib.Path('$HOME5/.xlings.json').read_text()).get('verifiedBy', ''))
")
[[ -z "$i5_verified" ]] \
  || fail "I5: verifiedBy must not be written while a cross-subos child failed; got '$i5_verified'"

log "PASS: doctor_cross_subos_fix"
