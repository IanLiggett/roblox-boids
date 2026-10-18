# Renderer maintenance contracts

Renderer ownership and transport

Invariant

- BoidsClient.BoidsRenderer is an inert-on-import ModuleScript. ClientSimulation.Start explicitly calls its idempotent Start before binding it through ClientRendererBridge.SetRenderer and starting simulation. Only Start creates the single root/folder and presentation callback; read/codec consumers do not start rendering. The viewing-camera hook is supplied by ClientSimulation, which owns reporting and replicated intake.
- ClientRendererBridge calls the renderer directly for client-local snapshots and lifecycle updates.
- NetworkResults.PublishSimulationSnapshot delegates to its LocalDelivery child, which forwards each populated cell's origin, existing canonical quantized row buffer, actual boidCount and original completionTime through ClientRendererBridge.ConsumeCellSnapshot(origin: Vector3, networkBoids: buffer, boidCount: number, completionTime: number). It does not assemble packets or copy the row payload.
- Direct cell intake retains renderer row acceptance, stale/equal-time filtering, render-cell assignment and reconciliation. PacketCodec constructs/decodes actual network packets; CorrectionIntake consumes them as simulation steering targets, never direct renderer poses.
- Do not reintroduce a BindableEvent snapshot transport that deep-copies local snapshot/table payloads.

Renderer lifecycle intake

Current contract

- The coordinator's local spawn/delete bridge carries process-local boid lifetimes. Renderer tombstones reject delayed retired spawns/deletes without corrupting a reused ID; duplicate registration is ignored. A rejected batch cannot recreate an empty group.
- Snapshots for unknown IDs are ignored before timestamp tracking, so pre-spawn rows cannot poison the new rendered lifetime. Accepted snapshots still use the unchanged no-snap reconciliation path.
- Renderer alone owns dense row swaps, cell/model/Motor/query-index removal and group presentation state. Group deletion clears its color/count registry as well. Legacy renderer remote intake was retired by explicit owner decision (2026-10-17). SimulationState supplies replicated lifecycle and BoidJobUpdate supplies steering corrections; there is no alternate renderer producer.

Rendered boid representation

Current implementation

- Rendered boids live in workspace.BoidFolder.
- Each rendered boid carries a numeric BoidId attribute.
- Rendered boids have CanQuery disabled unconditionally. Physics world queries are not a supported boid-query path: even an Include-filtered ray retains broad-phase cost proportional to queryable boids. Client boid hit queries use BoidQueryIndex.
- BoidsRenderer anchors an invisible identity-space BoidRoot.
- Each rendered boid is driven as Motor6D.Part1, with BoidRoot as Part0.
- Calculated boid CFrames are assigned to Motor6D.Transform.
- Snapshot rows assign rendered boids to dense 64-stud renderer-owned cell lists; this subdivides, but does not change, the 128-stud simulation/query-cell contract.
- The renderer compiles visible/offscreen cell intervals from LODConfig render bands and assigns Motor6D.Transform only for boids processed by due cells. It does not maintain a per-boid priority heap or scan every rendered boid each frame.

Renderer observation reads

Current interface

- GetRenderedBoidState(boidId) returns an independent value record with groupId, the current rendered CFrame, rendered velocity, isRendered, renderedAt, and snapshotAt. Lookup is O(1); no render/simulation state is advanced or mutated.
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

Camera-report ownership (F19)

- ClientSimulation.CameraReporter alone sends CameraUpdate. ClientSimulation explicitly starts it and supplies Update to the existing renderer callback; rendering passes only the current viewing CFrame and clock.
- The reporter retains one-second periodic reports and 128-stud jump reports with a 1/30-second minimum interval. Handoff entry/replacement/explicit moves use ReportNow and update the same state, avoiding duplicate periodic sends.
- No additional camera writer or reporting loop was added. The obsolete ServerSimulationReplication switch, direct renderer packet intake and three unused lifecycle remotes are removed; actual network correction transport remains.

Renderer scheduling

Current implementation

- BoidsClient.BoidsRenderer is the sole active renderer.
- It compiles visible render-band intervals and peripheral edge-distance scale per LOD preset, uses binary band selection per due cell, and schedules completed cells from their completion time. Cells moving toward the view center may be promoted immediately; peripheral demotions apply when their current interval completes.
- Rendering is capped by client.maxRenderBoidsPerFrame. Dense cells retain a resume slot, and cells deferred for 0.5 seconds receive a bounded aging round-robin pre-pass before returning to normal near-first work; this prevents starvation without demoting nearby cells after their fairness slice.
- Continuous renderer/updater comparison paths are retired from the active package. User-owned backup content is not part of the active architecture.

Renderer instrumentation and reporting (F08)

- BoidsRenderer.Measurements owns opt-in timing/work counters with copied reads. Rendering accepts generic enable/reset controls; it does not interpret benchmark attributes or write reports.
- BoidsClient.Testing.RendererBenchmark owns the existing enable/reset-revision attributes, sample window and Workspace exports, composed explicitly by the client test initializer. Stop disconnects and disables instrumentation.
- The no-op printer/task and unconsumed legacy interval counters are retired. Snapshot deduplication/state timestamps and GetQueryMetrics remain active. No render scheduling, reconciliation or pose-query ownership changed.
