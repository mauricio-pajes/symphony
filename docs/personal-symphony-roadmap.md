# Personal Symphony roadmap

Design revision 2 · Approved for incremental implementation · November 26, 2026

## Rollout and exit criteria

| Stage | Deliverable | Exit criteria |
| --- | --- | --- |
| 0. Provider preflight | Confirm installed runtimes, supported authentication, model and effort, structured output and observed telemetry with one approved identity per provider. | Repeat a synthetic execution with no private data. Record exact versions, success shape and model when available. Use controlled fixtures for rate-limit, timeout, invalid output and partial failures. Check the provider's effective filesystem, tool, network and credential boundaries before real repo work. |
| 1. Read-only TUI | Go console against the current loopback GET API, with optional local source artwork. In use on the synthetic pilot. | Inspect running, retrying and blocked issues and available usage. Verify keyboard use, resizing, reconnect and daemon continuity. |
| 2. Deterministic router and serial workflow | Add one opt-in internal phase sequence, direct provider adapters, routing explanations and structured local outcomes. Preserve the tracker-driven mode. | A clear ticket uses no classifier, an ambiguous case classifies once per requirement revision, and the same Linear state supports a verified handoff. Exercise independent review, rejection of bad evidence and bounded rework. Prove one writer across cancellation, timed-out or surviving descendants, retries, late events, reload and restart. Parked work stays parked across polls and restarts. |
| 3. Profiles, durable recovery and authorized effects | Add per-project account bindings and quota observations, persisted checkpoints, an effect journal and central effects. | Prove scoped identities and effective worker isolation. Distinguish cooldown from task retry, and show unknown quota. Verify restart, revocation, cancellation and lost acknowledgements at both sides of the effect boundary. Prevent duplicate comments, transitions and publication. |
| 4. Live scoped pilot | Choose one approved test queue, Jira project, repository and environment. Make a small change with verifiable acceptance criteria. Use the approved project-specific demo and review rules. | A Jira link resolves the expected revision without changing Jira. A workpad advances with checked evidence. Record and verify the real product UI or native API client with a visible cursor. Provide the approved internal request link or sanitized cURL where applicable. Pause for human review and preserve approval boundaries. |
| 5. Comparative evaluation | Establish the Codex-only baseline. Measure deterministic multi-provider runs and replay policy candidates in shadow mode. | Compare quality, elapsed and human time, consumption, throughput, rework and interventions. Declare assumptions and unknowns. Promote a routing change only when scoped results support it. |
| 6. Rich console, more profiles and selective adaptation | Add versioned events, history, authorized operations, verified assets and event-driven motion. Expand profiles and routing policies when justified by observed demand. | Verify cursor replay, permission checks, profile separation, rollback, rate-limit handling and UI controls. A lack of supporting evidence keeps the affected feature on its prior policy. |

The deterministic policy, internal phases and durable launch boundary have
been exercised through the daemon on one selected synthetic Linear issue.
Stage 2 activation for general project work still requires authenticated
provider adapters and automatic admission policies. Add full checkpoint and effect recovery in stage
3. Allow additional graph behavior and parallel work when the pilot identifies a repeatable
need. Measure the public snapshot load before adding push transport.

The earlier increment remains available for isolated synthetic testing.
A live run uses an expressly scoped pilot board and environment. Confirm
the permitted repositories, tracker scopes, approved provider identity for
each data class, credential boundary, and publication surface. A local
team profile supplies repository-native engineering, independent review
and demo requirements. Save execution evidence and corporate configuration
outside the public fork. A persona's login status or a model listing
does not authorize sending work material.

## Evidence at this revision

| Verified | Evidence and limits |
| --- | --- |
| Elixir local gates | `make -C elixir all` passed at the code baseline: 311 tests, 0 failures, 6 skipped, with Dialyzer clean. Skipped integrations are not proof of live services. GitHub reports no checks on the draft at review time. |
| Jira intake | A synthetic HTTP test proves link enrichment at the runner boundary, request credentials scoped to the configured endpoint, redirect refusal and skip of classification for a clear scope. No corporate Jira ticket was used. |
| Phase dispatch | Local tests exercise subprocess output, removal of configured secrets, process-group cancellation, same-workspace handoff and a pause through the OTP orchestrator. These do not certify all-platform descendant cleanup or restart recovery. |
| Codex | Live synthetic App Server turn with explicit `on-request`, plus a synthetic Codex classifier result. Generated schema verifies the declared account/usage and session surfaces, without validating multiple profiles or quota data. |
| Claude Code | Live synthetic CLI output on the earlier slice. Current CLI version and flags inspected. Permission and usage behavior in an isolated live worker still require preflight. |
| Antigravity | Updated standalone CLI to 1.5.18 and verified the approved personal identity and presence of quota metadata through its interactive status-line hook. A live synthetic Neon Low turn returned NDJSON with success, a schema-matching `structured_output` and usage metadata. The current parser's success predicate matches the terminal event. It reads the text response and discards the separate structured field. This was a direct CLI check outside Symphony. |
| Terminal client | The separate Go console uses the existing GET endpoints, displays observed provider activity, and supports optional local PNGs. A synthetic OTP daemon supplies the demo data. |
| Routing and workflow components | The deterministic router evaluates scoped profile eligibility, capacity, independence and affinity. A combined test passes verified artifacts and criterion evidence across internal phases and parks at Human Review. The legacy scheduler remains in use. |
| Durable admission | The single-scheduler journal records launch reservations and matches boot IDs and generations before attachment. Reopening it preserves unresolved leases and requires trusted reconciliation before reuse. |
| Isolated internal dispatch | The opt-in fixture routes four phases through real local Docker containers, enforces read-only phases, binds verifier execution to a drained container, and persists Human Review. A timed-out container descendant survives BEAM termination, blocks the next reservation and stops writing after recovery drains the container. A lost create acknowledgement is reconciled only after a matching stopped container is observed. Provider work and tracker access use synthetic inputs. |

Routed headless providers now enforce an elapsed-time budget even while
emitting progress. The local deadline test also checks that a background
descendant does not write after timeout. The current production runner
discards headless results before deciding continuation, and the legacy
successful-exit path can revisit an unchanged active ticket. The isolated path verifies bounded, versioned terminal proposals against
the current lease, drains it and applies independently verified evidence.
The opt-in daemon pilot adopts that path for one synthetic issue.
General authenticated provider execution and project-wide admission remain pending.
A macOS fixture demonstrated the restart case: a background child wrote after
the BEAM running its headless parent was forcibly terminated. The local
container lease now demonstrates the required separation and verified drain.
See the [container lease decision](adr-0006-local-container-leases.md).

The [synthetic Linear pilot](adr-0007-synthetic-linear-pilot.md) recorded
Human Review from the built daemon against a local Linear GraphQL fixture.
It verified persisted acknowledgement, uncertain transition recovery by
observation, and cancellation after the source issue changed. An
authenticated Linear Cloud test then confirmed the real ticket transition
with an independent API read and a four-phase journal entry. That test used
simulated Jira requirements and fixture workers.

The [authenticated Codex pilot](adr-0008-personal-codex-pilot.md) then
used Codex to propose a version-label normalization change for a disposable
personal Git repository. The daemon applied the proposal offline and verified
the unchanged diff and four passing checks through isolated worker leases.
An independent Linear Cloud read confirmed Human Review, the matching diff,
and test evidence. Jira remained simulated. This milestone validates the
daemon-to-provider handoff and one review projection for a bounded fixture.

The [authenticated multi-agent pilot](adr-0009-personal-multi-agent-pilot.md)
then verified a Gemini 4 Neon Low plan, a Codex implementation and independent
Claude Code approval for that same fixture in sequence. The daemon verified
the diff and all four checks. A separate Linear Cloud read confirmed the
published plan digest, review bound to the diff digest, and Human Review.
A local test verified that a request for changes parks the run instead.

The [Stockroom API pilot](adr-0010-stockroom-api-demo.md) exercised a new
inventory route from a simulated Jira issue in Linear Cloud. Gemini planned,
Codex implemented the route configuration, Claude approved the tested diff,
and Gemini directed the native Bruno recordings. An independent read confirmed
Human Review with both private video links, cURL and all four passing HTTP
checks. A local regression also confirmed that a demo failure leaves the
issue in Todo without attempting a review transition.

## Comparison with a Codex-only workflow

Use two comparisons. First run the same proposed workflow contract and
checks with Codex-only and multi-provider selection to isolate routing.
Then compare against the existing Codex workflow to measure total
change, including added phases and review. Keep order balanced when
replaying tasks from a fixed commit. Use separate worktrees, equivalent
requirements, tools, environments and deadlines. Review results without
provider labels where feasible. Begin with a small calibration sample
across routine fixes, contract changes, research-heavy cases and evidence
verification. Record case complexity and avoid promoting sparse results.

| Measure | How to record it |
| --- | --- |
| Quality | Verified criteria at first human review, confirmed defects and severity, and missed or false review findings. Treat mandatory criteria and permission controls as gates. |
| Productivity and latency | Accepted comparable tasks per work period, elapsed time and time to first review-ready result. Record queue waits, active phase latency and human time separately. |
| Quotas, tokens and spend | Provider-specific windows, backoffs, input/output/cache units and cost when known. Report missing values and estimated cost separately. Never sum incomparable entitlement units. |
| Rework and human intervention | Fix or validation cycles, failed attempts, reopenings, active operator minutes and reason for each handoff or escalation. |
| Effect of routing | Record policy version, eligible alternatives, selection rationale, model/effort, profile alias and session reuse. Compare outcomes per task class and risk. |

Publish comparison design before collection, including scoring, exclusion
criteria, approved budgets and quality floor. Record paired deltas and
uncertainty, including timeouts and blocked cases. A candidate policy must
maintain the agreed quality floor and improve at least one of throughput,
human time, latency or budget efficiency for the covered category.
Start with manual promotion and a scoped rollback. A counterfactual
score based on previously recorded results is useful for triage but
requires a real paired run to establish improvement.

## Upstream synchronization

Keep each extension behind the existing worker, config, tracker and
presentation seams. Preserve disabled-mode fixtures and run them with
new upstream releases alongside enabled-mode tests. Separate commits
that adapt changed upstream contracts from commits that add fork behavior.
Confirm app-server compatibility against installed and pinned versions
after a sync. At review, fork and upstream main both pointed to `be10a1b`. Record an ADR before replacing any significant upstream
component. The proposed internal coordinator, account registry and client
rely on current lifecycle boundaries. Revisit an additional service or
general-purpose workflow engine only if evidence warrants it.

[Design](personal-symphony-design.md) · [Terminal console](personal-symphony-tui.md) ·
[Current opt-in configuration](../elixir/README.md#personal-linear-queue-with-jira-intake-and-multiple-agents)
