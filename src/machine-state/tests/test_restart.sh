#!/usr/bin/env bash
# Tests for restart-run.sh, service.sh, and the restart-sentinel hook.
#
# Everything runs against temp dirs. The sentinel is driven with a
# stub hook runtime whose silent/wake EXIT the script, like the real
# runtime (emit-and-exit) — a returning stub would mask fall-through
# bugs after an emit, which is exactly the class this suite exists
# to catch.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MS_DIR="$(cd "$HERE/.." && pwd)"
HOOK="$MS_DIR/../hooks/restart-sentinel.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
fails=0
check() { # check LABEL ACTUAL EXPECTED
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1 (want [$3] got [$2])"; fails=$((fails+1)); fi
}
count() { grep -c "$2" "$1" 2>/dev/null || true; }

# --- a fake deployment -------------------------------------------------
D="$T/deploy"; mkdir -p "$D/recycle.d"
cp "$MS_DIR/restart-run.sh" "$MS_DIR/service.sh" "$D/"
printf 'MS_TZ=UTC\n' > "$D/machine.env"
printf '#!/bin/bash\necho hello-a\n' > "$D/recycle.d/10-a.sh"
printf '#!/bin/bash\necho hello-b\n' > "$D/recycle.d/20-b.sh"
chmod +x "$D/recycle.d/"*.sh "$D/restart-run.sh"

# --- runner: all pass --------------------------------------------------
out="$(MS_RUN_LABEL=test "$D/restart-run.sh")"; rc=$?
check "runner all-pass rc" "$rc" "0"
check "runner all-pass rows" "$(printf '%s\n' "$out" | wc -l)" "2"
check "runner events lines" "$(count "$D/events.log" 'test .* rc=0')" "2"
check "runner no bootlog without restart reason" "$([ -e "$D/recycles.log" ] && echo yes || echo no)" "no"

# --- runner: restart reason writes the weather line --------------------
MS_RUN_LABEL=test MS_RUN_REASON=restart "$D/restart-run.sh" > /dev/null; rc=$?
check "runner restart rc" "$rc" "0"
check "runner bootlog line" "$(count "$D/recycles.log" 'restart: boot')" "1"

# --- runner: a failing subscriber --------------------------------------
printf '#!/bin/bash\necho bad-news\nexit 3\n' > "$D/recycle.d/15-bad.sh"
chmod +x "$D/recycle.d/15-bad.sh"
MS_RUN_LABEL=test "$D/restart-run.sh" > /dev/null; rc=$?
check "runner failure rc" "$rc" "1"
check "runner failure logged" "$(count "$D/events.log" 'test 15-bad.sh rc=3')" "1"
check "runner bootlog untouched on failure" "$(count "$D/recycles.log" 'restart: boot')" "1"
rm "$D/recycle.d/15-bad.sh"

# --- runner: a hung subscriber is killed, later ones still run ---------
printf '#!/bin/bash\nsleep 30\n' > "$D/recycle.d/15-hang.sh"
chmod +x "$D/recycle.d/15-hang.sh"
start=$(date +%s)
MS_RUN_LABEL=test MS_SUBSCRIBER_TIMEOUT=1 "$D/restart-run.sh" > "$T/hang.out"; rc=$?
elapsed=$(( $(date +%s) - start ))
check "runner hang rc" "$rc" "1"
check "runner hang killed at timeout" "$(count "$D/events.log" 'test 15-hang.sh rc=124')" "1"
check "runner later subscriber still ran" "$(grep -c '20-b' "$T/hang.out" || true)" "1"
check "runner hang bounded" "$([ "$elapsed" -lt 15 ] && echo yes || echo no)" "yes"
rm "$D/recycle.d/15-hang.sh"

# --- service.sh finders --------------------------------------------------
printf 'import time\ntime.sleep(30)\n' > "$T/svc.py"
python3 "$T/svc.py" serve &
svc_pid=$!
sleep 1
found="$(bash -c "source '$D/service.sh'; ms_find_python_script '*svc.py' serve")"
check "ms_find_python_script mode match" "$found" "$svc_pid"
found="$(bash -c "source '$D/service.sh'; ms_find_python_script '*svc.py' connect" || true)"
check "ms_find_python_script mode mismatch" "${found:-none}" "none"
ok="$(bash -c "source '$D/service.sh'; ms_pid_has_string $svc_pid svc.py && echo yes || echo no")"
check "ms_pid_has_string" "$ok" "yes"
python3 -m http.server 18771 --bind 127.0.0.1 > /dev/null 2>&1 &
sleep 1
ok="$(bash -c "source '$D/service.sh'; ms_listening 127.0.0.1 18771 && echo yes || echo no")"
check "ms_listening hit" "$ok" "yes"
ok="$(bash -c "source '$D/service.sh'; ms_listening 127.0.0.1 18772 && echo yes || echo no")"
check "ms_listening miss" "$ok" "no"
kill "$svc_pid" 2>/dev/null

# --- sentinel with a stub runtime ---------------------------------------
mkdir -p "$T/home"
cat > "$T/runtime.sh" <<'EOF'
silent() { echo "silent: $1" >> "$STUB_OUT"; exit 0; }
wake()   { echo "wake: $1" >> "$STUB_OUT"; exit 0; }
log()    { echo "log: $1" >> "$STUB_OUT"; }
EOF
export STUB_OUT="$T/stub.out"; : > "$STUB_OUT"
run_sentinel() {
  env -i PATH="$PATH" HOME="$T/home" HATCH_HOOK_RUNTIME="$T/runtime.sh" \
    STUB_OUT="$STUB_OUT" MS_RESTART_RUN="$D/restart-run.sh" \
    MS_WATCH_FILE="$T/watch" HATCH_HOOK_DRY_RUN="${DRY:-0}" \
    bash "$HOOK"
}
ev_before="$(count "$D/events.log" 'sentinel')"

DRY=1 run_sentinel
check "sentinel dry run reports missing" "$(count "$STUB_OUT" 'silent: dry run: watch file missing')" "1"
check "sentinel dry run wrote no watch" "$([ -e "$T/watch" ] && echo yes || echo no)" "no"
check "sentinel dry run ran nothing" "$(count "$D/events.log" 'sentinel')" "$ev_before"

DRY=0 run_sentinel
check "sentinel live pass is silent" "$(count "$STUB_OUT" 'silent: post-restart run completed')" "1"
check "sentinel watch created" "$([ -e "$T/watch" ] && echo yes || echo no)" "yes"
check "sentinel bootlog line" "$(count "$D/recycles.log" 'restart: boot')" "2"

run_sentinel
check "sentinel steady state silent" "$(count "$STUB_OUT" 'silent: watch file present')" "1"

printf '#!/bin/bash\necho broken\nexit 1\n' > "$D/recycle.d/15-bad.sh"
chmod +x "$D/recycle.d/15-bad.sh"
rm -f "$T/watch"
run_sentinel
check "sentinel failure wakes" "$(count "$STUB_OUT" 'wake: post-restart')" "1"
check "sentinel failure leaves watch missing" "$([ -e "$T/watch" ] && echo yes || echo no)" "no"
run_sentinel
check "sentinel failure wakes once per episode" "$(count "$STUB_OUT" 'wake: post-restart')" "1"
check "sentinel still-failing is silent" "$(count "$STUB_OUT" 'silent: post-restart scripts still failing')" "1"
rm "$D/recycle.d/15-bad.sh"
run_sentinel
check "sentinel recovery completes" "$(count "$STUB_OUT" 'silent: post-restart run completed')" "2"
check "sentinel watch recreated" "$([ -e "$T/watch" ] && echo yes || echo no)" "yes"
check "sentinel failure flag cleared" "$([ -e "$T/home/hooks/state/restart-sentinel/failure_active" ] && echo yes || echo no)" "no"

echo
if [ "$fails" = "0" ]; then echo "ALL PASS"; else echo "$fails FAILURE(S)"; exit 1; fi
