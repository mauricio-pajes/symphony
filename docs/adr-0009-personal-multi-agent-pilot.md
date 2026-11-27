# ADR 0009 · Verify three authenticated provider handoffs in the pilot

- Implemented for the personal pilot · November 27, 2026

## Context

[ADR 0008](adr-0008-personal-codex-pilot.md) verified one authenticated
implementation against simulated Jira and a real Linear issue. The next
milestone exercises independent planning and review within the same daemon,
with the original workspace leases and a result that a human can inspect.

## Decision

The opt-in `implementation: multi_agent` mode admits only the `PILOT-3`
fixture on the configured Linear issue. The daemon supervises a Gemini 4
Neon Low planning turn in Antigravity CLI, a Codex proposal, and an
independent Claude Code review. Provider responses are accepted only for the
current phase's task and pinned configuration. Before launching a workspace
lease the daemon checks that Linear still reports the original source.

Each CLI receives only a synthetic snapshot from a scratch directory with
tracker credentials removed. Antigravity uses explicit deny rules for file,
command, URL and MCP actions. Claude Code runs in safe mode with no built-in
tools, empty MCP configuration and no session persistence. Codex retains
the read-only proposal boundary. Gemini's structured plan becomes a digest
reference in the reducer and a data-only input to the Codex prompt. The
existing offline worker applies the bounded proposal and runs the original
checks. Claude reviews the resulting diff while the host binds any approval
to the diff digest. A second read-only lease rechecks the fixture and the
host compares that digest before accepting the review. A change request or
a failed provider parks the run for inspection without attempting Human Review.

Keep the existing journal and one-shot Linear projection. The daemon
publishes the plan, independent approval, diff and test results in the same
update as the review state. On restart it parks unfinished provider work
and observes already attempted tracker updates. The journal stores phase
disposition and lease identity. Provider summaries are held in memory until
projection and are recoverable from the verified Linear description after
publication. Only the Docker leases grant permission to modify the fixture.

## Alternatives and consequences

- **Run authenticated agents with a shared writable worktree.** This would
  let them change the fixed checks and would require a general provider
  containment and recovery mechanism. The pilot only applies a bounded
  one-file proposal with the existing lease owner.
- **Retry automatically after a review requests changes.** That would need
  a correction policy and additional provider turns. This pilot records the
  rejection and parks so a human can inspect it.

The live run used authenticated Gemini, Codex and Claude Code with the
synthetic requirements. An independent test runner confirmed the four-phase
journal, all four offline checks, the Git diff and the approval referring to
the same SHA-256 on the Linear Cloud issue in Human Review. The local
fixture covers rejection, scoped evidence, and recovery without replay.
The provider CLIs still run on the host in scratch directories. Recovering
their process identities after an abrupt BEAM crash and admitting arbitrary
repositories remain outside this milestone.

[Antigravity CLI permissions](https://antigravity.google/docs/permissions?tab=cli) ·
[Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) ·
[Pilot instructions](../elixir/README.md#authenticated-multi-agent-pilot)
