# ADR 0011 · Require a verified Linear demo before Human Review

## Context

The default workflow delegates tracker operations to the coding agent. A
prototype could therefore enter Human Review with a local recording path
that other reviewers cannot open. A failed or interrupted publication can
also leave an attachment or uploaded asset that must be recovered without
creating a second attachment.

## Decision

Use the original Linear poller, workspace lifecycle and retry ownership.
Add an opt-in `hooks.after_success` stage for required host effects, and
retain `hooks.after_run` for best-effort cleanup. A required hook failure
fails the attempt even if the provider finished successfully. Workflows
that give the host publication responsibility set
`agent.tracker_tools_enabled: false`. This keeps tracker reads and
credential stripping while disabling tracker tools on that agent session.

The publishing hook independently validates the requested artifact against
the worktree revision. For the CiberHéroes workflow, the daemon records the
actual application, checks desktop and mobile, and obtains a Claude Code
review of the diff. A private `fileUpload` grants a signed PUT destination.
The uploader requests the asset again and compares its length and SHA-256
with the original recording. The auth header is only sent to the Linear
asset endpoint. The hook saves the asset URL and attachment UUID outside
the workspace before it creates an attachment. It observes the exact
attachment UUID, owning issue, title and URL before moving the issue to
Human Review. A retry can recheck a saved attachment intent without
creating another attachment.

Gemini's visual intake receives an explicit set of product reference
images and returns the ticket breakdown. Codex handles implementation and
Claude Code independently reviews it. The local CiberHéroes workflow
scopes the issue IDs, screenshots, baseline, browser checks and review
receipts outside this repository. Symphony prepares each workspace from
the verified predecessor revision in this iteration. The Stockroom
recording runner shares the private video uploader and retains its current
demo and tracker workflow.

## Alternatives and consequences

An instruction to the coding agent to upload before moving the issue
depends on the same agent to perform and enforce the check. Adding
project-specific recording and storage rules to the orchestrator would
make those rules part of the upstream execution path. The opt-in hook
keeps them in workflow configuration.

Linear does not combine the attachment and state mutations in a
transaction. The publisher rechecks scope, artifact and attachment before
transitioning. Operators should keep the publication hook as the writer
for that transition while the daemon processes a ticket.
