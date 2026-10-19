# BoidsSystem architecture

BoidsSystem owns reusable simulation, rendering, replication, queries, Scenarios, tests, and developer observation. Hosts own combat, damage, timed gameplay effects, character controls, and policy. The package must not require a host game's modules.

## Runtime and data

PackageBootstrap moves BoidsReplicated into ReplicatedStorage and BoidsClient into StarterPlayerScripts; server orchestration stays in ServerScriptService.BoidsSystem. Both processes use the same WorkerCore. BoidStorage/SharedTypes describe packed data separately from systems operating on it.

Boids is one process-local coordinator, configured explicitly before groups are created. Imports do not create pools, render roots, or background work. JobBuilder selects work, ActorsInitializer.JobExecution owns reservation/completion, and ResultCommit merges settled results. Cells owns cell lifetime; Scheduler remains cell-based. Timeout does not prove worker completion or permit premature Actor reuse.

JobBuilder dispatches earliest-due cell work using free Actor capacity rather than simulation-kind boid quotas. Its DispatchPump shares a 1 ms coordinator allowance across Heartbeat, safe Actor release, and a single next-due timer. JobExecution notifies availability only after result settlement and physical reuse are safe. WorkerCore owns mutable scratch per invocation; cells within a job may reuse it, but jobs do not share scratch.

## Replication, rendering, and queries

SimulationReplication owns authoritative lifecycle/group state and reliable bootstrap. NetworkResults preserves correction source time and direct local-buffer delivery. Corrections steer simulation, not direct renderer placement. The renderer turns toward its smoothed target and moves along facing without snapshot/orientation snaps.

BoidsRenderer owns one global cell scheduler, presentation lifetimes and the optional client query index. A separate fixed render Actor pool owns persistent shard-local smoothing buffers and CFrame arrays. Accepted input changes and cell-fragment grants cross Actors; calculated pose arrays do not. Workers calculate in parallel and synchronize to submit their own Motor6D transforms. One epoch remains in flight until terminal settlement; deleted lifetimes are immediately hidden and original Motor references cannot affect replacements. Synchronous queries catch up from committed Motor transforms using per-Actor epoch markers. Live observer poses are synchronous; internal motion samples and group age reductions are requested asynchronously. No SharedTables or alternate renderer are retained.

Boid IDs share all 65,536 u16 slots in each process. The coordinator allocates server IDs from the lowest free slot and client-local IDs from the highest, using hierarchical free bitmaps. Reliable client intake reserves server IDs even while commands are queued. A collision retires the local boid through normal settlement before creating the server replica; surviving IDs never change. Group IDs retain their server/client partition. Ownership is explicit, never inferred from a boid ID's numeric range.

Server.BoidQueryIndexServer owns authoritative index lifetime and copied queries. Client queries and rendered-pose reads are package-owned too. Hosts consume results without acquiring mutable storage/index ownership. Diagnostics expose values, not scheduling authority.

## Scenarios and hosts

Registry selects configuration and owns one-session orchestration; Catalog owns definitions and Fixtures owns generated world resources. Testing owns reporting/benchmark policy outside simulation calculations. Host launchers explicitly call server/client scenario startup modules; the standalone project supplies character-free launchers.

Observation owns authorization, session identity, selected sampling, camera/dock, and streaming resources. It receives typed host suspension hooks before registration instead of locating a game's controls. Server hooks suspend authoritative input; client hooks suspend local control presentation. Returned cleanup belongs to observation lifetime. Hooks may be absent when there are no host controls.

Scenarios and observation stay package-owned but outside Boids/WorkerCore calculations. Diagnostics and camera modes never author simulation state or change scheduling/reconciliation. AGENTS routes detailed editing contracts; humans do not need historical plans to understand this design.
