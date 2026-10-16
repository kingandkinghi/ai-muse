# knockpipe

The machinery that turns a knock (a pointer: "something
changed") into a judgment-ready report, per channel. The stages
are independent and separately tested; the consumer and wait
stages are shared by every channel, and only the filter stage is
source-specific. Two channels run on it: Gmail (pointer knocks)
and Slack (payload knocks) — see "Channels" below.

Design home: `../../design/event-driven-thinker-dispatch.md` — read its
2026-10-15 amendment for the operating policy (no polling where a
blocked wait exists; the agent quiescent while waiting; mechanical
stages are filters, not agents; at-least-once delivery). This
directory is that policy as running code.

## Stages

A run flows through whichever stages the state requires:

1. **Wait** — `knockwatch.py`. Blocks on inotify over the knock
   queue directory and exits at the first knock (or when its block
   window elapses). Check-then-block: knocks already queued exit it
   immediately, so re-arming can never miss one. No debounce.
2. **Claim** — the consumer renames queued knocks into a claimed
   directory (rename, never delete). Claims are archived only
   after the run that consumed them has reported.
3. **Pull + filter** — the channel's filter program
   (`KP_FILTER_CMD`), the one source-specific stage. Its contract:
   reconcile truth from the source (a stored high-water mark where
   the source offers one — push is latency, pull is truth, so any
   knock, however stale or duplicated, reconciles the same range),
   classify as a pure function, and park the report on disk
   *before* advancing any high-water state.
4. **Report** — the hook script `knock-consume.sh` glues the
   stages inside a scheduler hook: it settles the previous run's
   claim, claims, runs the filter, and ends with exactly one
   `silent` (nothing qualified; no agent runs, no tokens) or
   `wake` (the qualifying items ride in the payload for the
   thinker, or the filter failed and must be loud).

News-vs-echo is deliberately **not** a stage. Whether a delivered
message is news or an echo of an action the user (or the agent)
just took is the thinker's judgment at delivery time, from its
context — not a filter rule and not a pre-populated registry.

## Channels, and where the parameterization lives

Two channels run on this machinery today, sharing the consumer,
the wait stage, and the delivery handshake unchanged. Everything
channel-specific is in exactly two places:

1. **A wrapper script** (deployment config, six exported values):
   queue dir, claimed dir, parked-report path, filter command,
   watch path, label. `gmail-knock.sh` and `slack-knock.sh` are
   nothing but config + `exec knock-consume.sh`.
2. **The filter program** (`KP_FILTER_CMD`), which owns the
   source-specific work: where input comes from, the classify
   rule, dedup, side effects, and the report shape
   (`{"kept": [...], "dropped": {...}}`, parked before printing).

Site values (user IDs, tokens) live in neither: they sit in
config files beside the deployment, read by the filter.

An optional third knob, `KP_TLOCK`, turns on the **thinker
lock** for channels that must never run two thinkers: a wake
creates the lock file just before it emits; while the lock
exists the consumer abstains from claiming (it waits for the
unlock on inotify, via `lockwatch.py`) and the awake thinker
owns the queue — after each batch it lingers on a short
knockwatch fuse and self-serves follow-ups by running its own
wrapper with `KP_SELF=1` (claim + filter, report on stdout, no
runtime emit), removing the lock as its final act. A lock
older than `KP_TLOCK_STALE` (default 900s) is a dead thinker's
and is reclaimed loudly. Exactly one creator (the consumer,
at the wake) and one remover (the thinker it launched) per
epoch — no refcount, no race. Channels whose thinkers may work
in parallel leave the knob unset and none of this exists.

Worked channels in production deployments include a mail channel
(pointer knocks from a demux; the filter reconciles against the
provider API from a high-water mark and classifies on the
provider's placement labels) and a chat channel (payload knocks
written by a socket transport; the filter dedups on event id
against a persistent seen set and classifies on addressing — a
mention, or a direct message as implicit addressing — with a
reaction-ack protocol layered on the report step). Those filters
encode one household's policy and live in its private instance
repo; this repo carries the shared machinery and the contract
they satisfy.

## Channel docs

Every channel has one standing doc, always named `CHANNEL.md`,
living in the channel's deployment home beside its state. It is
the thinker's **first consult**: each channel's hook prompt
carries one standard line naming its CHANNEL.md, and the doc
holds the channel's standing context — what the channel is,
who the human is, local policy, and pointers to logs and
deeper documents. Policy consolidates there over time rather
than accumulating in prompt text.

This README is the general doc: it ships in the shared repo as
the default, and it points off to the user-specific path —
`<channel home>/CHANNEL.md` — where a deployment's own facts
live. A muse that forks the repo accepts the convention as-is
and writes its own CHANNEL.md instances; a deployment may
overwrite or augment freely. What must not happen is two
standing docs for one channel: when a channel already has a
document serving this role under another name, the CHANNEL.md
points to it (or absorbs it) — never duplicates it.

Situational context (recent history, what was already said)
is deliberately not in either doc: it stays in the channel's
logs, reached through the CHANNEL.md pointers when a thread
needs more than the payload carries.

## The one runtime fact that shapes the glue

In the hook runtime, `silent` / `wake` **emit and exit** — no
statement after them runs. Cleanup placed after an emit is dead
code, and state it was meant to clear re-triggers the next run
(this bug looped the live channel for ~20 minutes before it was
caught). So delivery is a two-run handshake:

- a run about to emit a pull's report first drops a marker file
  beside the parked report, then emits;
- the next run settles first: claim + marker = already reported,
  so archive the claim, remove report + marker, and *continue* to
  the wait; claim + no marker = predecessor died before
  reporting, re-issue (worst case: one duplicate); claim + no
  parked report = the pull never finished, run the filter over
  the un-advanced range.

The only loss window is a death between the marker write and the
emit — two adjacent statements. A slower independent sweep (a
daily inbox digest) is the backstop behind it.

## Deployment

Canonical source is this directory. Deploy by copying:

- `knock-consume.sh` + the channel's wrapper → the hooks scripts
  directory; enable the wrapper as a hook with a 5s poll
  interval and a 600s script timeout (the script blocks up to
  ~540s inside a run; the scheduler re-arms it).
- The channel's filter + `knockwatch.py` → beside the channel's
  own state (Gmail: `~/workspace/gmail/`; Slack: the relay dir).

Site values stay out of this repo: paths derive from `$HOME`,
and credentials and IDs live beside the deployment (`.tokens`,
`watch.env`; mode 600), never in code.

Caution: replacing a hook script's file while a run is blocked
inside it corrupts that run (the shell reads its script lazily;
the process continues into the new, shorter file and exits
without emitting). The design tolerates it — the knock stays
queued and the next run reconciles — but expect one failed run
in the log per mid-flight swap. Proven live 2026-10-15.

## Tests

    tests/run_all.sh

- `test_knockwatch.py` — pending / event / timeout behavior
  against a throwaway HOME, including the queue-dir argument.
- `test_consume.py` — the claim/settle/report state machine
  against stub deployments, run under BOTH channel configs to
  prove the consumer is channel-blind. Its stub runtime's emit
  **exits**, matching the real runtime on purpose: a stub whose
  emit returns is how the recovery-loop bug passed its first
  tests.

Filter-stage tests live with the filters, in the instance repos
that own them; what is tested here is the shared machinery and
the contract a filter must satisfy.
