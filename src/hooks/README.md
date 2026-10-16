# hooks

Scheduler hooks: clocks, not minds. A hook polls a cheap condition on a
short interval and wakes an agent only when a result policy says the
outcome is anomalous. Routine success is silent and, where useful, logged
by the script doing the work — never by waking anyone.

- `gmail-knock.sh` / `slack-knock.sh` — channel wrappers living
  with their pipeline in `../knockpipe/` (the shared consumer
  `knock-consume.sh`, the stages, and their tests); deployed by
  copying them from there. Each wrapper is deployment config
  only: the consumer claims knocks, runs the channel's filter,
  and wakes the thinker only for qualifying messages or a
  failure of the filter itself.
- `ssh-state-ensure.sh` — runs the machine-state converger
  (`../machine-state/ensure.sh`) every minute and applies its results
  policy: silent on healthy and on drift-then-verified minutes; wakes
  once per episode on cannot-converge or converged-but-unverified.
  Locate the deployed ensure.sh via `$MS_ENSURE` (default: this repo's
  checkout path).
- `restart-sentinel.sh` — polls every 20s for a volatile watch file
  (`$MS_WATCH_FILE`, default `/tmp/muse-restart.watch`). Missing
  means the machine restarted and this boot has not run its
  post-restart scripts: the hook makes one pass over the deployment's
  `recycle.d/` via `../machine-state/restart-run.sh` (locate it via
  `$MS_RESTART_RUN`) and creates the watch file only when every
  subscriber passed, retrying each poll while any fail and waking
  once per failure episode.

Install a hook by copying its script into your hooks scripts directory
and enabling it with your hook tooling; the script expects the hook
runtime in `$HATCH_HOOK_RUNTIME` and standard tools (`jq`, `bash`).
