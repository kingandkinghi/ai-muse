#!/usr/bin/env bash
# ssh-state-ensure: the clock for the machine-state policy (see
# ../machine-state/). Every minute it runs ensure.sh, which converges the
# machine's declared ephemeral client state to its per-machine masters.
#
# Results policy: healthy minutes and drift-then-verified minutes are
# silent (drift is logged by ensure.sh itself). Only the two anomaly
# outcomes wake an agent — ensure exit 2 (cannot converge: the manifest or
# a master is missing/unreadable, or a step failed) and exit 3 (converged
# but verification failed). Wakes are edge-triggered per episode via a
# state flag, so a persistent fault wakes once, not every minute.
#
# The deployment's ensure.sh is located via $MS_ENSURE; the default
# assumes a checkout of this repo at ~/workspace/ai-muse with the scripts
# run in place. Deployments that copied the scripts elsewhere set
# MS_ENSURE in the hook's environment to the deployed path.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

STATE_DIR="$HOME/hooks/state/ssh-state-ensure"
FLAG="$STATE_DIR/anomaly_active"
mkdir -p "$STATE_DIR"
ENSURE="${MS_ENSURE:-$HOME/workspace/ai-muse/src/machine-state/ensure.sh}"

payload() { jq -cn --arg rc "$1" --arg out "$2" '{ensure_rc: $rc, output: $out}'; }

if [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ]; then
  # Check-only: never mutate state from a dry run.
  RC=0; OUT=$("$ENSURE" --check 2>&1) || RC=$?
  case "$RC" in
    0) silent "dry run: machine state converged" "$(payload "$RC" "$OUT")" ;;
    4) silent "dry run: drift present; a live run would converge it" "$(payload "$RC" "$OUT")" ;;
    *) wake "dry run: ensure cannot converge (rc=$RC)" "$(payload "$RC" "$OUT")" ;;
  esac
  exit 0
fi

RC=0; OUT=$("$ENSURE" 2>&1) || RC=$?
case "$RC" in
  0)
    rm -f "$FLAG"
    if [ -n "$OUT" ]; then
      log "converged after drift" "$(payload "$RC" "$OUT")"
      silent "machine state drifted and was converged + verified" "$(payload "$RC" "$OUT")"
    else
      silent "machine state converged" "$(payload 0 '')"
    fi
    ;;
  2|3)
    if [ -f "$FLAG" ]; then
      silent "machine state anomaly already reported; still failing (rc=$RC)" "$(payload "$RC" "$OUT")"
    else
      touch "$FLAG"
      wake "machine state anomaly (ensure rc=$RC)" "$(payload "$RC" "$OUT")"
    fi
    ;;
  *)
    silent "unexpected ensure exit code $RC" "$(payload "$RC" "$OUT")"
    ;;
esac
