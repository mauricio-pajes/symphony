# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

This fork can also [read Jira links from a personal Linear queue and route phases to different agents](elixir/README.md#personal-linear-queue-with-jira-intake-and-multiple-agents).
The independent [terminal console](tui/README.md) reads the running daemon's queue and session snapshots.
The [Linear-to-Human-Review pilot](elixir/README.md#synthetic-linear-to-human-review-pilot) exercises the daemon and its isolated internal phases. Its [authenticated modes](elixir/README.md#authenticated-multi-agent-pilot) publish a verified test-repository diff, check results and, in multi-agent mode, the Gemini plan and Claude Code review on a scoped Linear issue with simulated Jira requirements.

The [Stockroom example](elixir/README.md#stockroom-api-and-bruno-pilot) adds an API-only work item and runs the demo in Bruno as part of the orchestration.
The [container fixture](elixir/README.md#isolated-internal-phase-fixture) covers workspace recovery.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
