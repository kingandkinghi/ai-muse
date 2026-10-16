#!/usr/bin/env bash
# Run the knockpipe suite (shared machinery). Exit non-zero on any failure.
set -u
cd "$(dirname "$0")"
rc=0
for t in test_knockwatch.py test_lockwatch.py test_consume.py; do
  echo "== $t"
  python3 "$t" || rc=1
done
exit $rc
