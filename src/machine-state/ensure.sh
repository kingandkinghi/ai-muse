#!/bin/bash
# ensure.sh — converge this machine's ephemeral client state to per-machine
# masters, as listed in a manifest. State only: file contents, permissions,
# git system keys, and package presence — whatever the manifest names.
# No verification battery (that is verify.sh).
#
# Policy: masters are policy, live files are cache. Idempotent — running it
# any number of times produces the same end state.
#
# Site-specifics arrive as data, never as literals (see the repo README's
# environment strategy):
#   machine.env   optional shell fragment beside this script, sourced when
#                 present; holds this machine's MS_* settings. Never commit.
#   manifest.tsv  what to converge on this machine (format: see the shipped
#                 manifest.example). $MS_MANIFEST overrides the path.
#                 Never commit a real manifest.
#   files/        the masters the manifest names. $MS_FILES_DIR overrides.
#
# Modes:
#   ensure.sh          converge; on drift, run verify.sh once afterwards.
#   ensure.sh --check  report only: no writes of any kind.
#
# Exit codes:
#   0  converged (with or without drift)
#   2  cannot converge (manifest/master missing or unreadable, a step failed)
#   3  converged, but post-drift verification failed
#   4  --check only: drift detected
#
# Drift events are appended to ensure.log beside this script. Quiet
# runs write nothing and print nothing. (Post-restart recovery is
# not this script's job: the restart-sentinel hook runs the
# recycle.d/ subscribers via restart-run.sh.)
set -u

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$BASE/machine.env" ]; then
  set -a; . "$BASE/machine.env"; set +a
fi

SRC_DIR="${MS_FILES_DIR:-$BASE/files}"
MANIFEST="${MS_MANIFEST:-$BASE/manifest.tsv}"
LOG="$BASE/ensure.log"
VERIFY="$BASE/verify.sh"
OWNER="${MS_OWNER:-root}"
GROUP="${MS_GROUP:-root}"
TZONE="${MS_TZ:-UTC}"
PIP_FLAGS="${MS_PIP_FLAGS:---break-system-packages}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

now_iso() { TZ="$TZONE" date -Iseconds; }

[ -r "$MANIFEST" ] || { echo "ENSURE-FAIL: manifest $MANIFEST missing or unreadable"; exit 2; }

DRIFT=0
CHANGES=""

note_change() { DRIFT=1; CHANGES="$CHANGES $1"; }

# ensure_dir <path> <mode>   (stat %a prints modes without a leading zero)
ensure_dir() {
  local want_mode="${2#0}" cur_mode
  if [ ! -d "$1" ]; then
    [ "$CHECK_ONLY" = "1" ] || install -d -o "$OWNER" -g "$GROUP" -m "$2" "$1" || return 1
    note_change "dir:$1"
    return 0
  fi
  cur_mode="$(stat -c '%a' "$1")"
  if [ "$cur_mode" != "$want_mode" ]; then
    [ "$CHECK_ONLY" = "1" ] || chmod "$2" "$1" || return 1
    note_change "dir-mode:$1"
  fi
  return 0
}

# ensure_file <master> <target> <mode>
ensure_file() {
  local src="$SRC_DIR/$1" dst="$2" mode="$3" cur_mode
  if [ ! -r "$src" ]; then
    echo "ENSURE-FAIL: master $1 missing or unreadable"
    exit 2
  fi
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    if [ "$CHECK_ONLY" = "0" ]; then
      install -o "$OWNER" -g "$GROUP" -m "$mode" "$src" "$dst" || { echo "ENSURE-FAIL: install $dst"; exit 2; }
    fi
    note_change "$dst"
    return 0
  fi
  cur_mode="$(stat -c '%a' "$dst")"
  if [ "$cur_mode" != "${mode#0}" ]; then
    if [ "$CHECK_ONLY" = "0" ]; then
      chmod "$mode" "$dst" || { echo "ENSURE-FAIL: chmod $dst"; exit 2; }
    fi
    note_change "mode:$dst"
  fi
  return 0
}

# Manifest: one entry per line, whitespace-separated; blank lines and
# #-comments are ignored.
#   dir    <path> <mode>
#   file   <master> <target> <mode>
#   gitkey <key> <value>                 (git config --system)
#   pip    <package-spec> [<module>]     (module guessed from the spec when
#                                         omitted: name up to the first
#                                         version character, '-' becomes '_')
while read -r kind a b c || [ -n "$kind" ]; do
  case "$kind" in
    ''|'#'*) continue ;;
    dir)
      ensure_dir "$a" "$b" || { echo "ENSURE-FAIL: dir $a"; exit 2; }
      ;;
    file)
      ensure_file "$a" "$b" "$c"
      ;;
    gitkey)
      cur_git="$(git config --system --get "$a" 2>/dev/null || true)"
      if [ "$cur_git" != "$b" ]; then
        if [ "$CHECK_ONLY" = "0" ]; then
          git config --system "$a" "$b" || { echo "ENSURE-FAIL: git config $a"; exit 2; }
        fi
        note_change "git:$a"
      fi
      ;;
    pip)
      mod="$b"
      if [ -z "$mod" ]; then
        mod="$(printf '%s' "$a" | sed -e 's/[<>=!~;\[ ].*//' -e 's/-/_/g')"
      fi
      # Word splitting of $PIP_FLAGS is intended: it may hold several flags.
      if ! python3 -c "import $mod" 2>/dev/null; then
        if [ "$CHECK_ONLY" = "0" ]; then
          pip install -q $PIP_FLAGS "$a" \
            || { echo "ENSURE-FAIL: pip install $a"; exit 2; }
          python3 -c "import $mod" 2>/dev/null \
            || { echo "ENSURE-FAIL: import $mod after install"; exit 2; }
        fi
        note_change "pip:$a"
      fi
      ;;
    *)
      echo "ENSURE-FAIL: unknown manifest entry kind: $kind"
      exit 2
      ;;
  esac
done < "$MANIFEST"

# --- Results policy ---
if [ "$CHECK_ONLY" = "1" ]; then
  if [ "$DRIFT" = "1" ]; then
    echo "DRIFT:$CHANGES"
    exit 4
  fi
  exit 0
fi

if [ "$DRIFT" = "1" ]; then
  ts="$(now_iso)"
  if [ -x "$VERIFY" ]; then
    if "$VERIFY" >/dev/null 2>&1; then
      echo "$ts converged:$CHANGES — verify PASS" >> "$LOG"
      echo "converged:$CHANGES — verify PASS"
      exit 0
    else
      echo "$ts converged:$CHANGES — verify FAIL" >> "$LOG"
      echo "ENSURE-FAIL: converged ($CHANGES ) but verify failed"
      exit 3
    fi
  fi
  echo "$ts converged:$CHANGES — no verify.sh" >> "$LOG"
  echo "converged:$CHANGES — no verify.sh"
  exit 0
fi

exit 0
