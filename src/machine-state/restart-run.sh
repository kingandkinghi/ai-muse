#!/bin/bash
# restart-run.sh — one post-restart pass over the recycle.d/ scripts.
#
# Runs every executable in recycle.d/ (beside this script, or
# $MS_RESTART_D), in name order, each under a timeout (default 30s,
# $MS_SUBSCRIBER_TIMEOUT), with the event in its environment:
#
#   MS_EVENT=recycle          MS_NEW_BOOT=<current kernel boot id>
#   MS_PREV_BOOT=             MS_BOOT_ISO=<boot time, ISO 8601>
#   MS_DETECTED_ISO=<now, ISO 8601>
#
# (MS_PREV_BOOT is empty by design: the sentinel model does not track
# the previous boot; subscribers must not need it — the event means
# "a restart happened", and each subscriber checks its own state.)
#
# Subscribers are isolated: a failing or hung subscriber never blocks
# the others. Every run is appended to events.log (beside this
# script, or $MS_EVENT_LOG) as one line per subscriber with its exit
# code and one-line output. Results also go to stdout as TSV —
# name <TAB> rc <TAB> output — for the caller (the restart-sentinel
# hook) to shape into its wake payload. Exit code: 0 iff every
# subscriber passed (or there are none), 1 otherwise.
#
# When the pass is a restart pass ($MS_RUN_REASON=restart, set by the
# sentinel) and every subscriber passed, one line is appended to
# recycles.log (or $MS_BOOTLOG): the "muse weather" record that a
# boot was recycled and cleared, kept by the runner now that boot-id
# detection is retired.
#
# Per-machine settings come from machine.env beside this script,
# when present (MS_TZ, MS_RESTART_D, MS_EVENT_LOG, MS_BOOTLOG,
# MS_SUBSCRIBER_TIMEOUT, MS_RUN_LABEL).
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$BASE/machine.env" ]; then
  set -a; . "$BASE/machine.env"; set +a
fi
TZONE="${MS_TZ:-UTC}"
SUBDIR="${MS_RESTART_D:-$BASE/recycle.d}"
EVENTLOG="${MS_EVENT_LOG:-$BASE/events.log}"
BOOTLOG="${MS_BOOTLOG:-$BASE/recycles.log}"
TIMEOUT="${MS_SUBSCRIBER_TIMEOUT:-30}"
LABEL="${MS_RUN_LABEL:-restart-run}"

now_iso="$(TZ="$TZONE" date -Iseconds)"
boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
btime="$(awk '/^btime/{print $2}' /proc/stat 2>/dev/null || true)"
boot_iso=""
[ -n "$btime" ] && boot_iso="$(TZ="$TZONE" date -d "@$btime" -Iseconds 2>/dev/null || true)"

export MS_EVENT=recycle MS_NEW_BOOT="$boot_id" MS_PREV_BOOT="" \
       MS_BOOT_ISO="$boot_iso" MS_DETECTED_ISO="$now_iso"

all=0
if [ -d "$SUBDIR" ]; then
  for f in "$SUBDIR"/*; do
    [ -x "$f" ] || continue
    name="$(basename "$f")"
    out="$(timeout "$TIMEOUT" "$f" 2>&1)"; rc=$?
    flat="$(printf '%s' "$out" | tr '\n\t' '  ')"
    echo "$now_iso $LABEL $name rc=$rc${flat:+ — $flat}" >> "$EVENTLOG"
    printf '%s\t%s\t%s\n' "$name" "$rc" "$flat"
    [ "$rc" = "0" ] || all=1
  done
fi

if [ "$all" = "0" ] && [ "${MS_RUN_REASON:-}" = "restart" ]; then
  echo "$now_iso restart: boot $boot_id booted $boot_iso; post-restart run cleared ($LABEL)" >> "$BOOTLOG"
fi
exit "$all"
