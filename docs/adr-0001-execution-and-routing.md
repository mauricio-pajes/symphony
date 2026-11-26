# ADR 0001 · Phase-based agent selection and execution

- Proposed. The authorized increment is undergoing local validation.
- November 26, 2026

## Context

Symphony selects work and controls its lifecycle through an OTP orchestrator. The original runner opens a Codex App Server session. The fork needs to launch Claude Code and Antigravity directly, with Codex as the default and an optional classifier for phases with ambiguous scope.

## Decision

Keep the orchestrator and its claim, retry, reconciliation, and workspace contracts. Add an opt-in policy that maps an active state to a provider. In designated states, a scope ambiguity signal allows a brief classification turn in a temporary directory. The result maps to a supported category, and the selector chooses the provider for the attempt.

Keep the App Server session for Codex. For Claude Code and Antigravity, start a local process in the ticket directory and read the CLI's structured result. Each attempt has one provider. A transition to a different phase returns to the dispatch boundary and preserves the ticket files. Add advanced session, permission, usage, and cancellation features as specific provider needs emerge.

## Alternatives

- **Route all decisions through a primary agent.** This reuses its integration but consumes an extra model call for selection and couples every provider to one agent.
- **Make each provider emulate App Server.** This keeps the Elixir call site small at the cost of translating permissions, sessions, and events with different semantics.
- **Adopt another fork's engine.** This offers more integrations early, replaces the operational baseline, and makes upstream synchronization harder.
- **Introduce ACP or the SDKs from day one.** These are useful when callbacks or resumption matter. The documented CLIs allow an earlier routing test with fewer dependencies and an explicit local scope.

## Consequences and verification

Existing workflows continue to use Codex. The first increment requires authenticated CLIs, scoped permissions, and separate Linear access for Claude and Antigravity if they need to update the ticket. Classification is heuristic and may need project-specific tuning. Local tests cover structured output, timeouts, and workspace reuse. The pilot must verify real authentication and external service access.

Synthetic inputs exercised the local Codex and Claude binaries. Both the classifier and Claude returned the expected output. Codex App Server 0.170.0 completed a turn with an explicit `on-request` policy and rejected the upstream default `reject` object. The pilot configuration sets the policy explicitly for compatibility. Antigravity, Linear, and Jira still require verification in the live pilot.

[Design and roadmap](personal-symphony-design.md)
