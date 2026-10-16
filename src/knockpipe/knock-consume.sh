#!/usr/bin/env bash
# knock-consume: the shared consumer for a knock channel. It holds
# the blocked wait (the agent stays quiescent), claims knocks by
# rename, runs the channel's filter — pure code, zero tokens —
# and wakes the thinker ONLY when the filter kept qualifying
# messages, or when the filter itself failed (a dead filter must
# be loud). Channel wrappers (one per channel; a few lines of config each) set
# the KP_* config and exec this script; ALL channel-specific
# behavior lives in the filter program (KP_FILTER_CMD). The
# parameterization is exactly:
#   KP_Q           queue directory (knock files land here)
#   KP_C           claimed directory (claims renamed here)
#   KP_LP          parked-report path (filter writes, glue reads)
#   KP_FILTER_CMD  the filter: reads the claims, prints a report
#                  {"kept": [...], "dropped": {...}} and parks the
#                  same report at KP_LP before printing it
#   KP_WATCH       knockwatch.py path (blocked inotify wait)
#   KP_LABEL       channel name for the failure payload
#   KP_TLOCK       (opt-in) thinker-lock path. When set, a wake
#                  creates the lock just before emitting, and
#                  while it exists this consumer abstains from
#                  claiming: the awake thinker owns the queue
#                  and self-serves follow-ups (KP_SELF below).
#                  The thinker removes the lock as its final
#                  act. A lock older than KP_TLOCK_STALE
#                  (seconds, default 900) is a dead thinker's
#                  and is reclaimed loudly. Channels whose
#                  thinkers work in parallel (a parallel-safe channel) leave
#                  KP_TLOCK unset and none of this exists.
#   KP_LOCKWATCH   lockwatch.py path (blocked wait-for-unlock);
#                  defaults to lockwatch.py beside this script.
# The filter receives KP_CLAIMED_DIR and KP_REPORT in its env.
#
# KP_SELF=1 is the self-serve mode: the awake thinker runs the
# wrapper itself to claim + filter the next batch. No hook
# runtime is touched (no emit exists on this side of the wake);
# the report is printed on stdout instead, and the epoch
# bookkeeping is completed inline. The caller holds KP_TLOCK,
# so the claim gate is skipped — it IS the owner.
#
# Runtime fact that shapes this whole script: in the hook
# runtime, silent/wake EMIT AND EXIT — no statement after them
# ever runs. (A stub runtime whose emit returns masked this in
# tests; the first version put cleanup after the emit and looped
# forever re-recovering its own last pull. Fixed 2026-10-15.)
# So cleanup NEVER follows an emit in the same run. Instead,
# delivery is a two-run handshake:
#   - the filter parks its report at KP_LP before returning;
#   - a run that is about to emit a report first drops a marker
#     (KP_LP.reported), then emits and exits;
#   - the NEXT run settles first: claim + marker = reported, so
#     archive the claims, remove report + marker, and CONTINUE
#     to the normal wait (no exit). Claim + no marker = the
#     predecessor died before reporting: re-issue the report
#     (worst case one duplicate) — or, if the parked report is
#     empty, clear it and continue. Claim + no parked report =
#     the filter never finished: run the filter again over the
#     still-claimed input.
# The only loss window is a death between the marker write and
# the emit — two adjacent statements; a slower independent sweep
# (a daily digest) is the backstop behind it. (Self-serve mode
# has the mirror-image window: a death between its print and
# its inline archive costs one duplicate, never a loss.)
set -euo pipefail

SELF="${KP_SELF:-0}"
if [ "$SELF" = "1" ]; then
  # Self-serve: no hook runtime exists on this side of the
  # wake, and none may be touched.
  log() { :; }
else
  source "$HATCH_HOOK_RUNTIME"
fi

: "${KP_Q:?knock-consume: KP_Q not set (use a channel wrapper)}"
: "${KP_C:?knock-consume: KP_C not set}"
: "${KP_LP:?knock-consume: KP_LP not set}"
: "${KP_FILTER_CMD:?knock-consume: KP_FILTER_CMD not set}"
: "${KP_WATCH:?knock-consume: KP_WATCH not set}"
KP_LABEL="${KP_LABEL:-channel}"
KP_TLOCK="${KP_TLOCK:-}"
KP_TLOCK_STALE="${KP_TLOCK_STALE:-900}"
KP_LOCKWATCH="${KP_LOCKWATCH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lockwatch.py}"

Q="$KP_Q"
C="$KP_C"
LP="$KP_LP"
MARK="$LP.reported"
export KP_CLAIMED_DIR="$C"
export KP_REPORT="$LP"
mkdir -p "$Q" "$C" "$C/archive"

count_in() {
  shopt -s nullglob
  local f=("$1"/*.knock)
  echo "${#f[@]}"
}

claim() {
  shopt -s nullglob
  local files=("$Q"/*.knock)
  for f in "${files[@]}"; do
    if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
      mv "$f" "$C/"
    fi
  done
}

clear_claimed() {
  [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ] && return 0
  shopt -s nullglob
  local f=("$C"/*.knock)
  if [ "${#f[@]}" -gt 0 ]; then
    mv "${f[@]}" "$C/archive/" 2>/dev/null || true
  fi
  rm -f "$LP" "$MARK"
}

# Creates the thinker lock just before a wake emit: the run is
# about to launch a thinker, and from this moment the queue is
# that thinker's. Noclobber create — if a lock somehow already
# exists, the epoch in progress keeps it and this is only
# logged; lock bookkeeping must never eat a wake.
tlock_create() {
  [ -z "$KP_TLOCK" ] && return 0
  [ "$SELF" = "1" ] && return 0
  [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ] && return 0
  mkdir -p "$(dirname "$KP_TLOCK")"
  if ( set -o noclobber; printf 'wake %s\n' "$(date +%s)" > "$KP_TLOCK" ) 2>/dev/null; then
    log "thinker lock created" '{}'
  else
    log "thinker lock already present at wake" '{}'
  fi
}

# The claim gate (KP_TLOCK channels only): returns 0 when this
# consumer may claim. While a fresh lock exists a thinker is
# awake and owns the queue — wait for the unlock on a kernel
# object (lockwatch/inotify, never a timer); if it is still
# held when the wait ends, end this run silent (the scheduler
# re-arms). A stale lock is a dead thinker's: reclaim loudly
# and proceed. Returns 1 when the unlock happened but the
# thinker drained the queue meanwhile (caller re-blocks).
tlock_gate() {
  [ -z "$KP_TLOCK" ] && return 0
  [ -e "$KP_TLOCK" ] || return 0
  local now age
  now=$(date +%s)
  age=$(( now - $(stat -c %Y "$KP_TLOCK" 2>/dev/null || echo "$now") ))
  if [ "$age" -gt "$KP_TLOCK_STALE" ]; then
    log "thinker lock stale; reclaiming" "{\"age_s\": $age}"
    rm -f "$KP_TLOCK"
    return 0
  fi
  python3 "$KP_LOCKWATCH" 240 "$KP_TLOCK" || true
  if [ -e "$KP_TLOCK" ]; then
    silent "thinker active (lock held); consumer abstaining" '{}'
    exit 0
  fi
  [ "$(count_in "$Q")" -gt 0 ]
}

EMIT_OUTCOME=""
EMIT_REASON=""
EMIT_PAYLOAD=""

# Runs the filter and loads EMIT_* with its report. On filter
# failure it clears the claims itself and reports directly: a
# failure report holds nothing worth re-issuing, and the claims
# must not survive to re-enter recovery.
filter_stage() {
  rm -f "$MARK"
  local out
  if ! out=$(bash -c "$KP_FILTER_CMD" 2>&1); then
    local ep
    ep=$(printf '%s' "$out" | tail -c 400 | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")
    clear_claimed
    if [ "$SELF" = "1" ]; then
      printf '{"label": "%s", "error": %s}\n' "$KP_LABEL" "$ep"
      exit 1
    fi
    tlock_create
    wake "filter failed" "{\"label\": \"$KP_LABEL\", \"error\": $ep}"
  fi
  local parsed kc
  parsed=$(printf '%s' "$out" | python3 -c "
import sys, json
d = json.load(sys.stdin)
kept = d.get('kept', [])
print(json.dumps({'kept_count': len(kept), 'kept': kept, 'dropped': d.get('dropped', {}), 'new_history_id': d.get('new_history_id')}))")
  log "filter ran" "$parsed"
  kc=$(printf '%s' "$parsed" | python3 -c "import sys, json; print(json.load(sys.stdin)['kept_count'])")
  if [ "$kc" -gt 0 ]; then
    EMIT_OUTCOME="wake"
    EMIT_REASON="qualifying messages arrived"
  else
    EMIT_OUTCOME="silent"
    EMIT_REASON="knocks carried no qualifying messages"
  fi
  EMIT_PAYLOAD="$parsed"
}

# Drops the reported-marker, then emits. The emit exits the
# script; the marker is how the next run knows this report
# already went out and the claim is safe to settle. In
# self-serve mode there is no emit: the report is printed on
# stdout for the awake thinker, and the epoch bookkeeping is
# completed inline — printed BEFORE archiving, so a death in
# between costs one duplicate, never a loss.
emit_marked() {
  if [ "$SELF" = "1" ]; then
    printf '%s\n' "$EMIT_PAYLOAD"
    clear_claimed
    return 0
  fi
  if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
    touch "$MARK"
  fi
  if [ "$EMIT_OUTCOME" = "wake" ]; then
    tlock_create
    wake "$EMIT_REASON" "$EMIT_PAYLOAD"
  else
    silent "$EMIT_REASON" "$EMIT_PAYLOAD"
  fi
}

# --- settle phase: reconcile whatever a previous run left ------
if [ "$(count_in "$C")" -gt 0 ]; then
  if [ -f "$MARK" ] && [ -f "$LP" ]; then
    clear_claimed
  elif [ -f "$LP" ]; then
    payload=$(python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
print(json.dumps({'kept_count': len(d.get('kept', [])), 'kept': d.get('kept', []), 'dropped': d.get('dropped', {}), 'recovered': True}))" "$LP") || payload=""
    if [ -n "$payload" ]; then
      kc=$(printf '%s' "$payload" | python3 -c "import sys, json; print(json.load(sys.stdin)['kept_count'])")
      if [ "$kc" -gt 0 ]; then
        EMIT_OUTCOME="wake"
        EMIT_REASON="qualifying messages arrived (recovered report)"
        EMIT_PAYLOAD="$payload"
        emit_marked
        exit 0
      fi
      clear_claimed
    else
      filter_stage
      emit_marked
      exit 0
    fi
  else
    filter_stage
    emit_marked
    exit 0
  fi
fi

# --- serve phase ---------------------------------------------------
iter=0
while [ "$iter" -lt 3 ]; do
  iter=$((iter + 1))
  if [ "$(count_in "$Q")" -gt 0 ]; then
    if [ "$SELF" != "1" ] && [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ]; then
      wake "knocks arrived (dry run: filter skipped)" '{}'
      exit 0
    fi
    if [ "$SELF" != "1" ]; then
      tlock_gate || continue
    fi
    claim
    filter_stage
    emit_marked
    exit 0
  fi
  if [ "$SELF" = "1" ]; then
    printf '{"kept_count": 0, "kept": [], "dropped": {}, "self": true}\n'
    exit 0
  fi
  if [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ]; then
    silent "queue empty (dry run: block and filter skipped)" '{}'
    exit 0
  fi
  python3 "$KP_WATCH" 480 "$Q" || true
  if [ "$(count_in "$Q")" -eq 0 ]; then
    silent "block window elapsed, no knocks" '{}'
    exit 0
  fi
done
if [ "$SELF" != "1" ]; then
  silent "serve loop exhausted" '{}'
fi
