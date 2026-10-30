# Error based network LOD implementation plan

Replace frequency based snapshot selection with per boid, per recipient prediction error selection in both presentation modes. The server owns baselines; direct rendering remains independent of client simulation. This is the implementation and handoff checklist.

## Agreed behavior

- Compare completed authoritative packet-ready state with the last sent decoded quantized position plus velocity times source-time delta. Trigger on positional error OR velocity difference, using squared distances.
- Interpolate tolerances using existing observer distance policy and network interest range, per recipient and cell. No frequency gate or minimum send interval.
- LOW: position 4 to 16 studs, velocity 2 to 8 studs/s. MEDIUM: 2 to 8 and 1 to 4. HIGH: 1 to 4 and 1 to 2.
- Initial missing baseline selects a snapshot on the next eligible completed update. Baselines advance only for rows handed to FireClient. No acknowledgements, retries, recovery, periodic refresh, or reliable motion transport.
- Queue only the newest pending state per recipient/boid; preserve source timestamps and homogeneous source-time packets. Never publish failed or incompletely merged jobs.
- Keep a finite cap, per client, temporarily 50,000 packets/s. The owner supplied operating limit is 500 packets/s/client; target sustained traffic below 400 for headroom.
- Start batching at 50 ms. During validation increase in 25 ms steps if needed for packet headroom. Report unsupported populations rather than weakening accuracy. This is validation tuning, not runtime adaptation.
- Direct rendering continues constant-velocity prediction beyond 24 seconds and uses fixed correction half-lives, preserving facing-first movement without snaps.

## Implementation checklist

- [x] Inspect current replication, Actor transport, renderer and maintenance contracts.
- [x] Replace network interval configuration and frequency eligibility with interest and error tolerances.
- [x] Implement coordinator-owned compact recipient baselines and pending row selection; decode each candidate once across recipients.
- [x] Generate packed candidates from eligible completed jobs without per-boid object materialization or a separate simulation-storage traversal.
- [x] Handle actual sends, source ordering, migration, deletion, ID reuse, group teardown and disconnect.
- [x] Implement per-client cap; start at 50 ms and retain measured 75 ms batching.
- [x] Remove renderer extrapolation cutoff and packet-gap-based smoothing.
- [x] Instrument selection CPU, candidates/comparisons, selected/sent rows, per-client traffic, queue latency, cap drops and baseline memory.
- [x] Update architecture and narrow runtime/rendering/measurement contracts.
- [x] Add meaningful automated coverage and run available checks.
- [x] Build game and standalone package, generate sourcemaps, run UnitTest and normal-client handoff checks.
- [x] Measure 20k obstacle, 20k spread, 30k concentrated and forced-nearest 30k workloads; tune batching and record runtime limits.
- [ ] Follow-up validation: actual multi-client load (only one client was connected). Independent recipient behavior is unit/integration tested, and isolated CPU probes used one/four recipients.

## Required handoff findings

- Coordinator filtering necessarily adds a visit to packed completed rows that previously could be copied in bulk. It must not reread all simulation storage or scan the full population. Work scales with completed candidate rows times interested recipients; measure rather than claim a speedup.
- WorkerCore remains shared and simulation-only; do not copy recipient baseline histories through Actor jobs. Existing full-job Actor transport and commit guards remain authoritative.
- NetworkResults.ServerTransport now owns per-client tokens (50,000/s temporary) and 75 ms partial batching. PacketCodec keeps packets homogeneous by source time. Full packets must not flush unrelated partial source-time packets early; rowsByTime tracks fullness without re-scanning all pending rows on every enqueue.
- Actor transport stringifies sparse numeric keys. Preserve source/destination normalization at ResultCommit and use dense cross-Actor data.
- Packet position and velocity are quantized. Baselines must match decoded wire values. Prediction horizons are source-time deltas, never queue/flush clocks.
- Existing source timestamps are job completion times; preserve that contract in this change. Simulation update scheduling bounds detection latency.
- BoidsSystem is an independent submodule. No commits, pushes, publication, remote changes or parent pointer updates are authorized.
- Working tree already contains unrelated game edits and pre-existing package edits in LODConfig.luau and BoidsReplicated/init.meta.json. Preserve them; LODConfig network interval fields are intentionally replaced by this feature.
- Owner confirmed server packet layouts are trusted: no additional malformed-packet validation pass. Existing CorrectionIntake documentation/test expectations were stale and are aligned with fail-fast programmer errors.
- Regenerating the checked-in worker fixture exposes three existing tests that assume MAX_SEEN=100 while production has MAX_SEEN=20. The pre-change production worker reproduces the same failures. Do not change simulation or expectations to hide them.
- Studio handoff verification must run from a normal LocalScript with observation CLOSED; the connected session had observation active, and the first check failed its prerequisite. Closing observation then rerunning passed.

## Validation record

Completed checks on 2026-10-29:

- Game: `./rojo.cmd build default.project.json --output build/BoidShooter.rbxlx` and the required sourcemap command passed.
- Standalone: `./rojo.cmd build packages/BoidsSystem/default.project.json --output build/BoidsSystem.rbxlx` and its sourcemap command passed. The root rojo.cmd always changes cwd to the game root: passing ../../ output paths from the package directory initially failed. Use explicit package project paths from the game root.
- `git -C packages/BoidsSystem diff --check` passed. Git prints existing LF/CRLF conversion notices for generated fixtures.
- Studio UnitTest: 102 run, 99 passed, 3 existing worker failures. Use `require(game.ServerStorage.UnitTest.RunUnitTest)(nil,10)`; the default five-second timeout races the intentional five-second deadline test. JobExecution separately passed all 16 checks with timeout 10.
- Existing worker failures: Step01 co-located 101 accounting expected 10100/got 2020; Step27 100/101 accounting expected 10000/got 2020; Step27 coincident/boundary tick-wrap expected 1/got 3. The original production worker reproduces these offline; regenerated fixtures expose old assumptions. Do not change MAX_SEEN or these expectations as part of network work.
- Full package source/tests type analysis reports only three pre-existing Catalog errors at lines 554, 555 and 568 (PathNode union/table narrowing). Targeted network code has no TypeError/SyntaxError. Builds are not a type-clean claim.
- Normal LocalScript handoff verification passed acquired=2, released=2, cameraRestored=true after explicitly closing observation. The initial failure was caused by running with an active observation session.
- Offline actual-transport harness passed batching, recipient-specific thresholds, retirement, ID reuse and disconnect. New UnitTest cases cover positional/velocity triggers independently, quantized baselines, quiet intervals, pending coalescing/cancellation, partial sends and ordering, packet splitting, retirement and metrics copies.

Live Studio measurements used LOW, one client and the current server simulation cadence. Rates below are canonical payload, not engine framing; engine network Stats were unavailable. These are feature runs, not a paired performance claim despite older benchmark metadata using the label baseline.

| Workload | Batch ms | Packets/s | Payload kB/s | Selection ms/s | Notes |
|---|---:|---:|---:|---:|---|
| PolarSphereObstacle 20k, renderer | 50 | 133.1 | 76.4 | 9.1 | Original observer/camera state |
| BenchmarkReference20k, simulation | 50 | 426.9 | 32.2 | 10.3 | Motivated larger batching |
| Reference20k before partial-flush fix | 75 | 431.9 | 32.2 | 11.5 | Historical diagnostic, not final behavior |
| Concentrated30k, renderer, all interested | 75 | 347.0 | 146.0 | 23.7 | Minimum-distance fixed observer; all 30k baselines |
| Concentrated30k confirmation | 75 | 338.9 | 139.7 | 18.1 | No UnitTest activity; maximum sampled packet bin 357 |
| WorstCase30k, all nearest LOD | 75 | 289.4 | 144.8 | 17.5 | Minimum network thresholds for all; nearest simulation; every render cell scheduled at 30 Hz; max packet bin 326 |

No local cap drops, failed merges or timed-out simulation jobs were observed in the measured workload windows. Batching stayed at 75 ms once the 30k headroom target was met. The worst-case recipient held 30k baselines with 1,086,976 packed state bytes (excluding Lua table/allocator overhead).

Worst-case interpretation is essential: a normal bounds-following camera had to pull back as the flock spread, so it did not prove the close-LOD workload. Temporary normal runtime Scripts then forced minimum LOW network tolerances (4 studs/2 studs/s), nearest simulation multiplier 1, and all renderer cells at 30 Hz, without changing production presets or forcing accuracy downward. All 30,000 rendered parts were confirmed in the camera viewport. A subsequent five-second renderer sample produced 39 frames (~7.7 FPS), ~42.2 ms renderer time/frame: network headroom passed, but this client/Studio rendering workload is past comfortable frame rates. Scheduled 30 Hz is not achieved 30 FPS. Current simulation cells use a one-second base interval and clamp multipliers to at least 1; these results do not establish capacity at a faster future simulation cadence.

Local raw evidence and harnesses live under game-root .tools/error-network-*.json/.txt and .tools/verify-error-network-lod.luau (ignored, not redistributable package dependencies). Studio reports were read from actual runtime StringValues; no second coordinator was started in an inspection VM. The native annotation is not proof of native execution. Play was stopped, removing test-only Scripts and LOD overrides. Original Edit attributes were restored and read back: PolarSphereObstacle, renderer, both; temporary BoidBenchmark* attributes were removed.


## Background visibility follow up

### Simulation-mode CPU regression follow-up (20k load limit)

#### Correction delivery inspection — ownership review required

New owner constraints: at least eight client Actors; original correction buffers should cross the Actor boundary without coordinator decoding/materialization or validation, and each Actor should traverse its received buffer once into stable tables. Current Actor count is 16 and was not changed.

Confirmed violations: SimulationReplication.CorrectionIntake.Consume invokes Boids.SetReconciliationTargets with a per-row acceptance callback. Boids decodes each incoming packet on the coordinator, CorrectionIntake maintains a separate position/velocity/time cache, Boids constructs liveTargets containing one allocated table per row, and SendMessage deep-copies those tables to every Actor. WorkerCore then traverses the copied list, repeats lifecycle/time acceptance and allocates a new ReconciliationTarget record. There is no full packet-layout validation pass; there is a source-time finite check and per-row lifecycle/freshness handling. These lifecycle/order checks have a purpose with unreliable reordering and reused IDs, but can belong in the single Actor decoding pass rather than a coordinator traversal.

Proposed concrete path: forward the original packet buffer plus its existing source timestamp through Boids to each existing Actor, with no row walk, repacking or per-row target objects before the boundary. Decode once per Actor directly into reusable correction records. Distribute replica ownership, lifetime and retirement cutoffs through lifecycle controls so local-only/retired/reused IDs cannot be steered by old packets. Do not change the wire format, add recovery/coalescing, reduce Actors or relax accuracy thresholds as part of this change. The unavoidable buffer copy is once per destination Actor, not once globally for the entire pool.

Architecture impact requiring owner review: runtime.md currently makes CorrectionIntake the sole correction acceptance owner and maintains a coordinator correction mirror for ForEachClientCorrection/PerformanceTelemetry.Divergence. Keeping that mirror updated from every network packet would violate the requested once-only decoding path. Proposed ownership is Actor-owned correction acceptance/state, with divergence aggregates produced through existing worker result reporting instead of a coordinator per-boid correction cache. Worker-sampled divergence has a different sampling cadence/weighting from the current coordinator-wide metric and must be documented. Worker stable-record mutation also needs to preserve control/parallel-job consistency. The owner subsequently approved this ownership/API change and required the heavy Actor work to execute in parallel. The implementation and validation below supersede the pending-review status.


Parallel correction implementation (owner approved):

- [x] Original network buffer/source timestamp forwarded without coordinator validation, decoding, row filtering, repacking, or a correction mirror. One engine copy per destination Actor; sixteen Actors retained.
- [x] WorkerCore correction, stats, retirement, path and other control handlers all use BindToMessageParallel. Their Actor-local table updates do not yield. No serial/parallel cache copy is introduced.
- [x] ActorCorrections decodes once into persistent records, preserving the previous six-second steering expiry. Per-row freshness and lifecycle fences run in that pass. A scalar nextLifetime high-water mark captures which process-local lifetimes existed when a packet was forwarded; stats registration supplies group ownership and rejects pre-creation pending rows. Reliable cutoff retirements are batched into dense ID lists, avoiding one message per boid.
- [x] Worker/job diagnostics replace ForEachClientCorrection. Job sampling revisions fence late results; constant-size aggregates preserve exact mean/RMSE/standard deviation/max over the worker samples with the existing three-second inclusion window. Median values are omitted because no per-boid errors are copied. These job-frequency-weighted statistics are not equivalent to the old one-second population sample.
- [x] Unit coverage checks stable record identity, reordered/duplicate targets, corrections before stats, pre-creation fences, retirement/ID reuse, full-u16 ownership, trusted malformed-row decode failures, original-buffer relay identity, and exclusively parallel registration of worker controls.

Live 20k/16-Actor sample: coordinator correction forwarding 30.20ms over 8.022s for 849 packets (3.76ms/s, 0.0356ms/packet), versus the previous decoded/table-forwarding sample's 953.92ms over 8.077s for 938 packets (118.1ms/s, 1.017ms/packet). This is about 97% less coordinator-path elapsed time, not a claim of 97% less total simulation CPU. Actor correction callbacks report 958.53ms summed across all sixteen Actors over the sample (~119.5ms/s), 14,279 packet copies and 923,550 decoded rows. These counters drain with the next successful worker job, so interval edges can include delayed samples. They exclude boundary transfer; worker job execution is a separate counter. More frames allowed more rendering work in this run, so do not infer a whole-client CPU/FPS multiplier from the coordinator gain alone.

Repeat/final run after sharing immutable inert targets on server workers: .tools/parallel-correction-cpu-20k-final.json records 33.28ms coordinator forwarding / 8.003s for 854 packets (4.16ms/s), plus 940.86ms summed parallel intake (~117.6ms/s). Client behavior is unchanged by that server-only allocation reduction. Together the runs support a coordinator forwarding range of 3.8?4.2ms/s.

Raw result: .tools/parallel-correction-cpu-20k-measured.json. The earlier parallel-correction-cpu-20k.json has zero probe correctionCalls because the initial relay captured a function before the probe replaced it; it is excluded from forwarding timing. Actual worker divergence reports in that run contained 306,205 observations, confirming functioning intake. All load probes reuse exactly the existing 20k boids. No additional simulation population was spawned.

Owner now requests 20,000-boid load tests only. Preserve the owner's uncommitted `BoidClientPresentationMode=simulation` metadata setting. Current task compares package HEAD ebd84f2/d688890 with the fixes below; no package commits or uploads are authorized.

- [x] Find and fix migration-triggered render deadline promotion. The visibility implementation added `nextDueTime=min(nextDueTime, now)` for every moved row, including existing visible destination cells. Frequent local snapshots consequently bypassed render LOD and repeatedly visited whole cells. Only required opacity changes now promote an existing cell; normal migrations preserve its deadline.
- [x] Preserve an active migrant's cell clock and opacity when creating a new cell. Spatial cell creation must not masquerade as a pause/resume event. Hidden migration retains its existing resume marker and no-catch-up behavior.
- [x] Remove per-migrated-row GetServerTimeNow calls; sample once per buffer/packet. Return from unchanged-cell intake using existing bounds before origin/key construction and ownership-map lookup.
- [x] Reuse the existing private CorrectionIntake target record on newer corrections; skip empty accepted-target Actor broadcasts. Source ordering, lifetime rejection and packet trust remain unchanged. Detailed correctionMessages now counts actual nonempty broadcasts. These small changes do not solve the broader Actor fan-out cost.
- [x] Add a normal-client regression assertion that an already-visible row migrating into a settled slow cell cannot change an anchor member's renderedAt before its deadline. Strengthen correction tests for duplicate timestamps after updating an existing record.

Measured CPU evidence (normal runtime LocalScripts, not tool-cache coordinator instances): the PolarSphereObstacle scenario contains exactly 20k real boids. No additional synthetic population was created. A controlled phase intercepts only renderer snapshot intake, then feeds those same 20k existing IDs in 1k-row cohorts across adjacent 32-stud cells. The simulation keeps running; the phase isolates renderer scheduling rather than claiming a realistic flock workload. Use .tools/cpu-20k-controlled-before.json for the valid pre-fix controlled run: 2,178,000 motion updates / 6.034s and 1,735.2ms renderer time. The post-scheduling-fix controlled phase in .tools/cpu-20k-after.json records 341,000 updates / 6.015s and 278.9ms: about 84% less renderer CPU, despite processing 352k intake rows versus 200k before. Frame counts were 199 versus 351, so this is actual work/time evidence, not a claimed general FPS multiplier. Controlled migration intake cost per row falls from about 0.797us to 0.512us.

Live near-view PolarSphereObstacle samples: pre-fix renderer 1,556.6ms / 8.046s = 193.5ms/s; final 1,355.2ms / 8.077s = 167.8ms/s (about 13% lower). Local snapshot intake 198.0ms / 8.046s = 24.6ms/s versus 153.8ms / 8.077s = 19.0ms/s (about 23% lower), while accepted local rows rose from 179,350 to 188,712. Dynamic client/server paths and cell counts differed, so treat live deltas as indicative. Worker CPU remained around 112–118ms/s summed across workers; no worker steering or simulation LOD setting was changed. The final probe still spends about 118ms/s in SetReconciliationTargets (decode, target construction and Actor sends), across 938 packet calls in 8.077s with 16 client Actors. This measurement does not include each worker's target-handler CPU and is not an isolated SendMessage timing.

Remaining decision: the new error-triggered policy emits corrections far more often than the former LOW 12–24-second periodic schedule. The pre-existing correction path decodes targets into per-row tables, broadcasts every accepted batch to all Actors, and constructs worker target records. Sixteen Actors amplify this cost; it is absent in direct rendering. Prefer a reviewed packed/coalesced Actor correction design to preserve accuracy while reducing table copies/messages. Coalescing adds bounded correction latency; fewer Actors trade transport overhead against parallel simulation capacity; looser thresholds reduce accuracy. Routing only to the currently assigned Actor is unsafe because jobs migrate between Actors. No such transport/ownership redesign or accuracy reduction was made here.

Raw local evidence/harnesses: .tools/cpu-20k-before.json (use actual_* stages only), cpu-20k-controlled-before.json, cpu-20k-after.json, cpu-20k-final-near.json, cpu-20k-controlled.client.luau, cpu-20k-after.client.luau, cpu-20k-before-renderer.luau. The first exploratory controlled stage in cpu-20k-before.json used an incorrect 128-stud assumption; offsets clamped under the actual 64-stud wire cell and it is excluded. The corrected controlled harness uses origin 3008 and local X 31/33, producing genuine render-cell migration.

Validation/cleanup: normal-client visibility checks pass in simulation and direct-renderer modes, including the new migration/deadline regression and previous hidden-clock/opacity/query/lifecycle assertions. Handoff passes acquired=2/released=2/cameraRestored=true. Full UnitTest is 105/109; the unchanged four failures are the three WorkerCoreStep01/27 neighbor/tick expectations and the owner-tuned LOW 8-versus-4 error assertion. Full analysis retains only the same three Catalog PathNode type errors. Both Rojo builds and both sourcemaps pass; git diff --check passes. Play is stopped, current fixes read back in Edit, and original PolarSphereObstacle/simulation/both settings restored. The owner's metadata edit remains untouched in the filesystem. All added load probes reused exactly the existing 20k boids; the separate reusable integration checker uses its usual three temporary fixture IDs. No commit, publish or remote change.

Current owner-requested experiment: replace smooth fades with binary opacity at network.farDistance, retaining camera-only scheduling suspension and hidden-clock correction. Remove fade-in/warm-up state and the 30 Hz transition cadence. Rows update pose before being revealed in the same frame; hide/reveal each needs one opacity write per affected row, still capped at 2,048 writes/frame. Thus individual rows switch instantly while a 30k population can take multiple frames. The original smooth-fade approval/results below are historical comparison evidence.

### Instant visibility comparison

Implemented binary visibility. Two fresh smooth-control sessions and two fresh instant sessions used the same normal-client 30k synthetic workload, LOW preset, 2,048-write cap, 90-degree view, near camera at 180 studs, two-second boundary sweep, and six-second hidden/offscreen windows. The normal BenchmarkReference20k scenario remained running with its renderer groups outside the test view. All 32 synthetic renderer cells were in view at the near/0.9-range stages. Source snapshots are static/zero velocity: this measures presentation work, not simulation accuracy or network throughput. Transition counters include the subsequent settle window; CPU totals below cover the whole phase rather than omit deferred work.

| Stage | Smooth writes | Instant writes | Smooth total renderer ms | Instant total renderer ms |
|---|---:|---:|---:|---:|
| Initial reveal | 34,800 | 30,000 | 242.4 | 160.8–180.6 |
| Boundary sweep and settle | 71,168–72,016 | 30,000 | 154.6–158.3 | 112.4–123.1 |
| Reveal at 0.9 network range | 38,400 | 30,000 | 139.8–144.5 | 72.3–78.9 |
| Full hide | 30,000 | 30,000 | 39.1–40.3 | 36.1–37.7 |
| Near reentry | 38,400 | 30,000 | 239.2–251.5 | 156.9–193.1 |

Boundary writes fall about 58%; near-reentry writes fall 22%. Full hide already required only one write per row. Settled hidden/offscreen samples in every run have zero motion and transparency writes; camera rotation still triggers no hide/reveal pass. Each instant transition writes each affected row once; it does not animate fractional opacity or run a hidden warm-up pass.

Timing limitation: smooth hidden windows achieved about 60 frames/s, while instant sessions achieved about 15 frames/s even with zero renderer membership work. The sessions also retained differing background-cell counts. This is not an established FPS improvement, and the observed total phase CPU reductions are indicative rather than a controlled per-frame speedup claim. In the first matched pair the boundary phase plus settle took 2.12s smooth versus 2.57s instant; the 0.9-range reveal took 5.35s versus 1.12s. The per-frame cap remains necessary, and low frame rates can delay completion of whole-population switches.

Local ignored evidence: .tools/instant-visibility-benchmark.client.luau, instant-visibility-smooth-baseline.json, instant-visibility-smooth-repeat.json, instant-visibility-result.json, instant-visibility-repeat.json. The captured pre-change renderer is .tools/instant-visibility-smooth-renderer.luau. Exploratory near-80/cached-session runs were excluded from the table; the final harness fixes a degenerate offscreen look target introduced when increasing the near distance. Current source was restored after each temporary smooth control.

Instant validation: seven updated visibility unit cases pass. Normal-client verification passes in renderer and simulation modes, retaining mixed-ownership behavior, one-boid frame budgeting, dense removal/ID reuse, hidden query exclusion, rotation zero-work, and moving hidden-clock reentry checks. Handoff passes acquired=2/released=2/cameraRestored=true. Game/standalone builds and both sourcemaps pass; full analysis retains only the same three Catalog PathNode type errors. git diff --check passes aside from informational CRLF notices. Play was stopped, current binary policy read back, and original PolarSphereObstacle/renderer/both Edit settings restored. No commit, upload or remote change.

Approved: smooth distance fade for server-owned boids in both modes, client-only distance policy unchanged, and no per-boid work for fully hidden/offscreen cells. Fade spans 80% to 100% of network range; re-entry warms hidden poses then fades in over 0.25 seconds. Reuse dense cell lists and frame budget, partition mixed ownership cells, preserve cached observation poses, and remove invisible rows from presentation hit queries. No additional network messages or recovery.

Owner clarification: camera rotation must only suspend render scheduling, with no fade or membership work on exit. The original implementation incorrectly shared its opacity target between distance and frustum culling. The correction below supersedes camera fade/re-entry behavior described in the original validation; warm-up/fade-in applies to initial/distance-hidden entry only.

- [x] Separate camera culling from distance opacity. Cache one in-view boolean per cell; remove offscreen cells from aging and due work before evaluating distance opacity. Retain opacity, partial cursor, fade state and cached query entries while offscreen. Snapshot/lifecycle intake continues.
- [x] Verify repeated camera exits/reentries in both presentation modes: zero motion/transparency writes while offscreen; visible local and replicated parts retain opacity; returning to view does not restart a fade.
- [x] Rebuild game/standalone and both sourcemaps; seven visibility unit cases pass. Full package analysis retains only the three existing Catalog PathNode type errors. No additional per-boid data or structural ownership change is needed.

- [x] Implement per-cell visibility and ownership partition without a full-population render scan.
- [x] Budget smooth transparency transitions; keep stable hidden cells out of aging and due queues.
- [x] Verify index seeding, picking, deletion, migration and dense swaps while hidden/fading.
- [x] Add visibility tests and metrics; build and analyze source.
- [x] Measure 30k visible, fading, hidden/offscreen and re-entry costs; record actual results.

Required findings: current renderer cells are 32 studs, not the older 64-stud documentation. Visibility must use the last accepted snapshot cell, not extrapolated pose or packet age. The all-cell scheduler scan remains; only membership iteration is eliminated when hidden. Smooth fading adds per-part property writes during transitions and must be measured separately from motion.

### Visibility implementation findings

- Hidden-clock correction: skipping member work did freeze poses, but wall-clock integration delta and snapshot extrapolation age still accumulated. Returning after a long hidden interval therefore advanced toward a scattered predicted target during fade-in. Cells now mark motion resume time; scheduled rows lazily subtract the suspended gap from both calculations. Fresh accepted snapshots reset prediction offsets while retaining authoritative source-time ordering. Two additional scalar arrays preserve row resume markers and suspended prediction duration, including hidden-to-active migration and dense swaps. This supersedes the original two-array-only count below. No hidden membership pass is added.
- Hidden-clock validation: extended the normal-client verification with 128-stud/s snapshots and two-second distance/camera suspensions. It checks exact cached pose/timestamp freeze, bounded first resumed displacement, and no subsequent movement toward the hidden-time extrapolation. Both presentation modes pass. A fresh control Play session temporarily restored only the old wall-clock delta/age formulas and failed with `First resume integrated hidden time`; current filesystem source was restored afterward. Seven visibility unit cases pass; game/standalone builds and both sourcemaps pass. Full package analysis retains only the three existing Catalog type errors.

- Dense per-cell member lists and swap removal are retained. New per-group ownership metadata separates replica/local spatial maps; stable numeric cell handles avoid enlarging spatial Cantor keys. Extra per-boid data is two parallel arrays (cached part reference and opacity), not individual objects or heaps. Cell visibility state and cached centers are O(cell count). A dispersed population can have many cells, so the retained cell scan is not a constant-cost promise.
- Initial transparency work using the full 100,000-boid budget produced multi-second engine stalls when 30k parts changed together. Final code additionally caps transparency changes at 2,048/frame, within the existing overall budget. Engine/GPU cost is not captured by Lua renderer timing alone. Cell fade clocks target 0.25 seconds but population completion is allowed to take longer under the cap or slow frames.
- Stable fractional transparency returns to ordinary distance LOD; only changing opacity/warm-up uses the 30 Hz transition cadence. Otherwise a stationary distant fade band would unnecessarily update all members at 30 Hz.
- Visible migrants initialize new cells as eligible, avoiding a blink on every cell crossing. Mixed-opacity membership invalidates the cell's uniform-opacity marker. Removing a member rewinds a partial cursor to cover a swapped-in unvisited row.
- Query seeding skips fully hidden cell lists. Spawns no longer trigger global reseeding: accepted snapshots cannot precede registration, and each new row is inserted by its first visible render. Fully transparent members are removed during budgeted hide passes, while cached observation poses remain available.
- Current owner-tuned LOW errors are 8/32 studs and 4/16 studs/s, differing from this document's original approved defaults. Preserve that tuning. NetworkLOD_Test's old hard-coded LOW expectation now fails (expected 4, actual 8); this failure pre-dates the visibility edits.

### Visibility validation

- Seven new RenderVisibility unit cases passed. Full Studio UnitTest run: 109 run, 105 passed, 4 existing failures (the earlier three worker accounting/tick-wrap failures, plus the owner-tuned LOW accuracy mismatch above). Full package analysis still reports only the three pre-existing Catalog PathNode type errors at lines 554, 555 and 568.
- Normal-client VerifyRenderVisibility passed in direct-renderer and client-simulation presentation modes, including mixed ownership at one location, smooth mid-band opacity, a one-boid overall frame budget, dense deletion, invisible query exclusion, hidden snapshot intake without pose advancement, offscreen zero-work, ID reuse, and visible migration without restarting a fade. Normal-client handoff verification passed acquired=2/released=2/cameraRestored=true.
- The controlled 30k visibility probe adds 30,000 synthetic renderer members in 500-row chunks near x=3040; the existing 30k server scenario remains hidden. Thus it holds about 60k engine instances' boids but exercises exactly 30k target render members. Static packed inputs isolate renderer work rather than claim a simulation benchmark. Six-second hidden samples cover the previous five-second offscreen cadence.
- A fresh Play session temporarily used the captured pre-fade renderer (only its measurement call was adapted to the new counter arity), then the current filesystem renderer was restored for another fresh session. Single-session timings below are indicative, not a statistically repeated throughput claim. Their retained cell counts varied slightly (84 versus 87). Instances remain allocated even when hidden; zero Lua member work does not imply zero engine/physics cost or a guaranteed overall FPS.

| Controlled stage | Before average renderer ms/frame | After average renderer ms/frame | Before motion visits | After motion visits |
|---|---:|---:|---:|---:|
| Beyond range, six seconds | 1.482 | 0.061 | 162,303 | 0 |
| Offscreen, six seconds | 0.451 | 0.054 | 42,303 | 0 |
| Visible near, two seconds | 21.632 | 14.798 | 176,700 | 822,000 |

Visible samples had different achieved frame counts, so use the counters as context rather than attributing an overall frame-rate improvement to culling. Stable hidden stages had zero transparency writes and zero due/aging membership work. The settled partial-opacity stage had zero transparency writes and 0.923 ms average renderer time. All transition samples respected the 2,048-write maximum. In the final probe, fade-in sampling took 1.257 seconds plus 0.884 seconds until fully settled; the distance fade took 1.020 seconds plus 3.005 seconds to settle; re-entry took 1.252 seconds plus 0.230 seconds. These population transition delays are the intentional budget tradeoff, not a 0.25-second whole-flock guarantee.

Raw evidence: game-root .tools/fade-30k-unlimited-transition.json, fade-30k-capped-first.json, fade-30k-baseline.json, fade-30k-final.json; probe source .tools/fade-perf.client.luau. These are local ignored artifacts. The redistributable client verification is tests/Client/VerifyRenderVisibility.luau, mapped as RenderVisibilityVerification only in the standalone project.

Final visibility cleanup: Play was stopped; original PolarSphereObstacle/renderer/both Edit settings were restored and read back, with temporary BoidBenchmark attributes removed. The current filesystem renderer was restored after the baseline comparison and its 2,048-write cap verified in Edit. Game and standalone builds and both sourcemaps passed; git diff --check passed apart from informational LF/CRLF notices. Actual multi-client load validation remains outside the single-client visibility runs.


Parallel correction validation: full Studio UnitTest 113 run / 109 passed / 4 pre-existing failures (three worker neighbor/tick expectations and the LOW 8-versus-4 tuning assertion). Six new ActorCorrections cases pass, including parallel-only control registration; buffer-relay and worker-divergence tests pass. Offline targeted suite 46/49 with the same three worker failures; DynamicIds CLI 26/26. Full type analysis retains only the three existing Catalog PathNode errors. Both builds and sourcemaps pass. Runtime visibility regression passed in simulation and direct-renderer modes; the normal-client handoff check passed acquired=2/released=2/cameraRestored=true. The generated worker/scheduler fixtures were refreshed using their production generators. Load probes used exactly 20k existing boids and sixteen client Actors.

Final parallel cleanup: Play stopped; PolarSphereObstacle/simulation/both settings read back unchanged, with the parallel raw-buffer implementation present in Edit. No Actor count reduction, wire/remotes change, publish, commit or push. Server workers share one frozen inert target instead of allocating client correction metadata; client Actors retain reusable target/lifecycle records. Memory was not compared, so the reduced transient allocation/copy work is not a claimed total-memory reduction.
