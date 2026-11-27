# ADR 0010 · Produce a native API demo before projecting Human Review

- Implemented for the Stockroom pilot · November 27, 2026

## Context

[ADR 0009](adr-0009-personal-multi-agent-pilot.md) exercised the authenticated
providers against a small command-line fixture. An API-only ticket needs to
show the actual request and response in a client a reviewer can use. The
orchestrator also needs to own the demo milestone instead of relying on a
separate recording after the ticket enters Human Review.

## Decision

The `api_demo` pilot admits the simulated `PILOT-4` requirements on the
configured Linear UUID. Its baseline is a standalone Python/SQLite inventory
project. Codex proposes the bounded JSON route configuration for the new
endpoint. The host-owned HTTP handler computes the quantity and the fixed
HTTP checks cover the existing contract, available and fully reserved items,
and the unknown-SKU error. The workspace stays within the existing journal,
router, reducer and Docker leases.

The existing poll loop starts a supervised demo task after independent
review. Gemini chooses the order, pointer emphasis and result hold for two
captures. A trusted local executor opens requests in Bruno, records its
actual window with the cursor, checks each capture and uses the Linear
upload API. The executor's authority comes from the workflow configuration.
The model may choose only the allowed presentation controls and receives no
tracker credential, command arguments or file paths. The executor passes
only private asset URLs and the SHA-256 of the reviewed diff to the daemon.

The daemon rechecks the issue and the diff and sends one Linear update with
the demo links, reproducible cURL, test evidence and Human Review status.
When demo execution fails, the ticket remains eligible for manual inspection.
A restart observes attempted review updates and never repeats the native
capture or uploads automatically.

## Alternatives and consequences

- **Record a custom API viewer.** Bruno shows the exact client interaction
  and is the chosen tool for repositories without an existing Hoppscotch
  collection. Corporate Hoppscotch requests are outside this local fixture.
- **Give the model direct shell and desktop access.** The demo needs only a
  bounded plan and a trusted executor. Keeping those distinct limits the
  visible and writable desktop surface and makes the handoff testable.
- **Publish the ticket before recording.** Reviewers would see the state
  before the required evidence. The review projection waits for both clips.

The authenticated run reached Human Review on the scoped Linear Cloud issue.
The two recordings captured an available item with HTTP 200 and an unknown
SKU with HTTP 404. The executor read back the privately uploaded bytes, and
an independent Linear read confirmed both links, matching cURL commands and
four passing HTTP checks beside the reviewed diff.

[Linear private uploads](https://linear.app/developers/how-to-upload-a-file-to-linear) ·
[Pilot instructions](../elixir/README.md#stockroom-api-and-bruno-pilot)
