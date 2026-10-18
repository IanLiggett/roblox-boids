--!strict
return function(t: any): ()
 local package = game.ReplicatedStorage.BoidsReplicated
 local Storage = require(package.BoidStorage)
 local template = game.ServerStorage.UnitTest.Fixtures.WorkerCoreStep01
 local cloneId = 0
 local lifetime = 1
 local function run(count: number, missingLast: boolean, migrate: boolean, detailed: boolean, buckets: boolean?, reconciliationBatches: any, emitSnapshot: boolean?, raycastProvider: any?, elapsedTicks: number?, initialPosition: Vector3?, initialObstacleDirection: Vector3?): any
  cloneId += 1
  local clone = template:Clone()
  clone.Name = "RunningWorkerFixture_" .. cloneId
  assert(not template.Parent:FindFirstChild(clone.Name))
  clone.Parent = template.Parent
  local ok, result = pcall(function()
   local handlers: {[string]: any} = {}
   local actor: any = {}
   function actor:BindToMessageParallel(name: string, fn: any): () handlers[name]=fn end
   function actor:BindToMessage(name: string, fn: any): () handlers[name]=fn end
   local core = require(clone)
   core.Start(actor)
   if raycastProvider then
    core.SetTestRaycastProvider(raycastProvider)
   end
   if reconciliationBatches then
    for _, targets in reconciliationBatches do
     handlers.SetBoidReconciliationTargets(targets)
    end
   end
   local stats=buffer.create(count*16)
   local registered=if missingLast then math.max(count-1,0) else count
   for i=0,registered-1 do
    buffer.writeu16(stats,i*16,i+1)
    buffer.writeu8(stats,i*16+2,20);buffer.writeu8(stats,i*16+3,1)
    buffer.writeu8(stats,i*16+4,16)
   end
   handlers.NewBoidsStatsBatch({boidCount=registered,data=stats,lifetimes=table.create(registered,lifetime)})
   local pages: {any} = {}
   local tickDelta = if elapsedTicks == nil then (if migrate then 60 else 0) else elapsedTicks
   for start=0,math.max(count-1,0),64 do
    local n=math.min(count-start,64)
    local page={id=#pages+1,setId=999,index=#pages+1,size=n,deadCount=0,
     firstDeadWord=0,cursor=n,data=buffer.create(1024),dead=buffer.create(8)}
    for slot=0,n-1 do
     Storage.WriteBoidId(page.data,slot,start+slot+1)
     local startPosition=initialPosition or Vector3.new(if migrate then 127 else 40,40,40)
     Storage.WritePosition(page.data,slot,startPosition.X,startPosition.Y,startPosition.Z)
     Storage.WriteVelocity(page.data,slot,1,0,0);Storage.WriteSpeed(page.data,slot,20)
     Storage.WriteLastTick(page.data,slot,100-tickDelta)
     Storage.WriteObstacleDirection(page.data,slot,initialObstacleDirection or Vector3.zero)
    end
    table.insert(pages,page)
   end
   local cell={id=1,origin=Vector3.zero,networkTick=1,networkInterval=1,emitSnapshot=if emitSnapshot == nil then true else emitSnapshot,
    pages={pages=pages,pageCount=#pages,openPages={},pendingPages={}},
    pageCount=#pages,scheduledBoidCount=count,processedBoidCount=0,boidCount=count}
   local job:any={groupId=1,usesPath=false,jobCells={cell},averageSight=16,detailedMetrics=detailed,movedBoids={}}
   -- The replay boundary receives recorded target/path inputs before every
   -- execution; run() recreates all mutable stats/pages/job tables above.
   handlers.NewGroupTarget(1, { Position = Vector3.new(320, 40, -80) }, lifetime)
   handlers.NewGroupPath(1, {
    { Position = Vector3.new(320, 40, -80), offset = Vector3.zero },
    { Position = Vector3.new(360, 40, -80), offset = Vector3.zero },
   }, 77, false, true, 8, lifetime)
   job.usesPath = true
   local returned:any
   local event:any={Fire=function(_: any,j: any): () returned=j end}
   handlers.NewJob(job,event,1,100/60)
   return returned
  end)
  clone:Destroy()
  assert(ok,tostring(result))
  return result
 end
 -- Zero elapsed time does not issue speculative obstacle probes.
 t.test("zero elapsed time avoids obstacle raycasts",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(): any calls += 1;return nil end,0)
  t.expect.equal(calls,0);t.expect.equal(job.measurement.obstacleForwardRays,0)
  t.expect.equal(job.measurement.obstacleEscapeRays,0);t.expect.equal(job.measurement.obstacleDetourStarts,0)
 end)
 -- A clear tangent exit commits full-distance lateral movement instead of stopping at the wall.
 t.test("clear escape probes commit a lateral detour",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   if calls == 1 then return {Normal=Vector3.new(-1,0,0),Distance=10} end
   return nil
  end,60)
  local position=Vector3.new(Storage.ReadPosition(job.jobCells[1].pages.pages[1].data,0))
  local detour=Storage.ReadObstacleDirection(job.jobCells[1].pages.pages[1].data,0)
  t.expect.equal(calls,5);t.expect.equal(job.measurement.obstacleForwardRays,1)
  t.expect.equal(job.measurement.obstacleEscapeRays,4);t.expect.equal(job.measurement.obstacleDetourStarts,1)
  t.expect.truthy(detour.Magnitude>0.9);t.expect.truthy(position.Z < 30)
 end)
 -- Distant geometry cannot hold a local detour after its original obstacle is no longer near.
 t.test("distant target hit releases the detour",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   return {Distance=100}
  end,60,nil,Vector3.new(0,0,-1))
  local page=job.jobCells[1].pages.pages[1].data
  local detour=Storage.ReadObstacleDirection(page,0)
  local position=Vector3.new(Storage.ReadPosition(page,0))
  local displacement=position-Vector3.new(40,40,40)
  local pathDirection=(Vector3.new(320,40,-80)-Vector3.new(40,40,40)).Unit
  t.expect.equal(calls,1);t.expect.equal(detour,Vector3.zero)
  t.expect.truthy(displacement.Magnitude>19)
  t.expect.truthy(displacement.Unit:Dot(pathDirection)>0.99)
 end)
 -- At a wall edge, a clearer reverse ray must not beat a safe continuation.
 t.test("edge escape preserves committed travel direction",function()
  local calls=0
  local initialDirection=Vector3.new(0,0,-1)
  local job=run(1,false,false,true,nil,nil,true,function(_: Vector3,_direction: Vector3): any
   calls += 1
   if calls==1 then return {Distance=10,Normal=Vector3.xAxis} end
   if calls==2 then return {Distance=10,Normal=Vector3.xAxis} end
   if calls==3 then return {Distance=43} end
   return nil
  end,60,nil,initialDirection)
  local page=job.jobCells[1].pages.pages[1].data
  local detour=Storage.ReadObstacleDirection(page,0)
  local position=Vector3.new(Storage.ReadPosition(page,0))
  local displacement=position-Vector3.new(40,40,40)
  t.expect.equal(calls,6)
  t.expect.equal(job.measurement.obstacleEscapeRays,4)
  t.expect.truthy(detour:Dot(initialDirection)>0.99)
  t.expect.truthy(displacement.Unit:Dot(initialDirection)>0.99)
 end)
 -- A future heading hit beyond this update's travel distance does not trigger an early turn.
 t.test("distant heading hit holds committed direction",function()
  local calls=0
  local initialDirection=Vector3.new(0,0,-1)
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   if calls==1 then return {Distance=10,Normal=Vector3.xAxis} end
   return {Distance=30,Normal=Vector3.xAxis}
  end,60,nil,initialDirection)
  local page=job.jobCells[1].pages.pages[1].data
  local detour=Storage.ReadObstacleDirection(page,0)
  local position=Vector3.new(Storage.ReadPosition(page,0))
  local displacement=position-Vector3.new(40,40,40)
  t.expect.equal(calls,2)
  t.expect.equal(job.measurement.obstacleEscapeRays,0)
  t.expect.truthy(detour:Dot(initialDirection)>0.99)
  t.expect.truthy(displacement.Unit:Dot(initialDirection)>0.99)
 end)
 -- If the new surface's tangent probes are all sideways, keep the stored heading instead of reversing.
 t.test("edge with no forward escape retains heading",function()
  local calls=0
  local initialDirection=Vector3.new(0,0,-1)
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   if calls==1 then return {Distance=10,Normal=Vector3.zAxis} end
   if calls==2 then return {Distance=10,Normal=Vector3.zAxis} end
   return nil
  end,60,nil,initialDirection)
  local page=job.jobCells[1].pages.pages[1].data
  local detour=Storage.ReadObstacleDirection(page,0)
  local position=Vector3.new(Storage.ReadPosition(page,0))
  local displacement=position-Vector3.new(40,40,40)
  t.expect.equal(calls,6)
  t.expect.equal(job.measurement.obstacleEscapeRays,4)
  t.expect.truthy(detour:Dot(initialDirection)>0.99)
  t.expect.truthy(displacement.Unit:Dot(initialDirection)>0.99)
 end)
 -- A nearby blocker on the path ray keeps the committed detour active.
 t.test("local path blocker preserves detour commitment",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(_: Vector3,direction: Vector3): any
   calls += 1
   if calls==1 then return {Distance=10,Normal=Vector3.xAxis} end
   return nil
  end,60,nil,Vector3.new(0,0,-1))
  local page=job.jobCells[1].pages.pages[1].data
  local detour=Storage.ReadObstacleDirection(page,0)
  local position=Vector3.new(Storage.ReadPosition(page,0))
  local displacement=position-Vector3.new(40,40,40)
  t.expect.equal(calls,2)
  t.expect.truthy(detour.Magnitude>0.9)
  t.expect.truthy(displacement.Unit:Dot(detour)>0.99)
  t.expect.truthy(displacement.Magnitude>19)
 end)
 -- A committed detour carries its packed heading when it crosses into another cell.
 t.test("migrating detour preserves its packed heading",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   if calls == 1 then return {Normal=Vector3.new(-1,0,0),Distance=10} end
   return nil
  end,60,Vector3.new(40,40,1))
  local _,moved=next(job.movedBoids)
  t.expect.truthy(moved);t.expect.equal(#moved,6);t.expect.truthy((moved[6] :: number)>0)
 end)
 -- When all tangent exits are blocked, the response stays advisory and allows progress.
 t.test("blocked escapes retain soft pass-through",function()
  local calls=0
  local job=run(1,false,false,true,nil,nil,true,function(): any
   calls += 1
   if calls == 1 then return {Normal=Vector3.new(-1,0,0),Distance=10} end
   return {Distance=1}
  end,60)
  t.expect.equal(calls,5);t.expect.equal(job.measurement.obstacleForwardRays,1)
  t.expect.equal(job.measurement.obstacleEscapeRays,4);t.expect.equal(job.measurement.obstacleSoftFallbacks,1)
 end)
 -- A stationary input updates once without becoming a migration.
 t.test("stationary boid is processed and survives",function()
  local job=run(1,false,false,true)
  t.expect.equal(job.measurement.processedBoids,1);t.expect.equal(job.measurement.survivingBoids,1)
  t.expect.equal(job.measurement.migratedBoids,0);t.expect.equal(job.jobCells[1].processedBoidCount,1)
 end)
 -- Moving out of a cell still counts as completed simulation.
 t.test("migrant is processed but absent from source rows",function()
  local job=run(1,false,true,true)
  t.expect.equal(job.measurement.processedBoids,1);t.expect.equal(job.measurement.migratedBoids,1)
  t.expect.equal(job.measurement.returnedSourceBoids,0);t.expect.equal(job.measurement.survivingBoids,0)
 end)
 -- Missing stats leave a row in storage but do not claim integration.
 t.test("missing stats are skipped not counted as successful survivors",function()
  local job=run(2,true,false,true)
  t.expect.equal(job.measurement.processedBoids,1);t.expect.equal(job.measurement.skippedBoids,1)
  t.expect.equal(job.measurement.returnedSourceBoids,2)
 end)
 -- An allocated empty page consumes transport bytes, not boid work.
 t.test("empty page counts bytes without boids",function()
  local job=run(0,false,false,true)
  t.expect.equal(job.measurement.pages,1);t.expect.equal(job.measurement.inputBufferBytes,1032)
  t.expect.equal(job.measurement.observedBoids,0);t.expect.equal(job.measurement.processedBoids,0)
 end)
 -- Direct examinations include self checks; accepted interactions do not.
 t.test("two close boids distinguish candidates from accepted interactions",function()
  local job=run(2,false,false,true)
  t.expect.equal(job.measurement.candidateExaminations,4);t.expect.equal(job.measurement.acceptedDirectInteractions,2)
  t.expect.equal(job.measurement.aggregateBucketVisits,0)
 end)
 -- The bucket threshold uses the same diagnostic definitions without double counting.
 t.test("101 co-located boids have bounded accepted direct interactions",function()
  local job=run(101,false,false,true)
  t.expect.equal(job.measurement.acceptedDirectInteractions,10100)
  t.expect.equal(job.measurement.candidateExaminations,10200)
 end)
 -- Instrumentation changes measurement only, not packed simulation output.
 t.test("minimal and detailed modes produce identical rows and snapshots",function()
  local a,b=run(4,false,true,false),run(4,false,true,true)
  t.expect.equal(buffer.tostring(a.jobCells[1].pages.pages[1].data),buffer.tostring(b.jobCells[1].pages.pages[1].data))
  t.expect.equal(buffer.tostring(a.jobCells[1].pages.pages[1].dead),buffer.tostring(b.jobCells[1].pages.pages[1].dead))
  t.expect.deepEqual(a.movedBoids,b.movedBoids)
  for id,snapshot in a.snapshotGroups[1] do
   t.expect.equal(buffer.tostring(snapshot.networkBoids),buffer.tostring(b.snapshotGroups[1][id].networkBoids))
  end
  t.expect.equal(a.measurement.candidateExaminations,0)
  t.expect.truthy(b.measurement.snapshotMs>0)
 end)
 -- Source snapshots reserve the pre-update source-cell count; migrant destinations retain checked growth.
 t.test("snapshot emission preserves source and migration counts across disabled and enabled sweeps",function()
  local disabled=run(4,false,false,false,nil,nil,false)
  t.expect.falsy(next(disabled.snapshotGroups) ~= nil)
  local source=run(4,true,false,false)
  local sourceSnapshot=source.snapshotGroups[1][1]
  t.expect.equal(sourceSnapshot.boidCount,3)
  t.expect.equal(buffer.len(sourceSnapshot.networkBoids),4*8)
  for _,count in {1,4} do
   local migrated=run(count,false,true,false)
   local snapshot=migrated.snapshotGroups[1]
   local destinationCount=0
   for _,cellSnapshot in snapshot do destinationCount += cellSnapshot.boidCount end
   t.expect.equal(destinationCount,count)
   t.expect.equal(migrated.measurement.migratedBoids,count)
  end
 end)
 -- Fixed-input Actor replay: each execution gets a fresh cloned worker and
 -- newly built mutable inputs, but recorded tick/time/target/path are equal.
 t.test("fixed replay preserves encoded state, masks, counts, migrations, and snapshots",function()
  local a,b=run(4,false,true,false),run(4,false,true,false)
  local ac,bc=a.jobCells[1],b.jobCells[1]
  t.expect.equal(ac.scheduledBoidCount,bc.scheduledBoidCount)
  t.expect.equal(ac.processedBoidCount,bc.processedBoidCount)
  t.expect.equal(ac.boidCount,bc.boidCount)
  t.expect.equal(buffer.tostring(ac.pages.pages[1].data),buffer.tostring(bc.pages.pages[1].data))
  t.expect.equal(buffer.tostring(ac.pages.pages[1].dead),buffer.tostring(bc.pages.pages[1].dead))
  t.expect.deepEqual(a.movedBoids,b.movedBoids)
  t.expect.equal(a.completionTime,b.completionTime)
  for sourceCellId,snapshot in a.snapshotGroups[1] do
   t.expect.equal(buffer.tostring(snapshot.networkBoids),buffer.tostring(b.snapshotGroups[1][sourceCellId].networkBoids))
  end
 end)
 -- A batch received before static stats is retained, and repeated rows use the final row in packet order.
 t.test("batched reconciliation preserves pending and repeated-row ordering",function()
  local first={boidId=1,position=Vector3.new(20,40,40),velocity=Vector3.new(2,0,0),snapshotTime=1,lifetime=lifetime}
  local last={boidId=1,position=Vector3.new(100,40,40),velocity=Vector3.new(4,0,0),snapshotTime=1,lifetime=lifetime}
  local batched=run(1,false,false,false,nil,{{first,last}})
  local expected=run(1,false,false,false,nil,{{last}})
  t.expect.equal(buffer.tostring(batched.jobCells[1].pages.pages[1].data),buffer.tostring(expected.jobCells[1].pages.pages[1].data))
 end)
 -- Separate packet deliveries retain their receive ordering, matching the prior singular-message behavior.
 t.test("batched reconciliation preserves packet arrival ordering",function()
  local newer={boidId=1,position=Vector3.new(100,40,40),velocity=Vector3.new(4,0,0),snapshotTime=1,lifetime=lifetime}
  local older={boidId=1,position=Vector3.new(20,40,40),velocity=Vector3.new(2,0,0),snapshotTime=0,lifetime=lifetime}
  local reordered=run(1,false,false,false,nil,{{newer},{older}})
  local expected=run(1,false,false,false,nil,{{older}})
  t.expect.equal(buffer.tostring(reordered.jobCells[1].pages.pages[1].data),buffer.tostring(expected.jobCells[1].pages.pages[1].data))
 end)
 -- An expired snapshot is inert and therefore has the same outcome as no correction.
 t.test("expired batched reconciliation target is inert",function()
  local expired={boidId=1,position=Vector3.new(100,40,40),velocity=Vector3.new(4,0,0),snapshotTime=-10,lifetime=lifetime}
  local actual=run(1,false,false,false,nil,{{expired}})
  local expected=run(1,false,false,false,nil,nil)
  t.expect.equal(buffer.tostring(actual.jobCells[1].pages.pages[1].data),buffer.tostring(expected.jobCells[1].pages.pages[1].data))
 end)
end
