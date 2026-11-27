# ADR 0008 · Verify a Codex change in the personal pilot

- Implemented for the personal pilot · November 27, 2026

## Context

[ADR 0007](adr-0007-synthetic-linear-pilot.md) proved that the daemon could
drive a single Linear issue to Human Review with simulated Jira and fixed
worker commands. The next pilot needs an authenticated provider to supply the
implementation and a reviewable diff backed by independent tests. It reuses
the existing scheduler, phase reducer, journal and container leases.

## Decision

The opt-in `implementation: codex` mode admits the `PILOT-2` fixture and
seeds a disposable local Git repository. The authenticated CLI runs in a
scratch directory with read-only sandboxing, disabled tools and a restricted
environment. Its input consists of fixture requirements, an ASCII
normalization program and four regression checks. The CLI returns a bounded
declarative file. The pilot accepts only the three supported `sed` commands
for this fixture and passes the proposal as data to a fixed worker command.

The implementation lease applies the proposal. A separate read-only lease
runs the original checks. The host computes and compares the Git diff digest
after both workers drain. It publishes the diff, digest and check results
with the Human Review state in one Linear update. The update requires the
original issue scope and source to still match. A fresh read confirms the
review state and the evidence. The existing journal holds the review intent
before the update and recovers uncertain outcomes by observation after a
restart. It never replays the provider proposal or the tracker update.

## Alternatives and consequences

- **Give the authenticated CLI a writable repository.** That requires
  a general authenticated provider boundary and would allow the agent to
  edit the checks it is meant to pass. This pilot preserves the existing
  isolated leases for all repository writes and test execution.
- **Prepare the diff and mark Human Review in separate Linear updates.** A
  partial result could leave reviewers with a review state and missing
  evidence. The issue description and state are sent in the same mutation.

The default fixture mode and the upstream workflow remain available. The
local integration test uses a provider stub and covers scope, evidence and
restart behavior. A separate run against Linear Cloud used an authenticated
Codex CLI and independently verified Human Review, the local Git diff and
four passing tests. General-purpose agent edits, authenticated Jira and
multi-provider execution remain separate milestones.

[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode) ·
[Pilot instructions](../elixir/README.md#authenticated-codex-pilot)
