# ADR 0004 · Deterministic routing with scoped profiles

- Proposed · November 26, 2026

## Decision

Use explicit candidate capabilities and a deterministic router before adding
a learned policy. The router consumes normalized task facts, project policy,
capacity observations and session bindings. It returns an eligible decision
or a typed wait reason. The orchestrator reserves slots at dispatch. Measure
all attempts and retain the basis for manual overrides. The classifier may
resolve semantic ambiguity once per requirements revision. Permissions and
routing stay in the engine.

Enroll provider auth through native mechanisms. Keep account scope, rate limits
and time windows in native units. Rebind credentials through an operator action
when required. Preserve session affinity and use validated handoffs at
provider boundaries. Apply circuit breakers at the observed failure scope.
Roll out one verified profile per provider, then expand only where authenticated
isolation and policy are demonstrated.

## Alternatives and consequences

- **Fixed provider per tracker state** provides a useful baseline and remains
  available in existing workflows. It cannot account for model abilities,
  session continuity or independent review on its own.
- **An LLM router on every dispatch** supplies semantic flexibility and adds
  latency, cost and another failure point for tasks with clear facts.
- **Fully adaptive selection from day one** needs verified outcome labels and
  comparable samples. Begin in shadow mode and evaluate changes against a
  Codex-only baseline before promotion.
- **Common quota pool or profile rotation** hides provider, identity and billing
  constraints. Keep dispatch, capacity signals and permitted fallback explicit.

Keep the selector behind the opt-in execution boundary. Add fixtures for
deterministic ties, stale observations, cooldown, restricted model effort,
concurrent reservations, a rejected override and absent telemetry. The
existing provider-state map remains the rollback mode. No additional scheduler
or auth-proxy service is required for the first slice.

[Routing and phase design](personal-symphony-design.md#agent-router) ·
[Provider capabilities](personal-symphony-providers.md)
