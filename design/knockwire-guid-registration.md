# GUID certs in certmint — FINAL model (2026-10-15, Chris's design)

Supersedes this folder's earlier drafts (`guid-addressing-model-draft-2026-10-15.md`
and the first version of this file). The design is filed in the
ai-certmint repo as **GUID.md**, with API.md and LIFECYCLE.md updated
to match, and is **built** (cm-web.py + cm-client.py) — local
end-to-end tests pass (24/24 plus a client pass); deployment and the
live positive test follow the repo push.

**STATUS 2026-10-15 19:45 HST: the knockwire registration system
below is also BUILT and DEPLOYED** (kw-web.py v2 + kw-authkeys +
sshd drop-in on the KNOCKWIRE VM; as-built doc: REGISTRATION.md in
this folder). Local suite 21/21 against a test mint; on the VM, a
staged loop (hand-inserted probe record) proved AuthorizedKeysCommand
auth, the port forward, and a public path-only knock end to end,
and flipping the probe serial to a revoked one proved
revocation-on-connection. The one unproven step is registration
with a real guid cert — it awaits a fresh identity cert from
Chris's next login, exactly as certmint's did.

## The model as settled

- **One service, not two.** Certmint mints guid certs; the association
  function (working name *certlink*, hence certlink.ai) is a second
  cert class inside certmint, not a separate registrar.
- **Certmint generates the GUID** (32 random bytes), hashes it, mints
  a cert binding the hash to a key fingerprint, hands the raw GUID to
  the muse **once**, and retains nothing of it. Uniqueness is by
  generation: the mint only ever signs hashes of GUIDs it generated
  itself, so a signed guid cert attests the GUID is **unique and not
  copied from elsewhere**. There is **no registry and no burned set** —
  the hash in the certs is the whole of the server's knowledge. The
  system is stateless w.r.t. GUIDs.
- **Security does not derive from the GUID.** It is an address, not a
  credential. A knock delivers a pointer; authority is cert
  possession. Knocks for a GUID are delivered only to its holder —
  whoever proved possession of a live guid cert for it.
- **Peers, not a chain.** Every guid cert for a GUID is independent;
  any one live cert can renew the GUID or authorize a new
  fingerprint. Staggered expiries are the resilience mechanism; the
  GUID strands only if *all* peers lapse or all keys are lost.
- **Three verbs**, all possession-gated with single-use challenges:
  *issue new* (authorizer: a valid id cert — the only step needing
  one), *renew* (authorizer: a live guid cert; same key, fresh
  peer), *issue another* (authorizer: a live guid cert; binds the
  hash to a new key — the caller must prove possession of **both**
  the authorizing key and the new key). Invariant: the mint never
  signs a binding to a fingerprint the caller hasn't just proven
  they hold.
- **Trust-boundary flag: ruled on by Chris (Oct 15 17:45).**
  Certmint transiently sees the raw GUID at generation and tosses
  it; Chris accepts this — the GUID is not the security foundation,
  and post-issuance a hacked mint holds only hashes and certs,
  nothing knockable or impersonable.

## Amendment — Oct 15 20:06 HST (Chris)

Guid **issue-another is dropped** from certmint: no operation binds
a GUID to a second key, and there is no reissue path via another id
cert. The guid verbs are **issue** and **renew**, full stop — one
key per GUID for its whole life. Rationale: knockwire authenticates
with the guid cert itself, so extra key edges were surface without
a need. (The both-keys possession machinery built for it on
2026-10-15 was removed from cm-web.py/cm-client.py the same
evening; GUID.md records the change.)

## Knockwire registration — settled Oct 15 18:49–19:08 HST (Chris's design)

- **REST registration is the control plane.** Anyone can POST
  `{guid, guid cert}` — no accounts — but every cert presented is
  **verified owned**: knockwire checks the mint signature, expiry,
  /revoked, `hash(guid) == guid-hash:`, and a possession signature
  from the cert's key (challenge, as at certmint). Registration
  provisions a port and writes one `authorized_keys` line for the
  service account: the cert's key, restricted to exactly that
  forward (`restrict, port-forwarding, permitlisten`). The muse then
  opens its long SSH connection with that key; sshd enforces
  key ↔ port. The public address is the GUID in the webhook URL;
  the port is internal plumbing and may change across
  registrations.
- **Two reapers, two clocks (both 24h to start).** Culling
  *authorized certs* (the lease: `authorized_keys` line + route)
  runs on time since last register; collecting *unused ports* runs
  on time since a port last held a live forward. They are separate
  mechanisms — the gap between a culled lease and a collected port
  is the guard band that keeps a port from being reissued while a
  zombie forward might still hold it.
- **Register while alive returns the same port** (and refreshes the
  lease). A lapsed lease re-registers fresh: new port, new
  connection. Reconnect *is* re-register + reconnect; there is no
  in-band renewal — fresh peer certs are presented at registration.
- **The knock is path-only.** Knockwire strips the webhook's body,
  query, and fragment; the POST delivered to the muse carries just
  the URL path (the service segment). One datum: which service
  knocked. The muse pulls the truth itself (push = latency,
  pull = truth).
- Open residuals for the operator to rule: knocks to an unregistered or
  unconnected GUID are dropped, never queued (lossy by design);
  a takeover registration by a different peer key must drop the old
  SSH session or the new key cannot bind the returned port;
  a cert revoked mid-lease rides out the ≤24h lease (bounded by
  design, re-checked at every register).

## Rulings — Oct 15 19:13 HST (Chris)

- **Knocks to an unregistered/unconnected GUID: dropped.** Settled.
- **Takeover: blocked, not forced.** Knockwire never kills a live
  connection. A registration whose port is in use is blocked until
  the port frees; contention resolves by waiting.
- **Lease expiry alone does not kill the connection** (deleting an
  auth line never drops an established sshd session) — so the
  culler tears down actively, **in reverse order** (Chris, 19:19):
  **kill the connection first, then strip the port from the auth
  file.** (Setup runs provision → authorize → connect; teardown
  unwinds it.) Contention still never kills — only expiry does.
  The teardown sequence need not be atomic for v1; the known wart
  is a cull racing a same-GUID re-register, whose worst case is a
  spurious reconnect the muse self-heals. Because a connection can
  briefly outlive its lease record, **port allocation consults
  actual use, not just the registration table**: a port is
  allocatable only when no live lease holds it AND nothing is
  actually bound to it. Corollary: a GUID re-registering after its
  lease lapsed can re-adopt the port its own still-live connection
  holds.
- **One lock.** Registrations race to update the authorized-keys
  state; read-modify-write happens under a single lock (with atomic
  replace, as in certmint's state file).
- **Revocation is checked on connection AND on registration.** A
  cert revoked after registering cannot (re)connect; mechanically
  this points at `AuthorizedKeysCommand` (or an equivalent
  connect-time hook) rather than a purely static file. An already
  open connection is not re-checked until it reconnects — the bound
  is the reconnect cadence plus the 24h lease cull.
