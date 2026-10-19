# BoidsSystem agent instructions

This repository must work without a private host game. Human documentation starts at [README](README.md).

## Required reading

Read [architecture](docs/architecture.md) and [style](agent-docs/style.md) before edits. Simulation/startup/configuration/queries/replication require [runtime contracts](agent-docs/runtime.md) and [Boids lessons](agent-docs/lessons-boids.md). Rendering/observation also require [rendering contracts](agent-docs/rendering.md), [observer contracts](agent-docs/observation.md), and [rendering lessons](agent-docs/lessons-rendering.md). Search relevant lessons by subsystem/symbol.

Renderer replacement work follows the [parallel rendering implementation plan](docs/parallel-rendering-plan.md), including its section completion markers and continuation notes.

Instrumentation/reporting changes also require [measurement contracts](agent-docs/metrics.md).

## Invariants and precedence

- One shared WorkerCore implementation; one explicitly started coordinator/renderer per process. Imports remain inert except data/configuration setup. No restart/fallback architecture or retired legacy intake.
- Keep DOD representation separate from operations. Keep Scenarios, telemetry, and observation inside the package but outside simulation calculations.
- All boid-specific geometric queries are package-owned. Host combat, damage/health, field lifetimes, character controls, and game module lookups do not belong here.
- Preserve authoritative server state, safe rejection of untrusted input, process-local lifetime identity, copied diagnostics/queries, full-job Actor transport, timestamp ordering, and facing-first no-snap rendering.
- Host integration uses typed startup hooks with observer-owned cleanup, never hard-coded host module/context names. Install hooks before registration; no duplicate startup paths.
- Make the smallest requested change, with one exception. If a larger change, e.g. changing indirectly related api to avoid unnecessary copying, will eliminate unnecessary work, consider it. Ask before choosing new structural ownership, authority models, canonical representations, or public interfaces not established by the task.

Precedence: these invariants, explicit architecture invariants/compatibility constraints, lesson guardrails, style, implementation. Do not rewrite rules to excuse regressions. Conflicting higher-precedence requirements require owner clarification. No unresolved architectural decisions are currently recorded.

## Verification and maintenance

Build default.project.json and its sourcemap with Rojo 7.7.1. The standalone Scenario must work without host-game scripts/assets. Run UnitTest and hook cleanup checks; report baseline failures separately, not a clean type check from a build. Read runtime-produced reports rather than starting a second runtime in an inspection VM.

When a nearby code comment explicitly calls the implementation poor, temporary, rejected, or awaiting a fix, inspect whether the code still has that problem. Develop a concrete fix proposal and ask the owner to review it; after review, attempt the fix while preserving higher-precedence contracts.

If code encountered during the task violates the style guide or a lesson already relevant and known for that work, ask the owner to review it. Do not read every lesson or search the project for violations outside the task's scope.

The standalone place maps tests/Client/VerifyHostHandoff.luau as PlayerScripts.HostHandoffVerification. After normal scenario startup, with observation closed, call it from a normal LocalScript in that client runtime. Do not require Handoff from a separate inspection VM: its CameraReporter cache has not started there. The check covers duplicate Start/Stop, reentry, exact hook acquisition/release, and camera restoration; it does not start another coordinator.

Update shared architecture for durable boundary changes and maintenance contracts for narrow facts. Public usage stays in README with links to Scenarios, not duplicated guides/reference/example code. Lessons require tags, rejected approach, reason, and current guardrail.

Do not copy private historical evidence here. Do not publish/upload, add licenses, change remotes, commit, or push unless requested. Review redistribution rights for dependencies/models before publication. Game instructions cannot silently override package contracts.
