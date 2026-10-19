# Parallel boid rendering implementation plan

Replace serial per-boid presentation math with persistent render Actors. Each Actor computes CFrames in parallel, synchronizes, and assigns its own Motor6D transforms from local arrays. Improve renderer elapsed time and frame-time tails at equivalent work, primarily in RandomTargetStress, with BenchmarkReference20k as the controlled comparison.

## Authority and continuation

Read [AGENTS](../AGENTS.md) and its rendering, runtime, observation, and measurement reading routes before implementation. This plan authorizes the renderer ownership/storage changes and observer interface changes described below; preserve simulation authority, lifecycle ordering, and facing-first no-snap reconciliation.

The package is on the dedicated `renderer-multithread` feature branch. **Replace the old rendering architecture directly; do not maintain it alongside the new architecture, introduce compatibility adapters, or add a baseline runtime switch. Package `main` is the baseline.** At plan creation, package main was `c2b35bbf13097ca9feb92668a39fae0cee7b026b`. Use separate builds/checkouts for comparisons. The containing game's branch was still `main`; do not confuse the host branch with the package branch or switch either as an implementation shortcut.

Mark a section complete only after its stated checks pass. Record only hard-to-recover continuation information under Continuation notes: unresolved blockers, evidence/artifact locations, or a necessary departure from this plan. Do not add a running diary, repeat discoverable code facts, or duplicate checklists. No implementation sections are complete initially.

## 1 Baseline and execution timing

- [x] Complete

- Capture baseline builds/evidence from package main before replacement. Preserve unrelated host changes; record the actual source/build identity used for measurements.
- Use a small tagged Actor probe to establish dispatch, parallel calculation, synchronization, serial Motor assignment, and engine transform-batch timing in the installed Studio build. Begin with the current render-cycle placement and no intentional additional frame delay. If dispatch introduces an unintended extra frame, resolve that before expanding the implementation.
- Retain Motor6D and the invisible identity-space root. Do not replace them with BulkMoveTo. Motor6D assignments are submitted offsets; the engine applies them later in a deferred parallel batch after PreSimulation. Measure both script work and that later engine work. Reference: [Motor6D timing](https://create.roblox.com/docs/reference/engine/classes/Motor6D).
- Ordinary mutable module tables are not a supported cross-Actor sharing mechanism. Tables/buffers local to an Actor survive its parallel-to-serial transition. Use no SharedTables, recurring CFrame result arrays, or shared per-boid pose publication.

## 2 Local state and calculation kernel

- [x] Complete

- Keep BoidsRenderer as the sole process-local facade. It owns model/Motor creation, public lifecycle visibility, group metadata, accepted snapshot ordering, global cell scheduling, and the optional client query index.
- Create a renderer-owned Actor pool separate from simulation Actors. Imports remain inert; explicit startup is idempotent. Add `Renderer.Start(callback, renderOptions?)` and `ClientSimulation.Start(simOptions?, renderOptions?)`. Renderer options contain `actorCount`, default 8, an integer in 1–32, fixed for the session. Existing callers remain valid. Testing alone resolves benchmark overrides and records the resolved count.
- Assign each boid lifetime to `(boidId % actorCount) + 1`; retain that owner across cell changes. Each shard owns dense state buffers, ID/slot lookup, cell-fragment membership, scratch, Motor references, and calculated CFrame arrays. Compact slots locally; do not exchange global dense indices.
- Extract one native, strictly typed calculation kernel from the current renderer. Preserve equations, constants, f32 state storage, elapsed-time handling, first-render initialization, extrapolation limits, correction intervals, facing smoothing, and forward-only movement. Representation remains separate from operations.
- Replay identical input/state/time sequences against the main implementation and extracted kernel. Cover initialization, stationary/reversing targets, stale/equal snapshots, long intervals, and zero elapsed time before adding parallel dispatch.

## 3 Input transport scheduling and lifetime

- [x] Complete

- Preserve direct ClientRendererBridge ingress. After snapshot acceptance, stage only changed inputs for the owning shard. Coalesce pending samples to the newest accepted sample per lifetime, retaining the correction interval calculated from consecutive accepted source timestamps, not consecutive deliveries.
- Send one combined frame message per participating Actor: epoch identity, pending lifecycle/membership changes, packed changed-sample rows, common render timestamp, and compact work grants. Use dense typed message lists. Do not broadcast population/state buffers or duplicate each input buffer to every Actor. Changed inputs can still require messages every frame; the avoided traffic is persistent render state and calculated results.
- Workers apply incoming changes locally, calculate granted poses in parallel, synchronize, and perform a non-yielding serial assignment pass. Return only completion identity, counts, and opt-in aggregate timings. Install listeners before dispatch and require startup readiness.
- Keep one render epoch in flight and at most one job per participating Actor. While unsettled, do not enqueue more frame jobs; coalesce incoming changes. Freeze epoch scheduling topology and apply queued topology changes after settlement.
- Preserve 64-stud render cells, bands, peripheral scaling, near-first ordering, the global attempted-boid cap, and aging protection. Split cell membership into mirrored dense per-Actor fragments. Grant contiguous fragment ranges, with resumable cursors; do not build a per-frame population-sized ID list. Aging slices precede normal work and cannot duplicate slots within an epoch.
- Advance completion-dependent scheduling only after successful settlement. Deferred/failed work is not completed work. Keep global budgets rather than allocating an independent full budget to each shard.
- Deletions immediately remove public visibility, query entries, and original Instances even while topology changes await settlement. Guard work/replies with lifetime tokens, epoch IDs, and exact Motor references. Old references/replies cannot affect replacement IDs or groups.
- Worker errors send terminal failure acknowledgement. Missing acknowledgement never licenses scratch/Actor reuse. Surface renderer failure without a restart pool or fallback renderer.
- Test real Actor execution, dense-cell partial grants, cap/aging behavior, membership moves, local swap removal, LOD/camera changes, deletion during work, group teardown, reused IDs, delayed messages, and worker failure.

## 4 Gameplay query integration

- [x] Complete

- Preserve synchronous RaycastBoids/GetBoidsInRadius APIs and result shapes; projectile callers remain unchanged. All geometric query implementations stay package-owned.
- With the client index enabled, update it from submitted Motor6D.Transform values for granted live boids after shard commits. Retain grant membership until settlement so the coordinator can traverse it without receiving pose lists. Retain lazy seeding and immediate removal.
- Publish one committed-epoch marker per Actor after serial assignment. Query calls check markers and synchronously catch the index up if acknowledgement delivery is pending. Ensure catch-up is idempotent and cannot dispatch new work before safe worker settlement.
- With client indexing disabled, perform no transform-read/index-maintenance pass. Query-enabled runs retain this serial cost; do not conceal it in performance claims.
- Test against submitted poses, including queries between marker publication and acknowledgement, uninitialized boids, deletion/reuse, lazy seeding, and disabled-index behavior.

## 5 Observation without continuous state export

- [x] Complete

- Replace the combined observation getter with `GetRenderedBoidPose(id)`, a synchronous copied ID/group/CFrame/availability read, and `RequestRenderedBoidSample(id, callback)`, a cancellable asynchronous copied internal-state sample carrying lifetime and actual sample/update timestamps.
- Use one first-render marker per Motor lifetime; do not write per-boid per-frame attributes. Camera follow reads the latest submitted transform each frame. Request selected-boid details at the existing 4 Hz inspection cadence.
- Picking and group bounds read submitted transforms on demand; retain 2 Hz bounds sampling. Obtain group update-age metadata through small asynchronous shard reductions, not pose arrays.
- Keep detailed CFrame/velocity/update-time samples internally consistent; serve requests after active calculation commits. Live poses and sampled details have separate timing semantics. Never substitute read time for render/simulation freshness. Pending or unavailable details remain explicit.
- Reject replies after selection, session, request-generation, or lifetime changes. Update all observer consumers of the old getter/types. Preserve lifecycle-maintained group counts/colors without recurring population scans.
- Verify follow camera, picking, group bounds, stale/pending displays, cancelled requests, and normal host camera/input handoff. No observation path starts another runtime.

## 6 Measurement acceptance and handoff

- [ ] Complete

- Keep timing/work collection renderer-owned and opt-in; benchmark policy/export stays Testing-owned. Measure coordinator preparation, input bytes/messages, parallel kernel work, synchronization delay, serial assignments, query maintenance, engine Motor processing, and end-to-end renderer elapsed time separately. Sum of parallel durations is not frame cost.
- Sweep 1, 2, 4, 8, and 16 render Actors. Eight is the initial default; changing it requires recorded comparison evidence. Keep simulation Actor count unchanged across comparisons.
- Compare fresh sessions with identical population, seeds, camera, LOD, graphics settings, instrumentation mode, and simulation configuration. Test RandomTargetStress through target changes/cell migration and BenchmarkReference20k. Include client-query-enabled runs and query-disabled isolation runs.
- Before starting a test, inspect all connected Studio sessions and stop any prior simulation started for this work. Run only one test simulation at a time; discard timings collected while another owned simulation was active.
- Use three alternating baseline/candidate pairs, each with 30-second warmup and 90-second sampling. Report p50/p95/p99 frame times, actual updates/second, update-age distributions, and renderer elapsed time. Accept improvement only beyond observed run-to-run variation, without lower update coverage or increased pose staleness. There is no fixed FPS promise. Intentional one-frame pipelining is deferred unless separately justified by measured benefit.
- Run package UnitTest with sufficient per-case timeout for the existing five-second deadline test and run host-handoff verification in the normal client runtime. Confirm actual parallel execution/native compilation, not just mocked behavior.
- In the containing game, run `./rojo.cmd build default.project.json --output build/BoidShooter.rbxlx` and `./rojo.cmd sourcemap default.project.json --include-non-scripts --output sourcemap.json`. Verify the standalone package as required by AGENTS. Run available type analysis using the ordinary edit-time hierarchy; a successful build is not type cleanliness. Report exact checks and pre-existing failures separately.
- Update package architecture, rendering/observation contracts, and measurement definitions to the implemented design. Add a searchable lesson only for a reusable non-obvious failure mode. Remove obsolete central render-state storage and superseded observer paths instead of maintaining parallel architectures.
- Package edits belong to its repository. No commits, uploads, publication, remote changes, or pushes are authorized by this plan.

## Continuation notes

V4 matrix is complete: 20 valid captures, three alternating query-enabled pairs per scenario, Actor counts 1/2/4/8/16, and one query-disabled diagnostic pair per scenario. **Performance acceptance fails; section 6 stays open.** Candidate-8 stress p95 is 17.2-44.6% worse in every pair, updates/sec 1.2-2.1% lower, and sampled p95 ages higher. Reference improvement is within baseline variation; Actor sweep is inconclusive. Stress regression persists without queries. Default remains eight. Next target is coordinator preparation/input packing and transport/synchronization overhead, then repeat equivalent-work comparisons.

Exact results, paired changes and five passing long-session correctness checks: host `.tools/renderer-visible-v4-summary.json`; raw captures `.tools/renderer-<runId>.json`; matrix/runner `.tools/renderer-visible-v4-test-matrix.json` and `.tools/renderer-visible-v4-runner.js`. Discard all earlier hidden/interrupted/overlapping captures and the zero-render V4 attempt; its valid retry has `-retry-1`. No active orchestration remains.

Main snapshots/provenance: `.tools/renderer-main-baseline-99a4f6e655b2499bb11855e4bb3f7d6a` and `.tools/renderer-main-baseline-provenance.txt`. Compare package build `build/BoidsSystem-main-c2b35bbf.rbxlx`, not dirty host or host main's older package pin `6b9eeb4`. Tested candidate V3 build SHA256: `58F99633B17BF5F419C82C70442CE3CCE7718A0E92D92E10950998F0B6674C2A` (unchanged after final rebuild). Candidate repairs main's pre-existing query swap-slot bug; baseline deliberately retains it.

Verified: kernel 305 identical CFrames/packed rows; five shard/scheduler cases; UnitTest 92/92; DynamicIds 18/18; fixtures; host/package builds and sourcemaps. Client test type analysis passes; full analysis retains known unrelated host errors (`.tools/renderer-v3-typecheck.txt`). Twenty repeated live query checks: `.tools/renderer-v3-query-repeated.json`. Eight distinct concurrent calculating threads: `.tools/renderer-parallel-verified.json`; same-frame Actor/Motor probe: `.tools/renderer-timing-probe.json`. Nested engine joint scopes are inclusive, not additive. Client native compilation remains unverified; native generation is documented as server-side.

All five connected Studios are Edit. Visible baseline `2ffd03e0-ed45-42a0-ab6f-ad0028a6a60b` (window 134000); candidate `ecde6cfb-e915-4aa5-8634-674b3b2016bf` (window 199480). Original game preserved; exclude two old hidden test instances. Temporary acceptance harnesses were removed, Catalog restored, and query/render test overrides reset in visible editors. Recreate harnesses before reusing the saved runner; it assumes they exist. No commits, publishing or pushing.

Test guardrails: actual input (Escape after activation) was needed to wake a stale Studio viewport; activation alone produced one zero-PreRender run while Heartbeat continued. Use visible equal viewports, explicit focus input, and wall-clock render continuity. Heartbeat/render count mismatch alone can be genuine frame loss, so is diagnostic only. Compare renderer callbacks against PreRender; report first/last/maximum render gaps and accumulated render time. Set query mode before startup (QueryIndexConfig caches an early default), seed lazy indexing before sampling, and verify entry counts. Ages sample 32 fixed IDs, not full-population distributions. Warnings may be handled with owner approval already granted.
