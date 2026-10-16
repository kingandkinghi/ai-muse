#!/bin/bash
# verify.sh — prove the converged state is actually in force. Read-only:
# mutates nothing. Exit 0 = all proof holds; 1 = at least one FAIL line.
#
# Two layers:
#   1. ensure.sh --check must report no drift (live state matches masters).
#   2. Every executable in verify.d/ beside this script runs, in name
#      order; any non-zero exit fails verification. Site-specific proof —
#      config resolutions, key fingerprints, service probes — lives in
#      those checks, authored per machine (see the shipped example).
#      verify.d/ contents are per-machine and are never committed.
#
# machine.env settings are exported, so verify.d/ checks can read MS_*
# values from their environment.
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$BASE/machine.env" ]; then
  set -a; . "$BASE/machine.env"; set +a
fi

fail=0

out="$("$BASE/ensure.sh" --check 2>&1)"; rc=$?
if [ "$rc" = "4" ]; then
  echo "FAIL: drift present:$out"
  fail=1
elif [ "$rc" != "0" ]; then
  echo "FAIL: ensure --check exited $rc: $out"
  fail=1
fi

if [ -d "$BASE/verify.d" ]; then
  for f in "$BASE/verify.d"/*; do
    [ -x "$f" ] || continue
    "$f" || { echo "FAIL: verify.d/$(basename "$f")"; fail=1; }
  done
fi

if [ "$fail" = "0" ]; then
  echo "Verify OK: state converged and all site checks pass."
  exit 0
fi
exit 1
