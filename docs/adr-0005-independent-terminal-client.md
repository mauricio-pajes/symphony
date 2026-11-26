# ADR 0005 · Independent terminal console

- Accepted · November 26, 2026

## Decision

Build an independent, read-only Go client using Bubble Tea, Lip Gloss and
Bubbles as the first terminal slice. Consume the existing snapshot and
issue detail GET endpoints on loopback. Keep existing Elixir logging and
Phoenix views. The console renders an event or snapshot received from the
daemon. It never starts or owns workers. Add replay and authenticated
controls through a versioned daemon API after there is a concrete need.

The first slice excludes tracker refresh and all other HTTP mutations.
Use synthetic or otherwise explicitly shareable data with the existing
unauthenticated snapshot API. Require a scoped loopback credential or a
permission-restricted Unix socket and verified authorization before exposing
protected data. Keep terminal output sanitized and avoid redirects.
Reuse daemon permissions and audited operations for every future control.

## Alternatives and consequences

- **Extend the existing Elixir terminal output.** Less distribution work
  for a passive dashboard. Maintaining independent tabs, navigation and
  immersive session inspection would add complexity to the host UI.
- **Use the existing Phoenix dashboard.** Strong for remote visual controls,
  with a browser interaction model. Keep it available as a complementary view.
- **Embed the daemon in the client.** Simplifies single-command launch but
  couples user exit and agent lifetime, contrary to the operator's workflow.

Go adds one maintained toolchain and test matrix. The initial read-only
consumer can ship without changing the daemon contract or upstream UI.
Enable controls only after proving authorization, idempotency and stable
daemon operation with disconnecting clients.

[Wireframes and client contract](personal-symphony-tui.md)
