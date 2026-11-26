# Symphony terminal console

Design revision 2 · Proposed wireframes · November 26, 2026

## Product and stack

The operator needs to find the ticket that needs attention, understand why it
is waiting, and inspect the evidence behind the next action without leaving
the terminal. The console should have its own visual identity while making
the agent's native identity recognizable. The ticket timeline is the central
visual element. Keep the background quiet, status text readable and color
reserved for selection, events and interventions.

Evaluate a separate Go executable with [Bubble Tea](https://github.com/charmbracelet/bubbletea)
for updates and input, [Lip Gloss](https://github.com/charmbracelet/lipgloss)
for terminal-aware styling and [Bubbles](https://github.com/charmbracelet/bubbles)
for lists, viewport and help. Its lifecycle and distribution are independent
of the Elixir daemon. Go 1.24.4 is present on the review host. The examined
Bubble Tea v2.1.1 and Lip Gloss v2.0.3 releases declare Go 1.26.0 and 1.25.0
minimums respectively. Pin a compatible, supported toolchain and dependency
set when implementing. [Bubble Tea module](https://github.com/charmbracelet/bubbletea/blob/v2.1.1/go.mod) ·
[Lip Gloss module](https://github.com/charmbracelet/lipgloss/blob/v2.0.3/go.mod)

An Elixir client with Owl avoids a second toolchain and is viable for a small
table viewer. It needs more custom work for pane focus, filtering, live
updates and a standalone binary. Phoenix LiveView is already useful for a
browser dashboard. Keep it as a parallel view. Choose Go for the early
terminal slice, revisiting the decision if compatibility or deployment
measurements make it impractical. [Owl](https://github.com/fuelen/owl) ·
[Terminal client ADR](adr-0005-independent-terminal-client.md)

## Layout concepts

Examples below show **synthetic data and future fields**. The read-only
implementation uses only facts currently available in the daemon.

### A. Queue and evidence inspector

Start here. The work list puts human interventions first. The selected ticket
shows its handoff, next required gate and recent activity. The same pane holds
tabs for criteria, review, tests, demo and the recorded routing decision.
The layout takes keyboard cues from lazygit and puts the ticket's progress
and evidence first.

```text
SYMPHONY    Local daemon  Connected                         Queue  Agents
Issue    Phase         Status          | DEMO-17 · Validation
>DEMO-17 Validate      Needs you       | Intake > Code > [Validate] > Review
 DEMO-21 Implement     Running         | Criteria 2/3      Review 1 open
 DEMO-24 Plan          Waiting         | Latest  Claude -> Codex · finding verified
                                       | Next    Verify response in API demo
                                       | Criteria  Tests  Demo  Route  Activity
j/k Move  Tab Focus  Enter Inspect  / Filter  ? Help  q Close
```

### B. Agent and capacity view

Use this secondary view when deciding how to spend remaining capacity. Model
and effort appear next to the profile alias. A waiting reason remains visible
in text. Show scoped quotas only when their source and observation age are
known. The compact meter treatment is inspired by btop.

```text
SYMPHONY    Agents                                         Queue  Agents
Provider       Model / effort     Profile      Phase      Availability
Codex          Default / medium   Personal     Coding     1 local slot free
Claude Code    Configured / high  Review       Reviewing  Quota unknown
Antigravity    Neon / low         Personal     Waiting    Reset 14:00
----------------------------------------------------------------------------
DEMO-21       Plan ready > Codex reserved > Coding
Enter Inspect session   / Filter   Esc Queue
```

### C. Ticket timeline

Use this as the main detail view on narrow terminals and for detailed
debugging. The active handoff is a line in the history with source and
recipient names plus an artifact the operator can inspect. At wide sizes,
show the evidence summary alongside the timeline.

```text
DEMO-17 · Validation                              2/3 criteria verified
09:12  Antigravity  Plan verified                  Open plan
09:15  Symphony     Handoff to Codex               Open routing decision
09:28  Codex        Implementation checkpoint      Open diff
09:31  Claude Code  Independent review             Open findings
09:36  Symphony     Waiting for demo               Open evidence request
----------------------------------------------------------------------------
Enter Inspect event   Tab Evidence   Esc Queue
```

Use 120 columns for queue plus inspector, 80 columns for a compact queue
with tabs and below 72 columns for one pane at a time. Preserve the
focused issue through refreshes and resize. Use arrows and `j/k`, `Tab`,
`Enter`, `Esc`, search and a contextual help footer. Use terminal default,
dark and light themes with 16-color fallbacks. Labels, borders and focus
markers carry meaning in monochrome. Use cell-width-aware clipping,
plain ASCII status markers, configurable animation and a no-alt-screen mode.
Keep stable text available for screen readers and never steal focus on
updates. On disconnect, retain the last snapshot with its age and retry
with backoff. Empty, loading, unavailable and access-denied states have
distinct text.

## Original provider assets

| Provider | Verified source | Proposal for reuse |
| --- | --- | --- |
| Codex | OpenAI's TUI catalog names the built-in `codex` pet as the original Codex companion and references `codex-spritesheet-v4.webp`. The asset loader obtains it from a separately hosted first-party pack. | Use the original Codexito where permitted. Test cell rendering that preserves its silhouette, colors and frame proportions. The Apache-licensed source and the remote art require separate provenance. |
| Claude Code | Anthropic's official CLI demo shows the coral pixel character commonly called Clawd in the startup view. The public repo's license points to commercial terms. | Use the original published art if an applicable license for reuse and adaptation is confirmed. Preserve Anthropic's original silhouette and palette. Use the text label when the asset is unavailable. |
| Antigravity with Gemini | Installed Antigravity CLI 1.5.18 displays a block-character sign-in emblem. The official press kit publishes Antigravity icons and lockups. Google also identifies the Gemini spark as Gemini brand art. | Prefer the unmodified official Antigravity icon for the provider and the name Gemini Neon for the model. Evaluate the native CLI emblem as a compact alternative if attribution and permitted use are confirmed. A named Antigravity mascot and a reusable animation atlas remain unverified. |

Record source URL, revision or hash, asset terms and attribution for each
included asset. The fork's identity is separate from vendor marks. Start
with provider text labels and allocate optional space for official assets
after rights and rendering checks. No substitute mascots. Existing
representations keep their original palette and proportions. Separate
motion and status cues from an asset when the applicable terms limit
adaptation.

[Codex original pet catalog](https://github.com/openai/codex/blob/main/codex-rs/tui/src/pets/catalog.rs) ·
[Codex asset loader](https://github.com/openai/codex/blob/main/codex-rs/tui/src/pets/asset_pack.rs) ·
[Codex repository license](https://github.com/openai/codex/blob/main/LICENSE) ·
[OpenAI brand guidelines](https://openai.com/brand/) ·
[Claude Code official demo](https://github.com/anthropics/claude-code/blob/main/demo.gif) ·
[Claude Code license](https://github.com/anthropics/claude-code/blob/main/LICENSE.md) ·
[Antigravity press assets](https://antigravity.google/press) ·
[Gemini spark identity](https://blog.google/company-news/inside-google/company-announcements/gradient-g-logo-design/)

## Event-driven motion and handoffs

Keep the original shape stable. Limited pulses, progress marks and attention
borders can animate around licensed art, with a static label beside every cue.
A reconnect applies current state and skips historical animation. An
unrecognized phase displays its last verified state and timestamp.

| Visible status | Trigger | Motion when enabled |
| --- | --- | --- |
| Idle | Available identity, no active attempt | Static original frame |
| Thinking | Provider explicitly reports a reasoning start | Brief side indicator while reported active |
| Researching | Research phase starts | Pulse the phase marker |
| Planning | Planning phase starts | Highlight the plan step |
| Coding | Implementation phase starts | Advance the active phase underline on work events |
| Reviewing | Independent review starts | Highlight the review pane header |
| Testing | Verifier starts a named check | Advance the test marker when progress arrives |
| Collaborating | A verified handoff is queued | One source-to-target cue after dispatch binds the recipient |
| Waiting | Dispatch deferred, pending human action or retry timer | Static reason and next check |
| Rate limited | Quota breaker opens on typed provider evidence | Static reset and a brief status change cue |
| Blocked | Missing permission, requirement or exhausted budget | Persistent visible intervention |
| Completed | Engine accepts phase or run completion | One completion cue |
| Error | Terminal attempt or service failure | One error cue and typed reason |

Providers without distinct thinking events display their observed phase. A
handoff is visible when Symphony verifies the result and selects its recipient.
For example, Gemini can produce a plan that reaches Codex, then Codex can pass a
verified implementation checkpoint to Claude for independent review. If no
recipient is scheduled, show the queued handoff and waiting reason.

## Read-only slice and later controls

The first independent client reads only `GET /api/v1/state` and
`GET /api/v1/:issue_identifier` from the loopback daemon. Poll slowly in the
background with a bounded timeout and no overlapping requests. Start with a
two-second minimum between snapshots and tune if there is measurable scheduler
load. Use the actual running, retrying and blocked entries, current snapshot
status, selected issue and existing Codex telemetry. The current API does not
supply all eligible backlog, completed tickets, durable logs, generalized
provider quotas, verified criteria, dependencies or new router history.
Show a field once the API can represent it. Limit the unauthenticated API
to synthetic or shareable data. Add scoped authentication before displaying
protected data. Keep sensitive paths and raw transcripts out of the client cache.

Later views add scoped profiles, session inspection, model and effort,
quota and tokens, dependencies, live redacted logs, routing and handoffs,
criteria, test output and demo references. Serve versioned replay by opaque
cursor from the daemon after an authorized snapshot. On duplicate events,
keep the latest valid sequence. On gaps, refresh the snapshot. The console
never constructs control decisions from display state. Pause, retry and
override use authorized daemon operations after explicit confirmation,
with a stable request key and a recorded response. Closing the client
ends its reads. The daemon owns and continues its sessions.

Validate resizing at 60, 80 and 120 columns, keyboard-only navigation,
focus, monochrome and ASCII, reduced motion, reconnect and stale snapshots,
and daemon continuity across several client exits. Verify no HTTP mutations
in the first slice. Add a fixture for future provider fields to check
forward-compatible parsing. Wireframes precede implementation approval.

[Navigational reference](https://github.com/jesseduffield/lazygit) ·
[Capacity view reference](https://github.com/aristocratos/btop)
