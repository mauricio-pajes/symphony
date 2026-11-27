# ADR 0006 · Local container leases for internal phases

- Implemented for the synthetic pilot · November 26, 2026

## Context

The internal phase engine needs a reliable boundary between work in a
workspace and permission to hand that workspace to the next phase. On
macOS a descendant of a headless command survived the BEAM process that
started it. A BEAM task exit or a check of the command's root PID cannot
prove that the workspace is safe to give to another writer.

## Decision

Use the local Docker Engine as a process boundary for synthetic internal
phases. Connect over an explicitly selected Unix socket using the existing
Req dependency. Scope the durable identity to the engine and the full
container ID, and verify that the container label binds it to the workspace
root and run, boot and attempt generation.

1. The scheduler resolves the phase, binds its routing request to the
   admitted physical workspace and selects an eligible profile.
2. It persists a reservation, creates a stopped container and attaches the
   engine and container identity to the journal.
3. It hands the attached lease to one supervised task. The task starts the
   container and observes its exit status. The scheduler owns the journal.
4. The scheduler checks the binding, removes the container and verifies
   absence on the same engine. It then asks a trusted verifier to check the
   workspace evidence, applies the reducer and persists the disposition.
5. On cancellation or restart, the scheduler can reconcile an attached
   lease and park the run. Ambiguous creation without a recorded container
   ID requires trusted reconciliation. A changed or unavailable engine
   retains the lease until the correct engine can settle it.

The command is built by trusted host code from a locally present image
pinned by SHA-256 ID. The container gets a single non-recursive workspace
mount, writable only for implementation. It runs as the workspace's
non-root owner with networking disabled, a read-only root, bounded memory
and process count, and an ephemeral temporary directory. Docker
configuration, the Docker socket, tracker credentials and the state
directory stay on the host. The runtime rejects images with implicit
volumes. Commands must come from the trusted execution profile.

The trusted Docker engine, local socket and workspace provisioning are
deployment assumptions. Only one scheduler can own a journal across BEAM
instances. Provision scope and authentication separately before any real
project work. Production scheduling still uses the existing tracker-driven
path. This extension supplies the internal scheduler boundary and a local
fixture to prove it.

## Alternatives and consequences

- **Wait for the task's exit or stop its process group.** This keeps host
  requirements minimal. It cannot prove that every descendant stopped
  writing when the host BEAM fails or a descendant starts a new session.
- **Use a persistent worker service or a remote scheduler.** These can
  enforce a stronger deployment boundary. For the first local pilot they
  introduce another owner and an operational dependency.
- **Limit the local pilot to a container runtime.** This makes a whole
  process boundary verifiable without adding transport or dependencies to
  the existing runner. It requires a Linux engine and a trusted image.

The fixture runs four scoped phases with deterministic provider profiles,
checks the writer and reader mounts, and verifies that Human Review stays
parked after reopening the journal. A second fixture times out and kills an
independent BEAM process while a container descendant remains active. A new
boot is unable to reserve a writer until the old container is drained.
The fixture uses BusyBox commands and synthetic artifacts. Authenticated
provider execution and external tracker effects require their own gates.

[Docker Engine API v1.47](https://docs.docker.com/reference/api/engine/version/v1.47/) ·
[Docker container removal](https://docs.docker.com/reference/cli/docker/container/rm/) ·
[Durable admission design](adr-0003-internal-workflow.md)
