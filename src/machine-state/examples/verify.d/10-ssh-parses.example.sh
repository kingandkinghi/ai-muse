#!/bin/bash
# Example site check for verify.d/: the converged SSH client config must
# resolve a chosen host with an identity file set.
#
# To use: copy into verify.d/ beside verify.sh, drop the ".example" from
# the name, make it executable, and set MS_VERIFY_SSH_HOST in machine.env
# to a host your client config is supposed to resolve. Checks receive the
# machine.env MS_* values in their environment.
# Exits 0 (skip) when the variable is unset.
set -u

host="${MS_VERIFY_SSH_HOST:-}"
[ -n "$host" ] || { echo "skip: MS_VERIFY_SSH_HOST unset"; exit 0; }

ssh -G "$host" 2>/dev/null | grep -q '^identityfile ' \
  || { echo "FAIL: no identityfile resolved for $host"; exit 1; }
exit 0
