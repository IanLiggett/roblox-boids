# Renderer maintenance contracts

Renderer ownership and transport

Invariant

- BoidsClient.BoidsRenderer is an inert-on-import ModuleScript. ClientSimulation.Start explicitly calls its idempotent Start before binding it through ClientRendererBridge.SetRenderer. Only Start creates the single root/folder and presentation callback; read/codec consumers do not start rendering. The viewing-camera hook is supplied by ClientSimulation, which owns reporting and replicated intake.
- ClientRendererBridge calls the renderer directly for client-local snapshots and lifecycle updates.
- NetworkResults.PublishSimulationSnapshot delegates to its LocalDelivery child, which forwards each populated cell's origin, existing canonical quantized row buffer, actual boidCount and original completionTime through ClientRendererBridge.ConsumeCellSnapshot(origin: Vector3, networkBoids: buffer, boidCount: number, completionTime: number). It does not assemble packets or copy the row payload.
- Direct cell intake and direct network-packet intake share renderer row acceptance, stale/equal-time filtering, render-cell assignment and reconciliation. `BoidClientPresentationMode=renderer` decodes packed network cells directly into that intake; `simulation` routes them through CorrectionIntake as steering targets.
- Do not reintroduce a BindableEvent snapshot transport that deep-copies local snapshot/table payloads.

Renderer lifecycle intake

Current contract

- The coordinator's local spawn/delete bridge carries process-local boid lifetimes. Renderer tombstones reject delayed retired spawns/deletes without corrupting a reused ID; duplicate registration is ignored. A rejected batch cannot recreate an empty group.
- Snapshots for unknown IDs are ignored before timestamp tracking, so pre-spawn rows cannot poison the new rendered lifetime. This applies to local cell buffers and direct network packets; accepted snapshots use the unchanged no-snap reconciliation path.
- Reliable deletion/group retirement records its authoritative source-time cutoff in ReplicaIdentity. That cutoff survives serial assignment and numeric ID reuse. Both renderer snapshot entry paths reject older/equal rows before recording source time; late old poses cannot steer a new incarnation. Process-local renderer tombstones retain their separate spawn/delete role.
- Renderer alone owns dense row swaps, cell/model/Motor/query-index removal and group presentation state. Group deletion clears its color/count registry as well. The legacy renderer remote listeners were retired by explicit owner decision (2026-10-17); current `BoidJobUpdate` packets feed either CorrectionIntake or the renderer according to startup configuration.

Rendered boid representation

Current implementation

- Rendered boids live in workspace.BoidFolder.
- Each rendered boid carries a numeric BoidId attribute.
- Rendered boids have CanQuery disabled unconditionally. Physics world queries are not a supported boid-query path: even an Include-filtered ray retains broad-phase cost proportional to queryable boids. Client boid hit queries use CollisionIndex over actual rendered poses.
- BoidsRenderer anchors an invisible identity-space BoidRoot.
- Each rendered boid is driven as Motor6D.Part1, with BoidRoot as Part0.
- Calculated boid CFrames are assigned to Motor6D.Transform.
- Persistent render state is stored in parallel contiguous lists, with Vector3 values and CFrame poses. Buffers remain only at the existing snapshot/lifecycle transport boundaries.
- Snapshot rows assign rendered boids to dense 32-stud renderer-owned cell lists, partitioned by server-replica/client-only ownership. They subdivide the existing Quantization.CELL_SIZE transport cells without changing that transport layout.
- The renderer compiles visible/offscreen cell intervals from LODConfig render bands and assigns Motor6D.Transform only for boids processed by due cells. It does not maintain a per-boid priority heap or scan every rendered boid each frame.

Renderer observation reads

Current interface

- GetRenderedBoidState(boidId) returns an independent value record with groupId, the current rendered CFrame, rendered velocity, isRendered, renderedAt, and snapshotAt. Lookup is O(1); no render/simulation state is advanced or mutated.
- QueryAttack accepts a CollisionIndex request and shared budget and returns copied result metadata/hits with replica serials, contact/proxy positions and optional Part references for cosmetic feedback. Only live server replicas with serials become hit claims. Pose updates use ordinary scheduled rendering; queries never move boids or snap reconciliation. Visibility removal and dense swaps preserve index/serial lifetime.
- HasRenderedGroup(groupId) provides an O(1) lifecycle check. GetRenderedGroupBounds(groupId) traverses only that group's rendered members on demand, returning count, centroid, minimum/maximum (including collision radii), sampledAt, and oldestRenderedAt.
- Camera follow reads a single boid each frame or selected-group bounds at 2 Hz. No recurring full-population observation scan is added. These APIs work with queryIndexMode="none" and expose no mutable renderer tables, Instances, or buffers.
- renderedAt is last visual update time and snapshotAt is last accepted snapshot time; neither is the last simulation tick. Simulation tick/age comes separately from Boids.GetBoidObservation and scenario age tracking, never from renderer snapshot/read timestamps.

- GetRenderedGroupInfo returns an independent group ID/count/color record. Counts are maintained at renderer spawn/deletion boundaries, so displaying all group counts requires no recurring population scan.
- PickRenderedBoid(origin, direction, groupId?, angularTolerance?) performs an on-demand ray/sphere test against current rendered transforms, returning a value-only boid/group/position/distance record. It ignores world geometry and does not create, seed, or query BoidQueryIndex; boids remain non-queryable.
- The inspector's click handler pairs raw UserInputService.GetMouseLocation coordinates with Camera:ViewportPointToRay. GUI hit testing and top-bar/text/menu exclusions prevent selection through controls. See lessons-rendering.md for the inset pitfall.

Snapshot reconciliation

Invariant

- Do not directly place a rendered boid at an authoritative snapshot.
- Do not snap facing from snapshot velocity or otherwise snap orientation during correction.
- Turn toward the smoothed target first, then move only along current facing.
- Temporary positional error is preferred over a visible snap.
- While rendering is active, snapshot prediction continues with the latest velocity without an age cutoff. Error-triggered network silence does not establish staleness. Camera/distance suspension is excluded from both motion integration and prediction age when rendering resumes; it must not become a catch-up step. Accepted snapshots reset the prediction suspension offset without altering their source timestamps. Position correction uses a fixed 0.75-second half-life and orientation a fixed 0.1-second half-life, independent of packet gaps; both local and network intake retain the same facing-first path.

Camera-report ownership (F19)

- ClientSimulation.CameraReporter alone sends CameraUpdate. ClientSimulation explicitly starts it and supplies Update to the existing renderer callback; rendering passes only the current viewing CFrame and clock.
- The reporter retains one-second periodic reports and 128-stud jump reports with a 1/30-second minimum interval. Handoff entry/replacement/explicit moves use ReportNow and update the same state, avoiding duplicate periodic sends.
- No additional camera writer or reporting loop was added. The obsolete ServerSimulationReplication switch, direct renderer packet intake and three unused lifecycle remotes are removed; actual network correction transport remains.

Renderer scheduling

Current implementation

- BoidsClient.BoidsRenderer is the sole active renderer.
- It compiles visible render-band intervals and peripheral edge-distance scale per LOD preset, uses binary band selection per due cell, and schedules completed cells from their completion time. Cells moving toward the view center may be promoted immediately; peripheral demotions apply when their current interval completes.
- LODConfig.client.maxRenderMsPerFrame (default 4 ms) and maxMobileRenderMsPerFrame (3 ms for touch without keyboard) bound cooperative row scheduling; maxRenderBoidsPerFrame remains the secondary count cap. The clock starts before camera/cell preparation. Every row completes its pose, visibility, collision-proxy and Motor6D work before the next check, with no final transform flush. Check at cell entry and every 32 rows. The existing all-cell visibility scan, due sorting/cleanup, one row chunk and engine/GC work can overshoot: this is not a hard total-frame guarantee. Permit one initial chunk when preparation consumed the allowance so all poses cannot starve indefinitely.
- Dense cells retain their resume slot. Cells deferred for 0.5 seconds enter the existing round-robin aging pre-pass, capped at 10% of both row capacity and remaining elapsed time; normal work then remains near-first. This is an aging threshold, not a promise to finish every cell in 0.5 seconds. No missed-pose queue or catch-up burst is accumulated, and deferred displayed poses keep their corresponding query proxies. Full-pass delay grows under sustained overload.
- Each partial pass partitions completed/unvisited members. Removing a completed member repairs only that boundary, never rewinds across the completed prefix. A unique pass stamp per visited row keeps a migrant that leaves and returns in the same pass in that prefix. New pass/visibility changes invalidate the stamp by pass identity; row stamps follow dense renderer swaps and are cleared on deletion. Continuous moving membership must not starve unchanged suffix members.
- Renderer frame work and the due-cell array persist through frames. Due entries reference renderer-owned cells with cached scalar distances and per-frame visit stamps, not new wrapper/hash records. Clear due references at the end of the callback. Visibility/due collection shares one cell scan; aging completion is rechecked before ordinary due work.
- Snapshot migration into an existing cell preserves its scheduled deadline unless the member needs an opacity change. Frequent local snapshots must not promote entire destination cells to snapshot cadence. New visible cells inherit an active migrant's motion clock rather than treating cell creation as suspension. Unchanged-cell intake checks existing bounds before allocating an origin/key; current time is sampled once per incoming cell buffer/packet, not per migrated row.
- Continuous renderer/updater comparison paths are retired from the active package. User-owned backup content is not part of the active architecture.

Renderer instrumentation and reporting (F08)

- BoidsRenderer.Measurements owns opt-in timing/work counters with copied reads. Rendering accepts generic enable/reset controls; it does not interpret benchmark attributes or write reports.
- BoidsClient.Testing.RendererBenchmark owns the existing enable/reset-revision attributes, sample window and Workspace exports, composed explicitly by the client test initializer. Stop disconnects and disables instrumentation.
- The no-op printer/task and unconsumed legacy interval counters are retired. Snapshot deduplication/state timestamps and GetQueryMetrics remain active. No render scheduling, reconciliation or pose-query ownership changed.

## Hidden cell rendering

- Server replicas switch directly between opacity one/zero at active network.farDistance in both presentation modes. There is no fractional fade band, fade clock or transition-specific render cadence. Client-only groups keep their existing distance LOD. Ownership is cached per group using the established group partition policy, never inferred from individual boid IDs.
- Culling uses accepted snapshot cell locations, with the parent network-cell center for the range boundary. A cached per-frame horizontal/vertical frustum uses a conservative five-degree vertical half-angle margin, aspect-correct horizontal planes and cell sphere extent. Each sphere also encloses cached visible displayed poses: migration and ordinary render visits grow its radius in constant time; a completed pass replaces it with that pass's conservative maximum, including incoming members. Never assume snapshot membership bounds enclose smoothed presentation. No hidden-member scan, snapshot-age timeout or network request is introduced. Fixed observers may still receive distant snapshots; camera visibility is presentation policy, not acknowledged server-interest membership.
- A cell retains its dense member list and gains visibility state. Two spatial maps separate mixed ownership, with stable cell handles. Parallel arrays cache part references, row opacity, motion-resume time and accumulated prediction suspension. No per-boid heap or all-population visibility pass is added.
- Stable hidden cells are excluded from due sorting, aging, movement, transforms, query updates and transparency writes. The existing all-cell camera/scheduling scan remains. Snapshot/lifecycle intake still accepts hidden rows, but does not advance their rendered poses.
- Camera culling only suspends cell scheduling: offscreen cells leave aging/due queues immediately, without traversing members or changing transparency or partial-pass cursors. Returning to view resumes ordinary work. Distance opacity is evaluated only for in-view cells; offscreen parts and query entries retain their cached state.
- Cells mark motion suspension/resumption in the existing cell scan. Scheduled members lazily exclude the hidden gap from integration and extrapolation, preserving cached poses/timestamps throughout suspension. Hidden-to-active cell migration carries the resume marker through snapshot intake; dense swaps/removal maintain both clock arrays. No hidden-member clock maintenance pass is allowed.
- Initial/distance-hidden entry updates each scheduled pose through ordinary facing-first reconciliation before revealing it in the same frame. Already visible migrants keep their opacity on cell crossing. Each membership pass captures binary opacity, with cursor repair on membership swap/removal.
- Visibility changes use LocalTransparencyModifier and preserve template transparency/color. Membership visits share maxRenderBoidsPerFrame; property writes have a separate ceiling of min(maxRenderBoidsPerFrame, 2048) per frame. Each row switches instantly, while an entire large population may span multiple frames under this cap. Settled rows do not repeat unchanged transparency writes.
- Opacity-zero rows are excluded from picking and removed from the client hit-query index as the budgeted hide reaches them. Initial index seeding visits only cells that can contain visible rows. Spawning does not reseed existing members: new rows enter the index on their first visible pose. Cached GetRenderedBoidState/GetRenderedGroupBounds observations retain existing pose/count semantics; isRendered denotes an available cached pose, not guaranteed current visibility, and renderedAt remains unchanged while hidden. Parts and Motors remain allocated; this optimization does not unload engine instances.
- tests/Client/VerifyRenderVisibility.luau is mapped as RenderVisibilityVerification in the standalone project. Run it from a normal LocalScript after startup, with observation closed and any host camera writer suspended by the caller. It exercises the existing renderer, not a second runtime, and restores configuration/camera while deleting its reserved test groups on completion.
- tests/Client/VerifyRenderBudget.luau is mapped as RenderBudgetVerification in the standalone project. Run from a normal LocalScript with host camera control suspended and the game viewport visible. It forces partial passes with a tiny cooperative allowance, verifies Motor/query/displayed-pose agreement, deletion/dense swap/ID reuse, and far-cell aging progress under near-cell pressure; it restores configuration, measurements and fixtures. The tiny test allowance exercises bounded progress, not a supported performance target.

## Residual trajectory correction

The displayed position is advanced by latestVelocity * active dt before its residual to the predicted target is decayed with the existing position half-life. This removes steady constant-velocity lag from position-only smoothing. The resulting desired movement still passes through the existing facing-first projection; correction does not bypass orientation or introduce a positional snap. Hidden suspension clocks and render/proxy work budgets are unchanged. VerifyRenderBudget covers sparse perfect motion, corrections/reversals, matching displayed proxies and clock-separated reads; --position-only deliberately restores the old expression in memory to demonstrate the motion regression.
