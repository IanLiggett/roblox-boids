# BoidsSystem architecture

BoidsSystem owns reusable simulation, rendering, replication, queries, Scenarios, tests, and developer observation. Hosts own combat, damage, timed gameplay effects, character controls, and policy. The package must not require a host game's modules.

## Runtime and data

PackageBootstrap moves BoidsReplicated into ReplicatedStorage and BoidsClient into StarterPlayerScripts; server orchestration stays in ServerScriptService.BoidsSystem. Both processes use the same WorkerCore. BoidStorage/SharedTypes describe packed data separately from systems operating on it.

Boids is one process-local coordinator, configured explicitly before groups are created. Imports do not create pools, render roots, or background work. JobBuilder selects work, ActorsInitializer.JobExecution owns reservation/completion, and ResultCommit merges settled results. Cells owns cell lifetime; Scheduler remains cell-based. Timeout does not prove worker completion or permit premature Actor reuse.

JobBuilder dispatches earliest-due cell work using free Actor capacity rather than simulation-kind boid quotas. Its DispatchPump shares a 1 ms coordinator allowance across Heartbeat, safe Actor release, and a single next-due timer. JobExecution notifies availability only after result settlement and physical reuse are safe. WorkerCore owns mutable scratch per invocation; cells within a job may reuse it, but jobs do not share scratch.

## Replication, rendering, and queries

NetworkResults.ServerTransport owns per-recipient last-sent prediction baselines and error-based network LOD. Workers return packed candidates for interested cells; after complete merge, the coordinator compares each decoded row once across recipients and queues only position/velocity errors beyond distance-selected thresholds. This adds a measured completed-row traversal, never a full-population storage scan. Baselines use quantized wire state and advance only on FireClient. A mode/preset-configured per-boid/per-recipient minimum send interval bounds correction frequency using actual send time; pending corrections keep their original source time and newest-state coalescing/cancellation during cooldown. Unreliable loss is accepted without recovery; pending rows coalesce by ID, and deletion/disconnect clear their state. LODConfig owns separate simulation/renderer network profiles per quality preset, selected through GetNetworkConfig using startup presentation mode and the current quality preset. The transport retains per-client token caps and homogeneous source-time packets.

SimulationReplication owns authoritative lifecycle/group state and reliable bootstrap. The startup-only `BoidClientPresentationMode` selects either client simulation with network corrections or direct network-packet rendering; the default is `simulation`. Direct renderer mode retains reliable lifecycle handling but starts no client Actors or simulation job scheduler. It is incompatible with client-only `BoidSimulationMode`. NetworkResults preserves correction source time and direct local-buffer delivery. Both snapshot paths use renderer stale-time acceptance and the no-snap facing-first reconciliation rule. Simulation corrections remain packed through the coordinator and cross each Actor boundary once; Actor-local parallel handlers own single-pass decoding, stable targets and lifecycle/source ordering. Stats carry group ownership, and scalar lifetime ceilings fence corrections forwarded before ID creation. Worker/job divergence aggregates replace the coordinator correction mirror, without adding another per-boid scan. All worker batch and control message handlers execute in parallel.

Boid IDs share all 65,536 u16 slots in each process. The coordinator allocates server IDs from the lowest free slot and client-local IDs from the highest, using hierarchical free bitmaps. Reliable client intake reserves server IDs even while commands are queued. A collision retires the local boid through normal settlement before creating the server replica; surviving IDs never change. Group IDs retain their server/client partition. Ownership is explicit, never inferred from a boid ID's numeric range.

Renderer cell lists are partitioned by replica/local ownership. Binary cell-level distance visibility skips fully transparent membership work; camera culling immediately suspends offscreen scheduling without changing opacity or traversing members. Both retain snapshot/lifecycle intake and cached observation poses. Distance visibility transitions share the render budget and cap Instance transparency writes separately; client hit indexing excludes fully transparent rows.

Server.BoidQueryIndexServer owns authoritative index lifetime and copied queries. Client queries and rendered-pose reads are package-owned too. Hosts consume results without acquiring mutable storage/index ownership. Diagnostics expose values, not scheduling authority.

## Scenarios and hosts

Registry selects configuration and owns one-session orchestration; Catalog owns definitions and Fixtures owns generated world resources. Testing owns reporting/benchmark policy outside simulation calculations. Host launchers explicitly call server/client scenario startup modules; the standalone project supplies character-free launchers.

Observation owns authorization, session identity, selected sampling, camera/dock, and streaming resources. It receives typed host suspension hooks before registration instead of locating a game's controls. Server hooks suspend authoritative input; client hooks suspend local control presentation. Returned cleanup belongs to observation lifetime. Hooks may be absent when there are no host controls.

Scenarios and observation stay package-owned but outside Boids/WorkerCore calculations. Diagnostics and camera modes never author simulation state or change scheduling/reconciliation. AGENTS routes detailed editing contracts; humans do not need historical plans to understand this design.
