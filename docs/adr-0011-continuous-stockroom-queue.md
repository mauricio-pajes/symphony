# ADR 0011 · Poll the Stockroom pilot as a continuous Linear queue

- Implemented for the personal sandbox · November 27, 2026

## Context

[ADR 0010](adr-0010-stockroom-api-demo.md) demonstrated one explicitly
selected Linear issue. The next milestone needs new Todo issues to enter
that workflow without a per-ticket daemon launch and needs browser
demonstrations for changes visible in the product.

## Decision

Keep queue selection inside the existing daemon poll loop. Reuse the normal
Linear candidate query, then confirm the selected issue's project, team,
state and exact simulated Jira source before the scoped worker starts. Only
the three known Stockroom fixtures are admitted. An optional creation-time
cutover excludes tickets from earlier pilots in an existing sandbox.

The queue supervises a single active item so the desktop and loopback
service are exclusively available to that item. The current item uses the
existing workflow, provider adapters and Docker leases. A bounded view of
recent outcomes stays in the running daemon for the TUI. The admission
journal remains the source of truth for restart checks and prevents replay
of known issue IDs. A new boot verifies and drains outstanding leases before
admitting unrelated work. A failure with a settled lease can leave the
issue parked and let the next eligible ticket progress.

Queue deployments can configure the same team's In Progress state
by UUID. Todo remains the discovery state. Once the daemon admits the
issue durably, it reads the issue again, writes the new state once and
confirms the destination with the original issue source before launching
planning. If the transition is uncertain, the daemon polls readback for
up to twenty seconds and parks the attempt if it cannot confirm the change.
Linear's state update and the source read are separate operations.

Retry transient provider errors and invalid structured output in the
same phase after five and fifteen seconds. Recheck the run, workspace
identity, absence of a lease and current Linear source before retrying.
Leave provider configuration errors and requests for changes parked.
Bruno may repeat transient-request preparation once before it starts
recording or uploading. If a Human Review transition is uncertain, read
Linear for up to twenty seconds to confirm the published evidence.
The write and uploads are issued once. These in-process retries do not
rearm earlier parked records after a daemon restart.

The two frontend fixtures share a responsive catalog baseline. Codex
enables one pre-existing interaction through a bounded JSON change. Four
offline HTTP checks precede independent Claude Code review. Gemini directs
the capture viewport and pace. Playwright verifies actual mouse clicks
on the filter or sort, observes and resets the result, and records the
pointer and click positions. The executor uploads and reads back the
private video before the daemon publishes the matching diff and Human
Review. The API-only fixture retains its separate Bruno and cURL
evidence workflow.

## Verification

With the daemon already polling, three new Todo issues entered Symphony
Sandbox. Gemini planned the changes, Codex proposed the implementations
and Claude Code reviewed the verified diffs. An independent Linear Cloud
read confirmed Human Review with the correct diff and four passing checks
for each issue. The filter and sort issues had one private browser video
each. The API issue had two private Bruno videos covering the available
and missing responses, plus a reproducible cURL command. All three issues
used simulated Jira requirements.

After enabling In Progress for the same Sandbox project, an independent
Linear Cloud read observed Todo, In Progress and Human Review on a new
catalog issue. The daemon confirmed In Progress before launching Gemini,
and Human Review contained the approved diff, passing checks and browser
recording. A local fixture also exercised lost acknowledgements and a
start transition that never applied.

## Consequences

- The daemon can stay running with the TUI closed. The desktop runner
  still needs its local applications and permissions when a demo starts.
- With the optional In Progress state configured, claimed issues stay
  there until Human Review or a human transition. An interrupted or blocked
  issue may remain In Progress for inspection. The running provider and
  current-boot blocked reason are available on the loopback endpoint and TUI.
- Interrupted work stays recorded for inspection. The pilot does not replay
  uploads or review mutations. General repository admission and concurrent
  desktop captures are outside this experiment.

[Continuous queue setup](../elixir/README.md#continuous-stockroom-queue)
