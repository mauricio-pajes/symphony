# ADR 0007 · Drive one synthetic Linear issue through the daemon

- Implemented for the synthetic pilot · November 26, 2026

## Context

The local container fixture exercised the reducer and journal in isolation.
The next proof needs the daemon's normal OTP poll and supervision boundary,
a Linear issue with a simulated Jira link, and an observable Human Review
transition, prior to authenticated provider and project-wide dispatch.

## Decision

Use a startup-only `agent.internal_pilot` configuration with one Linear issue
UUID and a Human Review workflow-state UUID. The daemon's existing
orchestrator timer and task supervisor drive the phases. The host freezes
tracker, worker and workspace settings and stops the run if its scope changes.
The pilot owns one journal under that orchestrator. Its workspace name uses
a namespace outside the legacy workspace identifier sanitizer.

The tracker reader filters by project and issue UUID and requires the target
state to be named Human Review and belong to the issue's team. Only a Todo
issue with the known fixture Jira link is admitted. The host handles the
simulated read-only Jira response using the existing Jira parser. Fixture
workers run the phase-specific commands in local containers with the
previously established process, filesystem and network boundaries. They
receive neither Linear nor Jira credentials. Before accepting a worker
result, the host rechecks the issue and verifies the output after drain.

Record `review_pending` in the existing admission journal after the last
verified phase. Re-read the source before attempting a single scoped
`issueUpdate`. A subsequent read that observes the configured Human Review
state records `human_review`. If the daemon reopens a pending record, it
only reads the issue to settle the observation. It does not send the
mutation again. Linear's update does not provide a conditional state change
in this fixture, so the re-read limits the race window but cannot eliminate it.

Startup attempts recovery of a durable worker lease even if the tracker is
unavailable. A changed state, changed ticket, lost worker, or failed drain
prevents further phase dispatch. Use a dedicated workspace and retain the
original scope to reconcile leases before moving the pilot configuration.

## Alternatives and consequences

- **An outer process polls Linear and calls the reducer.** This would leave
  task lifetime and scope outside the daemon and split the scheduler owner.
- **Enable internal phases for every tracker issue.** That requires
  authenticated worker boundaries, repository admission policy, and a
  broader external effects journal. The single synthetic item proves the
  seam while keeping those dependencies explicit.
- **Automatically retry an unconfirmed review transition.** This could
  repeat an applied effect or overwrite a later external edit. The pilot
  parks before attempting the transition and reconciles by reading.

The daemon integration fixture starts the built escript against a loopback
Linear GraphQL simulation and a real local Docker Engine. It checks normal
Human Review, an applied update with a lost acknowledgement, an unapplied
update with a lost acknowledgement, a source issue edit, and an active
lease recovered after forcibly terminating the daemon. Reopening the
journal across process restarts proves that no phase or mutation replays.
A real Linear test project needs a separately configured host credential.

[Linear GraphQL](https://linear.app/developers/graphql) ·
[Local container lease](adr-0006-local-container-leases.md) ·
[Fixture instructions](../elixir/README.md#synthetic-linear-to-human-review-pilot)
