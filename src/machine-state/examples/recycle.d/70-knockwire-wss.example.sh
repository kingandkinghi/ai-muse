#!/bin/bash
# Example recycle.d/ subscriber: keep a knockwire consumer connected
# when the machine recycles, with the SSH leg wrapped as HTTPS
# (wstunnel) so it works from hosts whose only egress is HTTPS — no
# direct SSH egress, no VPN/exit node, no proprietary tunnel client.
#
# The channel is three detached processes, in dependency order:
#   1. kw-client serve      knock demux on 127.0.0.1:<demux port>
#   2. wstunnel client      maps 127.0.0.1:<local port> through a
#                           WebSocket (wss://) to the knockwire
#                           host's sshd; the server side of wstunnel
#                           sits behind the host's HTTPS front door
#                           restricted to sshd (see wstunnel server
#                           --restrict-to). sshd's own key gate is
#                           unchanged — wstunnel is transport only.
#   3. kw-client connect    ssh -R <lease port>, dialed to the local
#                           wstunnel map via KW_SSH_TARGET/PORT.
# A connect found dialed anywhere else is a previous transport: it
# is killed so the wss connect can take the lease port.
#
# Prerequisite: the knockwire host's SSH key must already be in
# ~/.ssh/known_hosts (e.g. via ssh-keyscan or a first manual connect
# with StrictHostKeyChecking=accept-new) — kw-client.py connect does
# not set StrictHostKeyChecking itself and will fail otherwise.
#
# To use: copy into recycle.d/ in the deployment directory (beside
# restart-run.sh and service.sh), drop the ".example" from the name,
# make it executable, and set in machine.env:
#   MS_KW_DIR         directory holding kw-client.py (consumer side)
#   MS_KW_WSS_URL     e.g. wss://ssh.example.net — the front door
#   MS_WSTUNNEL_BIN   path to the wstunnel binary (client)
#   MS_KW_LOCAL_PORT  local map port (default 10023)
#   MS_KW_SSH_USER    knockwire ssh user (default kw)
#   MS_KW_DEMUX_PORT  serve/demux port (default 18765)
#
# Idempotent, per the subscriber contract: one pass, no internal
# retry loop — the restart-sentinel re-runs failures. Liveness is
# listener sockets plus exact-argv matching from service.sh, never
# a bare pgrep -f. Exits 0 (skip) when unconfigured.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/../service.sh"

DIR="${MS_KW_DIR:-}"
WSS_URL="${MS_KW_WSS_URL:-}"
WSTUN_BIN="${MS_WSTUNNEL_BIN:-}"
LOCAL_PORT="${MS_KW_LOCAL_PORT:-10023}"
SSH_USER="${MS_KW_SSH_USER:-kw}"
DEMUX_PORT="${MS_KW_DEMUX_PORT:-18765}"

[ -n "$DIR" ] && [ -n "$WSS_URL" ] && [ -n "$WSTUN_BIN" ] \
  || { echo "skip: MS_KW_* unset"; exit 0; }

SERVE_LOG="${MS_KW_LOG_DIR:-/tmp}/kw-serve.log"
CONNECT_LOG="${MS_KW_LOG_DIR:-/tmp}/kw-connect.log"
WSTUN_LOG="${MS_KW_LOG_DIR:-/tmp}/kw-wstunnel.log"
LOCAL_MAP="tcp://127.0.0.1:$LOCAL_PORT:127.0.0.1:22"
SSH_TARGET="$SSH_USER@127.0.0.1"

lease_field() { # $1 = sed pattern over `kw-client.py show` JSON
  (cd "$DIR" && python3 kw-client.py show 2>/dev/null) | sed -n "s/.*$1.*/\1/p" | head -1
}

actions=""

# --- serve -------------------------------------------------------------
if ! ms_listening 127.0.0.1 "$DEMUX_PORT"; then
  pid="$(ms_find_python_script '*kw-client.py' serve)" && kill "$pid" 2>/dev/null
  ms_launch "$SERVE_LOG" "$DIR" python3 kw-client.py serve
  sleep 3
  ms_listening 127.0.0.1 "$DEMUX_PORT" || { echo "knockwire: serve failed to listen (see $SERVE_LOG)"; exit 1; }
  actions="serve revived"
fi

# --- lease -------------------------------------------------------------
port="$(lease_field '"port": \([0-9]*\)')"
exp="$(lease_field '"lease_expires": "\([^"]*\)"')"
if [ -n "$exp" ]; then
  exp_s="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
  if [ "$exp_s" -gt 0 ] && [ $((exp_s - $(date +%s))) -lt 3600 ]; then
    (cd "$DIR" && python3 kw-client.py register > /dev/null 2>&1)
    port="$(lease_field '"port": \([0-9]*\)')"
  fi
fi
if [ -z "$port" ]; then
  (cd "$DIR" && python3 kw-client.py register > /dev/null 2>&1)
  port="$(lease_field '"port": \([0-9]*\)')"
fi
[ -n "$port" ] || { echo "knockwire: no lease (register failed)"; exit 1; }

# --- wstunnel client ---------------------------------------------------
if ! ms_listening 127.0.0.1 "$LOCAL_PORT"; then
  pid="$(ms_find_with_arg '*wstunnel' "$LOCAL_MAP")" && kill "$pid" 2>/dev/null
  ms_launch "$WSTUN_LOG" "$HOME" "$WSTUN_BIN" client -L "$LOCAL_MAP" "$WSS_URL"
  sleep 4
  ms_listening 127.0.0.1 "$LOCAL_PORT" || { echo "knockwire: wstunnel client failed to listen (see $WSTUN_LOG)"; exit 1; }
  actions="${actions:+$actions, }wstunnel revived"
fi

# --- connect -----------------------------------------------------------
if ms_find_with_arg '*ssh' "$port:127.0.0.1:$DEMUX_PORT" > /dev/null; then
  if ! ms_find_with_arg '*ssh' "$SSH_TARGET" > /dev/null; then
    pid="$(ms_find_with_arg '*ssh' "$port:127.0.0.1:$DEMUX_PORT")" && kill "$pid" 2>/dev/null
    sleep 2
  fi
fi
if ! ms_find_with_arg '*ssh' "$SSH_TARGET" > /dev/null; then
  export KW_SSH_TARGET="$SSH_TARGET"
  export KW_SSH_PORT="$LOCAL_PORT"
  ms_launch "$CONNECT_LOG" "$DIR" python3 kw-client.py connect
  sleep 5
  if grep -q 'remote port forwarding failed' "$CONNECT_LOG" 2>/dev/null; then
    echo "knockwire: forward bind failed on port $port (stale server session; sentinel retries)"
    exit 1
  fi
  ms_find_with_arg '*ssh' "$SSH_TARGET" > /dev/null || { echo "knockwire: connect did not start (see $CONNECT_LOG)"; exit 1; }
  actions="${actions:+$actions, }connect revived (wss)"
fi

echo "knockwire: ${actions:-already running} (port $port, wss)"
exit 0
