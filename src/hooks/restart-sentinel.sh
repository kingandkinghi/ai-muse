#!/usr/bin/env bash
# restart-sentinel: the clock for post-restart recovery (see
# ../machine-state/). Every poll (20s as deployed) it checks a
# volatile watch file. /tmp does not survive a machine recycle, so a
# MISSING watch file means "this boot has not yet completed its
# post-restart run": the hook makes one pass over the deployment's
# recycle.d/ subscribers via restart-run.sh, and creates the watch
# file only when every subscriber passed. While any subscriber
# fails the file stays missing and the next poll retries — which
# also covers subscribers that depend on state the converger has
# not installed yet in the first moments of a boot. A failure
# episode wakes an agent once, edge-triggered by a state flag.
#
# The runner is located via $MS_RESTART_RUN; the default assumes a
# checkout of this repo at ~/workspace/ai-muse with the machine-state
# scripts run in place. Deployments that copied the scripts
# elsewhere set MS_RESTART_RUN in the hook's environment. The watch
# file path is $MS_WATCH_FILE (default /tmp/muse-restart.watch) and
# must live somewhere that does NOT survive a recycle — that is the
# whole detection mechanism; no boot-id state is kept anywhere.
#
# Premise, stated plainly: on the machines this was built for, /tmp
# is rebuilt per boot (verified across repeated recycles). On a
# machine where /tmp persists across reboots the sentinel never
# fires; use boot-id detection there instead.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

RUNNER="${MS_RESTART_RUN:-$HOME/workspace/ai-muse/src/machine-state/restart-run.sh}"
WATCH="${MS_WATCH_FILE:-/tmp/muse-restart.watch}"
STATE_DIR="$HOME/hooks/state/restart-sentinel"
FLAG="$STATE_DIR/failure_active"
mkdir -p "$STATE_DIR"

TZONE="${MS_TZ:-UTC}"
now_iso="$(TZ="$TZONE" date -Iseconds)"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"

payload() { # $1 = TSV results file
  jq -cn --arg b "$boot_id" \
    --argjson r "$(jq -Rn '[inputs | split("\t") | {name: .[0], rc: (.[1] | tonumber), output: .[2]}]' < "$1")" \
    '{boot: $b, results: $r}'
}

if [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ]; then
  if [ -e "$WATCH" ]; then
    silent "dry run: watch file present; nothing to do" '{"watch":"present"}'
  else
    silent "dry run: watch file missing; a live run would make one post-restart pass" '{"watch":"missing"}'
  fi
  exit 0
fi

if [ -e "$WATCH" ]; then
  silent "watch file present" '{"watch":"present"}'
fi

# Watch file missing: this boot has not completed its post-restart run.
RESULTS="$(mktemp)"
rc=0
MS_RUN_LABEL=sentinel MS_RUN_REASON=restart "$RUNNER" > "$RESULTS" 2>/dev/null || rc=$?

if [ "$rc" = "0" ]; then
  printf 'boot %s cleared %s\n' "$boot_id" "$now_iso" > "$WATCH"
  rm -f "$FLAG"
  log "post-restart scripts passed; watch file created" "$(payload "$RESULTS")"
  silent "post-restart run completed for boot $boot_id" "$(payload "$RESULTS")"
fi

# Some subscriber failed: leave the watch file missing (retry next
# poll), wake once per failure episode.
if [ -f "$FLAG" ]; then
  silent "post-restart scripts still failing; already reported" "$(payload "$RESULTS")"
else
  touch "$FLAG"
  wake "post-restart script(s) failing after restart (boot $boot_id)" "$(payload "$RESULTS")"
fi
