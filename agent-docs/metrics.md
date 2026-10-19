# Measurement maintenance contracts

Current measurement contracts for agents editing instrumentation. Historical
benchmark evidence is not part of this repository; do not infer measured speedups
from these definitions or from type-only changes.

Scope and ownership

- Renderer Measurements separates per-frame sampling from completed render epochs. rendererMsTotal sums epoch elapsed time, including transport/scheduler/synchronization delays; worker phase totals sum parallel work and must not be added to elapsed time or called OS utilization. coordinatorMs includes preparation/dispatch and acknowledgement-owned query maintenance; inputBytes counts changed-sample buffer payload only, excluding topology/engine framing. Existing simulation metrics below keep their meanings.
- RuntimeMetrics is a generic process-local collector. It has no frame callbacks.
- SharedTypes.RuntimeMetrics / WorkerMeasurement are canonical schemas.
- The coordinator combines its own counters with measurements returned by Actors.
- Workers do not assume module-local state is shared with the coordinator.
- Scenario sampling/report export remains in Testing.PerformanceTelemetry.
- Never require Boids from a Studio tool to inspect an already-running game:
  the tool's require cache may be separate; calling Start would create another coordinator.
  Read the runtime-produced PerformanceTelemetry.Report_server / Report_client
  StringValue instead, in the corresponding DataModel. This was observed here.

Modes
Set BoidsReplicated.RuntimeMetrics.InstrumentationMode before Play.
"minimal" (default): basic accounting, coarse phase timing, bounded latency.
"detailed": additionally count candidates, accepted direct interactions, aggregate
visits/accepted population, obstacle probes/detour outcomes, page/allocated buffer
bytes, correction Actor messages, and per-append snapshot construction time. These
diagnostics perturb hot code.
Use fresh sessions when changing modes; mode is captured at module initialization
and propagated explicitly on each job. Zero detailed counters in minimal mode mean
NOT COLLECTED, not that no such work occurred.

Counts (all cumulative except explicitly identified gauges)
- scheduledJobs/Boids: dispatched work; scheduledBoidCount is never modified.
- completedJobs/CompletedScheduledBoids: work returned to the active result listener.
- observedBoids: actual live input slots visited by returned workers.
- processedBoids: integration attempted with available stats in successfully
  returned jobs, including migrants; an erroring job does not report completion.
- skippedBoids: live rows lacking stats.
- survivingBoids: processed rows remaining in their source cell.
- migratedBoids: processed rows emitted as migration records.
- returnedSourceBoids: returned source-cell counts, including skipped rows.
- Expected identities per completed job:
  observed = processed + skipped = scheduled;
  processed = surviving + migrated;
  returnedSource = surviving + skipped.
  countMismatches records violations instead of forcing the numbers to agree.
- discardedJobs: logical retirement for a removed/replaced group, explicit group
  cancellation, terminal worker failure, or uncertain dispatch failure. These
  outcomes are counted once even if the retired worker replies later.
- mergeFailures: owner-check/commit failure or an incomplete returned cell set.
  completedJobs includes current worker replies even if their serial merge fails;
  completed worker work is NOT a claim that it merged successfully.
- timedOutJobs: logical five-second deadline expiry. It does not count the
  eventual retired reply as completed worker work or prove physical completion.
- outstandingJobs / peakOutstandingJobs: current logical active jobs and session
  high-water mark, not total CPU tasks or quarantined physical workers. F13's
  ActorsInitializer.JobExecution retires accounting once; quarantined Actors stay
  unavailable until their terminal acknowledgement and late replies add no second
  completion/retirement measurement.
- group boids/s counts processed updates (migrants included), not unique entities.
  Periodic sampling uses os.clock exclusively and divides by actual elapsed time.

Detailed workload counters
- candidateExaminations includes self and missing-stat candidate checks.
- acceptedDirectInteractions counts individual accepted separation/alignment
  interactions, not cohesion a second time.
- aggregateBucketVisits counts occupied non-current buckets actually examined;
  acceptedAggregatePopulation counts their accepted population-weighted contribution.
  Never combine these into a claim of exact pairwise work.
- obstacleForwardRays counts normal or active-heading clearance probes;
  obstacleEscapeRays counts tangent escape probes after a blocking ray.
  obstacleDetourStarts records selected new headings, obstacleDetourUpdates records
  active-heading movement or replacement, and obstacleSoftFallbacks records when no
  local escape exists and state is cleared. These are zero when a job is minimal
  because they were not collected.
- pages/occupiedSlots/inputBufferBytes/outputBufferBytes are sums over completed
  detailed jobs. Input bytes count allocated data+dead buffers, even empty pages.
  Output adds snapshot buffer capacity. These are BUFFER PAYLOAD bytes, not the
  total serialized table payload, engine framing, or migration-table byte estimates.
- correctionMessages counts client coordinator Actor SendMessage calls for
  corrections, not remote packets or distinct corrected boids.

Clock and phase definitions (milliseconds)
- os.clock differences are taken within one execution context.
- workerExecutionMs: worker handler elapsed execution through measurement assembly;
  excludes inbound scheduling and return-event delivery.
- inboundDelayMs: shared timestamp from before SendMessage to handler entry;
  combined transfer + scheduling delay, NOT pure serialization time.
- outboundDelayMs: shared completion timestamp to listener receipt;
  combined transfer + scheduling delay.
- jobTurnaroundMs: coordinator-local time before SendMessage to listener receipt.
  It is NOT CPU utilization or worker execution.
- jobBuildMs: job construction inclusive.
- dispatchMs: SendMessage call elapsed, not time waiting for completion.
- schedulerMs: Heartbeat maintenance plus every deferred dispatch pump, counted
  once. Includes dispatchPumpMs, jobBuildMs and dispatchMs; do not add child times.
- dispatchPumpMs: selection, building, and dispatch across all wakeup sources.
  The shared 1 ms epoch allowance excludes serial merge and result handling.
- dispatchPumps and dispatchBudgetStops/dispatchNoActorStops/dispatchNoDueStops:
  cumulative pump/stop counts. heartbeatDispatches/completionDispatches/timerDispatches
  count dispatched jobs by the coalesced request that drove the pump, not OS tasks.
- actorReadyDelayMs: ready-to-next-dispatch latency, including startup and
  intentional no-due/budget waits. Interpret with stop counters, never as pure
  avoidable idle time. cellOverdueMs samples the selected group's oldest due
  deadline at dispatch, not every cell or a time-weighted backlog integral.
- Per-Actor completedJobs/processedBoids/workerExecutionMs follow the same accepted
  current-reply accounting as aggregate completed worker counters. Diagnostics
  return cumulative copies; scenario reports include per-window deltas and an
  end-of-window cell summary. These are not per-core measurements or CPU usage.
- resultHandlingMs: current result processing/retirement inclusive. Contains
  snapshotDeliveryMs, mergeMs, observerPreparationMs, observerCallbacksMs and
  rescheduling/control overhead. This is elapsed time, including yielded
  observers; no profiler annotation spans the execution owner's commit callback.
- mergeMs: merge/migration/control elapsed excluding timed observer preparation.
  In minimal mode cheap migrant observation appends remain inside mergeMs; detailed
  mode additionally separates them using per-migrant clock pairs.
- observerPreparationMs: allocated batch arrays and returned-page decode traversal;
  detailed mode also times migrant observation appends.
- observerCallbacksMs: post-merge batch construction/delivery and synchronous
  callbacks. Existing independently-owned arrays and delivery ordering are unchanged.
- snapshotDeliveryMs: coordinator enqueue/local renderer delivery inclusive,
  after a complete merge. Incomplete/failed commits do not publish snapshots.
- packetizationMs: actual NetworkResults.ServerTransport packet assembly inclusive;
  flush calls run separately in PostSimulation. Direct client cell publishing does
  not assemble packets or increment packetizationMs; its intake work remains
  inside snapshotDeliveryMs. F18 makes PacketCodec pure: explicit codec fixtures
  do not mutate runtime measurements.
- NetworkResults.GetTransportMetrics (also TransportMetrics.Read) returns copied
  sentPackets/sentPayloadBytes for actual server sends only. F19 removed obsolete
  renderer packet intake; renderer measurement policy remains testing-owned.
- workerSnapshotMs: detailed-only snapshot allocation/growth/appending; a CHILD of
  workerExecutionMs. Do not add it again to worker execution.
- frameMs: Heartbeat dt, not script CPU time or pure renderer frame cost.
Parallel work and elapsed waits can sum to more than 1000 ms per second. Nothing in
this contract is an OS CPU percentage. Profiling and end-to-end coverage remain
necessary; lower accumulated worker time can also mean less work completed.

Latency and report windows
Each latency series retains at most 512 values. A monotonically increasing sequence
identifies events; report start watermarks exclude warmup samples. Reports expose
totalSamples, windowSamples, retained sampleCount, droppedSamples, and nearest-rank
p50/p95/p99/maximum. Quantiles are of the RETAINED SUFFIX, not an unbiased full-window
estimate when evictions occur. A full-window tail estimate requires appropriate
capacity or a separate capture; do not label a retained suffix as the full window.
Counter deltas use actual os.clock sample duration. Outstanding/peak are gauges,
not differenced rates. Metadata records build, side, mode, source revision, configured
Actor count, end population/groups, LOD, requested sampling, and native evidence.
GetRuntimeMetrics(sinceTotals?) returns owned snapshots; mutating one cannot modify
the collector. Report JSON is emitted after sampling, never per boid or frame.
Unavailable Stats bandwidth values stay absent, not zero.
Engine build detection does not call deprecated version(). Reports default studioBuild
to "unrecorded"; supply an externally recorded studioBuild through the existing
benchmark metadata override when collecting reproducible measurements.

Validation
The test suite lives under ServerStorage.UnitTest; UnitTestRunner is disabled.
To refresh the generated fixture in Edit mode:
  require(game.ServerStorage.UnitTest.PrepareWorkerFixture)()
  require(game.ServerStorage.UnitTest.PrepareSchedulerFixture)()
Then start Play and run:
  require(game.ServerStorage.UnitTest.RunUnitTest)(nil, 5)
Keep UnitTestRunner disabled when invoking tests manually, to avoid duplicate runs.
Worker fixtures exercise the production worker body with fixed clock/tick and
stubbed Actor messaging/stats input, plus real row/snapshot codecs. They do not
prove Actor scheduling performance. Fresh live tests provide real Actor coverage.
The generated worker fixture is test-only and must be refreshed from the current
WorkerCore body when WorkerCore changes; never use it as another runtime implementation.
Require side-attributable measurements before claiming a server/client profiler
cross-check. A Studio-host capture alone does not establish either side's cost.
Profiler summaries include complete scopes only and omit boundary-truncated
instances; durations are inclusive. Do not sum nested scope timings.
Native execution remains unverified unless separate profiler/native-code evidence
explicitly establishes it. --!native and successful loadstring compilation alone
are insufficient.

Do not turn instrumentation maintenance into unrelated optimization work. Preserve
the explicit execution/retirement ownership described in runtime.md.

Before starting live tests, inspect connected Studio sessions and stop prior simulations started for the task. Run only one test simulation at a time and discard overlapping captures; unrelated sessions require owner coordination rather than silently stopping them.

Renderer acceptance captures use PreRender frame intervals and record Heartbeat counts diagnostically. Heartbeat can outnumber rendered frames under load; a count mismatch alone must not reject genuine frame loss. Check accumulated render time, first/last callback times and maximum wall-clock render gap for continuity, and compare renderer callbacks with PreRender callbacks. A hidden/non-targetable Studio can continue Heartbeat while rendering stops; such a capture is not performance evidence. Use visible, equally sized test windows, dismiss startup modals, and reject missing render coverage instead of treating fewer updates as a speedup.
