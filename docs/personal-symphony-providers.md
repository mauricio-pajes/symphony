# Provider capabilities and account policy

Design revision 2 · November 26, 2026

## Installed runtimes

| Provider | Local evidence | Supported surface and remaining checks |
| --- | --- | --- |
| Codex CLI 0.170.0 | ChatGPT login mode, synthetic classifier and App Server turns. The generated protocol schema contains model listing, account and rate-limit reads and notifications, thread resumption, interruption and token usage. | Keep native App Server. Select supported model and effort from its catalog. Validate authenticated account binding and usage through the same worker identity. A subscription window percentage and a token count describe different quantities. |
| Claude Code 2.1.330 | Authenticated CLI, earlier synthetic turn, and current help for model, effort, schema, resume, MCP and tool options. | Use the published JSON CLI and validate session and permissions before enabling repo work. Consider the Agent SDK if a concrete callback or resume requirement warrants the dependency. CLI usage and rate-limit events depend on runtime and auth. Console API usage and billing are a separate billing surface. |
| Antigravity CLI 1.5.18 | The official per-user installer and updater identified 1.5.18 as latest at review time. The previous bundled 1.5.5 remains in the app. The standalone CLI listed the four Neon effort slugs and its status-line hook reported the approved personal identity and presence of quota buckets. A synthetic Neon Low turn returned structured output and usage. | Pin a catalog slug, validate effort in its native units, and review NDJSON, structured errors, process cancellation and tool controls. Treat the status-line hook as a documented interactive observation. Verify whether headless mode supplies independently usable identity and quota signals. |

The Codex pilot App Server uses explicit `on-request`. This version rejected the
original `reject` object before completing the synthetic turn with `on-request`.
An approval setting supported by the protocol does not by itself implement an
authorization boundary. [Codex App Server](https://learn.chatgpt.com/docs/app-server) ·
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference) ·
[Claude Code headless](https://code.claude.com/docs/en/headless) ·
[Antigravity headless](https://antigravity.google/docs/cli/headless/) ·
[Antigravity status-line schema](https://antigravity.google/docs/cli/statusline/)

## Authentication and isolation

| Provider | Supported mechanism | Initial policy |
| --- | --- | --- |
| Codex | Managed ChatGPT login or separately billed API authentication. `CODEX_HOME` scopes CLI state and the documented credential store controls file, keyring, automatic or ephemeral storage. | Candidate profiles can be enrolled individually. Verify account and workspace from an authenticated worker, including after concurrent launches and refresh. Use a dedicated OS identity or other verified isolation for corporate execution. |
| Claude Code | Subscriptions, Console and managed providers. Anthropic documents per-account `CLAUDE_CONFIG_DIR` for separate sign-ins and an exception for Console sign-ins without API keys. macOS keyring isolation requires a runtime test. | Enroll one approved CLI identity first. Verify configuration and effective auth in the worker, clear competing credential variables and retain managed restrictions. Use published auth flows. |
| Antigravity | Local OAuth and shared local keyring across surfaces. Google documents enterprise ADC and a separately billed Gemini API provider mode. `--settings` is per session. | Run one explicitly verified local OAuth identity for the pilot. The operator can nominate a personal or institutional sign-in for synthetic preflight. Institutional data access and company-policy admission remain separate. No documented per-process desktop OAuth account selector was verified. Do not infer separation from a configuration path. |

For candidate profiles, including the user's multiple Codex and two Antigravity
identities, require separate enrollment and explicit data and billing scopes.
Use dedicated OS users or isolated hosts where account selection and refresh must
be independent. Test concurrent cold starts, model entitlement, revoked access,
and refresh under each identity before permitting multi-profile scheduling.
Credentials stay in provider-supported stores and are omitted from the daemon's
database, logs, prompts, UI and child-tool environment. Verify the binding
in the actual worker profile or isolated runtime before passing work content.
It reports only an alias. For global or mutable keyring authentication, an
interactive status check of another process supports synthetic preflight only.
Require stable provider-supported binding or a dedicated identity with controlled
sign-in and refresh before using protected data. Serialize shared credential
refresh where the launcher controls it. A mismatch invalidates the session and
blocks new work until revalidated.

[Codex authentication](https://learn.chatgpt.com/docs/auth) ·
[Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference) ·
[Claude Code authentication](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts) ·
[Antigravity authentication](https://antigravity.google/docs/install) ·
[Google Workspace entitlements](https://antigravity.google/docs/workspace)

## Quotas and scheduling

Record each observation with opaque profile alias, provider bucket, scope,
unit, value, measured or estimated source, observation time, expiry and optional
provider reset time. Retain unknown values explicitly. Track consumption
(input, output, cache and other provider-defined units) separately from limits
(quota buckets, capacity or service busy) and monetary charges. Aggregate only
commensurate values. Use an application concurrency limit even with unknown
provider quota. Multiple local aliases for the same metered account share an
effective concurrency key. Do not add entitlements together.

- **Codex.** Consume supported App Server account rate-limit snapshots and updates.
  Respect scope, returned windows and reset times. API usage and ChatGPT plan use
  have separate denominators. Paid capacity or provider credits require the
  applicable billing authorization.
- **Claude.** Use documented CLI or SDK metadata and classified failures from
  actual fixtures. Anthropic documents plan usage and supplemental credit
  controls. Treat exact remaining subscription quota, reset time and billing
  as unknown when the selected surface omits them.
- **Antigravity.** Personal plans publish quota windows by plan. Paid Pro has a
  short window and a weekly cap. The CLI documents `/usage` and structured
  quota observations through the status-line hook. Validate before choosing
  a headless ingestion path. Keep separate personal, enterprise, API and
  institutional entitlement scopes. Provider-managed overage flags are
  independent of Symphony's configured budget.

Reserve capacity at the orchestrator's dispatch boundary. Start with conservative
per-provider and per-account concurrency plus the existing global slot limit.
Reserve atomically and release once after confirmed exit. Add a bounded adaptive
cap only if observed capacity warrants it. Distinguish a rate limit, provider
outage, expired authentication, denied permission and a task-specific failure.
Apply a cooldown to the affected quota bucket or service scope. With a known
reset, defer until reset plus jitter. With an unknown reset, use backoff and one
probe before allowing more work. Authentication failures require revalidation.
Authorization failures block the project action. Capture bounded, redacted stderr
and typed exit events to support these distinctions.

A session is bound to provider, profile, project, workspace identity, approved
runtime capability and native session ID. Resume with that binding after checking
the saved revision and permissions. Cross-provider or cross-profile execution
starts a new session from the checked handoff. Failover can serve a separately
authorized workstream or permitted alternate provider under approved policy.
A quota event never rotates same-provider subscription accounts to work around
a limit. Wait for reset, escalate, or use capacity already authorized for that
project and allowed by the provider. Do not auto-purchase, redeem or turn on
overages. Track operator overrides and show when they would affect usage or billing.

[OpenAI usage and plans](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) ·
[OpenAI Terms](https://openai.com/policies/terms-of-use/) ·
[Claude costs and credits](https://code.claude.com/docs/en/costs) ·
[Claude Code terms and integration](https://code.claude.com/docs/en/legal-and-compliance) ·
[Antigravity plans](https://antigravity.google/docs/plans) ·
[Antigravity credits](https://antigravity.google/docs/cli/credits) ·
[Antigravity terms](https://antigravity.google/terms)

## Model evidence and compatibility

Use the provider catalog to discover effort levels and model IDs. Store the actual
model/effort returned when observable and record discrepancies. Use task suitability
as a prior. A coding benchmark or a long-context/video evaluation can suggest what
to test. It cannot establish relative performance on a specific repository,
under different harness settings, or across effort levels. Compare equivalent
cases in the [evaluation plan](personal-symphony-roadmap.md#comparison-with-a-codex-only-workflow).
[Terminal-Bench rankings](https://www.tbench.ai/) ·
[Gemini Neon technical evaluation](https://storage.googleapis.com/deepmind-media/gemini/gemini_4_neon_model_evaluation.pdf)

Use provider subprocesses and native protocols first. ACP is documented and
`agy acp` is exposed locally. Evaluate it if shared permission or session semantics
provide measurable value, with a capability probe per supported version.
Avoid making a provider emulate Codex App Server or adopting another scheduler
to obtain an adapter. [ACP specification](https://agentclientprotocol.com/protocol/v1/overview) ·
[Antigravity ACP](https://antigravity.google/docs/cli/acp/)
