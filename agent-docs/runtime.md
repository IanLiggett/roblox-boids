# Maintenance contracts

Detailed editing constraints; start with ../docs/architecture.md. This is not a tutorial.

Boids Runtime Architecture

Package boundary

Invariant

- Reusable Boids code is simulation-only.
- BoidsSystem includes its shared simulation runtime, Scenarios, Testing, and scenario observation. Scenario/test/observation orchestration stays inside the package but outside Boids/WorkerCore simulation calculations.
- Game-owned combat health and timed field lifecycles remain outside the reusable simulation code.
- Server and client processes use the same shared simulation implementation rather than divergent flocking algorithms.

Shared runtime

Current implementation / invariant within the current package design

- BoidsReplicated.Boids is the shared simulation coordinator and packed WorkerCore implementation in each process.
- Server and client Actor bootstraps load the same WorkerCore.

Explicit process startup

Current contract (architecture review F01-F03)

- Requiring Boids, ActorsManager, JobBuilder, NetworkResults, SimulationReplication, BoidsRenderer, telemetry or logging does not create an Actor pool/render root, subscribe to runtime events or launch background work. Pure data/configuration initialization and configuration-only attribute watching remain allowed. Importing through a separate tool VM still does not expose the running process's module-local state.
- Server.Testing.ScenarioTestInitializer resolves the selected scenario through Registry.ConfigureRuntime before Boids.Start and scenario creation. Testing.BenchmarkHarness resolves benchmark Actor-count/job-budget policy once before startup; Boids.Start receives generic RuntimeConfig options. ActorsManager and JobBuilder do not read scenario names or benchmark attributes.
- Boids.Start is an idempotent process-lifetime initializer for the current singleton: initialize the fixed Actor pool, bind the running state reader, start server queue/control replication, stats batching, deletion settlement and job/viewer scheduling. NewGroup requires Start. Read-only imports and subscriptions do not implicitly start it.
- ClientSimulation.Start is the existing client composition point. It starts the sole BoidsRenderer, binds it through ClientRendererBridge.SetRenderer, starts Boids with generic options, and then starts replicated intake. Both existing client entry points install Scenarios.Delivery before intake and obtain startup options from Testing.BenchmarkHarness; the generic facade has no scenario handler or queue. ClientSimulationController and the test initializer share this idempotent path. Renderer.Start creates only the presentation root/callback and accepts a narrow viewing-camera observation hook. ClientSimulation owns CameraReporter startup and the sole replicated intake; there is no legacy intake selector.
- Component Start/StartServer calls are idempotent. No hot reload, restart, replacement pool, second coordinator or renderer is introduced.

Runtime configuration, query lifetime and scenario extensions

Current boundaries (F04/F06/F07)

- RuntimeConfig owns trusted generic options/defaults: 16 active Actors on the client, two on the server, and a 4 ms target job budget. Testing.BenchmarkHarness alone recognizes Benchmark names/attributes, resolves supported overrides once per scenario/session, and shares the resolved values with runtime startup and report metadata. Actor counts 1-32 retain the existing minimum two-Instance pool; only the requested active worker count is initialized. Invalid benchmark overrides fall back to defaults; malformed direct trusted runtime options assert. Configuration changes require a fresh session.
- Server.BoidQueryIndexServer owns authoritative index population, subscription lifetime and copied read-only queries. Start receives the existing coordinator's narrow RuntimeTypes.IndexSource, seeds current rows and subscribes to creation/settled merges/deletion. Stop disconnects and releases all entries; a later Start freshly seeds the current population. Old callbacks are guarded by the exact index owner. No writable index is exported.
- All boid-specific geometric queries remain package-owned. Host games consume copied query results and own authorization, hit tolerance, damage, and timed combat effects.
- The server initializer locks configured query mode and starts the query owner before scenario population; Registry selects configuration but does not operate index lifetime.
- RuntimeTypes owns generic capability contracts. Scenarios.Runtime consumes only GroupWriter; server/client observation and obstacle capture use their narrow runtime contracts. Generic ClientSimulation/SimulationReplication do not import the scenario spawner or observation contracts.
- Scenarios.Types owns definitions, spawn results, GroupBinding, ScenarioContext and benchmark timing context. ObservationTypes retains observation-specific session/sample contracts.
- Scenarios.Delivery owns scenario metadata storage, live/replay output and the late-handler queue. It registers one explicit server replay/client state extension with SimulationReplication and reuses SimulationState; core replay calls the extension before Complete, and core client intake delegates unrecognized state messages without interpreting scenario policy. Existing process entry points install Delivery before starting intake.
- Delivery preserves runtime-ID contexts and dispatches each scenario name once per client session, including duplicate live/replay arrivals and handler registration after bootstrap. The test initializer retains its own once-per-name guard. No extra remote, event framework, coordinator, renderer, or arbitrary restart protocol is added.

Debug presentation

Current owner (F02)

- BoidsReplicated.DebugPresentation owns target/path/cell debug Instances and their cleanup. The coordinator supplies resolved values and group-lifetime/cell lifecycle notifications; Boids.Cells reports cell removal for result settlement, deletion and group teardown.
- Visual state is keyed by process-local group lifetime, so cleanup for an old group cannot remove a replacement group's visuals. Cell storage and Actor payloads contain no visualizer Instance. Target/path debug options, resolved offsets, styling and the opt-in server cell-outline switch are preserved. No per-boid debug renderer or extra simulation work is added.

Diagnostic reads

Current interface (F03)

- Boids.GetRuntimeSummary returns independent group/population/cell/Actor counts; telemetry uses it rather than traversing schedulees or importing ActorsInitializer.
- Boids.GetRuntimeDiagnostics delegates to its Diagnostics child for an on-demand value snapshot: aggregate cell scheduling/age, per-group numeric statistics and Actor idle statistics. NumericStatsSummary/RuntimeSummary/RuntimeDiagnostics in SharedTypes contain no buffers, Instances, callbacks, schedulees or live runtime handles. Nested results are fresh copies, and unavailable detailed/empty statistics remain explicit.
- Runtime owns measurement collection and scheduling interpretation; testing/diagnostics own formatting, sample/report policy and output. Public groupsScheduler/cellValidator exports are removed. Existing group mutation APIs and internal runtime owner dependencies remain intact.
- Server.Diagnostics.Logs.Start receives a narrow reader from the existing running coordinator. Only Start installs its output callback; Stop disconnects it. Importing Logs does not require/start a coordinator or retain an idle runtime callback.

Actor job transport

Invariant

- Actor jobs exchange dense job-cell lists, not sparse numeric cell-ID maps.
- The scheduled boid count for an Actor job is immutable during that job.

Current execution ownership (architecture review checkpoint 2 / F13)

- ActorsManager owns the existing fixed Instance pool. Boids.ActorsInitializer composes it; its child JobExecution owns per-Actor reservation, busy/reusable state, adaptive feedback, per-job reply/deadline and logical retirement accounting. JobBuilder and ResultCommit do not change Actor readiness or feedback directly.
- ActorsInitializer.RunJob receives the original group/job plus narrow IsCurrent, Commit and Retire callbacks. Boids.ResultCommit owns storage/result commit and identity-guarded cell/page/scheduler/recipient settlement. Both worker bootstraps still use the same WorkerCore and full-job transport.
- Install reply handling before dispatch. Keep the Actor busy through serial commit and retirement, including yielded observers. Snapshot publication follows a complete merge; incomplete/failed results release reservations for retry without publishing uncommitted snapshots or training adaptive feedback.
- The five-second deadline retires logical work once and quarantines the Actor; it does not prove worker completion. Group cancellation and uncertain dispatch failure use the same quarantine. Retain the per-job terminal listener, but clear captured coordinator job/group callbacks after retirement. A late reply only permits physical reuse; it cannot commit or retire again.
- WorkerCore sends success or failure on the existing terminal reply after scratch access ends. Never reuse a quarantined Actor without such acknowledgement. A worker that never replies remains unavailable; the fixed pool is not expanded or restarted automatically.
- Boids.DestroyGroup cancels that group's executions by object identity after removing its current schedulee. Cancellation during an already-yielding serial commit waits for its retirement callback. Original schedulee/cell identities guard cleanup against replacements. Group teardown then settles the entity/storage/replication lifetime described below.
- BoidStorage.RestorePendingPages ignores retired buffers. OverwriteWithJobResults validates the entire locked page range before mutating that cell; this does not provide transactional rollback across an entire multi-cell job.

Entity and group retirement

Current lifecycle contract (architecture review F05)

- Boids owns logical deletion, metadata, generated-ID reuse and lifecycle notifications. BoidStorage.deleteBoidAtSlot and DeletePagedBuffer are physical operations only; the unused overlapping DeleteBoid/RemovePage APIs are removed.
- DeleteBoid returns false while the cell is worker-owned. QueueDeleteBoid retains the original owner and retries until safe. IsDeletionPending includes notification settlement; IDs remain reserved until deletion subscribers return.
- DestroyGroup removes the current group from selection, cancels its executions by identity and waits for any already-completing serial commit. It then removes all owned rows/pages, metadata, batch registration and control/debug state, emits per-boid deletion notifications and retires replication/renderer state. IsGroupRetiring remains true until this settles; an old Group object cannot destroy its replacement.
- Boid/group lifetimes are process-local tokens, not packed row fields or network revisions. Dense row-aligned stats lifetimes and dense retirement records cross Actor transport, avoiding sparse numeric-key conversion. Workers reject retired stats/controls and retain matching correction-before-stats targets.
- Reliable replication removes pending spawn/replay records on deletion. The client defers reused-ID spawns until old deletion settles and preserves reliable order while a group replacement waits. Queued correction rows are purged before IDs are released; correction ingress requires a live, non-pending ID and a source time after its retirement cutoff. SimulationReplication.CorrectionIntake owns accepted per-boid source times and retirement cutoffs; stale/equal rows never replace a newer steering target, including across ID reuse.
- NetworkResults.ServerTransport owns per-recipient queue removal on disconnect and ignores disconnected recipients of an already-running job. Deletion filtering does not mutate snapshots shared by multiple recipients.

Replication and group control

Current implementation

- SimulationReplication is the server-owned group control plane.
- Compact BoidJobUpdate packets are the correction plane. NetworkResults.ServerTransport groups queued rows by their original job completion/source time before packetizing; one packet never mixes source times. Queue residence uses a separate enqueue clock. Packet layout, global send-token budget and unreliable backlog dropping remain unchanged; sparse partial chunks are retained as dense lists.
- SimulationReplication.CorrectionIntake is the sole replicated correction acceptance owner. It validates a complete packet before accepting rows, drops unknown/pending-deletion IDs, and rejects nonfinite/stale/equal source times and pre-retirement rows. Live IDs can accept corrections before Actor stats; WorkerCore preserves lifetime/time ordering at its control boundary. Corrections remain steering targets.
- SimulationReplication.Replay materializes replay boid records from immutable spawn/tuning recipes plus a narrow state-reader callback bound once by the running Boids coordinator. It copies latest settled position/velocity, excludes missing/pending-deletion state, and never requires/starts a runtime or advances simulation. LOD can make this pose old: bootstrap does not extrapolate it or label the serialization clock as its simulation time. Only initial creation uses this pose; existing rendered boids are not repositioned by duplicate bootstrap spawns.
- The control ledger retains only the active target or path. Path nodes are copied by value (dynamic Instance references remain references); a newer Path also cancels unresolved client target resolution.
- SimulationReplication.Bootstrap owns per-Player connection admission: one successful reliable replay, no reentrant/duplicate replay, and at most three failed-send attempts separated by five seconds. PlayerRemoving releases admission state. Begin/Complete are informational reliable replay markers, not full resets or proof that deferred local lifetimes/Actor stats/streaming are settled. No general resynchronization/restart protocol is introduced.
- Actor result transport can return sparse snapshot and moved-boid map keys as strings. The result boundary normalizes both source snapshot keys before recipient lookup and moved destination keys before storage/cell scheduling. Cell IDs remain numeric throughout coordinator storage, schedulees, and recipient maps; viewer IDs remain real user IDs.

Compatibility constraint

- Server group IDs are 0-32767.
- Client-local group IDs are 32768-65535.

LOD

Current implementation

- LODConfig has independent server, client-prediction, and client-local simulation settings.
- LODConfig.client.visibleRenderBands, offscreenHertz, maxRenderBoidsPerFrame, and peripheralLodDistanceScale are the canonical renderer performance schedule. Renderer cells are 64 studs, independently subdividing the unchanged 128-stud simulation/query cells; visible-band work is selected per renderer cell, never per-frame per boid. Peripheral scale expands effective visible distance only near the view-cone edge.

Viewer observer scheduling

Current interface

- Boids.SetViewerObservers(viewerId, cameraEnabled, fixedPositions) replaces the process-local observer configuration for that real viewer ID. JobBuilder copies the fixed-position array; the caller retains no mutable array alias.
- Boids.ResetViewerObservers(viewerId) removes fixed positions and reenables the latest cached camera position. A viewer defaults to camera enabled and no fixed positions; fixed-only configuration also works before a camera report arrives.
- Existing camera reports continue updating cached positions while their LOD observer is disabled. Invalid/nonfinite camera positions are safely rejected at the remote boundary; reports cannot change the enabled flag or fixed positions.
- Simulation LOD uses the nearest enabled camera/fixed observer across viewers. Network LOD selects the nearest enabled observer for each recipient and retains its existing real-user phase and interval, emitting that recipient once per source cell.
- An empty observer set provides no simulation influence or regular correction recipients. Cells without any nearby observer retain their existing background schedule. Player removal deletes its complete observer record.
- Rendering continues to use the actual viewing camera. Client prediction and client-local simulation use the same observer calculations with their independent LOD configs.
- Configuration applies to subsequent cell scheduling, without forcing extra simulation work. Already scheduled results/queued packets can still arrive after a change.
- These are trusted configuration APIs, not client request handlers. Server.Scenarios.Observation validates developer requests and applies accepted sets on the server. Its reliable session snapshots make the owning client apply the same set; cross-process synchronization is not part of the generic scheduler API.

Obstacle avoidance

Current implementation

- WorkerCore uses one forward ray per positive-delta normal update and only probes four surface-tangent escape directions after that ray hits.
- A selected escape is packed into the boid row and directly owns movement until the target ray is clear or its hit lies beyond the current local reaction horizon. This state survives worker jobs and cell migration but is not added to snapshots or network packets.
- Active detours normally use a target-clearance ray and a heading-clearance ray; a blocked heading may evaluate four replacement escapes only when the hit is within this update's travel distance plus clearance margin. Among candidates meeting the clearance threshold, directions that continue generally along the committed heading are eligible; pathward progress and clearance rank them. If none is safe, the committed heading is retained for best-effort pass-through instead of reversing. A locally clear target corridor releases the detour and rejoins the path. Initial avoidance with no safe escape still uses soft pass-through.
- The forward horizon covers the current full travel distance plus reaction time and safety padding, capped at Roblox's 1024-stud ray length.

Fields

Compatibility constraint

- Boids fields use signed gravity-well strengths:
  - positive attracts
  - negative repels

Path targets

Current implementation / data contract

- A boid path node is a record { Position = Vector3 | BasePart, offset = Vector3 }.
- Static positions are used directly; dynamic BasePart positions are resolved per job.
- Standalone targets may also be a BasePart or a record exposing Position.
- The offset is always present on path-node records, not on the BasePart itself.

Scenario observation context

Current interface

- Server.Scenarios.Registry.StartServerScenario returns its existing groups, boid IDs, and scenario plus a fourth ScenarioContext return.
- BoidsReplicated.Scenarios.Types defines ScenarioContext {name, serverGroups}; each GroupBinding contains groupId, ownership, and the resolved GroupDefinition. Metadata contains no live Group objects.
- Server.Scenarios.Observation receives that context and the initializer's running Boids handle through RegisterScenario. It does not require or start a coordinator.
- Scenarios.Delivery carries the context as the fourth handler argument in both live broadcasts and full-state replay over SimulationState. It queues the same runtime-ID context when the client test handler is registered late; ClientSimulation and generic replication do not interpret it.
- BoidsClient.Scenarios.Observation registers the context and client-local SpawnGroups results through the existing client initializer. Bindings use runtime IDs, not names, and retain the existing client-local Group objects.
- SimulationReplication.GetClientGroup(groupId) resolves the current server-owned replica or nil. Client observation privately resolves local/replicated groups only to copy their counts into inspection group rows. GetBoids/GetRuntimeGroup are not client observation/UI APIs; no live Group or coordinator capability reaches the inspector.
- Server.Scenarios.Observation owns developer authorization, sessions, fixed observer identities/lifetime, and bounded read-only server sampling. Studio players, the individual experience creator, and explicit ObservationConfig.allowedUserIds entries are allowed; group-owned experiences require allowlist entries outside Studio.
- Each session has one optional camera observer and up to four fixed positions. Requests infer the viewer from the remote's Player, require that player's session token for mutations, and validate finite positions, ownership, limits, selection revisions, and a bounded request rate. Exit, disconnect, Stop, and access revocation clear fixed observers and reset camera observation.
- Shared Scenarios owns ObservationRequest (reliable commands), ObservationState (reliable accepted session snapshots), and ObservationSample (unreliable diagnostics). Client controls never apply speculative observer settings. Session snapshots have increasing per-player revisions; diagnostic samples carry a session ID, selection revision, boid ID, and sampledAt read time.
- Diagnostic sampling reads only the selected server boid at 4 Hz, independently of regular correction scheduling. The client caches matching samples for inspection only and rejects older selections, sessions, and reordered timestamps. Samples never enter client simulation, reconciliation, or renderer pose updates. Missing/deleted boids are explicitly unavailable; client-only selection clears the server selection. sampledAt is read time, not the last simulation tick. Samples now include the value-only GetBoidObservation record and separately tracked simulation age; selected-only age history distinguishes fresh reads from old simulation state.
- BoidsClient.Scenarios.Observation.Dock owns the single tabbed observer shell, authorized launcher, F6 entry/exit, and F8 collapse/restore. Observation.Controls owns Session / LOD and Camera content; Observation.Inspector owns Inspector content. Observation passes the dock's scrolling page hosts into their Start functions. Only the shell controls page visibility; collapsing or changing tabs does not change camera/diagnostic/overlay lifetimes or recurring inspection cadence. Layout memory is local to the current Play session. The existing initializer starts it through Observation.RegisterScenario; no extra entry point, coordinator, or renderer is introduced. Observation.Handoff owns the held viewing camera, character-camera suspension, the client input sink, and bounded streaming requests. Observation.Camera supplies free-flight, rendered-boid orbit, rendered-group orbit, and scenario overview through that handoff. Observation.Inspector renders copied inspection values and issues narrow selection/toggle commands. Observation.Inspection owns selected reads/age/capture availability and group-count acquisition; Inspector owns picking and bounded local overlay presentation.
- Server sessions add one camera replication focus and up to four fixed-observer foci while Workspace.StreamingEnabled is true. Additional anchored, invisible, non-queryable parts preserve the character's ordinary replication focus. Validated, bounded CameraUpdate reports move the viewing focus even with camera LOD disabled; fixed foci follow accepted observer ownership and lifetime.
- Observer host suspension is supplied by typed startup hooks. The host owns game controls; the package owns session cleanup and camera/streaming presentation.
- Client Observation.Handoff holds the current camera view, preserves it across CurrentCamera replacement and character respawn, and acquires the supplied host suspension hook. Stop restores camera/mouse state, releases host cleanup, and invalidates pending streaming callbacks. Observation.SetCameraCFrame reports through ClientSimulation.CameraReporter.ReportNow; the renderer supplies its actual camera to Update. Preserve one-second periodic reports and 128-stud jump/1/30-second minimum intervals. Immediate reports update the same policy state without a duplicate sender.
- Observation.Camera is package-owned client orchestration. Its input context has priority 5000 and sinks camera bindings while the server continues to own gameplay input suspension. The existing handoff render callback runs the camera driver; no second camera writer, coordinator, or renderer is added.
- Boid follow reads GetRenderedBoidState once per frame. Group follow reads GetRenderedGroupBounds for only the selected group at 2 Hz, smoothing its centroid between samples and framing the bounds with the current camera FOV/aspect. These read-only renderer APIs do not use query indexing or modify reconciliation state.
- Scenario overview frames available path nodes (including offsets/arrival radii), targets, and initial definition bounds. Missing references and stale rendered poses are labeled. Deleting an observed boid clears the diagnostic/inspector selection; deleting a followed group clears its group selection. Both return to free flight at the held viewing position.
- Streaming readiness is request progress, explicitly best effort. At most one request runs per active camera/fixed region; camera movement coalesces while a request is pending. Generation/revision checks reject stale completions, each request has a five-second timeout, and the panel shows loading, completion, or incomplete requests.
- Observation is unavailable for Benchmark-prefixed scenarios. README links to the canonical Scenario definitions; observation.md retains authorization/request constraints.

Read-only state inspection

Current interface

- SharedTypes.BoidObservation defines a value-only simulation record: boid/group/cell IDs, cell origin, position, velocity, optional path-node index, u16 lastSimulationTick/currentTick, and sampledAt. Boids.GetBoidObservation reads settled coordinator storage without advancing, scheduling, or exposing packed buffers.
- SharedTypes.GroupObservation and Boids.GetGroupObservation expose resolved runtime path nodes/offsets, target, loops, arrival radius, and copied global/group gravity-well records. SetPath/SetTarget retain their current source references for this read interface; DestroyGroup removes those references. Missing streamed references remain unavailable.
- Scenarios.ObservationAge owns selected-only age interpretation, outside reusable simulation calculations. Initial reads/gaps can have u16 history ambiguity and are labeled lower bounds. Repeated identical ticks retain elapsed age across wraps; the simulation's clamped TickDeltaSeconds is never used to make old inspection data appear fresh.
- Client Observation.Inspection reads one selected simulation state and rendered pose at 4 Hz, independently of Inspector construction, subscriptions or dock visibility. Inspector has no polling loop. Server sampling also stays selected-only at 4 Hz, independently of regular correction traffic. Client-only boids explicitly have no sampled server state. Server samples remain diagnostic-only and never write simulation or renderer state.
- Group rows refresh at 2 Hz with O(1) renderer counts and runtime IDs, including duplicate names. Picking scans rendered transforms only on a click, with an optional group filter, and ignores course geometry/query-index configuration. Recurring inspection never scans the full boid population.
- Local selection/velocity and optional runtime group overlays use AlwaysOnTop adornments, capped at 512 visible items for one boid/group. Overlay geometry is pooled during the session and destroyed on exit/Stop; its sole invisible anchor is non-queryable.

Client obstacle-decision observation

Current interface

- Boids.SetObstacleObservation(boidId?) is trusted process-local client configuration for one existing boid; nil disables capture. Boids.GetObstacleObservation returns an independent SharedTypes.ObstacleObservation value record or nil while waiting/unavailable. Nested probes and candidates are copied.
- SharedTypes owns ObstacleCaptureRequest, ObstacleProbe, ObstacleCandidate, and ObstacleObservation. Boids.ObstacleDiagnostics copies values and records existing query results; it never casts rays or starts a coordinator. WorkerCore captures the actual forward/target/heading/escape queries, thresholds, candidate scores/eligibility/winner, detour transition, soft response, and resulting displacement only for the requested boid.
- ResultCommit attaches the opt-in request only to the selected boid's naturally scheduled source-cell job. The active direct Job dispatch carries generation/monotonic job order; no scheduling frequency changes. Results are accepted after a successful normal merge, including migration, only for the current selection/generation, a returned source cell, an existing group/boid, and a newer job order. Ordering does not compare wrapped simulation ticks.
- This capture is client-only, including prediction of server-owned boids and client-local boids. Diagnostic records do not enter packed boid rows, snapshots/correction packets, or server ObservationSample messages; no obstacle-decision remote is added.
- BoidsClient.Scenarios.Observation.Obstacle owns capture lifetime and live/frozen value state. Observation synchronizes it with accepted sessions and selection revisions, including immediate close invalidation and selected-boid deletion through SubscribeDeleted. Observation.Inspection refreshes it at 4 Hz using its selected-only client-state availability read; GUI notifications do not synchronize capture.
- Observation.Inspector.ObstaclePanel supplies the client decision controls and readout in the scrolling inspector. Capture defaults OFF for each session. Freeze retains the already displayed world-space decision and disables capture; Resume clears it and waits for a fresh matching decision. Selection/session changes, missing/deleted client state, revocation, exit, and Stop invalidate the display and capture.
- Observation.Inspector.Overlays draws only actual queries at captured world coordinates, with hit markers/normals, numbered candidates, threshold markers, and optional target/detour/result/soft-response arrows. Pooled local AlwaysOnTop labels/adornments share the existing 512-visible-item cap; selected diagnostics take priority over optional group geometry. Queryability and renderer reconciliation remain unchanged.
- Decision age uses capture time, separately from inspector read time. Waiting, skipped checks, stale/frozen decisions, and unavailable client data are labeled. Low-frequency simulation is not promoted for inspection. These client decisions reflect client-resident geometry, not authoritative server decisions.
- Obstacle continuation uses threshold 0.1, matching the positive-margin guardrail. Observation capture reports that actual threshold.

Generic observation APIs

Invariant

- Boids exposes opt-in generic post-merge and deletion observation APIs.
- Post-merge batches are produced only after authoritative storage and cell moves are settled.
- These APIs do not contain game-owned types.

Runtime measurements

Current interface

- SharedTypes.RuntimeMetrics and WorkerMeasurement define the measurement schema.
- Boids.GetRuntimeMetrics(sinceTotals?) returns process-local counter snapshots and bounded latency summaries.
- Worker execution, transport/scheduling delay, and coordinator phases are distinct elapsed measurements, not CPU utilization.
- Testing.PerformanceTelemetry owns scenario reports and exports runtime-produced JSON for tools; tools must not require a fresh coordinator to inspect the running one.
- Read metrics.md before changing measurement nesting, sampling, count semantics, or report interpretation.


Renderer measurements, scenario catalog and diagnostic collection (F08-F10)

- BoidsRenderer.Measurements is renderer-owned opt-in numeric instrumentation. The render callback records only generic timings/work counts; SetMeasurementsEnabled, ResetMeasurements and GetMeasurements expose trusted controls and independent value snapshots. No benchmark attribute interpretation or report export remains in rendering.
- BoidsClient.Testing.RendererBenchmark is the continuous client session collector, explicitly composed by ClientScenarioTestInitializer. It resolves RendererBenchmarkEnabled at Start, owns reset-revision handling and the existing Workspace RendererBenchmark* export names, and disconnects/disables measurement collection on Stop. It publishes after at least 60 new measured frames; no recurring work is installed while disabled. Renderer intervals, dense/cell ownership, query metrics, deduplication timestamps and no-snap reconciliation are unchanged. The empty printer/task, uncalled audit/format helpers and otherwise-unconsumed legacy counters/interval sampling were removed.
- Server.Scenarios.Registry now owns lookup/configuration and one-scenario-per-session orchestration. Its Catalog child owns definitions/factories; Catalog.Fixtures owns course/target Instances and recurring target motion; Registry.Types is their common server contract. Fixtures.Stop destroys only tracked resources and invalidates delayed target work by generation and folder identity. Registry binds fixture cleanup to session shutdown; this does not destroy groups or establish scenario hot swapping.
- SimulationReplication retains correction acceptance/retirement/source-time state and exposes ForEachClientCorrection as immutable value handoff. Testing.PerformanceTelemetry.Divergence owns time-aligned simulation comparison, the existing 0-3 second inclusion window and error aggregation. The client test initializer supplies the existing running handle and correction reader; ClientSimulation no longer exposes diagnostic GetDivergence. No duplicate correction listener/cache or coordinator was introduced.

Measurement facility lifetimes

- Scenario PerformanceTelemetry.Start: once per label/side per Play; warmup then approximately one-second sampling for the requested interval; emits runtime-produced JSON under Report_server/Report_client, summary attributes and one console report. Divergence is read only during those client sample windows; it never advances simulation or changes renderer poses.
- RendererBenchmark.Start/Stop: independent continuous opt-in client measurement window, reset by its existing revision attribute, exporting Workspace attributes at measured-frame cadence. It is not implicitly reset or stopped by a scenario telemetry report.
- Server.Diagnostics.Logs.Start/Stop: opt-in periodic formatted output from a supplied value-only diagnostics reader; Stop disconnects. RuntimeMetrics remain process-local generic measurements, not report-policy owners.


Coordinator implementation boundaries (F11/F12/F14)

- Boids owns the live GroupRegistry (ID -> Group), group/boid logical lifetime and explicit startup. Group selection scans this registry for the earliest cell deadline across simulation kinds. Empty groups and future wakes are excluded from dispatch. Ties retain traversal order; cells are never run early to occupy idle Actors.
- Boids.JobBuilder owns cell-job construction, Actor rotation, group selection and recurring scheduling/stat polling. Its DispatchPump shares 1 ms of selection/build/dispatch work per Heartbeat epoch across coalesced deferred Heartbeat, completion, and next-due timer requests. One indivisible job build may exceed the remainder; dispatch then stops until Heartbeat. Merge/observer work is outside this allowance. Simulation maxBoidsPerFrame and Boids.MAX_BOIDS_PER_FRAME are removed; renderer budgets remain separate. Its ViewerLOD child retains camera/fixed-observer state and unchanged simulation/network LOD policy.
- ActorsInitializer installs one internal JobExecution reusable callback. It runs only after terminal acknowledgement, commit/observers, retirement, reply cleanup, and reservation release. It requests deferred dispatch, never recursive assignment. Timeouts/cancellation do not notify while quarantined; a late acknowledgement can notify after cleanup. Keep one active job per Actor and reserve whole-cell jobs only when assigning a free Actor.
- DispatchPump keeps one generation-guarded next-due timer only when capacity and the epoch allowance remain. Budget exhaustion waits for Heartbeat; busy Actors wait for safe release; absent work has no timer. Heartbeat discovers newly created/earlier cells and configuration changes. There are no extra lifecycle subscriptions, restarts, or prebuilt reserved queues.
- WorkerCore cellScratch, bucketRecordPool, and activeBucketRecords belong to runJob invocations. Reuse across cells within that job is allowed; no mutable scratch survives for another job. Stats, paths, reconciliation/lifetime state and read-only bucket-search lookup caches remain worker-owned persistent state. Returned buffers must not alias scratch mutated by later cell/job execution.
- Future scratch pooling is deferred; see [exclusive bundles and dynamic growth](../docs/future-scratch-pooling.md). Multiple jobs per Actor are not enabled by this feature.
- Boids.ResultCommit owns result preflight/merge, numeric destination-key normalization, moved-row settlement, source-key recipient delivery, post-merge notification and opt-in obstacle-result acceptance. Its Run method delegates unchanged full-job dispatch to ActorsInitializer.JobExecution through IsCurrent/Commit/Retire callbacks. Per-job recipients are passed by the builder and cleared at retirement rather than retained in a shared job map. Runtime measurement/capture remains outside report policy.
- Boids.Cells is the single cell create/insert/remove owner for spawning/migration, deletion, empty-result cells and group teardown. It coordinates pages, active-cell/schedulee membership, counts and DebugPresentation notifications; BoidStorage remains the separate packed-data/physical-storage owner. IsDue/WakeTime preserve existing cell cadence/staleness and heap behavior.
- Diagnostics accepts the live group registry and returns the same copied values; it neither exposes nor maintains an outer group heap. Per-cell generic Scheduler heaps, lazy invalidation and rebuild heuristics remain unchanged.
- The uncalled buildWorkerJob, helper-only aliases and unused SharedTypes.WorkerJob type are removed after renewed symbol checks. WorkerJobResult/WorkerJobCell/WorkerPagedBuffer/WorkerPage and both accepted codecs remain because active result/storage annotations use them. Full Job transport remains the sole supported Actor dispatch path; comments now describe that contract.


Results, camera reporting and explicit input roles (F18/F19/F21)

- NetworkResults remains the existing public result-delivery entry point. Its PacketCodec child owns pure packet layout/encoding/decoding and reuses SnapshotCodec's canonical row builder. CorrectionIntake and renderer cell decoding import PacketCodec directly rather than delivery runtime. The layout, signed origins, row bytes, packet-size bound and iterators are unchanged.
- NetworkResults.ServerTransport owns per-recipient queues, original source-time batching, deletion/disconnect retirement, the shared 300-call/second token budget and unsent unreliable-backlog dropping. Explicit StartServer installs callbacks once. Actual transport packet assembly records packetizationMs there; direct pure codec calls do not modify runtime counters.
- NetworkResults.LocalDelivery owns synchronous direct-cell publication through ClientRendererBridge, with original buffers/counts/completion times and no packet construction. TransportMetrics owns numeric sent counters; telemetry imports its copied Read without importing queues or renderer delivery. Generic counters/timings and the accepted direct local path are preserved.
- Owner decision (2026-10-17): the newer replicated setup entirely replaces legacy renderer remote intake. Removed the inactive listeners, unused renderer/bridge ConsumeSnapshot chain, ServerSimulationReplication switch, and the empty NewBoidBatch/DeleteBoidBatch/DeleteGroup RemoteEvents after active caller/publisher checks. The current BoidJobUpdate correction remote, reliable SimulationState lifecycle/bootstrap and direct local lifecycle/cell bridge remain. There is no fallback listener/metadata-only compatibility mode.
- ClientSimulation starts CameraReporter before Renderer.Start(CameraReporter.Update), binds the existing bridge, then starts simulation and normal replicated intake. The reporter alone sends CameraUpdate; the renderer still reads the actual camera but has no remote/report policy. Observation.Handoff uses ReportNow for entry, replacement, explicit view changes and large mode jumps, retaining one camera writer and the existing streaming cleanup.
- Observer host suspension is supplied by typed startup hooks. The host owns game controls; the package owns session cleanup and camera/streaming presentation.

Observation command, inspection and presentation boundaries (F22-F24)

- Shared Scenarios.ObservationTypes owns the exact Sync/Open/Close/SetCameraEnabled/CreateFixed/DeleteFixed/SelectBoid command variants, including session-bearing fields. Trusted client construction and validated server handlers use those types. Server ingress remains unknown: structural/field checks, authorization, session ownership, revisions, finite positions, limits, token admission and own-session Close bypass remain authoritative and unchanged. Types do not grant trust.
- Client Scenarios.Observation is the feature entry point. Camera, Handoff, Obstacle, Dock, Controls, Inspector, Inspection and client Types are children. Inspector alone owns its Overlays and ObstaclePanel presentation children. PackageBootstrap moves/clones that complete hierarchy normally; there are no duplicate helper instances or compatibility paths.
- Observation.Inspection receives narrow read/count callbacks from the existing registration, never starts a runtime, and owns one active-session 4 Hz selected sampler plus 2 Hz copied group rows. Only enabled selected-group overlays acquire GroupObservation. GetInspectionState/GetInspectionGroups return copied typed records, including nested simulation/sample/path/well/obstacle values. Selection/session changes reset selected-only age history; Stop and registration replacement disconnect the old sampler. Picking stays on demand inside the package.
- Client Types declares explicit Session/Selection/Camera/Streaming/Inspection/Groups/Capture subscription domains. Subscribe(domain, callback) returns cleanup. Camera/streaming notifications do not run Obstacle.Sync, notify session controls or acquire diagnostic state; capture synchronizes on relevant lifecycle/selection transitions and availability refresh.
- Controls retains session widgets and four fixed-observer slots, updating their values/visibility from current accepted state. Inspector renders received values; dock collapse/tab changes never own sampling/capture. Handoff returns a copied StreamingStatus record (state, total/loading/incomplete counts, needsAttention); Controls formats wording and Dock uses the flag, including mixed loading/incomplete requests. Camera math, its writer/restoration owner, streaming generation guards and the production renderer are unchanged.
