# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The [terminal console](../tui/README.md) connects to the enabled observability service on loopback.
The snapshot and issue endpoints include a `provider` field when adapter activity identifies
the worker. The terminal client can also read earlier servers where this field is absent.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

The bundled workflow's [demo evidence rules](WORKFLOW.md#demo-evidence) cover recorded product and
API changes. Configure the project to use its real UI or its authorized native API client. Review
handoff includes the verified video and a permitted request link or sanitized cURL. A live demo
requires access to the real client, target environment, and recording tools from the execution host.

The [personal queue intake rules](WORKFLOW.md#intake-from-a-personal-linear-queue) let a Linear ticket
reference a Jira issue as its source of requirements. Configure the Linear scope, Jira access, and
authorized repositories before running this workflow. The bundled front matter still targets Symphony's
example project. For a queue scoped to one repository, set `hooks.after_create` to clone that repository.
For Jira links that can point to several repositories, start with an empty issue workspace and provide a
repository catalog in the prompt so the agent can select and clone the target after reading Jira. If
the project requires approval before publication, configure its approval hold outside the active
dispatch states.

### Personal Linear queue with Jira intake and multiple agents

Enable these settings in your own workflow. Use the actual state names from the Linear project.
Keep the human approval states out of `active_states` so they pause execution.

```yaml
tracker:
  kind: linear
  provider:
    project_slug: your-personal-project-slug
  active_states: [Todo, Planning, In Progress, Agent Review]
  terminal_states: [Done, Canceled]
agent:
  jira_intake:
    base_url: $JIRA_BASE_URL
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
  providers_by_state:
    Todo: codex
    Planning: gemini
    In Progress: codex
    Agent Review: claude
  classify_scope_states: [Todo]
codex:
  approval_policy: on-request
```

- Paste a Jira `/browse/KEY` URL in the Linear description. Symphony fetches the issue, its visible
  comments and linked issue keys from the configured Jira site with a read-only request. It adds this
  context to the agent prompt while keeping Linear as the tracker. You can set `jira_intake.project_key`
  to limit intake to one Jira project. Tickets without a matching link use their Linear description.
- A state uses its configured provider and defaults to Codex when unmapped. In `classify_scope_states`,
  Symphony runs the read-only Codex classifier when the description lacks explicit acceptance criteria
  or the ticket has `scope-unclear`. It may choose another configured provider for that attempt. After
  an agent advances Linear to a different routed phase, Symphony starts a new session in the same workspace.
- Write the completion criteria and next Linear state for each active phase in the workflow prompt.
  Codex gets Symphony's tracker tools. Claude Code and Gemini run as local CLIs and need their own
  authorized Linear connection if their phase updates the workpad or transitions the ticket. Have each
  phase record its findings or changes before advancing so the next agent can resume from the workspace
  and workpad. Set their tool permissions for the project before enabling a route.
- Install and authenticate `claude` and `agy` on the worker. `agy` uses Gemini 4 Neon High by default.
  Override `agent.claude_command`, `agent.gemini_command`, or `agent.classifier_command` with an argv
  list to pin a different model or CLI installation. Use the same streaming output format when
  overriding a command. The classifier and the extra providers currently require a local worker.
- Prefer the current standalone `agy` from the [official CLI installer](https://antigravity.google/docs/cli/tutorial/).
  If the binary is outside the worker's `PATH`, set the first entry in `agent.gemini_command` to
  its absolute path and retain the streaming arguments. Use that binary's `models` command and
  verify its effective account before enabling the route.

The [Personal Symphony design](../docs/personal-symphony-design.md) describes the proposed internal
workflow, centralized effects and terminal client. This example documents the current tracker-driven
routing mode.

### Synthetic Linear-to-Human-Review pilot

Use a separate workflow and workspace root for a single synthetic test issue.
Start the daemon with the exact issue and review-state UUIDs, a trusted local
Docker socket, a pinned image and a private state directory outside the
workspace root. Both directories must exist, and the state directory must be
private. Run one daemon per state directory. Changes to the pilot scope require
a restart and settlement of any unresolved lease under the original scope.

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: your-personal-test-project-slug
  active_states: [Todo]
  terminal_states: [Done, Canceled]
workspace:
  root: /absolute/path/to/pilot/workspaces
agent:
  internal_pilot:
    issue_id: "<Linear test issue UUID>"
    human_review_state_id: "<Human Review state UUID on the same team>"
    state_directory: /absolute/path/to/pilot/state
    docker_socket: /absolute/path/to/docker.sock
    image: "sha256:<local BusyBox image ID>"
```

Set the test issue description to the single line
`https://jira.fixture.test/browse/PILOT-1` and put it in Todo or To Do.
The pilot also accepts the Markdown form that Linear returns for that URL.
Start the daemon with this separate `WORKFLOW.md` as described in [Run](#run).
The host will confirm project and team scope and resolve the Jira link with
the local fixture. It verifies a synthetic response file after isolated
planning, implementation, validation and review. The workers exercise selected
profile names using fixture commands. The Linear credential stays on the host.
The host records the review intent before sending one transition, then confirms
the result with a fresh read. If the transition result is unknown, later polls
recover only by observation.

Use an authenticated Linear test project for a real ticket. To reproduce the
fully local run with a simulated Linear GraphQL server, run from `elixir/`:

```bash
docker pull docker.io/library/busybox:1.37
mix build
python3 test/support/internal_linear_pilot.py \
  --socket /absolute/path/to/docker.sock \
  --image "$(docker image inspect busybox:1.37 --format '{{.Id}}')"
```

The fixture checks the daemon's HTTP API, observes the simulated Linear
transition, and verifies no duplicate transition after restart. It also
exercises a lost response before and after the update, a changed ticket,
and daemon recovery with an attached worker. Its Codex case substitutes
a local CLI stub, checks that the tracker credential stays off the provider
process, and compares the inline Linear diff with the Git working tree.
See the [pilot integration ADR](../docs/adr-0007-synthetic-linear-pilot.md).

#### Authenticated Codex pilot

For the version-label test, add `implementation: codex` under
`agent.internal_pilot` and use `https://jira.fixture.test/browse/PILOT-2`
as the Linear test issue description. Start with a fresh issue UUID and
private pilot directories. The host needs Git and a `codex` CLI on `PATH`
with an existing login. Symphony initializes a local Git repository for
the test and keeps the resulting diff in its pilot workspace.

Codex receives the synthetic requirements, baseline and fixed checks in a
tool-disabled session. The offline worker applies the bounded proposal and
runs the four checks against the resulting working tree. The daemon checks
the diff across the implementation and validation phases. On success it
adds the inline diff, its SHA-256 and test results to the ticket in the same
Linear update that moves it to Human Review. Use the [Codex pilot ADR](../docs/adr-0008-personal-codex-pilot.md)
for the execution boundary and restart behavior.

#### Authenticated multi-agent pilot

Set `implementation: multi_agent` under `agent.internal_pilot` and put
`https://jira.fixture.test/browse/PILOT-3` on a fresh scoped Linear test
issue. Use the same private Docker and workspace configuration. This mode
needs authenticated `agy`, `codex` and `claude` CLIs on the daemon's `PATH`.

Gemini 4 Neon Low produces a structured plan for the simulated requirements.
Codex receives the plan with the requirements and test fixture and proposes
the change. After offline validation, Claude Code reviews a snapshot of the
exact diff. The daemon only projects Human Review after approval and a
post-review check of that revision. The one Linear update includes the
plan, review, diff and four test results. Changes requested by Claude park
the pilot in Todo for inspection.

The local integration fixture verifies the handoffs and both review verdicts
using CLI stubs. See the [multi-agent pilot ADR](../docs/adr-0009-personal-multi-agent-pilot.md)
for the provider boundary and the verified live run.

#### Stockroom API and Bruno pilot

Use `https://jira.fixture.test/browse/PILOT-4` as the description of a fresh,
scoped Linear test issue. The daemon seeds a standalone [Stockroom inventory
project](priv/pilot/inventory/README.md) and adds a GET availability contract
while preserving the catalog. Use the same three authenticated provider CLIs.
Configure `agent.internal_pilot` as in the previous example, with these changes:

```yaml
agent:
  internal_pilot:
    implementation: api_demo
    image: "sha256:<local Python 3.12 Alpine image ID>"
    demo_runner: /absolute/path/to/elixir/test/support/bruno_demo/run.py
```

The optional desktop executor requires macOS 15 or later on Apple Silicon,
Bruno open in an English-language window, existing Accessibility and Screen
Recording access, Xcode command-line tools, Git, Python 3.9 or later and
FFmpeg. The sample uploader reads the previously configured
`symphony-linear-personal-pilot` Keychain entry. Keep the Bruno window free
while the daemon runs the demo. The local API binds only to port 8767 on
loopback. The executor stores verified MP4s in `~/Downloads/Symphony-Stockroom-qa-evidence/`.

After Claude approves the diff, Gemini chooses the order and focus of two
short Bruno recordings. The executor verifies the real HTTP results and the
captured status and body, uploads the clips privately, and returns links
bound to the reviewed diff. Linear receives both videos, cURL commands,
the checked test results and the review in the Human Review update. Failed
recording or upload leaves the scoped ticket in Todo for inspection.

For a local regression run, add `--api-image <local Python image ID>` to
the fixture command above. The regression suite uses desktop stubs and
checks the demonstration gate without touching Bruno or uploading anything.
See the [Stockroom demo ADR](../docs/adr-0010-stockroom-api-demo.md).

#### Continuous Stockroom queue

Use `implementation: queue` in this pilot's `agent.internal_pilot` settings,
omit `issue_id`, and pin the same project and Human Review state. Configure
`demo_runner` with the Bruno executor and set `frontend_runner` to a trusted
absolute launcher for `test/support/frontend_demo/run.py`. That executor
uses Node.js, Playwright with its video dependency, Chrome, Python and
FFmpeg. It reuses the private Linear asset uploader. The launcher can set
`NODE_PATH` to the directory containing its installed `playwright` package.
Set `queue_since` to an ISO 8601 timestamp when enabling an existing sandbox
if older tickets should be kept out of the initial run.

The daemon selects one eligible ticket at a time from the project's Todo
state. Use exactly one simulated Jira link in the issue description:

| Fixture | Work item | Demo client |
| --- | --- | --- |
| `https://jira.fixture.test/browse/PILOT-4` | Inventory availability endpoint | Native Bruno, with cURL in Linear |
| `https://jira.fixture.test/browse/PILOT-5` | In-stock catalog filter | Browser walkthrough |
| `https://jira.fixture.test/browse/PILOT-6` | Catalog sort by lowest availability | Browser walkthrough |

Launch the daemon with a loopback observability port and point the [TUI](../tui/README.md)
at that same address with `-url`. The daemon keeps polling when the TUI is
closed. Linear retains Todo while the serial phases run and receives Human
Review together with the approved diff and demo evidence. The TUI shows the
active provider, scheduled retries and recent outcomes. Retryable provider
errors get two attempts on the same phase after short delays. The daemon
checks the current issue source and the lease-free workspace before
restarting the provider. Bruno retries request preparation once before
capture. After an uncertain Human Review write, the daemon polls for
matching evidence without repeating the write. Unresolved Docker leases
must drain before new work starts after a restart. Recorded tickets
stay out of new admission.

See the [continuous queue ADR](../docs/adr-0011-continuous-stockroom-queue.md).

### Isolated internal phase fixture

The opt-in test routes a synthetic item through planning, implementation,
validation and independent review while the same issue claim remains active.
It binds each selected phase to a durable reservation, runs a shell command
in an isolated local Docker container, and parks the item at Human Review.
It also demonstrates a surviving container descendant after the worker
BEAM exits and verifies recovery before the workspace can be reused.
A separate case recovers a stopped container after a lost create
acknowledgement. The worker's final stdout line must be a versioned JSON
proposal such as `{"version":1,"status":"succeeded"}`. The host checks the
lease and outcome before applying its independent verification.

Run from `elixir/` with a trusted local Linux Docker Engine. Set its Unix
socket path and the ID of an installed BusyBox image.

```bash
docker pull docker.io/library/busybox:1.37
export SYMPHONY_TEST_DOCKER_SOCKET=/path/to/docker.sock
export SYMPHONY_TEST_DOCKER_IMAGE="$(docker image inspect busybox:1.37 --format '{{.Id}}')"
SYMPHONY_RUN_CONTAINER_TESTS=1 mix test test/symphony_elixir/internal_container_worker_test.exs
```

The fixture uses temporary workspace and journal directories. The container
worker uses an existing image with no implicit volumes. The daemon's
regular tracker dispatch remains in use for normal workflows. See the
[local container lease ADR](../docs/adr-0006-local-container-leases.md).

### Minimal workflow example

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the installed Codex App Server. Codex CLI
  0.170.0 accepts `on-request` and the object-form `granular` policy. It rejects the older
  `reject` object used by the bundled defaults. Use `on-request` in the personal workflow above
  to let Symphony surface requests for approval as blockers.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Routed headless providers use `codex.turn_timeout_ms` as the silence interval and default
  elapsed-time cap. Set `agent.headless_max_duration_ms` to configure the elapsed limit separately.
  Classifier invocations retain a cap of at most one minute.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
