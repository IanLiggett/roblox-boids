# Renderer maintenance contracts

Ownership and startup

- BoidsClient.BoidsRenderer is the sole inert-on-import facade. ClientSimulation.Start starts CameraReporter, calls Renderer.Start(callback, renderOptions?), binds ClientRendererBridge, then starts simulation and replicated intake. Both client entry points supply the same Testing-resolved render configuration.
- Renderer options contain a session-fixed actorCount, default 8, integer 1–32. The renderer owns a separate fixed pool under PlayerScripts.BoidsRenderActors; simulation Actors and their full-job transport are unchanged. Only explicitly enabled clones of the disabled Worker template run.
- The facade owns models/Motors, live registry/group metadata, snapshot acceptance, the global cell scheduler, and optional client query-index lifetime. Each boid lifetime has stable shard ownership (id % actorCount) + 1. Shards own dense packed smoothing state, local slot compaction, mirrored cell fragments, scratch and CFrame arrays.
- No SharedTables, writable cross-Actor ordinary table assumptions, alternate renderer, fallback pool, or restart framework exist.

Ingress and transport

- ClientRendererBridge retains synchronous local lifecycle and cell-buffer delivery; NetworkResults.LocalDelivery does not copy/repacketize the canonical rows at that boundary.
- After accepting rows, the facade coalesces the latest input per live renderer lifetime. The correction interval comes from consecutive accepted source timestamps, even if intermediate samples are coalesced.
- One dense frame message per participating shard carries topology changes, packed changed-input rows, cell-fragment range grants, epoch identity, common render time, and instrumentation enablement. No persistent smoothing state or recurring calculated pose array crosses Actors.
- Types owns the internal protocol. Kernel owns the existing 96-byte packed smoothing equations. Shard owns storage operations and calculation/commit operations; Worker owns Actor execution and terminal acknowledgement.
- A worker computes against ordinary local buffers in parallel, synchronizes, assigns its local Motor6D.Transform values without yielding, then publishes its Actor CommittedEpoch marker and terminal reply.

Scheduling and lifetime

- Snapshot positions assign dense 64-stud render cells, independently of the unchanged 128-stud simulation/query cells. Each cell holds mirrored per-shard dense fragments.
- Scheduler grants contiguous fragment ranges under one global attempted-boid cap. Keep visible/offscreen bands, peripheral scaling, near-first ordering, partial-fragment resume, and bounded aging round-robin work before normal work. Never grant an already-selected slot twice within an epoch.
- Only one render epoch is in flight. Topology is frozen through settlement; incoming changes coalesce for the next epoch. Completed cells are rescheduled only after successful settlement, using the epoch's common render timestamp plus the interval. Acknowledgement latency must not lengthen the intended cadence.
- Deletion immediately removes public visibility, original Motors/models, and query entries. Pending topology changes do not keep deleted lifetimes visible. Renderer-local lifetime identity, exact Motor references, epoch checks, and external lifecycle tombstones protect reused IDs/groups.
- Startup waits for readiness. Failures stop the renderer and surface RenderFailure. Missing terminal acknowledgement never permits reuse; the five-second watchdog does not prove physical completion.
- A rejected spawn batch cannot recreate an empty group. Unknown/pre-spawn snapshots cannot seed timestamps. Stale/equal snapshots do not replace accepted input.

Representation and reconciliation

- Rendered models remain under workspace.BoidFolder with BoidId attributes. Their Parts remain non-queryable, non-colliding, and non-touching. Physics world queries are not a boid-query path.
- Each boid remains Motor6D.Part1, with the invisible anchored identity-space BoidRoot as Part0. A one-time HasRendered marker distinguishes first submission; no per-boid per-frame attributes are published.
- Motor6D.Transform is the latest submitted offset; engine application is deferred. Pose reads and client queries use that submitted pose, matching the previous renderer's calculated-pose semantics.
- Kernel preserves facing-first no-snap correction: turn toward the smoothed target, then move only along facing. Never directly place at authoritative snapshots, snap orientation, or introduce sideways/backward correction.

Gameplay queries

- The facade retains synchronous RaycastBoids/GetBoidsInRadius and copied result shapes. Client-query mode is captured at startup; set it before startup. QueryIndexConfig caches its first read, so a later replicated attribute does not repair an early cached default.
- With indexing enabled, committed grants are traversed against current lifetime identity to update the index from Motor transforms. Public queries check each pending shard's CommittedEpoch marker and catch up idempotently if its reply has not arrived.
- Lazy seeding and immediate deletion remain. With indexing disabled there is no recurring transform-read/index-maintenance pass. Hosts receive no writable index ownership.

Observation

- GetRenderedBoidPose returns copied boidId/groupId/cframe/isRendered synchronously in O(1). It does not expose velocity or pretend that read time is update time.
- RequestRenderedBoidSample is cancellable and asynchronous. It returns a copied internally consistent CFrame/velocity/renderedAt/snapshotAt/sample-time/lifetime record after active worker calculation commits. It does not export all boid state each frame.
- RequestRenderedGroupAge returns a cancellable asynchronous reduction of selected-group render ages. GetRenderedGroupBounds traverses only the requested group's submitted poses on demand; its sampledAt is the bounds read time, not an oldest-render timestamp.
- Camera follows live poses each frame and samples selected details at 4 Hz. Group bounds/ages use 2 Hz. Picking traverses submitted poses only on demand and ignores world geometry. Group counts/colors are maintained at lifecycle boundaries.
- Selection/session/request generations and lifetime identity reject obsolete replies. Pending/unavailable age is explicit. The inspector keeps matching copied samples; observer reads never advance simulation or render state.
- Pair raw GetMouseLocation with ViewportPointToRay; preserve GUI/top-bar exclusions and existing handoff cleanup.

Instrumentation

- Measurements owns opt-in copied counters. Frame samples and completed epochs are separate. Renderer elapsed time includes scheduling/transport/synchronization/acknowledgement delay; parallel worker sums are work volume, not CPU percentages or critical-path duration.
- Worker input/kernel/synchronization/assignment totals, coordinator time, delta-buffer payload bytes, message count, and processed boids are separate. Reset revisions reject old in-flight measurements.
- Testing.RendererBenchmark owns enable/reset attributes and Workspace exports. BoidBenchmarkRenderActorCount is resolved only by Testing before startup; generic runtime does not interpret scenarios or test attributes.
- Profile prepare/dispatch/input/calculate/assign/query-index scopes and the engine's later Motor batch separately. Native annotations alone do not establish native execution.
