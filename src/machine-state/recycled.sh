#!/bin/bash
# recycled.sh — DEPRECATED (2026-10-16). Boot-id detection is retired.
#
# This script used to compare the kernel boot id with a recorded one
# on every ensure.sh run, log recycles, and dispatch the recycle.d/
# subscribers (with a pending-event retry owned by ensure.sh). That
# model is replaced by the restart-sentinel hook (see ../hooks/):
# a volatile watch file detects the restart, restart-run.sh makes
# the subscriber pass, and the sentinel's next poll is the retry.
# Detection, pending state, and the dispatch grace are all gone.
#
# The file remains as a compatibility shim because deployed copies
# of the old ensure.sh call it: with no arguments it is a silent
# no-op. With --dispatch it makes ONE post-restart pass via
# restart-run.sh, for manual use and for any old pending-event flow
# that still asks. Nothing here detects anything, keeps state, or
# logs a recycle.
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--dispatch" ]; then
  exec "$BASE/restart-run.sh"
fi
exit 0
