# Boids Lessons

[BOIDS] Simulation ownership

Tags: boids, ownership, combat health, fields, scenarios, test orchestration, package boundary

Rejected

Placing combat health, timed field lifecycles, scenario startup, or test orchestration inside reusable Boids/WorkerCore simulation calculations.

Current guardrail

Boids/WorkerCore stays simulation-only. The package owns its scenario registry, test initializers, and scenario observation as separate orchestration modules. Host games retain combat and timed-field ownership.

---

[BOIDS] Duplicate implementations and IDs

Tags: boids, WorkerCore, server, client, duplicate implementation, group ID, ID range

Rejected

Separate server/client flocking implementations and overlapping group ID spaces, or inferring boid ownership from a numeric half-range.

Current guardrail

Both processes load WorkerCore. Server group IDs are 0-32767; client-local IDs are 32768-65535.

Individual boid IDs share the full u16 space. Server reservations and settled collision eviction prevent overlap within a client runtime; IsServerBoid identifies live authoritative replicas. Delayed corrections and queued host hit reports must not treat a client-local numeric ID as authoritative.

---
[BOIDS] Inspecting metrics through a separate require cache

Tags: measurements, Studio MCP, module cache, Actors, telemetry, profiling

Rejected

Requiring Boids from an inspection tool and treating the returned module-local
counters as the already-running game's coordinator state.

Reason

During Step 1 validation the tool returned a new zero-job counter set while the
runtime reported thousands of completed jobs. Import side effects can additionally
initialize another coordinator/pool and perturb the benchmark.

Current guardrail

Runtime imports are now inert (F01); never call Start from a tool VM to inspect the already-running runtime. Read the runtime-produced Testing.PerformanceTelemetry.Report_server or
Report_client StringValue in its corresponding DataModel. Use fresh sessions
after any diagnostic require with initialization side effects. Do not infer
that all execution contexts share a module cache.

---

[BOIDS] Committed obstacle detours at wall edges

Tags: boids, WorkerCore, obstacle avoidance, raycasts, wall following, detour reversal

Rejected

Replanning as soon as a long-horizon heading ray sees any future surface can make a boid reverse along a wall before it reaches an edge. At an edge, tangent probes may all be sideways to the stored heading; selecting the clearest of those rays can also reverse the detour.

Current guardrail

Use the long horizon to detect geometry, but reselect only when the hit is within one update's travel distance plus the clearance margin. At an imminent hit, reject safe candidates that reverse the committed heading, using a positive alignment margin so packed-heading quantization noise does not classify sideways candidates as forward. If no safe forward candidate exists, retain the heading for best-effort pass-through; release it when the target corridor is locally clear. Keep the existing bounded probe count.

---

[BOIDS] Background scheduling and simulation tick validation

Tags: simulation ticks, Quantization, TickDeltaSeconds, LODConfig, client prediction, background interval, frozen boids

Rejected

Rejecting every elapsed simulation delta above 10 seconds while low-preset client prediction deliberately schedules background cells every 12 seconds.

Reason

A normal background update reaches about 720 ticks plus scheduling delay. Returning zero elapsed time suppresses movement, but WorkerCore still stamps the current tick, so repeated background updates can continually discard movement and warn once per boid.

Current guardrail

Quantization accepts elapsed deltas through 32 seconds, covering the current maximum configured 12-second interval with scheduling headroom. Keep this bound above supported simulation intervals when tuning LOD or the base cell interval. Preserve modulo-u16 wrap handling and rejection of implausible deltas. WorkerCore's separate steering clamp does not replace elapsed movement time.

---

[BOIDS] Actor snapshot recipient keys

Tags: observers, correction recipients, Actor, BindableEvent, sparse numeric keys, snapshotGroups, cell ID

Rejected

Looking up per-job correction recipients using the raw source-cell key returned through Actor result transport.

Reason

The section 2 live observer test selected the correct recipient and produced a snapshot, but the returned sparse snapshot map key was a string while the coordinator's recipient map used numeric cell IDs. The lookup silently failed and no correction packet was sent.

Current guardrail

Normalize returned source-cell keys with tonumber at the result boundary before looking up recipients. Also normalize movedBoids destination keys before addBoidToCell: string keys otherwise create string-valued cell IDs and separate schedule/storage identities, so later numeric recipient lookup fails again after migration. Section 7 reproduced 32 missing recipient lookups among 44 due snapshot cells; fresh sessions after destination normalization had zero misses. Keep recipient IDs as real viewer/user IDs, not marker IDs. Actor lifecycle messages must likewise avoid sparse numeric-key assumptions: stats lifetimes are dense and row-aligned, and boid retirement is a dense array of ID/lifetime records (F05 reproduced missing lifetimes when a sparse map crossed SendMessage). Validate migration and actual client packet delivery; an emitSnapshot flag or a startup-only check does not establish continued correction delivery.

---

[BOIDS] Read time is not simulation freshness

Tags: observer, inspector, sampledAt, lastSimulationTick, tick wrap, u16, stale, TickDeltaSeconds

Rejected

Using sampledAt as the last simulation update, or using the simulation's clamped TickDeltaSeconds helper to display diagnostic age.

Reason

A fresh diagnostic read may contain an old packed row. TickDeltaSeconds deliberately returns zero outside its supported simulation interval, which would make stale state look fresh. A u16 tick also repeats after about 1092 seconds.

Current guardrail

Keep read/transport age separate from simulation age. Track only the selected row's tick history, retain elapsed age while its tick is unchanged, and label initial or long-gap wrap ambiguity as a lower bound. Preserve the simulation delta clamp; observation does not change scheduling or write state.

---

[BOIDS] A job timeout does not prove Actor completion

Tags: Actor, WorkerCore, scratch, timeout, ready, quarantine, terminal reply, job retirement, pending pages, F13

Rejected

Setting actor.ready=true and destroying the reply event solely because the five-second job deadline elapsed.

Reason

The worker may still be accessing Actor-lifetime scratch. Reusing it then can overlap jobs, while discarded late output and unrestored page reservations leave coordinator lifecycle state inconsistent. A missing result is not a completion or cancellation acknowledgement.

Current guardrail

ActorsInitializer.JobExecution retires logical work once and keeps the Actor quarantined until the original terminal reply. WorkerCore acknowledges terminal success/failure after scratch access ends. Retired replies cannot merge, publish snapshots or update adaptive feedback. JobBuilder settles original cell/page reservations by owner identity on normal, incomplete, failed, cancelled and timed-out paths. Validate real late/error replies and pending-page cleanup, not just the timeout counter.

---

[BOIDS] Preserve correction source time and separate replay recipes from settled pose

Tags: F15, F16, NetworkResults, correction, source time, batching, reordering, replay, navigation, spawn recipe

Rejected

Stamping mixed queued snapshots with the flush clock, accepting targets by arrival order, or replaying historical spawn poses and both inactive/active navigation branches as current state.

Reason

Batching made old source state appear fresh; unreliable reordering could replace a newer steering target. A Path then Target sequence replayed Path last, and late joins began at historical positions.

Current guardrail

Keep packet rows homogeneous by original source time and queue age on a separate clock. CorrectionIntake owns live-lifetime/newer-time acceptance; preserve correction-before-Actor-stats behavior. Replay copies latest settled poses through the running coordinator's narrow reader without claiming a new simulation time or forcing work. The reliable control ledger keeps one active navigation branch, and Path cancels unresolved older target resolution.

---

[BOIDS] Imports do not own runtime startup or diagnostic capabilities

Tags: F01, F02, F03, startup, require side effects, Actor pool, renderer, debug visualizer, diagnostics, scheduler, value snapshots

Rejected

Creating Actors/render roots or installing runtime loops/listeners while importing read-oriented modules; storing debug Instances in simulation cells; exposing mutable scheduler/Actor state for report consumers.

Current guardrail

The existing process entry points explicitly start one runtime and renderer after configuration. Start paths are idempotent and imports remain inert apart from data/configuration setup. DebugPresentation exclusively owns visual lifetime by group token. Diagnostics remain runtime-produced independent values; telemetry and logging format those values without acquiring scheduling/Actor capabilities. Use fresh sessions for implementation verification rather than introducing restart support.

---

[BOIDS] Keep experiment policy, query ownership and scenario delivery at their boundaries

Tags: F04, F06, F07, BenchmarkHarness, RuntimeConfig, RuntimeTypes, query facade, index lifetime, ScenarioContext, late handler, replay extension

Rejected

Generic runtime interpreting benchmark names/attributes or importing scenario-spawner contracts; game consumers acquiring a mutable index; scenario selection operating index lifetime; core replication owning scenario replay/handler queues.

Current guardrail

Testing resolves one generic startup configuration and shares its resolved values with metadata. All boid-specific query operations remain package-owned, while the game owns report tolerance/authorization/damage. The query owner takes the existing running handle and exposes copied reads, with fresh seeding and old-owner callback rejection after Stop. RuntimeTypes owns generic capabilities; Scenarios.Types/Delivery own metadata/replay/late-handler policy through the existing reliable control-plane extension. Install Delivery before intake and preserve runtime-ID context plus once-per-name initialization.

---

[TYPING] Bootstrap relocation must retain edit-time import types

Tags: types, Studio, require, WaitForChild, BoidsReplicated, bootstrap, sourcemap

Rejected

Analyzing only a sourcemap with runtime service aliases, or casting a retrieved module to generic ModuleScript.

Reason

Runtime aliases can make external checks pass while Studio's edit-time hierarchy still resolves relocated package lookups as Instance and loses their exported types. A generic ModuleScript cast also loses the concrete module contract.

Current guardrail

Preserve runtime WaitForChild lookups, but annotate the retrieved folder/module with typeof pointing at its concrete edit-time instance under ServerScriptService.BoidsSystem. Test the ordinary edit-time sourcemap without runtime aliases. These annotations must live in the source shipped to Studio, not only in external checker configuration.
