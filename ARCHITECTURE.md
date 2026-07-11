# Architecture

BoidPlace is a Roblox Luau project for simulating and rendering large boid flocks. The server owns simulation state, partitions boids into spatial cells, schedules cell updates across parallel Actors, serializes compact snapshot packets, and sends those packets to clients. Clients instantiate visual boid models and smooth incoming snapshots for rendering.

The project is performance-oriented. Most hot-path state is stored in Roblox `buffer` objects, boids are grouped into fixed-size pages, positions and velocities are quantized, and scheduling uses heap-backed priority queues.

## Repository Layout

- `Test.server.luau` is the current stress-test entry point. It waits for a player, creates several boid groups, populates them with thousands of boids, periodically changes targets, and prints benchmark stats on shutdown.
- `ActorsManager.luau` creates a fixed pool of Roblox `Actor` instances and clones parallel worker scripts into them.
- `BoidsSystem/PackageBootstrap.server.luau` moves package folders into their runtime locations: `BoidsClient` goes to `StarterPlayer.StarterPlayerScripts`, and `BoidsReplicated` goes to `ReplicatedStorage`.
- `BoidsSystem/Boids` contains the server-side simulation orchestration, batching, scheduling, and parallel worker code.
- `BoidsSystem/BoidsClient` contains the client renderer and network snapshot consumer.
- `BoidsSystem/BoidsReplicated` contains shared types, quantization helpers, packed boid storage, and network packet serialization.
- `Libraries` contains general-purpose support modules such as binary heaps, benchmarkers, and object pooling.

## Runtime Placement

The package expects different folders to live in different Roblox services at runtime:

- Server modules are required from `ServerScriptService`, especially `ServerScriptService.BoidsSystem.Boids`.
- Shared modules are moved to `ReplicatedStorage.BoidsReplicated` so both server and client code can require the same type and serialization contracts.
- Client code is moved to `StarterPlayer.StarterPlayerScripts` so `BoidsUpdater.local.luau` runs for each player.
- Parallel job workers are cloned under Actors by `ActorsManager.MultiThreadModule`.

Several modules use runtime queries or typed casts that assume this placement. For example, `ActorsInitializer.luau` finds the actors manager through `ServerScriptService:QueryDescendants(">> .actors-manager-module")`, and client code types `BoidsReplicated` by peeking at the server-side source tree.

## Server Simulation API

`BoidsSystem/Boids/init.luau` is the main server module. Its public surface is:

- `newGroup(defaultBoidModel)` creates a group with its own active cells, scheduler, stats batcher, boid counts, average sight, and benchmarker.
- `destroyGroup(group)` removes the group from scheduling and tells clients to delete its rendered boids.
- `newBoid(group, position, velocity, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias, model)` allocates a boid id, batches static boid stats, inserts the boid into the correct spatial cell, and updates group averages.
- `setTarget(group, target, debugs)` broadcasts a target to every worker Actor and optionally creates a debug target part.

The server stores each group as a collection of active cells. Each cell has:

- A stable numeric cell id derived from its grid origin.
- An origin aligned to `Quantization.CELL_SIZE` (`128` studs).
- A `PagedBuffer` containing packed boid rows.
- Network tick fields used to decide how often snapshots are emitted.
- An optional visualizer model for debug cell outlines.

## Spatial Storage

`BoidsSystem/BoidsReplicated/BoidStorage.luau` owns the packed storage format used by the simulation.

Each boid row is `16` bytes:

- `u16 boidId`
- `u8 posX`, `posY`, `posZ` as local cell position
- `u8 velX`, `velY`, `velZ` as normalized direction
- `u8 speed`
- `u16 lastTick`
- `u8 pathNode`
- `u8 pathVersion`
- padding to `16` bytes

Rows are grouped into `Page` objects with `64` slots. A `PagedBuffer` tracks its pages, open pages, and pages temporarily marked pending while a worker owns them. Deleted rows are tracked with a `dead` bitset so slots can be reused without compacting every frame.

`BoidStorage.BoidRegistry` maps boid ids back to page, slot, and cell id. The current public `deleteBoid` path in `Boids/init.luau` is still a TODO, but lower-level deletion helpers exist in `BoidStorage`.

## Scheduling Model

Scheduling is implemented in `BoidsSystem/Boids/Scheduler.luau` with a heap-backed generic scheduler. A `Schedulee` wraps an entity with:

- `lastUpdated`
- `nextDue`
- `interval`
- `alreadyScheduled`
- `heapVersion`

The scheduler uses lazy invalidation: pushing a newer heap node increments `heapVersion`, and stale heap nodes are discarded when they reach the top. This keeps updates cheap and avoids removing arbitrary heap entries.

There are two scheduler levels:

- A global group scheduler chooses which group has cells ready for work.
- Each group has a cell scheduler that chooses due cells within that group.

Cells are eligible when they are non-empty, not already assigned to a worker, and their wake time has arrived. Cell cost is currently `max(boidCount, 1) ^ 2`, reflecting the neighbor-search cost of dense cells.

## Parallel Worker Flow

`ActorsManager.luau` creates `8` Actors. `BoidsSystem/Boids/ActorsInitializer.luau` clones `Boids/Parallelized/JobHandler.server.luau` into those Actors and tracks per-actor state:

- `ready`
- `targetJobWork`
- `avgMsPerWorkUnit`
- `lastJobMs`

On every heartbeat, `Boids/init.luau` assigns work to ready actors:

1. Pick a group with due cells.
2. Build a `Job` by taking due cells until the actor's target work or the frame boid budget is reached.
3. Mark selected cells as scheduled and mark their open pages pending.
4. Send the job to an Actor using `SendMessage("NewJob", job, bindableEvent)`.
5. Wait for the worker to return job results through the `BindableEvent`.
6. Update actor performance estimates from measured job time.
7. Merge returned cell buffers, moved boids, and network snapshot packets.
8. Release or complete scheduled cells.

If a job does not return within `5` seconds, the original cells are released so they can be scheduled again.

## Boid Integration

`BoidsSystem/Boids/Parallelized/JobHandler.server.luau` performs the hot simulation work inside `BindToMessageParallel("NewJob", ...)`.

For every job cell, the worker:

- Reads live boids from each page using `BoidStorage.liveWords`.
- Builds temporary arrays of ids, positions, velocities, last ticks, path metadata, page references, and slots.
- For dense cells, builds spatial buckets to reduce neighbor scans.
- Applies separation, alignment, cohesion, target bias, and repulsion from other boids.
- Clamps acceleration and speed.
- Advances local position using quantized simulation ticks.
- Moves boids crossing cell boundaries into `job.movedBoids`.
- Writes updated rows back into the page buffer.
- Emits network snapshots for cells whose `networkTick` reaches `networkInterval`.

Workers also receive `NewBoidsStatsBatch` messages containing static boid parameters and `NewGroupTarget` messages containing group targets.

## Networking

The project uses two packet streams:

- `NewBoidBatch` is a reliable `RemoteEvent` that tells clients about newly created boids, their ids, and which model type to clone.
- `BoidJobUpdate` is an `UnreliableRemoteEvent` that sends compact position and velocity snapshots generated by completed simulation jobs.

`BoidsSystem/Boids/BoidBatches.luau` batches static boid stats in `16` byte rows. Batches are sent to workers so they can simulate each boid, and a smaller network batch is sent to clients so they can instantiate models.

`BoidsSystem/BoidsReplicated/NetworkResults.luau` converts per-cell snapshots into packet buffers. Each packet contains one or more cell chunks:

- Cell header: quantized cell origin and boid count.
- Boid rows: `u16 boidId`, three local position bytes, and three velocity bytes.

Packets are capped by `MAX_PACKET_BYTES`, currently calculated from a conservative unreliable-remote budget.

## Client Rendering

`BoidsSystem/BoidsClient/BoidsUpdater.local.luau` owns client-side rendering.

When it receives `NewBoidBatch`, it:

- Creates or reuses a per-group folder under `workspace.BoidFolder`.
- Clones the requested model from `script.Parent.BoidModels`.
- Colors boids by group.
- Registers each boid into dense render arrays.

When it receives `BoidJobUpdate`, it:

- Iterates cell headers and boid rows with `NetworkResults.forEachCellHeader` and `NetworkResults.forEachBoid`.
- Dequantizes local positions and velocities.
- Stores the latest server snapshot for each boid.

On every `RenderStepped`, it:

- Sends the camera CFrame to the server once per second through `CameraUpdate`.
- Applies basic level-of-detail by spacing out render updates for far boids.
- Skips boids outside the camera view.
- Predicts server position from the latest snapshot and corrects local render state toward it.
- Updates all rendered parts with one `workspace:BulkMoveTo` call.

## Shared Contracts

`BoidsSystem/BoidsReplicated/SharedTypes.luau` defines cross-boundary data shapes: pages, paged buffers, jobs, job cells, snapshots, boid packets, network batches, targets, and boid model ids.

`BoidsSystem/BoidsReplicated/Quantization.luau` centralizes:

- Cell size and grid conversion.
- Position and velocity quantization/dequantization.
- Simulation tick wrapping at `60` Hz.
- Numeric cell-key generation for signed grid coordinates.

Because server, worker, and client code all interpret the same buffers, changes to these shared modules are architecture-sensitive. Any row layout, packet layout, cell size, or tick-rate change must be reflected across all readers and writers.

## Support Libraries

- `Libraries/BinaryHeaps/init.luau` is a buffer-backed binary heap used by schedulers and benchmark utilities.
- `Libraries/BinaryHeaps/LazyHeaps/init.luau` wraps binary heaps with lazy invalidation.
- `Libraries/BinaryHeaps/LazyHeaps/SlidingHeaps.luau` tracks a sliding window of values with heap semantics.
- `Libraries/Benchmarker/init.luau` computes rolling average, median, min, max, standard deviation, and optional stale counts using lazy heaps and buffers.
- `Libraries/ObjectPooling.luau` provides a named object pool based on constructor functions and CollectionService tags. It is present but not used by the current boid system.

## Current Limitations And Notes

- `Boids.destroyGroup` notifies clients but does not explicitly free every underlying boid id or page registry entry.
- `Boids.deleteBoid` is currently a placeholder.
- `CameraUpdate` is sent by the client, but no server-side consumer is present in the current files.
- `BoidStorage.removePage` and some debug/visualization paths exist but are not central to the current runtime flow.
- Several modules contain commented profiling and debugging blocks. These are useful for understanding intended diagnostics but are not active behavior.
