# service.sh — shared helpers for recycle.d/ subscribers.
#
# Subscribers are idempotent scripts that restart detached services
# which die when the machine is recycled. Every subscriber needs the
# same handful of moves — is my process alive, is my socket listening,
# start the thing detached, prove it came up — so they live here once,
# parameterized, instead of being re-written (and re-debugged) per
# subscriber. Source this file from a subscriber:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../service.sh"
#
# Liveness rule (learned the hard way, twice): NEVER decide liveness
# with a bare `pgrep -f` or any regex over full command lines. Such a
# pattern also matches ancestor shells whose command strings merely
# mention the service (a maintenance shell, the subscriber's own
# caller), so the check "finds" the invoker, records it as the
# service, and starts nothing while the service lies dead. Every
# finder below matches argv in POSITION: argv[0] is the interpreter
# or program, argv[1] the script, argv[2] its mode argument.
#
# Indexing here is 0-based, as in C: ms_argv PID 1 is the script a
# python process is running.

# ms_argv PID N — print argv[N] of PID (empty when absent).
ms_argv() {
  local -a a=()
  mapfile -d '' a < "/proc/$1/cmdline" 2>/dev/null || return 1
  printf '%s' "${a[$2]:-}"
}

# ms_find_python_script GLOB [ARG2] — pid of the first python process
# whose argv[1] glob-matches GLOB and, when ARG2 is given, whose
# argv[2] equals it exactly. Covers "the service is a python script"
# and "one script, several modes" (serve/connect style) services.
ms_find_python_script() {
  local glob="$1" arg2="${2:-}" p v
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    v="$(ms_argv "${p#/proc/}" 0)"; case "$v" in *python*) ;; *) continue ;; esac
    v="$(ms_argv "${p#/proc/}" 1)"; case "$v" in $glob) ;; *) continue ;; esac
    if [ -n "$arg2" ]; then
      v="$(ms_argv "${p#/proc/}" 2)"; [ "$v" = "$arg2" ] || continue
    fi
    echo "${p#/proc/}"; return 0
  done
  return 1
}

# ms_find_argv1 GLOB — pid of the first process whose argv[1]
# glob-matches GLOB, whatever the interpreter or program in argv[0].
ms_find_argv1() {
  local p v
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    v="$(ms_argv "${p#/proc/}" 1)"; case "$v" in $1) ;; *) continue ;; esac
    echo "${p#/proc/}"; return 0
  done
  return 1
}

# ms_find_with_arg A0GLOB EXACT — pid of the first process whose
# argv[0] glob-matches A0GLOB and which carries EXACT as a whole argv
# element (e.g. a tunnel client identified by its forwarding spec).
ms_find_with_arg() {
  local a0="$1" exact="$2" p v i
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    v="$(ms_argv "${p#/proc/}" 0)"; case "$v" in $a0) ;; *) continue ;; esac
    local -a a=()
    mapfile -d '' a < "$p/cmdline" 2>/dev/null || continue
    for i in "${a[@]}"; do
      [ "$i" = "$exact" ] && { echo "${p#/proc/}"; return 0; }
    done
  done
  return 1
}

# ms_pid_has_string PID STRING — true when PID is alive and its
# command line contains STRING (fixed string). The pidfile companion
# check: proves a recorded pid is really the service, immune to stale
# pidfiles and pid reuse.
ms_pid_has_string() {
  [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -qF "$2"
}

# ms_listening HOST PORT — true when something listens on HOST:PORT.
ms_listening() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx "$1:$2"
}

# ms_launch LOG CWD CMD... — start CMD detached (own session, stdin
# closed, output appended to LOG) from CWD. Export any environment the
# command needs BEFORE calling: the child inherits this shell's
# exported variables.
ms_launch() {
  local log="$1" cwd="$2"; shift 2
  ( cd "$cwd" && setsid nohup "$@" >> "$log" 2>&1 < /dev/null & )
}
