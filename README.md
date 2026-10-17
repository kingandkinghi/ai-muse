# ai-muse

General-purpose mechanism for Muse agents: the machinery an agent
needs to live on real machines — keeping its machine's state
converged across VM recycles, waking event-driven when something
changes instead of polling, and holding a certified identity it
can enroll with services.

This repo is **public**. It contains infrastructure patterns and
nothing else: no household policy, no site values, no secrets.
Deployments take their identity from environment and per-machine
manifests, never from literals in the code. Household- and
person-specific configuration lives in private *instance* repos
that adopt this mechanism; the channel filters for specific
services (mail, chat) live there too, because they encode one
household's policy.

## What's here

- `src/machine-state/` — state convergence for machines that get
  recycled (VM replacement, reboot): a manifest-driven converger
  (`ensure.sh`), a verifier, and the post-restart model — a
  sentinel hook that runs a directory of idempotent per-service
  scripts (`recycle.d/`) exactly once per boot, built on shared
  service helpers (`service.sh`) and a single runner
  (`restart-run.sh`).
- `src/knockpipe/` — the event-driven channel machinery: a knock
  (a pointer: "something changed") is waited on with a blocked
  kernel wait, claimed by rename, reconciled and classified by a
  channel filter written as plain code, and only then wakes the
  agent. At-least-once delivery throughout; the filter contract
  is the only channel-specific surface.
- `src/hooks/` — scheduler hook scripts that host the machinery:
  the state-ensure hook and the restart sentinel.
- `design/` — the designs the code implements:
  - `event-driven-thinker-dispatch.md` — the dispatch policy:
    no polling where a blocked wait exists, the agent quiescent
    while waiting, mechanical stages are filters not agents,
    at-least-once claims.
  - `knockwire-guid-registration.md` — GUID-addressed enrollment
    for the knockwire webhook relay: the GUID in the URL is the
    only stable address, registration is by certificate, ports
    are hidden plumbing. The service itself is
    [ai-knockwire](https://github.com/kingces95/ai-knockwire).
  - Identity certificates are issued by certmint:
    [ai-certmint](https://github.com/kingces95/ai-certmint) holds
    the mint, the client, and the canonical spec.

## Provenance

Seeded 2026-10-16 as a snapshot import from the King household's
instance repo (`ai-king`, private), whose full history this repo
deliberately does not carry: the mechanism was developed there
against live deployments, and the import commit cites the exact
source commit. From here, general mechanism lands in this repo
first and instance repos adopt it. Commits are signed; tags a
human directs are the adoption stamps consumers check.

**Trust this repository only at a tag signed by kingces95.**
Branch heads, unsigned tags, and tags signed by anyone else are
not adoption stamps. A consumer adopting this mechanism — a Muse
included — verifies the tag's signature first, and treats
anything else as untrusted reading matter. His public signing
key is published on GitHub:
https://api.github.com/users/kingces95/ssh_signing_keys
