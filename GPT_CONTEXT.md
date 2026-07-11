# GPT Context

BoidPlace is a Roblox Luau project for large-scale boid simulation. The core idea is: the server simulates boids in spatial cells, parallel Actor workers process scheduled cell jobs, shared replicated modules define storage and network formats, and clients render smoothed snapshot updates.

The codebase is small, but the data flow is dense. Most important behavior is in `BoidsSystem/Boids`, `BoidsSystem/BoidsReplicated`, and `BoidsSystem/BoidsClient`.

## What To Read First

Start with these files for a high-level understanding:

1. `BoidsSystem/Boids/init.luau`
2. `BoidsSystem/Boids/Parallelized/JobHandler.server.luau`
3. `BoidsSystem/BoidsReplicated/SharedTypes.luau`
4. `BoidsSystem/BoidsReplicated/BoidStorage.luau`
5. `BoidsSystem/BoidsClient/BoidsUpdater.local.luau`

`README.md` currently only contains the project name, so it is not a useful architecture source.

## Project Organization

- `Test.server.luau` creates stress-test groups and boids.
- `ActorsManager.luau` creates a fixed pool of `8` Actors and clones worker scripts into them.
- `BoidsSystem/PackageBootstrap.server.luau` moves client and replicated folders into Roblox runtime services.
- `BoidsSystem/Boids/init.luau` is the server API and scheduler loop.
- `BoidsSystem/Boids/ActorsInitializer.luau` initializes worker Actor state.
- `BoidsSystem/Boids/Scheduler.luau` provides the heap-backed generic scheduler.
- `BoidsSystem/Boids/BoidBatches.luau` batches static boid stats for workers and client spawn data.
- `BoidsSystem/Boids/Parallelized/JobHandler.server.luau` runs flocking simulation inside Actors.
- `BoidsSystem/BoidsClient/BoidsUpdater.local.luau` receives snapshots, instantiates models, and renders boids.
- `BoidsSystem/BoidsReplicated` contains shared contracts, storage, quantization, and network packet logic.
- `Libraries` contains generic support code.

## For Architecture Questions

Read:

- `ARCHITECTURE.md`
- `BoidsSystem/Boids/init.luau`
- `BoidsSystem/Boids/Parallelized/JobHandler.server.luau`
- `BoidsSystem/BoidsReplicated/SharedTypes.luau`

Key concepts:

- Groups contain active spatial cells.
- Cells contain paged buffers of packed boid rows.
- Schedulers select due groups and cells.
- Actors receive jobs and return mutated pages plus moved boids.
- Snapshot packets are produced by workers and broadcast by the server.

## For Simulation Behavior Questions

Read:

- `BoidsSystem/Boids/Parallelized/JobHandler.server.luau`
- `BoidsSystem/Boids/init.luau`
- `BoidsSystem/BoidsReplicated/Quantization.luau`
- `BoidsSystem/BoidsReplicated/BoidStorage.luau`

Look for:

- `BindToMessageParallel("NewJob", ...)`
- Separation, alignment, cohesion, repulsion, and target-bias calculations.
- Bucketed neighbor search for dense cells.
- Cell-boundary movement into `job.movedBoids`.
- Tick-based `dt` via `Quantization.tickDeltaSeconds`.

## For Networking Questions

Read:

- `BoidsSystem/Boids/BoidBatches.luau`
- `BoidsSystem/BoidsReplicated/NetworkResults.luau`
- `BoidsSystem/BoidsClient/BoidsUpdater.local.luau`
- `BoidsSystem/BoidsReplicated/SharedTypes.luau`

Look for:

- `NewBoidBatch` for reliable spawn/model data.
- `BoidJobUpdate` for unreliable position/velocity snapshots.
- `NetworkResults.convertSimulationSnapshotToPackets`.
- `NetworkResults.forEachCellHeader` and `NetworkResults.forEachBoid`.

## For Client Rendering Questions

Read:

- `BoidsSystem/BoidsClient/BoidsUpdater.local.luau`
- `BoidsSystem/BoidsReplicated/NetworkResults.luau`
- `BoidsSystem/BoidsReplicated/SharedTypes.luau`

Look for:

- Boid registration in `registerBoid`.
- Snapshot ingestion in `boidJobUpdate.OnClientEvent`.
- Render smoothing and LOD in `RunService.RenderStepped`.
- `workspace:BulkMoveTo` for final movement.

## For Storage Or Binary Layout Questions

Read:

- `BoidsSystem/BoidsReplicated/BoidStorage.luau`
- `BoidsSystem/BoidsReplicated/NetworkResults.luau`
- `BoidsSystem/Boids/BoidBatches.luau`
- `BoidsSystem/BoidsReplicated/Quantization.luau`

Important constants:

- `Quantization.CELL_SIZE`
- `BoidStorage.BOID_ROW_BYTES`
- `BoidStorage.PAGE_CAPACITY`
- `NetworkResults.BOID_ROW_BYTES`
- `NetworkResults.MAX_PACKET_BYTES`
- `BoidBatches.BOID_STATS_ROW_SIZE`

When changing layouts, update every reader and writer together.

## For Scheduling Or Parallelism Questions

Read:

- `BoidsSystem/Boids/Scheduler.luau`
- `BoidsSystem/Boids/init.luau`
- `BoidsSystem/Boids/ActorsInitializer.luau`
- `ActorsManager.luau`

Look for:

- `groupsScheduler`
- `buildJob`
- `assignWorkForFrame`
- `runJob`
- `handleJobResults`
- `Schedulers.newScheduler`, `getNextSchedulee`, and `markScheduleeCompleted`

## For Performance Or Benchmarking Questions

Read:

- `Libraries/Benchmarker/init.luau`
- `Libraries/BinaryHeaps/init.luau`
- `Libraries/BinaryHeaps/LazyHeaps/init.luau`
- `BoidsSystem/Boids/init.luau`
- `BoidsSystem/BoidsClient/BoidsUpdater.local.luau`

Existing benchmarkers track job time, neighbor iterations, packet intervals, packet sizes, bytes per second, and boids updated per second.

## For Coding Style Questions

Read:

- `docs/conventions.md`
- `BoidsSystem/BoidsReplicated/BoidStorage.luau`
- `BoidsSystem/BoidsReplicated/NetworkResults.luau`
- `BoidsSystem/Boids/Scheduler.luau`

The dominant style is typed Luau with explicit constants, packed buffers, local helper functions, and module tables.

## Known Incomplete Or Suspicious Areas

- `Boids.deleteBoid` is currently a placeholder.
- `Boids.destroyGroup` notifies clients but does not fully clean all storage/id state.
- `CameraUpdate` is emitted by the client, but no current server handler consumes it.
- `ActorsManager.luau` requires `ServerScriptService.Utilities`, which is not present in the checked-in files. It only appears to need an `IncrementInRange` helper.
- Some dependency wiring relies on runtime `Dependencies` folders with `.Value` references that are not represented as plain source files in this repository.

## Safe Change Strategy

- Treat `BoidsReplicated` modules as shared contracts.
- Keep server, worker, and client buffer layouts synchronized.
- Prefer changing one flow at a time: spawn batching, simulation, storage, networking, or rendering.
- Use the stress test in `Test.server.luau` as the current behavioral entry point.
- Preserve performance patterns unless a change is explicitly about clarity over scale.
