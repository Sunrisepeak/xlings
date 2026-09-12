#!/usr/bin/env bash
# E2E: an upgrade is announced once per home, not once per command.
#
# `xself::print_migration_hint_once`'s `static bool` was per PROCESS, so
# "show this the first time ever" printed on every single invocation: four
# call sites emitted "run xlings self doctor --fix" on `list`/`install`/`use`
# whenever the recorded version differed from the running one. This is the
# behavioural fix: `notice::notice_once` persists the decision in the home's
# own `.xlings.json`, so the SECOND process to run sees that the first one
# already said it.
#
# I0  a home with NEITHER "verifiedBy" NOR "version" on record (freshly
#     `self init`-ed, nothing else has ever touched it) prints nothing --
#     an absent record is not a mismatch, the same rule migration_hint's own
#     empty guard applies
# I1  a version mismatch is announced on the first ordinary command and not
#     on the second
# I2  `self doctor --fix` converging stamps "verifiedBy", which silences the
#     notice and clears the doctor report's own migration field
#
# The notice is TTY-gated (it must never land in a script's captured
# output), so this test runs xlings on a real pty -- see
# tui_output_contract_test.sh, which solved the identical problem for the
# color decision.

set -euo pipefail

# shellcheck source=./project_test_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project_test_lib.sh"

RUNTIME_DIR="$ROOT_DIR/tests/e2e/runtime/notice_once"
HOME_DIR="$RUNTIME_DIR/home"
BIN_DIR="$RUNTIME_DIR/bin"

cleanup() { rm -rf "$RUNTIME_DIR"; }
trap cleanup EXIT
cleanup

mkdir -p "$HOME_DIR" "$BIN_DIR"

XLINGS_BIN="$(find_xlings_bin)"
# The version this build reports, read from the source rather than pinned
# literally -- a version bump must not make this test assert a stale one.
WANT_VERSION="$(sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' \
                  "$ROOT_DIR/src/core/config.cppm" | head -1)"
[[ -n "$WANT_VERSION" ]] || fail "could not read Info::VERSION from config.cppm"

RUN() {
  ( cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin XLINGS_HOME="$HOME_DIR" "$XLINGS_BIN" "$@" )
}

# Runs xlings on a real pty, stdout and stderr merged onto it, so
# `platform::supports_rewrite_output()` sees a terminal -- otherwise the
# notice's own TTY gate would make this test pass whether or not the
# dedup logic works at all. See tui_output_contract_test.sh.
cat > "$BIN_DIR/run_pty.py" <<'PY'
import os, pty, fcntl, termios, struct, select, subprocess, sys

home, binary, *args = sys.argv[1:]
env = {"HOME": home, "PATH": "/usr/bin:/bin",
       "XLINGS_HOME": home, "TERM": "xterm-256color"}
mfd, sfd = pty.openpty()
fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
p = subprocess.Popen([binary, *args], stdin=subprocess.DEVNULL,
                     stdout=sfd, stderr=sfd, env=env, close_fds=True, cwd="/tmp")
os.close(sfd)
out = b""
while True:
    r, _, _ = select.select([mfd], [], [], 20)
    if not r:
        break
    try:
        d = os.read(mfd, 65536)
    except OSError:
        break
    if not d:
        break
    out += d
p.wait()
sys.stdout.buffer.write(out)
PY

run_pty() { python3 "$BIN_DIR/run_pty.py" "$HOME_DIR" "$XLINGS_BIN" "$@"; }

log "Initializing sandbox XLINGS_HOME at $HOME_DIR"
cat > "$HOME_DIR/.xlings.json" <<'EOF'
{ "mirror": "CN" }
EOF
RUN self init >/dev/null 2>&1 || fail "self init failed"

echo "== I0: a record-less home (self init alone) says nothing =="
# `self init` alone never writes "version" -- only `self install`/`self
# update` do -- so this home genuinely has no record of any client at all.
# That is not a mismatch; it is the absence of a fact to compare.
if python3 -c "import json,sys; sys.exit(0 if 'version' in json.load(open(sys.argv[1])) else 1)" \
      "$HOME_DIR/.xlings.json"; then
  fail "I0 setup: a plain 'self init' home unexpectedly already has a 'version' key"
fi
out0a="$(run_pty list)"
if grep -q "xlings is now" <<<"$out0a"; then
  echo "$out0a"
  fail "I0: a record-less home must not be announced as a version mismatch"
fi
out0b="$(run_pty list)"
if grep -q "xlings is now" <<<"$out0b"; then
  echo "$out0b"
  fail "I0: (second run) a record-less home must not be announced"
fi
log "  ok — neither run mentioned a version mismatch"

# Backdate the home: a client far older than the one running now set it up,
# and nothing has verified it since.
python3 - "$HOME_DIR/.xlings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["version"] = "v0.4.40"
p.write_text(json.dumps(d, indent=2))
PY

echo "== I1: the mismatch is announced once, not on every command =="
out1="$(run_pty list)"
count1="$(grep -c "xlings is now" <<<"$out1" || true)"
[[ "$count1" -le 1 ]] \
  || fail "I1: the notice printed $count1 times on the FIRST command; got:\n$out1"

out2="$(run_pty list)"
count2="$(grep -c "xlings is now" <<<"$out2" || true)"
[[ "$count2" -eq 0 ]] \
  || fail "I1: the notice printed again on a SECOND, identical command; got:\n$out2"
log "  ok — first run: $count1, second run: $count2"

echo "== I2: --fix convergence stamps verifiedBy and silences the notice =="
rc=0
out_fix="$(RUN self doctor --fix -y 2>&1)" || rc=$?
[[ $rc -eq 0 ]] \
  || fail "I2: a fixture home with nothing installed has no findings; --fix should exit 0, got $rc:\n$out_fix"

verified="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('verifiedBy',''))" "$HOME_DIR/.xlings.json")"
[[ "$verified" == "$WANT_VERSION" ]] \
  || fail "I2: expected verifiedBy='$WANT_VERSION' after --fix, got '$verified'"
log "  ok — verifiedBy stamped to $WANT_VERSION"

out3="$(run_pty list)"
if grep -q "xlings is now" <<<"$out3"; then
  echo "$out3"
  fail "I2: verifiedBy now matches the running version; the notice must be silent"
fi
if grep -q "self doctor --fix" <<<"$out3"; then
  echo "$out3"
  fail "I2: the deleted migration hint's own command line reappeared"
fi
log "  ok — a converged home stays quiet"

echo "== I3: the deleted per-process hint text is gone from the binary =="
# The four call sites and update.cpp's own three lines are deleted, not just
# unreached -- this is the difference between "refactored" and "still there,
# behind a flag nobody flips".
count="$(strings "$XLINGS_BIN" | grep -c "packages installed by the previous client" || true)"
[[ "$count" -eq 0 ]] \
  || fail "I3: the deleted hint text is still linked into the binary ($count occurrence(s))"
log "  ok — the old per-process hint text is gone"

echo
echo "PASS: notice_once_test.sh"
