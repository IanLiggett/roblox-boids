--!strict
-- Generic process-local measurement state; no scenario orchestration or runtime hooks.
local SharedTypes = require(script.Parent.SharedTypes)
local RuntimeMetrics = {}

type CounterName = SharedTypes.RuntimeCounterName
type Snapshot = SharedTypes.RuntimeMetrics
type WorkerMeasurement = SharedTypes.WorkerMeasurement
type Mode = SharedTypes.MeasurementMode
type Ring = {values: {number}, total: number}
export type State = {
 mode: Mode,
 capacity: number,
 counters: {[CounterName]: number},
 rings: {[string]: Ring},
}
local counterNames: {CounterName} = {"dispatchPumps", "dispatchPumpMs", "heartbeatDispatches", "completionDispatches", "timerDispatches", "dispatchBudgetStops", "dispatchNoActorStops", "dispatchNoDueStops", "scheduledJobs", "scheduledBoids", "completedJobs", "completedScheduledBoids", "processedBoids", "skippedBoids", "survivingBoids", "migratedBoids", "observedBoids", "returnedSourceBoids", "countMismatches", "timedOutJobs", "discardedJobs", "mergeFailures", "outstandingJobs", "peakOutstandingJobs", "workerExecutionMs", "workerSnapshotMs", "jobBuildMs", "dispatchMs", "resultHandlingMs", "mergeMs", "observerPreparationMs", "observerCallbacksMs", "snapshotDeliveryMs", "packetizationMs", "schedulerMs", "inboundDelayMs", "outboundDelayMs", "jobTurnaroundMs", "detailedJobs", "candidateExaminations", "acceptedDirectInteractions", "aggregateBucketVisits", "acceptedAggregatePopulation", "obstacleForwardRays", "obstacleEscapeRays", "obstacleDetourStarts", "obstacleDetourUpdates", "obstacleSoftFallbacks", "pages", "occupiedSlots", "inputBufferBytes", "outputBufferBytes", "correctionMessages"}
local latencyNames: {string} = {"workerExecutionMs", "jobTurnaroundMs", "inboundDelayMs", "outboundDelayMs", "frameMs", "actorReadyDelayMs", "cellOverdueMs"}

function RuntimeMetrics.New(mode: Mode, capacity: number): State
 assert(mode == "minimal" or mode == "detailed", "Invalid instrumentation mode")
 assert(capacity >= 1 and capacity % 1 == 0, "Capacity must be a positive integer")
 local counters: {[CounterName]: number} = {}
 for _, name in counterNames do counters[name] = 0 end
 -- Worker imports do not sample coordinator latency; avoid reserving full rings there.
 local rings: {[string]: Ring} = {}
 for _, name in latencyNames do rings[name] = {values = {}, total = 0} end
 return {mode = mode, capacity = capacity, counters = counters, rings = rings}
end

function RuntimeMetrics.Add(state: State, name: CounterName, value: number): ()
 state.counters[name] += value
end

function RuntimeMetrics.Sample(state: State, name: string, value: number): ()
 local ring = state.rings[name]
 assert(ring, "Unknown latency series")
 ring.total += 1
 ring.values[(ring.total - 1) % state.capacity + 1] = value
end

function RuntimeMetrics.Dispatched(state: State, scheduledBoids: number): ()
 local c = state.counters
 c.scheduledJobs += 1
 c.scheduledBoids += scheduledBoids
 c.outstandingJobs += 1
 c.peakOutstandingJobs = math.max(c.peakOutstandingJobs, c.outstandingJobs)
end

function RuntimeMetrics.TimedOut(state: State): ()
 state.counters.outstandingJobs -= 1
 state.counters.timedOutJobs += 1
end

function RuntimeMetrics.Completed(state: State, m: WorkerMeasurement, turnaroundMs: number, inboundMs: number, outboundMs: number): ()
 local c = state.counters
 c.outstandingJobs -= 1
 c.completedJobs += 1
 c.completedScheduledBoids += m.scheduledBoids
 c.processedBoids += m.processedBoids
 c.skippedBoids += m.skippedBoids
 c.survivingBoids += m.survivingBoids
 c.migratedBoids += m.migratedBoids
 c.observedBoids += m.observedBoids
 c.returnedSourceBoids += m.returnedSourceBoids
 if m.processedBoids + m.skippedBoids ~= m.observedBoids
  or m.survivingBoids + m.migratedBoids ~= m.processedBoids
  or m.observedBoids ~= m.scheduledBoids
  or m.returnedSourceBoids ~= m.survivingBoids + m.skippedBoids then
  c.countMismatches += 1
 end
 c.workerExecutionMs += m.executionMs
 c.jobTurnaroundMs += turnaroundMs
 c.inboundDelayMs += inboundMs
 c.outboundDelayMs += outboundMs
 RuntimeMetrics.Sample(state, "workerExecutionMs", m.executionMs)
 RuntimeMetrics.Sample(state, "jobTurnaroundMs", turnaroundMs)
 RuntimeMetrics.Sample(state, "inboundDelayMs", inboundMs)
 RuntimeMetrics.Sample(state, "outboundDelayMs", outboundMs)
 if m.detailed then
  c.detailedJobs += 1
  c.workerSnapshotMs += m.snapshotMs
  c.candidateExaminations += m.candidateExaminations
  c.acceptedDirectInteractions += m.acceptedDirectInteractions
  c.aggregateBucketVisits += m.aggregateBucketVisits
  c.acceptedAggregatePopulation += m.acceptedAggregatePopulation
  c.obstacleForwardRays += m.obstacleForwardRays
  c.obstacleEscapeRays += m.obstacleEscapeRays
  c.obstacleDetourStarts += m.obstacleDetourStarts
  c.obstacleDetourUpdates += m.obstacleDetourUpdates
  c.obstacleSoftFallbacks += m.obstacleSoftFallbacks
  c.pages += m.pages
  c.occupiedSlots += m.observedBoids
  c.inputBufferBytes += m.inputBufferBytes
  c.outputBufferBytes += m.outputBufferBytes
 end
end

function RuntimeMetrics.Rate(count: number, elapsedSeconds: number): number
 assert(elapsedSeconds > 0, "Rates require a positive measured interval")
 return count / elapsedSeconds
end

function RuntimeMetrics.PollInterval(last: number, now: number, interval: number): (number, number?)
 local elapsed = now - last
 if elapsed < interval then return last, nil end
 return now, elapsed
end

function RuntimeMetrics.Snapshot(state: State, sinceTotals: {[string]: number}?): Snapshot
 local latency: {[string]: SharedTypes.LatencySummary} = {}
 local totals: {[string]: number} = {}
 for name, ring in state.rings do
  local since = if sinceTotals then sinceTotals[name] or 0 else 0
  local window = math.max(ring.total - since, 0)
  local values: {number} = {}
  for seq = math.max(1, ring.total - state.capacity + 1, since + 1), ring.total do
   table.insert(values, ring.values[(seq - 1) % state.capacity + 1])
  end
  table.sort(values)
  local count = #values
  latency[name] = {
   sampleCount = count, totalSamples = ring.total, windowSamples = window,
   droppedSamples = math.max(window - count, 0),
   p50 = if count > 0 then values[math.ceil(count * 0.50)] else nil,
   p95 = if count > 0 then values[math.ceil(count * 0.95)] else nil,
   p99 = if count > 0 then values[math.ceil(count * 0.99)] else nil,
   maximum = if count > 0 then values[count] else nil,
  }
  totals[name] = ring.total
 end
 return {mode = state.mode, counters = table.clone(state.counters), latency = latency,
  latencyTotals = totals, latencyCapacity = state.capacity}
end

-- Startup-only attribute: use fresh sessions when comparing modes.
local configuredMode = script:GetAttribute("InstrumentationMode") or "minimal"
assert(configuredMode == "minimal" or configuredMode == "detailed", "Invalid InstrumentationMode")
RuntimeMetrics.State = RuntimeMetrics.New(configuredMode :: Mode, 512)
return RuntimeMetrics
