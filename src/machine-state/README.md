# machine-state — maintain machine state

Keep a periodically recycled machine's declared client state converged to
per-machine masters, automatically, and keep a factual log of the recycles
themselves.

For machines that are periodically recycled without notice, where
everything outside the persistent home is rebuilt from scratch: the state
that makes the machine *itself* — trust anchors, client configuration,
signing configuration, runtime packages — must reappear without a human
noticing the gap.

## Principles

- Masters are policy; live files are cache. Edit masters, never live files.
- Convergence is declarative and idempotent: a manifest states the desired
  end state; a dumb converger runs as often as a scheduler allows and makes
  reality match. It does not decide, infer, or repair beyond the manifest.
- Proof is separate from state. A verifier checks that converged state is
  actually in force; it runs on drift and on demand, not on a timer.
- Results policy:
  - No drift → silence.
  - Drift → converged → verified → one line in the log, silence.
  - Converged but verification fails → wake an agent.
  - Cannot converge (a master or the manifest is broken) → wake an agent
    immediately; a human fixes policy, the converger does not improvise.
  - Escalation is once per episode, not once per run.
- Recycles are weather: record them (one log line per boot change) so
  their frequency can be reviewed later. Recording never wakes anyone.

## The shape

- `ensure.sh` — the converger. Reads a per-machine manifest (below) and
  makes the machine match it: directories, files (content + mode), git
  system keys, package presence. Exit codes: 0 converged,
  2 cannot converge, 3 converged but verification failed,
  4 check-mode drift. `--check` reports without writing anything.
- `verify.sh` — the proof. Runs `ensure.sh --check`, then every executable
  in `verify.d/` (site-authored checks: config resolutions, fingerprints,
  probes). Read-only.
- `restore.sh` — the hand-run composition (ensure + verify) for
  development: edit masters, run it, watch the proof.
- `restart-run.sh` — one post-restart pass over the **recycle.d/**
  hook directory: every executable in it runs, in name order, each
  under a timeout (default 30s, `MS_SUBSCRIBER_TIMEOUT`), with the
  event in its environment (`MS_EVENT`, `MS_NEW_BOOT`, `MS_BOOT_ISO`,
  `MS_DETECTED_ISO`; `MS_PREV_BOOT` is always empty — nothing tracks
  the previous boot). Subscribers are how things that *die* in a
  recycle (detached services, listeners) get restarted: each checks
  its own state and acts only if it is actually missing. Every run
  is appended to `events.log` with name and exit code, and results
  go to stdout as TSV. A failing or hung subscriber never blocks
  the others. On a restart pass where everything passed, one line
  is appended to `recycles.log` — the weather record survives the
  detector that used to write it. (Unix has no general hook
  primitive for this; the convention reinvented here is the hook
  directory — run-parts, as with git hooks and `verify.d/` above —
  plus an append-only event log.)
- `service.sh` — the shared subscriber helpers, sourced by
  subscribers: liveness finders that match argv **in position**
  (never a bare `pgrep -f`, which also matches ancestor shells whose
  command strings merely mention the service), a pidfile companion
  check, a listener check, and a detached launcher. Subscribers
  declare their specifics; the moves live here once.
- Detection is the **restart-sentinel hook** (see `../hooks/`), not
  a boot-id diff: a watch file in /tmp cannot survive a recycle, so
  its absence means "this boot has not completed its post-restart
  run." The sentinel makes one pass via `restart-run.sh` and
  creates the watch file only when every subscriber passed; while
  any fail, the next poll (20s) retries — which also covers
  subscribers that depend on state the manifest installs, since
  convergence runs on its own minute clock. A failure episode
  wakes an agent once. Premise: /tmp is rebuilt per boot on the
  target machines (verified across repeated recycles); where /tmp
  persists across reboots, this detection cannot work.
- `recycled.sh` — DEPRECATED shim kept for deployed copies of the
  old ensure.sh that still call it: a silent no-op, or one manual
  pass with `--dispatch`. Boot-id detection, pending events, and
  the dispatch grace it used to own are retired.
- Scheduler hooks (see `../hooks/`) run `ensure.sh` every minute
  and the sentinel every 20s, applying their results policies: the
  hooks are clocks, not minds — they wake an agent only on anomaly
  outcomes, once per episode.
- Logs beside the scripts: `ensure.log` (drift incidents),
  `recycles.log` (one line per boot whose post-restart run cleared,
  with boot time), `events.log` (one line per subscriber run).

## Doing it

1. Copy `ensure.sh`, `verify.sh`, `restore.sh`, `restart-run.sh`,
   `service.sh` to the deployment directory on the machine.
   (`recycled.sh` too, if an old ensure.sh copy still calls it —
   it is a deprecated no-op shim.)
2. Copy `examples/machine.env.example` to `machine.env` there; set at
   least `MS_TZ`. Copy `examples/manifest.example` to `manifest.tsv`;
   replace every value with your machine's real entries. Neither file is
   ever committed.
3. Put your masters in `files/` (or point `MS_FILES_DIR` at them), named
   as your manifest's file entries name them.
4. Author your proof in `verify.d/`: one executable per assertion family,
   modeled on `examples/verify.d/`. Author any recycle reactions in
   `recycle.d/`, modeled on `examples/recycle.d/`.
5. Run `./restore.sh`; expect convergence and "Verify OK".
6. Wire the scheduler hooks: `ensure.sh` every minute, and the
   restart-sentinel every 20s (point `$MS_RESTART_RUN` at the
   deployed `restart-run.sh`).

## Configuration

Environment variables (set in `machine.env` or the calling environment):

- `MS_TZ` — timezone for log timestamps. Default `UTC`.
- `MS_MANIFEST` — manifest path. Default `manifest.tsv` beside ensure.sh.
- `MS_FILES_DIR` — masters directory. Default `files/` beside ensure.sh.
- `MS_OWNER`, `MS_GROUP` — owner/group for installs. Default `root`.
- `MS_PIP_FLAGS` — extra pip flags. Default `--break-system-packages`.
- `MS_SUBSCRIBER_TIMEOUT` — per-subscriber timeout for
  `restart-run.sh`, seconds. Default `30`.
- `MS_RESTART_D`, `MS_EVENT_LOG`, `MS_BOOTLOG` — override the
  subscriber directory and the runner's two logs. Defaults: beside
  `restart-run.sh`.

Manifest entries (whitespace-separated, `#` comments allowed):

- `dir <path> <mode>`
- `file <master> <target> <mode>`
- `gitkey <key> <value>`
- `pip <package-spec> [<module>]`

## Constraints

- No secrets are ever restored by this mechanism. It converges the public
  half of an identity — trust anchors, configuration, public keys. Private
  key material lives elsewhere and is provisioned by other means.
- The converger must stay dumb: any behavior beyond the manifest belongs
  in the manifest, the verifier, or an agent — not in ensure.sh.
- The deployment directory and its state files (masters, manifest,
  machine.env, logs, boot state) are per-machine and stay out of the repo;
  the repo carries the scripts and placeholder examples only.

## Completion

A machine is set up when: a full recycle (or a simulated one — delete a
converged file, remove a package) is followed, within one scheduler
interval, by silent convergence and a passing verify; the sentinel
clears the new boot within a poll or two — each `recycle.d/`
subscriber runs, the watch file reappears only when all of them
passed, and `recycles.log` gains exactly one line for the boot; a
broken master wakes an agent exactly once; and a broken subscriber
wakes an agent exactly once per episode while the sentinel keeps
retrying it every poll.
