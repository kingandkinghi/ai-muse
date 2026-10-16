#!/bin/bash
# restore.sh — the hand-run composition: ensure (state) + verify (proof).
#
# Development flow: edit the masters / manifest, run this script, watch the
# proof. Automation never calls this script: the scheduler hook runs
# ensure.sh alone, and ensure invokes verify.sh itself exactly once per
# drift incident. See ensure.sh for the results policy and exit codes
# (0 converged, 2 cannot converge, 3 converged but verify failed).
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$BASE/ensure.sh"
rc=$?
if [ "$rc" != "0" ]; then
  echo "Restore incomplete: ensure exited $rc (see above)."
  exit "$rc"
fi

"$BASE/verify.sh" || { echo "Restore incomplete: verification failed (see above)."; exit 1; }

echo "Restore complete: machine state converged and verified."
