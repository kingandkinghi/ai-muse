# Event-driven thinker dispatch (design note)

Status: design only, nothing built. This pins a direction explored while
tuning a chat relay's response latency.

## The primitive we have

The platform's only agent-launch mechanism is a subscription with this
shape:

- Every `period`, run a check (normal code).
- The check is hard-bounded by a maximum runtime.
- The check is stateless. Its memory is external state (files) that it
  reads at the start of a run and writes at the end, so its real
  signature is `check(state) -> verdict + new state`.
- On a positive verdict, exactly one thinker is spawned, open-loop: the
  thinker's result never returns to the check. Loops are closed through
  state files, by convention, not by the primitive.
- The check can end its own subscription, so one-shots are expressible:
  watch for X, fire once, vanish.

Latency to anything is therefore bounded by the period. The trigger is
a metronome impersonating an event.

## The gap

We want low-latency response to external events: a chat message, an
email arrival, a calendar or board update, an iMessage relayed by a
companion machine. No platform primitive launches a thinker on an
external event — plausibly by policy: an inbound trigger is a control
surface into an agent that can act, and an uncontrolled one is an
abuse vector. The controlled version has to be built on top of the
primitive.

## The rebuild

Replace the tick with a subscription. Everything downstream of the
trigger survives unchanged: filter, conditional spawn, open loop,
state in files.

### Source clients

One small normal-code client per event source. Each holds a persistent
connection to its source and appends arrivals to a shared queue.
Connections are initiated outbound and authenticated by the client —
the chat socket-mode pattern: no inbound ports, no listener on the
agent host. Webhook-only sources terminate at a public endpoint that
already exists for other reasons, and forward inward.

### The queue holds pointers, not payloads

An entry names a stream and a position (a watermark), not message
bodies. Thinkers load the stream's history themselves when they run.

### Dispatch coalesces

The pool dispatches on watermark advance, not per event. A burst of
events in one stream inside the drain window becomes one thinker whose
context is the whole backlog. One thinker per event is the failure
mode this design exists to avoid: thinking is the expensive unit, so
the dispatch granularity is the stream, not the event.

### The pool

A bounded set of interchangeable thinkers running one identical entry
point. Claims are taken under a lock with a visibility timeout: a
claim that is not completed in time becomes claimable again. Streams
that require ordering are keyed, so one stream is drained by one
thinker at a time. Today's single-stream relays are this pool with
n = 1.

### The filter moves into the event path

The hook's check is a pull predicate over state, run every period
whether or not anything happened. Here the filter is a push predicate
over the event itself, applied in the client or at enqueue time, and it
stays cheap: is this our stream, is it a duplicate, is it
machine-generated. Anything requiring judgment is the thinker's job.

### The metronome demotes to watchdog

Persistent connections fail silently: half-open sockets, expiring
subscriptions, host replacement. A period-and-check job with no
thinker attached watches connection liveness, renews subscriptions,
restarts clients, and runs a slow backstop poll for sources that
cannot push. The clock stops being the trigger and becomes the
liveness proof.

## Trust shape

- No inbound listeners on the agent host.
- Every event channel is a connection the client opened and
  authenticated.
- The filter is the policy gate on that surface.
- Dispatch is bounded: pool size, per-stream keys, visibility timeout.

## Open questions

- Lease variant: a woken thinker that stays resident through a
  conversation, blocking on the event source itself, reaped on idle.
  Unproven whether a worker turn can persist across repeated long
  blocking waits.
- Subscription lifecycle (expiry, renewal, re-authentication) is
  source-specific and belongs in the clients, not the pool.
- Claim state must live in files like everything else, so a host
  replacement is a restart, not a loss.

## Amendments — decisions settled after the pin (2026-10-13)

### Queue substrate: the filesystem

The queue is a directory per stream, in the maildir pattern:

- Producers enqueue by writing a temp file and renaming it into the
  queue. Delivery is atomic, concurrent producers cannot corrupt each
  other, and the filename carries ordering (timestamp + pid + counter).
- A claim is a rename within the directory. An event being processed
  stays visible, so a crashed thinker leaves recoverable state, not a
  hole.
- The thinker assignment is a single small file naming the current
  owner, mutated only under a file lock (`flock`). A handler that finds
  the slot empty requests activation and waits. The wait is a
  filesystem watch (`inotify`) on the queue directory, so new arrivals
  and assignment itself are both wakeup events at zero CPU.
- Staleness is mtime: claims older than the visibility timeout, and
  owner files whose process is gone, are reclaimed by the watchdog.

A thinker does not claim a snapshot. It owns the queue for its
lifetime: drain, wait for a quiet interval, drain again, and only then
unassign. Everything that arrives while it is alive lands in a
directory it is already watching, so the watermark-staleness problem
(a claim going stale mid-processing) does not arise. SQLite is the
runner-up for when claims become genuinely contended. A FIFO is the
wrong shape: a byte stream, no inspectable backlog, no redelivery. A
broker with consumer groups is the graduation path, at the cost of
running a server.

### Catch-up: high-water reconciliation

Event delivery is the latency path, never the truth path. On every
start and every reconnect, a source client diffs the service against
its stored high-water mark and injects the delta as one synthetic
event. Clients may therefore be lossy and replaceable. An
acknowledgement reaction means "accepted into the queue," not
"understood." A thinker that is unsure it has full context pulls from
the source itself, with its own credentials. (The policy for when to
pull is deliberately left open.)

### Two connection types

- **Dial the service.** Where a service offers a client-held
  connection (the chat socket-mode pattern), the client dials out,
  holds it, and enqueues arrivals. No relay is involved.
- **Dial the relay.** Webhook-only services cannot be dialed; they
  call out and expect a public URL. A relay node terminates the
  webhook (a Tailscale Funnel is one way to give the node that public
  face) and proxies it to a loopback port that exists only because a
  muse is holding it open with a reverse SSH forward (`ssh -R`, kept
  alive by autossh, authenticated by the existing certificate
  infrastructure). The bytes travel down the connection the muse
  opened, into her local socket and queue. The forward listener binds
  loopback only, so the port is never on the relay node's external
  interfaces. No third-party relay service is needed once sshd and
  certificates exist.

### Webhooks are hints, never trusted input

No authentication is performed on the push path: no signature
verification, no caller checks. This is safe because nothing downstream
trusts a webhook. It can only cause a wake, and truth enters on the
thinker's pull from the source, made with the muse's own credentials.
A forged or replayed hint costs at most a spurious wake and a pull
that contradicts it, a cost bounded by the pool size and by
coalescing.

### Port assignment is configuration

Reverse-forward ports are assigned statically, one per muse per
service, because webhook registrations and relay configuration are
static (the dynamic allocation mode, `-R 0`, is the wrong tool here).
The assignment table is a master file converged onto the node like the
rest of the machine state, and sshd can enforce it, restricting each
identity to its assigned listen ports. Whether each muse edits the
table herself or it is locked down and changed through a mediator is a
permissions decision on that file, not an architectural one.

### What this settles from the open questions

- Claim state lives in the queue directories: a host replacement is a
  restart, not a loss.
- Still open: the lease variant's feasibility, and the when-to-pull
  policy.

## Amendment — payload trust on the muse side (2026-10-13)

Whether an event's payload may reach the thinker is a property of the
channel it arrived on, decided by the client code, never by the
thinker:

- **Authenticated channel** (the muse dialed the service and holds the
  connection, e.g. chat socket mode): the payload travels with the
  event. The thinker may begin work on it immediately.
- **Unauthenticated channel** (webhook relayed over a reverse SSH
  forward): the client strips all data before enqueueing. The entry
  is a pure pointer: the stream's identity and the fact of change,
  nothing else. Metadata is data, so no subject lines or summaries
  survive either. The thinker is thereby forced to pull.

The thinker's contract is uniform: work with what you are handed, and
if you were handed nothing, pull. It never asks whether a message was
authenticated, because by the time an event reaches it, that question
has been answered structurally.

### High-water, pulls, and the one case neither is needed

High-water advances in exactly two ways:

- **By pull.** A pull reconciles the stream against the source with
  the muse's own credentials and sets high-water to what it verified.
  Bootstrap (first contact with a stream) is always a pull, and so is
  every reconnect: a broken connection is a broken continuity,
  repaired by the synthetic catch-up event described earlier.
- **By payload, under continuity.** On an authenticated channel, if
  the client has received every message since the current high-water —
  delivery is gap-free — each delivered message carries all new
  state, and high-water advances with it. No pull is needed: the
  channel itself performed the state transfer.

Optimistic thinking is safe under this rule because state, not
thought, is what high-water protects. A thinker that starts on a
payload speculates. If a later pull contradicts the payload, the
thought is discarded and no state has moved. On the stripped channel
there is nothing to speculate with, so the pull sits on the critical
path and thinking starts when it lands.

This refines the catch-up section: pulls are mandatory at bootstrap
and at continuity breaks, and optional at all other times (thinker
discretion, for context the stream does not carry).

## Amendment — the channel registry: worked example and policy (2026-10-13)

### Worked example: one front end, five channels

One relay node runs one funnel on port 443 under its single ts.net
hostname. Its serve config maps paths to backends:

| Path | Backend | Kind |
| --- | --- | --- |
| `/chris/trello` | `127.0.0.1`, port A | tunnel |
| `/sam/trello` | `127.0.0.1`, port B | tunnel |
| `/chris/gmail` | `127.0.0.1`, port C | tunnel |
| `/sam/gmail` | `127.0.0.1`, port D | tunnel |
| `/home/rachio` | `home.example.net`, Home Assistant's webhook port | named host |

Ports A–D are the sshd reservations from the registry. Each exists
only while the owning muse's autossh reverse tunnel is up, and each
muse may claim only her own (sshd enforces this per identity).

The last row shows the second backend kind. Home Assistant already
listens on the house network, so its backend is a named host, not a
tunnel. The relay node resolves the name with its own hosts/DNS view
of the house network. Senders register the node's ts.net URL with
the channel path; the house name appears only inside the house.

### General policy

- A channel is one row in a registry: destination, service, path,
  backend. The path is `/<destination>/<service>`, so rows group by
  owner and the owner is the revocation unit.
- The registry is the only table. It renders three times: the relay
  node's serve config (paths to backends), the sshd reservations
  (tunnel ports and per-identity listen permissions), and the node's
  hosts view (names for named backends, and a per-muse name for
  loopback endpoints — e.g. `agent.muse.example.net` resolving
  to `127.0.0.1` on the node, so on-node configuration and tooling
  can address a muse's ingress as name:port, the port selecting the
  service).
- Backends are of two kinds: a loopback port a muse holds open with
  a reverse tunnel, or a named host that listens for itself. The
  registry records which; the serve config treats them alike.
- The hosts view is load-bearing, not cosmetic: the relay resolves
  named backends through its own hosts file, so the render writes
  those entries rather than assuming them. A tunnel backend
  addressed by name needs the name mapped to `127.0.0.1`
  specifically. An OS installer's default entry maps the node's own
  hostname to `127.0.1.1`, where a loopback-bound reverse tunnel
  does not listen — a name that resolves is not necessarily a name
  that reaches the backend.
- A backend name is a resolution view only. The proxy preserves the
  request's original Host header, so the name appears in the node's
  configuration and administration and never in the requests the
  backend receives.
- The public name is fixed by the funnel certificate: senders always
  use the node's ts.net hostname. House names are the inside view
  only — administration, testing, and logs — and never appear in a
  sender's configuration.
- Channels are administered as units. Adding or removing a row
  re-renders all three layers together; revoking one channel touches
  no other.

## Amendment — rendering the serve config, from live practice (2026-10-13)

- **Exposure is a property of the port, set by the last verb that
  touched it.** Serve and funnel are not separate routers: funnel is
  the exposure flag on a port's serve config. Applying a path with
  the serve verb rewrites the port's config with exposure off, so
  adding one channel's path silently takes every channel on that
  port off the internet. A registry render therefore ends by
  re-applying exposure with the funnel verb, and verification is
  part of the render: the resulting state is read back (exposure on,
  every registry path present) before the render counts as applied.
- **The mount prefix is stripped.** The backend receives the request
  with the channel path removed. It sees `/`, not its public path,
  so a backend cannot learn its channel from the request path: the
  loopback port (or named host) it listens on is its channel
  identity. One backend serves exactly one channel.
- **Relay arrivals carry a marker, not an identity.** The funnel
  injects a marker header (`Tailscale-Funnel-Request`) and no
  identity headers at all. Nothing on the push path says who sent a
  request, and the marker says only that the request crossed the
  funnel. Both facts fit the hint model: the marker is useful for
  logging and debugging, and worthless as evidence.

## Amendment — delivery discipline, from the live Gmail build (2026-10-15)

The first channel built on this design (Gmail over knockwire)
settled the operating rules below. They are stated for any channel
on this pattern, not just that one.

- **No polling unless there is no alternative.** Waits block on
  kernel objects — an inotify watch on the queue directory, a
  socket accept — never on a timer that asks "anything yet?". A
  lease heartbeat and a connection keepalive are protocol
  obligations, not polls; nothing else periodic touches the data
  path.
- **The thinker is quiescent while waiting.** The wait lives in
  infrastructure the runtime owns (in the Gmail build, the polling
  hook's script, which blocks inside its run), never in a process
  the agent owns: an agent-owned waiter holds the conversation
  open and presents the user a busy agent. The hook script's own
  re-arm cycle (a 540s block cap inside a 600s script timeout) is
  the only cadence, and it reaches the agent only on an event.
- **Mechanical stages are filters, not agents.** Detection,
  pulling, and selection are plain code; the hook script runs the
  pull and the selection test itself. Tokens burn in exactly two
  cases: a result qualifies for the thinker (the qualifying items
  ride in the wake payload, already pulled), or the filter itself
  failed — and failure is reported loudly, because a filter that
  dies silently eats notifications.
- **Speed is a requirement, not a tuning knob.** No debounce or
  batching delay in the delivery path unless the user asks.
  Measured on the live channel: ~100ms from the queue write to
  the wake decision.
- **Queue discipline is at-least-once.** A knock is claimed by
  rename, never deleted, and archived only after the run has
  reported (wake or silent). The puller parks its report durably
  *before* advancing the high-water mark. Every consumer run
  begins with recovery: a stale claim plus a parked report means
  a predecessor died mid-report — re-issue the report; a stale
  claim with no parked report means the pull never finished and
  the high-water never moved — re-run the filter over the full
  range. The worst outcome after a mid-flight death is one
  duplicate report, never a lost one. This is cheap precisely
  because pushes are hints and the pull reconciles a range: a
  lost pointer costs nothing, so the discipline only has to
  protect the report, not the knock.

Refinement, same evening (Chris): there is **no expectations
registry**. News-vs-echo is the thinker's judgment at delivery
time, made from the context it already holds — the conversation
and the memory the work itself leaves behind (a purchase, a
login, a booking is recorded when it happens, as ordinary
bookkeeping). A registry the agent populates in advance would
duplicate that context in brittle string rules, and it would
suppress the most interesting case: the notice that resembles
an expected one but deviates (wrong amount, second charge). The
division stands: the filter is dumb and mechanical (placement,
categories); the thinker judges whether a delivered message is
news. The accepted cost is that an echo still completes one
wake-and-deliver cycle and is then silently set aside; an action
taken entirely outside recorded context may surface once as
news and be corrected by the user.
