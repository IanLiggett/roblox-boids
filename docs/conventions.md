# Coding Conventions

This project is written in Luau for Roblox and favors explicit, performance-conscious code. The conventions below describe the style already present in the repository.

## Luau Directives And Types

- Hot modules usually start with `--!strict`, `--!native`, or both.
- Public type contracts are declared with `export type`.
- Local aliases are used for imported exported types, for example `type Job = SharedTypes.Job`.
- Roblox instances are often cast with `::` when type information is otherwise unavailable.
- Generic types are used in reusable infrastructure such as `Scheduler<T>`.

## Module Shape

- Modules generally use `local module = {}` and return `module`.
- Public functions are assigned as `function module.name(...)`.
- Private helpers are `local function name(...)`.
- Shared constants are exported by assigning to `module.CONSTANT_NAME`.
- Some modules expose internal registries for diagnostics or cross-module access, such as `BoidStorage.PageRegistry` and `BoidStorage.BoidRegistry`.

## Naming

- File and folder names use PascalCase for major modules, such as `BoidStorage.luau`, `NetworkResults.luau`, and `BinaryHeaps`.
- Module variables often use PascalCase plural names for required modules, such as `BoidStorage`, `Quantization`, `Schedulers`, and `Benchmarkers`.
- Type names use PascalCase, such as `Group`, `Cell`, `Job`, `PagedBuffer`, and `Benchmarker`.
- Constants use uppercase snake case, such as `CELL_SIZE`, `MAX_PACKET_BYTES`, `BOID_ROW_BYTES`, and `DEFAULT_CELL_UPDATE_INTERVAL`.
- Local runtime values are mostly camelCase, such as `boidCount`, `currentTick`, `groupSchedulee`, and `packetBytes`.
- Some older or test code uses PascalCase local instance names such as `BoidGroup`, `Boid`, and `TargetPart`.

## Buffer Layouts

- Packed binary data is preferred in hot paths.
- Buffer row layouts are documented near their constants with offset, size, and field comments.
- Offset constants are declared once and reused by all read/write helpers.
- Row sizes are fixed and exported when other modules need to interpret the layout.
- Quantization is centralized in `BoidsReplicated/Quantization.luau`; avoid scattering equivalent formulas into unrelated modules.

## Performance Patterns

- Prefer dense arrays and buffers over object-heavy per-boid state in simulation and rendering loops.
- Cache required functions, constants, and offsets in locals near the top of hot modules.
- Use `table.create` for temporary arrays when expected sizes are known.
- Use `table.clear` to reuse tables in hot paths.
- Iterate live boids through bitsets instead of scanning every slot blindly.
- Use `workspace:BulkMoveTo` for client-side render updates.
- Use heap-backed scheduling and lazy invalidation rather than sorting work lists every frame.

## Parallel Actor Patterns

- Actor workers communicate through `SendMessage`, `BindToMessage`, and `BindToMessageParallel`.
- Shared worker state, such as boid stats and group targets, is sent to every Actor.
- Jobs should only include the cell pages they are allowed to mutate.
- Pages are marked pending before dispatch so new boids do not write into pages currently owned by a worker.
- Job return paths should release scheduled cells even when result handling fails or times out.

## Roblox Runtime Access

- Services are loaded with `game:GetService(...)`.
- Runtime package placement is assumed by many requires, especially `ReplicatedStorage.BoidsReplicated`.
- Remotes are read from `BoidsReplicated.Remotes`.
- Client-only code lives in `.local.luau` scripts and server-only code in `.server.luau` scripts.

## Comments And Debugging

- Comments are used to document non-obvious binary layouts, scheduler heuristics, and performance tradeoffs.
- Debug visualizers and profiling blocks are commonly left commented out near the code they inspect.
- Benchmarker output uses uppercase labels and compact single-line summaries.
- TODO-style placeholders exist for incomplete behavior, especially deletion and some diagnostics.

## Error Handling

- Invalid configuration often raises with `error(...)`, such as requesting more parallel modules than there are Actors.
- Runtime inconsistencies generally use `warn(...)`, especially returned jobs for missing cells, missing groups, or timed-out jobs.
- Critical job result handling is wrapped in `pcall` so one bad result does not leave actors permanently unavailable.

## Dependency Style

- Shared boid modules require dependencies from `ReplicatedStorage.BoidsReplicated`.
- Library dependencies are sometimes stored under a module's `Dependencies` folder and referenced through ObjectValue-style `.Value` entries.
- Avoid adding new dependency lookup styles unless the runtime tree requires it.

## Documentation Style

- Keep architecture docs grounded in current files and runtime behavior.
- Mention unfinished or placeholder paths explicitly instead of describing them as complete.
- When documenting binary contracts, include both logical fields and byte-level layout.
