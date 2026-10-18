# BoidsSystem architecture

BoidsSystem owns reusable simulation, rendering, replication, queries, Scenarios, tests, and developer observation. Hosts own combat, damage, timed gameplay effects, character controls, and policy. The package must not require a host game's modules.

## Runtime and data

PackageBootstrap moves BoidsReplicated into ReplicatedStorage and BoidsClient into StarterPlayerScripts; server orchestration stays in ServerScriptService.BoidsSystem. Both processes use the same WorkerCore. BoidStorage/SharedTypes describe packed data separately from systems operating on it.

Boids is one process-local coordinator, configured explicitly before groups are created. Imports do not create pools, render roots, or background work. JobBuilder selects work, ActorsInitializer.JobExecution owns reservation/completion, and ResultCommit merges settled results. Cells owns cell lifetime; Scheduler remains cell-based. Timeout does not prove worker completion or permit premature Actor reuse.

## Replication, rendering, and queries

SimulationReplication owns authoritative lifecycle/group state and reliable bootstrap. NetworkResults preserves correction source time and direct local-buffer delivery. Corrections steer simulation, not direct renderer placement. The renderer turns toward its smoothed target and moves along facing without snapshot/orientation snaps.

Server.BoidQueryIndexServer owns authoritative index lifetime and copied queries. Client queries and rendered-pose reads are package-owned too. Hosts consume results without acquiring mutable storage/index ownership. Diagnostics expose values, not scheduling authority.

## Scenarios and hosts

Registry selects configuration and owns one-session orchestration; Catalog owns definitions and Fixtures owns generated world resources. Testing owns reporting/benchmark policy outside simulation calculations. Host launchers explicitly call server/client scenario startup modules; the standalone project supplies character-free launchers.

Observation owns authorization, session identity, selected sampling, camera/dock, and streaming resources. It receives typed host suspension hooks before registration instead of locating a game's controls. Server hooks suspend authoritative input; client hooks suspend local control presentation. Returned cleanup belongs to observation lifetime. Hooks may be absent when there are no host controls.

Scenarios and observation stay package-owned but outside Boids/WorkerCore calculations. Diagnostics and camera modes never author simulation state or change scheduling/reconciliation. AGENTS routes detailed editing contracts; humans do not need historical plans to understand this design.
