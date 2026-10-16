#!/bin/bash
# Example recycle.d/ subscriber: restart a detached service that dies
# with the machine when it is recycled.
#
# To use: copy into recycle.d/ in the deployment directory (beside
# restart-run.sh and service.sh), drop the ".example" from the name,
# make it executable, and set in machine.env:
#   MS_SERVICE_NAME   a label for log lines
#   MS_SERVICE_CMD    the command line that starts the service
#   MS_SERVICE_PIDFILE  where the service's pid is kept
#   MS_SERVICE_LOG    where the service's output is appended
#   MS_SERVICE_CWD    working directory to start it in (default: $HOME)
#   MS_SERVICE_PATTERN  the service's script name as it appears in
#                     argv[1] of the running process (a glob is fine)
#
# Idempotent: a live service is left alone. Liveness is pidfile +
# cmdline check (immune to stale pidfiles and pid reuse), with a
# recovery scan that also refreshes the pidfile. All process logic
# comes from service.sh — see its header for why liveness must be
# matched in argv position, never with a bare pgrep -f. Exits 0
# (skip) when the service is not configured.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../service.sh"

name="${MS_SERVICE_NAME:-}"
cmd="${MS_SERVICE_CMD:-}"
pidfile="${MS_SERVICE_PIDFILE:-}"
log="${MS_SERVICE_LOG:-/dev/null}"
cwd="${MS_SERVICE_CWD:-$HOME}"
pattern="${MS_SERVICE_PATTERN:-}"

[ -n "$name" ] && [ -n "$cmd" ] && [ -n "$pidfile" ] && [ -n "$pattern" ] \
  || { echo "skip: MS_SERVICE_* unset"; exit 0; }

alive() {
  local pid=""
  [ -r "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null)"
  if ms_pid_has_string "$pid" "$pattern"; then
    return 0
  fi
  pid="$(ms_find_argv1 "$pattern")"
  if [ -n "$pid" ]; then
    printf '%s\n' "$pid" > "$pidfile"
    return 0
  fi
  return 1
}

if alive; then
  echo "$name already running"
  exit 0
fi

cd "$cwd" || { echo "$name: cannot cd to $cwd"; exit 1; }
ms_launch "$log" "$cwd" bash -c "$cmd"
sleep 2
if alive; then
  echo "$name restarted (event: ${MS_EVENT:-manual}, boot: ${MS_NEW_BOOT:-unknown})"
  exit 0
fi
echo "$name: start attempted but process not found"
exit 1
