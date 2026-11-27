# Symphony TUI

The terminal console is a read-only client for the local Symphony daemon. It
shows the active, retrying, and blocked tickets returned by the daemon, plus
recent events for the selected ticket. Provider cards identify workers when
the daemon reports their provider. Quota and token figures reflect reported
Codex data.

## Run

With Go 1.26 or later, run this from the repository root while the daemon's
observability endpoint is available on loopback.

```sh
cd tui
go run . -url http://127.0.0.1:4000
```

Use the unauthenticated endpoint for synthetic or shareable data. The client
uses two local GET endpoints and retries with backoff when the daemon is
unreachable. The last successful snapshot stays on screen with a stale
indicator. Closing the console with `q` leaves Symphony running.

## Original provider art

Place original PNG assets you may use locally in
`symphony-tui/assets` under the operating system's user config directory.
Use `-assets /path/to/assets` to select a different directory.

| PNG | Representation |
| --- | --- |
| `codex.png` | One frame of the original Codex pet |
| `claude.png` | The original Clawd artwork |
| `antigravity.png` | The official Antigravity icon |

Optional animation strips go in the same directory. A strip contains two to
eight square PNG frames on a single horizontal row, in playback order.
Each cell is at most 224 pixels. Add `-work.png` for running sessions,
`-review.png` for review states, and `-rest.png` when no session is running.
The prefix matches the still image, for example `codex-work.png`.
Missing review strips use the work strip. Missing work and rest strips
use a quick lift and slow breathing movement, respectively.

Ghostty and Kitty use native PNG graphics in the alternate screen. Other
terminals, multiplexers and inline mode use crisp terminal color cells.
Use `-graphics cells` to select the cell renderer explicitly. Providers
without a readable asset use text labels.

Work and rest loop from the first connected snapshot. An unchanged
poll leaves the current loop running. Work uses a livelier cadence and
rest uses a slower one. The surrounding text stays in place. Artwork
holds still while disconnected and resumes from the current state after
reconnecting. The [terminal design](../docs/personal-symphony-tui.md)
records asset provenance and the wider console scope.

`NO_COLOR=1` selects monochrome. `-ascii` selects monochrome and ASCII
interface markers. Use `-no-motion` for static indicators,
`-no-alt-screen` for inline output, and `-theme light` or `-theme dark`
to override automatic color detection.

## Navigate

Use `1`, `2`, and `3` for Queue, Agents, and Timeline. In Queue, use
`j/k` or the arrow keys to select tickets, `Enter` to focus the inspector,
and `/` to filter by identifier, state, status, or provider. Press `Esc`
to return to the queue or clear an active filter. Press `?` for help.

## Verify

```sh
go test -race ./...
go vet ./...
go build .
```
