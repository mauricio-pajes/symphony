# ADR 0002 · Personal Linear queue and Jira requirements

- Proposed. The authorized increment is undergoing local validation.
- November 26, 2026

## Context

Mauricio manages a personal queue alongside Blaze tickets that already have an owner and acceptance criteria in Jira. A Jira link should be sufficient to start work while preserving the original ticket and its ownership.

## Decision

Linear retains the work item identifier and execution state. The host reads Jira from the configured origin and, when set, the permitted project. Symphony builds the read endpoint from the issue key and adds the summary, criteria, visible comments, and related issue links to the description sent to the agent. The workflow continues to own phase configuration and permissions. Corporate ticket updates and publication of evidence follow Blaze approval rules.

The first increment recognizes links from one configured origin. If it finds more than one ticket from that origin, it reports the ambiguity. Tickets without a matching link retain their Linear description. The catalog defines which repositories a workflow can use, and the workflow checks the catalog before opening a repository.

## Alternatives

- **Use Jira as the only tracker.** This allows native polling in Blaze, combines the personal queue with the corporate board, and requires another tracker for personal projects.
- **Copy the full description into Linear.** This reduces initial reads but duplicates requirements and requires reconciliation when Jira changes.
- **Resolve any URL in the work item.** This supports more sources. A fixed origin and constructed path give tighter control over reads and credential use.

## Consequences and verification

Each attempt can read the current ticket version. The analysis records which requirements it used. Comments and links are treated as data, and the configured credentials stay with the host. Tests verify origin, project scope, redirect handling, and preservation of the Linear identity. A pilot with an agreed scope will verify corporate approval and live accounts.

[Design and roadmap](personal-symphony-design.md)
