--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
 local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
  :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
 local Metrics = require(package.RuntimeMetrics)
 local SharedTypes = require(package.SharedTypes)
 local function measurement(): SharedTypes.WorkerMeasurement
  return {detailed=true,executionMs=0,snapshotMs=0,scheduledBoids=0,observedBoids=0,processedBoids=0,skippedBoids=0,survivingBoids=0,migratedBoids=0,returnedSourceBoids=0,candidateExaminations=0,acceptedDirectInteractions=0,aggregateBucketVisits=0,acceptedAggregatePopulation=0,obstacleForwardRays=0,obstacleEscapeRays=0,obstacleDetourStarts=0,obstacleDetourUpdates=0,obstacleSoftFallbacks=0,pages=0,inputBufferBytes=0,outputBufferBytes=0}
 end
 -- A short sample does not reset counters or advance its window.
 t.test("poll uses elapsed interval and advances only when due", function()
  local last, elapsed=Metrics.PollInterval(10,10.5,1)
  t.expect.equal(last,10);t.expect.equal(elapsed,nil)
  last,elapsed=Metrics.PollInterval(last,12.5,1)
  t.expect.equal(last,12.5);t.expect.equal(elapsed,2.5)
  t.expect.equal(Metrics.Rate(25,elapsed :: number),10)
 end)
 -- Division by zero cannot manufacture a rate.
 t.test("nonpositive rate interval is rejected",function() t.expect.throws(function() Metrics.Rate(1,0) end) end)
 -- Migrants completed simulation even though no longer in source rows.
 t.test("processed throughput includes migrants and excludes missing stats",function()
  local s=Metrics.New("detailed",8);local m=measurement()
  m.scheduledBoids=5;m.observedBoids=5;m.processedBoids=4;m.skippedBoids=1
  m.migratedBoids=2;m.survivingBoids=2;m.returnedSourceBoids=3;m.executionMs=3
  Metrics.Dispatched(s,5);Metrics.Completed(s,m,20,7,10)
  local r=Metrics.Snapshot(s)
  t.expect.equal(r.counters.processedBoids,4);t.expect.equal(r.counters.skippedBoids,1)
  t.expect.equal(r.counters.migratedBoids,2);t.expect.equal(r.counters.countMismatches,0)
  t.expect.equal(r.counters.outstandingJobs,0)
 end)
 -- Delays must not inflate worker execution time.
 t.test("worker duration remains distinct from delayed completion",function()
  local s=Metrics.New("minimal",8);local m=measurement();m.executionMs=2;m.detailed=false
  Metrics.Dispatched(s,0);Metrics.Completed(s,m,100,40,58)
  t.expect.equal(s.counters.workerExecutionMs,2);t.expect.equal(s.counters.jobTurnaroundMs,100)
 end)
 -- Empty jobs and pages contribute zero boids without inventing throughput.
 t.test("empty completed job maintains identities",function()
  local s=Metrics.New("detailed",8);local m=measurement();m.pages=1;m.inputBufferBytes=1032;m.outputBufferBytes=1032
  Metrics.Dispatched(s,0);Metrics.Completed(s,m,1,0,0)
  t.expect.equal(s.counters.countMismatches,0);t.expect.equal(s.counters.occupiedSlots,0);t.expect.equal(s.counters.pages,1)
 end)
 -- Bad producer counts remain visible rather than being clamped to agree.
 t.test("inconsistent counts are flagged",function()
  local s=Metrics.New("minimal",8);local m=measurement();m.scheduledBoids=2
  Metrics.Dispatched(s,2);Metrics.Completed(s,m,1,0,0)
  t.expect.equal(s.counters.countMismatches,1)
 end)
 -- Timeouts close outstanding accounting without claiming processed work.
 t.test("timeout does not count as completion",function()
  local s=Metrics.New("minimal",8);Metrics.Dispatched(s,5);Metrics.TimedOut(s)
  t.expect.equal(s.counters.outstandingJobs,0);t.expect.equal(s.counters.timedOutJobs,1);t.expect.equal(s.counters.processedBoids,0)
 end)
 -- Quantiles describe only the bounded retained suffix and expose evictions.
 t.test("bounded latency samples expose quantiles and dropped count",function()
  local s=Metrics.New("minimal",4)
  for i=1,6 do Metrics.Sample(s,"frameMs",i) end
  local q=Metrics.Snapshot(s).latency.frameMs
  t.expect.equal(q.sampleCount,4);t.expect.equal(q.totalSamples,6);t.expect.equal(q.droppedSamples,2)
  t.expect.equal(q.p50,4);t.expect.equal(q.p95,6);t.expect.equal(q.p99,6)
 end)
 -- A report must exclude retained samples from the warmup period.
 t.test("latency watermark excludes earlier samples",function()
  local s=Metrics.New("minimal",4);Metrics.Sample(s,"frameMs",100)
  local before=Metrics.Snapshot(s)
  Metrics.Sample(s,"frameMs",2)
  local q=Metrics.Snapshot(s,before.latencyTotals).latency.frameMs
  t.expect.equal(q.sampleCount,1);t.expect.equal(q.p99,2);t.expect.equal(q.droppedSamples,0)
 end)
 -- Reading or mutating a returned report cannot modify internal counter state.
 t.test("snapshots have independently owned counters",function()
  local s=Metrics.New("minimal",4);local r=Metrics.Snapshot(s);r.counters.processedBoids=100
  t.expect.equal(Metrics.Snapshot(s).counters.processedBoids,0)
 end)
end
