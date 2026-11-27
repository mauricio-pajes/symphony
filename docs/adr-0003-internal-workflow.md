# ADR 0003 · Internal workflow under the existing issue claim

- Accepted for incremental implementation · November 26, 2026

## Context

The initial opt-in extension changes provider when a tracker state changes.
Routine steps such as a validation retry, independent review or read-only
investigation should be possible while the ticket remains in one external state.
Provider workers currently have different access to tracker tooling and their
terminal results do not form a reliable transition contract.

## Decision

Add a small internal phase reducer behind the current dispatch path. The existing
orchestrator retains tracker reconciliation, supervision, claim, retry and cleanup.
The reducer consumes versioned outcomes and emits a next phase, a wait reason or
an effect request. The same Elixir process owns live scheduling. It uses existing
worker supervision to run one phase at a time under the claim. In internal mode,
only an explicit retry outcome with remaining phase budget schedules a failure
retry. The orchestrator applies the backoff. A parked run has no worker slot.
Add parallel readers later and keep the same workspace writer rule.

| Contract | Minimum fields and validation |
| --- | --- |
| Phase request | Run, phase, attempt generation, policy and requirement revision, project, workspace lease, selected execution tuple, deadline, allowed capabilities and artifact refs. |
| Provider outcome | Schema version, typed status, observed session and usage (optional), summary, criterion and artifact claims, findings and blocker code. Results are proposals until validated. |
| Event | Version, run, phase, generation, sequence, timestamp, type and bounded, scoped fields. Engine events record verified progress and decisions. Provider events record observations with provenance. Ignore duplicates and late generations. |
| Checkpoint | Run/phase generation, approved requirements and policy revisions, tracker state, input/output refs and hashes, bound session if resumable, completed criteria, pending effects. Store outside agent-writable directories. |
| Handoff | Scoped working branch or immutable diff, open criteria, relevant decisions and scoped evidence, tests and findings. Preserve the source revisions. Pass only the next phase's required context. |
| Effect request | Scoped issue, action, destination, expected external revision, payload digest, matching actor approval when required and stable idempotency key. Send through the engine's authorized effect path. |

A successful tool exit is not a phase outcome. The engine verifies evidence
against the requested revision and applies the decision. The worker's result
cannot create its own permissions or approvals. Projection to Linear happens at
configured milestones. The originating Jira integration is read-only.

Keep the first slice local and serial, with ephemeral detailed history and
read-only tracker access in internal mode. Legacy writes apply only to legacy
workflow runs. Before dispatching an internal run, persist a minimal admission
and lease record outside the workspace. Bind it to an issue and run ID, daemon
boot ID, attempt generation, workspace identity and an OS process-tree identity
that can be revalidated after a restart. Persist the launch reservation before
starting a worker and confirm its handle before permitting it to write. A crash
between spawn and acknowledgement leaves a pending lease that requires
reconciliation. Persist parked status, retry budgets and the classification
attempt keyed to the requirements revision. Polls cannot redispatch an admitted run that is parked, completed or awaiting
intervention. A Linear comment or incidental revision change cannot rearm it.
On restart, reconcile the tracker and recorded leases before assigning a writer.
If ownership or exit cannot be verified, quarantine that workspace and surface
an intervention. Issue an explicit new run authorization before replacing a
closed run. Reject late events from previous run or boot IDs.

The admission journal uses a bounded, versioned JSON file in a private, separate
state directory. One scheduler owns updates. Each update flushes a temporary file
in that directory, atomically replaces the ledger, and flushes the directory.
Deployment must enforce a single owner across BEAM instances. Reserving an attempt
and attaching its process identity remain separate so a crash between the operations
leaves a record to reconcile. The store consumes proof supplied by a trusted launcher.

Introduce full durable checkpoints and an effect journal before enabling
automated external writes. Evaluate single-host SQLite with WAL when those
records need transactions across checkpoints and effects. Include migrations
and startup reconciliation. Keep phase progress outside the workspace and use
the tracker for eligibility. Recovery checks observed tracker state, approved
requirement hash and workspace revision, current permission and policy.
A changed requirement returns to intake, an inactive ticket remains parked,
and an uncertain worker lease requires proof of exit before any new writer.
Persist the outcome, checkpoint and effect intent atomically. If the engine
crashes after an external action and before acknowledgement, reconcile by
external identifier or stable marker. A destination without safe deduplication
or reliable reconciliation requires human resolution. Correlate the logical
effect across retries using its original key. For transitions without a
conditional API, record observed state before and after execution and surface
any conflict through reconciliation.

## Alternatives and consequences

- **External states as phases** are enough for the first increment. Multiple
  internal steps would otherwise require extra tracker states or hidden loops.
- **A general workflow DSL or external scheduler** supports richer workflows and
  distributed recovery, with extra state owners and a broad compatibility cost.
- **Agents directly own effects** allows faster initial integration. Divergent
  identities and unvalidated retries make approval and deduplication unreliable.

The opt-in seam adds only phase metadata, validated completion and reservation
hooks where they affect dispatch. Upstream mode keeps its settings and behavior.
Maintain disabled-mode and migration compatibility fixtures. Gate activation
on tests for late events, cancellation including descendants, deadline and
stall, reload, terminal transitions, lost acknowledgement and effect replay.
A reload can change future policy decisions. Revocation also applies to active
work and pending effects.

[Design](personal-symphony-design.md) ·
[Roadmap](personal-symphony-roadmap.md) ·
[SQLite WAL](https://sqlite.org/wal.html)
