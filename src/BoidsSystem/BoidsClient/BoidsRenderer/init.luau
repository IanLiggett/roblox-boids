--!native
--!strict
-- One process-local presentation owner; persistent Actors own smoothing state.
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local BoidsReplicated=(ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance) :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local SharedTypes=require(BoidsReplicated.SharedTypes)
local Quantization=require(BoidsReplicated.Quantization)
local PacketCodec=require(BoidsReplicated.NetworkResults.PacketCodec)
local LODConfig=require(BoidsReplicated.LODConfig)
local BoidCollisionConfig=require(BoidsReplicated.BoidCollisionConfig)
local BoidQueryIndex=require(BoidsReplicated.BoidQueryIndex)
local QueryIndexConfig=require(BoidsReplicated.QueryIndexConfig)
local Types=require(script.Types)
local Scheduler=require(script.Scheduler)
local Measurements=require(script.Measurements)
local BoidsRenderer={}
export type Options=Types.Options
export type RenderedBoidPose=Types.Pose
export type RenderedBoidSample=Types.Sample
export type RenderedGroupAge=Types.GroupAge
type NetworkBoidsBatch=SharedTypes.NetworkBoidsBatch
type BoidModel=SharedTypes.BoidModel
type Entry={
 id: number,lifetime: number,groupId: number,model: number,motor: Motor6D,part: BasePart,
 createdAt: number,cellKey: number?,cellOrigin: Vector3?,position: Vector3?,velocity: Vector3?,
 snapshotAt: number?,interval: number?,hasRendered: boolean,radius: number,
}
type PendingRequest={receive: (unknown)->()}
type Worker={
 actor: Actor,owner: number,ready: boolean,changes: {[number]: Types.Change},samples: {[number]: Entry},
 job: Types.Frame?,indexedEpoch: number,
}
type Epoch={
 id: number,started: number,frameDt: number,plan: Scheduler.Plan,pending: number,
 measure: boolean,measurementRevision: number,coordinatorMs: number,inputBytes: number,messages: number,
 dirty: number,kernelMs: number,synchronizeMs: number,assignmentMs: number,inputMs: number,
}
local entries: {[number]: Entry}={}
local boidsByGroup: {[number]: {[number]: Model | BasePart}}={}
local groupFolders: {[number]: Folder}={}
local groupIdByBoid: {[number]: number}={}
local boidModelById: {[number]: number}={}
local boidColors: {[number]: Color3}={}
local groupColors: {[number]: Color3}={}
local renderedCountByGroup: {[number]: number}={}
local spawnLifetimes: {[number]: number}={}
local retiredLifetimes: {[number]: number}={}
local lastSnapshotTimeByBoid: {[number]: number}={}
local BoidModelsStorage=script.Parent.BoidModels
local BoidFolder: Folder
local BoidRoot: Part
local U16_SIZE=2
local workers: {Worker}={}
local scheduler: Scheduler.State
local currentEpoch: Epoch?=nil
local nextEpoch=0
local nextLifetime=0
local nextRequest=0
local pendingRequests: {[number]: PendingRequest}={}
local isStarted=false
local failed=false
local onViewingCamera: ((CFrame,number)->())?=nil
local clientQueryIndexEnabled=false
local clientQueryIndex: BoidQueryIndex.Index?=nil

local function ownerOf(id: number): number return id % #workers+1 end
local function stage(entry: Entry,isRemoved: boolean?): ()
 local worker=workers[ownerOf(entry.id)]
 worker.changes[entry.id]={
  id=entry.id,lifetime=entry.lifetime,groupId=entry.groupId,
  motor=if isRemoved then nil else entry.motor,createdAt=entry.createdAt,
  cellKey=entry.cellKey,cellOrigin=entry.cellOrigin,
 }
 if isRemoved then worker.samples[entry.id]=nil end
end
local function fail(message: string): ()
 if failed then return end
 failed=true
 BoidFolder:SetAttribute("RenderFailure",message)
 warn("BoidsRenderer stopped: "..message)
end
local function hasRendered(entry: Entry): boolean
 if not entry.hasRendered then entry.hasRendered=entry.motor:GetAttribute("HasRendered")==true end
 return entry.hasRendered
end
local function catchUpIndex(worker: Worker): ()
 local index=clientQueryIndex
 local job=worker.job
 if not index or not job or worker.indexedEpoch==job.epoch or worker.actor:GetAttribute("CommittedEpoch")~=job.epoch then return end
 debug.profilebegin("BoidsRender.QueryIndex")
 for _,grant in job.grants do
  local cell=scheduler.cells[grant.key]
  local fragment=cell.fragments[worker.owner]
  for slot=grant.first,grant.first+grant.count-1 do
   local id=fragment.ids[slot]
   local entry=entries[id]
   local member=scheduler.members[id]
   if entry and member and member.lifetime==entry.lifetime and hasRendered(entry) then
    index:Update(id,entry.motor.Transform.Position,entry.radius)
   end
  end
 end
 worker.indexedEpoch=job.epoch
 debug.profileend()
end
local function getClientQueryIndex(): BoidQueryIndex.Index?
 if not clientQueryIndexEnabled then return nil end
 if not clientQueryIndex then
  local created=BoidQueryIndex.new()
  clientQueryIndex=created
  for id,entry in entries do
   local position=if hasRendered(entry) then entry.motor.Transform.Position else entry.part.Position
   created:Update(id,position,entry.radius)
  end
 end
 for _,worker in workers do catchUpIndex(worker) end
 return clientQueryIndex
end
local function registerBoid(id: number,boid: Model | BasePart,now: number): ()
 local part=if boid:IsA("Model") then boid.PrimaryPart :: BasePart else boid
 part.Anchored=false
 part.CanCollide=false
 part.CanTouch=false
 part.CanQuery=false
 local motor=Instance.new("Motor6D")
 motor.Name="BoidMotor"
 motor.Part0=BoidRoot
 motor.Part1=part
 motor.Parent=BoidRoot
 nextLifetime+=1
 local entry: Entry={id=id,lifetime=nextLifetime,groupId=groupIdByBoid[id],model=boidModelById[id],motor=motor,part=part,createdAt=now,hasRendered=false,radius=BoidCollisionConfig.GetRadius(boidModelById[id])}
 entries[id]=entry
 stage(entry)
 if clientQueryIndex then clientQueryIndex:Update(id,part.Position,entry.radius) end
end
local function unregisterBoid(id: number): ()
 local entry=entries[id]
 if not entry then return end
 stage(entry,true)
 entries[id]=nil
 entry.motor:Destroy()
 lastSnapshotTimeByBoid[id]=nil
 boidColors[id]=nil
 boidModelById[id]=nil
 if clientQueryIndex then clientQueryIndex:Remove(id) end
end
local function consumeCellSnapshot(origin: Vector3,networkBoids: buffer,boidCount: number,completionTime: number): ()
 if boidCount<=0 or buffer.len(networkBoids)<boidCount*PacketCodec.BOID_ROW_BYTES then return end
 for id,px,py,pz,vx,vy,vz in PacketCodec.ForEachBoid(networkBoids,0,boidCount) do
  local entry=entries[id]
  if not entry then continue end
  local previous=lastSnapshotTimeByBoid[id]
  if previous and completionTime<=previous then continue end
  lastSnapshotTimeByBoid[id]=completionTime
  entry.interval=if previous then completionTime-previous else nil
  entry.snapshotAt=completionTime
  local p=Vector3.new(origin.X+px,origin.Y+py,origin.Z+pz)
  entry.position=p
  entry.velocity=Vector3.new(vx,vy,vz)
  local cellOrigin=Vector3.new((p.X//64)*64,(p.Y//64)*64,(p.Z//64)*64)
  local key=Quantization.GetNumericalKey(cellOrigin.X,cellOrigin.Y,cellOrigin.Z)
  if key~=entry.cellKey then
   entry.cellKey=key
   entry.cellOrigin=cellOrigin
   stage(entry)
  end
  workers[ownerOf(id)].samples[id]=entry
 end
end
local function deleteRenderedBoid(boidId: number): ()
	local groupId = groupIdByBoid[boidId]
	if groupId == nil then
		return
	end

	renderedCountByGroup[groupId] = math.max(0, (renderedCountByGroup[groupId] or 0) - 1)
	groupIdByBoid[boidId] = nil
	local groupTracker = boidsByGroup[groupId]
	local boid: (Model | BasePart)? = if groupTracker then groupTracker[boidId] else nil
	if groupTracker then
		groupTracker[boidId] = nil
	end

	unregisterBoid(boidId)
	if boid then
		boid:Destroy()
	end
end

local function receiveNewBoidBatch(networkBoidsBatch: NetworkBoidsBatch): ()
	local boidCount:number = networkBoidsBatch.boidCount
	local groupId:number = networkBoidsBatch.groupId
	local boidModels: buffer = networkBoidsBatch.boidModels
	local boidIds:buffer = networkBoidsBatch.boidIds

	-- Rejected delayed batches must not recreate even an empty group registry.
	local hasLiveRow = false
	for row = 0, boidCount - 1 do
		local id = buffer.readu16(boidIds, row * 2)
		local lifetime = if networkBoidsBatch.lifetimes then networkBoidsBatch.lifetimes[id] else nil
		if not entries[id] and (not lifetime or lifetime > (retiredLifetimes[id] or -1)) then
			hasLiveRow = true
			break
		end
	end
	if not hasLiveRow then return end

	if typeof(networkBoidsBatch.renderColor) == "Color3" then
		groupColors[groupId] = networkBoidsBatch.renderColor
	elseif not groupColors[groupId] then
		groupColors[groupId] = Color3.new(math.random(), math.random(), math.random())
	end

	--print(`Got batch for group {groupId} with {boidCount} boids`)

	local groupTracker:{[number]:Model | BasePart} = boidsByGroup[groupId]
	local groupFolder = groupFolders[groupId]
	if not groupTracker then
		groupTracker = {}
		boidsByGroup[groupId] = groupTracker

		groupFolder = Instance.new("Folder")
		groupFolder.Name = "Boids-" .. tostring(groupId)
		groupFolder.Parent = BoidFolder

		groupFolders[groupId] = groupFolder
	end

	local now: number = workspace:GetServerTimeNow()

	local newBoidModel:(Model | BasePart)
	local boidId:number
	for i = 0, boidCount - 1 do
		boidId = buffer.readu16(boidIds, i * 2)
		local lifetime = if networkBoidsBatch.lifetimes then networkBoidsBatch.lifetimes[boidId] else nil
		if (lifetime and lifetime <= (retiredLifetimes[boidId] or -1)) or entries[boidId] then continue end
		spawnLifetimes[boidId] = lifetime

		local model = buffer.readu8(boidModels, i)
		local modelName = SharedTypes.BoidModelNames[model]
		local template = BoidModelsStorage:FindFirstChild(modelName)
		assert(template and template:IsA("BasePart"), "Missing BasePart template for boid model " .. modelName)

		newBoidModel = template:Clone()
		newBoidModel.Color = groupColors[groupId]
		newBoidModel:SetAttribute("BoidId", boidId)
		newBoidModel.CollisionGroup = "BoidRenderable"
		-- Set before parenting so a newly spawned boid never enters Workspace query broad phase.
		newBoidModel.CanQuery = false
		newBoidModel.Parent = groupFolder

		groupTracker[boidId] = newBoidModel
		groupIdByBoid[boidId] = groupId
		boidColors[boidId] = groupColors[groupId]
		boidModelById[boidId] = model

		registerBoid(boidId, newBoidModel, now)
		renderedCountByGroup[groupId] = (renderedCountByGroup[groupId] or 0) + 1
	end


	--print(`Client has registered {totalBoidsRegistered} boids`)
end


local function receiveDeleteBoidBatch(packet: buffer, lifetimes: {[number]: number}?): ()
	if typeof(packet) ~= "buffer" or buffer.len(packet) < U16_SIZE then
		return
	end

	local boidCount = buffer.readu16(packet, 0)
	if buffer.len(packet) ~= U16_SIZE + boidCount * U16_SIZE then
		return
	end

	for offset = 0, boidCount - 1 do
		local boidId = buffer.readu16(packet, U16_SIZE + offset * U16_SIZE)
		local lifetime = if lifetimes then lifetimes[boidId] else spawnLifetimes[boidId]
		if lifetime then
			retiredLifetimes[boidId] = math.max(retiredLifetimes[boidId] or -1, lifetime)
		end
		if not lifetime or (spawnLifetimes[boidId] or -1) <= lifetime then
			deleteRenderedBoid(boidId)
			spawnLifetimes[boidId] = nil
		end
	end
end


local function receiveDeleteGroup(groupId: number): ()
	--print(`Deleting {groupId}`)

	local groupFolder:Folder? = groupFolders[groupId]
	if groupFolder then
		for boidId, _ in boidsByGroup[groupId] or {} do
			local lifetime = spawnLifetimes[boidId]
			if lifetime then retiredLifetimes[boidId] = math.max(retiredLifetimes[boidId] or -1, lifetime) end
			spawnLifetimes[boidId] = nil
			groupIdByBoid[boidId] = nil
			unregisterBoid(boidId)
		end

		groupFolders[groupId] = nil
		groupFolder:Destroy()
	end

	boidsByGroup[groupId] = nil
	renderedCountByGroup[groupId] = nil
	groupColors[groupId] = nil
end


local function getRenderedInstance(boidId: number): BasePart?
	local groupId = groupIdByBoid[boidId]
	local group = groupId and boidsByGroup[groupId]
	local instance = group and group[boidId]
	if instance and instance:IsA("BasePart") then
		return instance
	end
	return nil
end


export type RenderedGroupBounds={groupId: number,count: number,centroid: Vector3,minimum: Vector3,maximum: Vector3,sampledAt: number}
function BoidsRenderer.GetRenderedBoidPose(id: number): Types.Pose?
 local entry=entries[id]
 if not entry then return nil end
 local rendered=hasRendered(entry)
 return {boidId=id,groupId=entry.groupId,cframe=if rendered then entry.motor.Transform else entry.part.CFrame,isRendered=rendered}
end
function BoidsRenderer.HasRenderedGroup(groupId: number): boolean return boidsByGroup[groupId]~=nil end
function BoidsRenderer.GetRenderedGroupBounds(groupId: number): RenderedGroupBounds?
 local group=boidsByGroup[groupId]
 if not group then return nil end
 local minimum,maximum=Vector3.one*math.huge,-Vector3.one*math.huge
 local sum=Vector3.zero
 local count=0
 for id in group do
  local entry=entries[id]
  if not entry or not hasRendered(entry) then continue end
  local position=entry.motor.Transform.Position
  local extent=Vector3.one*entry.radius
  minimum=minimum:Min(position-extent)
  maximum=maximum:Max(position+extent)
  sum+=position
  count+=1
 end
 if count==0 then return nil end
 return {groupId=groupId,count=count,centroid=sum/count,minimum=minimum,maximum=maximum,sampledAt=workspace:GetServerTimeNow()}
end
export type RenderedGroupInfo={groupId: number,count: number,color: Color3}
function BoidsRenderer.GetRenderedGroupInfo(groupId: number): RenderedGroupInfo?
 if not boidsByGroup[groupId] then return nil end
 return {groupId=groupId,count=renderedCountByGroup[groupId] or 0,color=groupColors[groupId]}
end
function BoidsRenderer.PickRenderedBoid(origin: Vector3,direction: Vector3,groupId: number?,angularTolerance: number?): {boidId: number,groupId: number,position: Vector3,distance: number}?
 local limit=direction.Magnitude
 if limit<=0 then return nil end
 local unit=direction/limit
 local bestDistance=limit
 local best: Entry?=nil
 for _,entry in entries do
  if groupId~=nil and entry.groupId~=groupId then continue end
  if not hasRendered(entry) then continue end
  local offset=entry.motor.Transform.Position-origin
  local along=offset:Dot(unit)
  if along<0 or along>limit then continue end
  local radius=math.max(entry.radius,along*(angularTolerance or 0))
  local perpendicularSq=math.max(0,offset:Dot(offset)-along*along)
  if perpendicularSq>radius*radius then continue end
  local hitDistance=math.max(0,along-math.sqrt(radius*radius-perpendicularSq))
  if hitDistance<bestDistance then bestDistance=hitDistance
  best=entry end
 end
 if not best then return nil end
 return {boidId=best.id,groupId=best.groupId,position=best.motor.Transform.Position,distance=bestDistance}
end
local function request(worker: Worker,id: number,lifetime: number,isGroup: boolean,receive: (unknown)->()): ()->()
 nextRequest+=1
 local token=nextRequest
 pendingRequests[token]={receive=receive}
 worker.actor:SendMessage("Observe",id,lifetime,token,isGroup)
 return function(): () pendingRequests[token]=nil end
end
function BoidsRenderer.RequestRenderedBoidSample(id: number,callback: (Types.Sample?)->()): ()->()
 local entry=entries[id]
 local active=true
 if not entry or not workers[ownerOf(id)].ready or failed then
  task.defer(function(): () if active then callback(nil) end end)
  return function(): () active=false end
 end
 return request(workers[ownerOf(id)],id,entry.lifetime,false,function(value: unknown): ()
  if entries[id]~=entry then callback(nil)
  return end
  callback(value :: Types.Sample?)
 end)
end
function BoidsRenderer.RequestRenderedGroupAge(groupId: number,callback: (Types.GroupAge?)->()): ()->()
 local folder=groupFolders[groupId]
 local active=true
 for _,worker in workers do
  if not worker.ready then
   task.defer(function(): () if active then callback(nil) end end)
   return function(): () active=false end
  end
 end
 if not folder or failed then
  task.defer(function(): () if active then callback(nil) end end)
  return function(): () active=false end
 end
 local cancellations: {()->()}={}
 local remaining=#workers
 local count,oldest,sampledAt=0,math.huge,math.huge
 for _,worker in workers do
  cancellations[#cancellations+1]=request(worker,groupId,0,true,function(value: unknown): ()
   local age=value :: Types.GroupAge
   count+=age.count
   if age.oldestRenderedAt then oldest=math.min(oldest,age.oldestRenderedAt) end
   sampledAt=math.min(sampledAt,age.sampledAt)
   remaining-=1
   if remaining==0 and active then
    callback(if groupFolders[groupId]==folder then {count=count,oldestRenderedAt=if count>0 then oldest else nil,sampledAt=sampledAt} else nil)
   end
  end)
 end
 return function(): ()
  active=false
  for _,cancel in cancellations do cancel() end
 end
end
export type QueryHit = {
	boidId: number,
	Instance: BasePart?,
	Position: Vector3,
	Distance: number,
	Normal: Vector3,
}

function BoidsRenderer.RaycastBoids(origin: Vector3, direction: Vector3, sweepRadius: number?, ignoredBoidIds: {[number]: boolean}?): QueryHit?
	local queryIndex = getClientQueryIndex()
	if not queryIndex then
		return nil
	end
	local hit = queryIndex:Raycast(origin, direction, sweepRadius, ignoredBoidIds)
	if not hit then
		return nil
	end
	return {
		boidId = hit.boidId,
		Instance = getRenderedInstance(hit.boidId),
		Position = hit.position,
		Distance = hit.distance,
		Normal = hit.normal,
	}
end

function BoidsRenderer.GetBoidsInRadius(center: Vector3, radius: number, ignoredBoidIds: {[number]: boolean}?): {QueryHit}
	local queryIndex = getClientQueryIndex()
	if not queryIndex then
		return {}
	end
	local sourceHits = queryIndex:QueryRadius(center, radius, ignoredBoidIds)
	local hits: {QueryHit} = table.create(#sourceHits) :: {QueryHit}
	for index, hit in sourceHits do
		hits[index] = {
			boidId = hit.boidId,
			Instance = getRenderedInstance(hit.boidId),
			Position = hit.position,
			Distance = hit.distance,
			Normal = hit.normal,
		}
	end
	return hits
end

function BoidsRenderer.GetQueryMetrics(): BoidQueryIndex.Metrics
	if not clientQueryIndex then
		return {
			entryCount = 0,
			queryCount = 0,
			candidateCount = 0,
			exactTestCount = 0,
			p50Ms = 0,
			p95Ms = 0,
		}
	end
	return clientQueryIndex:GetMetrics()
end


local function settleWorker(worker: Worker,result: Types.Result): ()
 local epoch=currentEpoch
 if not epoch or result.epoch~=epoch.id or not worker.job then return end
 if result.error then fail(result.error)
 return end
 local started=if epoch.measure then os.clock() else 0
 catchUpIndex(worker)
 if epoch.measure then epoch.coordinatorMs+=(os.clock()-started)*1000 end
 local renderedAt=worker.job.now
 worker.job=nil
 epoch.pending-=1
 epoch.dirty+=result.dirty
 epoch.kernelMs+=result.kernelMs
 epoch.inputMs+=result.inputMs
 epoch.synchronizeMs+=result.synchronizeMs
 epoch.assignmentMs+=result.assignmentMs
 if epoch.pending~=0 or failed then return end
 -- Publish cadence only after success, anchored to the pose timestamp, not ack latency.
 Scheduler.Settle(epoch.plan,renderedAt)
 if epoch.measure and epoch.measurementRevision==Measurements.Revision() then
  Measurements.RecordEpoch((os.clock()-epoch.started)*1000,epoch.coordinatorMs,epoch.kernelMs,epoch.inputMs,epoch.synchronizeMs,epoch.assignmentMs,
   epoch.inputBytes,epoch.messages,epoch.plan.activeCells,epoch.plan.scheduledCells,epoch.plan.attempted,epoch.dirty,LODConfig.GetActive().client.maxRenderBoidsPerFrame,epoch.plan.agedCells)
 end
 currentEpoch=nil
end
local function onRenderStepped(frameDt: number): ()
 local camera=workspace.CurrentCamera
 if not camera then return end
 Measurements.Frame(frameDt)
 local now=workspace:GetServerTimeNow()
 if onViewingCamera then onViewingCamera(camera.CFrame,now) end
 if failed then return end
 if currentEpoch then
  if os.clock()-currentEpoch.started>5 then fail("Render epoch did not acknowledge within five seconds; Actors are not reusable") end
  return
 end
 for _,worker in workers do if not worker.ready then return end end
 local measure=Measurements.IsEnabled()
 local started=os.clock()
 debug.profilebegin("BoidsRender.Prepare")
 local changesByOwner: {{Types.Change}}={}
 for owner,worker in workers do
  local changes: {Types.Change}={}
  for _,change in worker.changes do
   changes[#changes+1]=change
   Scheduler.Apply(scheduler,change,owner,now)
  end
  changesByOwner[owner]=changes
  table.clear(worker.changes)
 end
 local plan=Scheduler.Plan(scheduler,camera.CFrame,camera.FieldOfView,LODConfig.GetActive().client,now)
 nextEpoch+=1
 local epoch: Epoch={id=nextEpoch,started=started,frameDt=frameDt,plan=plan,pending=0,measure=measure,measurementRevision=Measurements.Revision(),
  coordinatorMs=0,inputBytes=0,messages=0,dirty=0,kernelMs=0,synchronizeMs=0,assignmentMs=0,inputMs=0}
 local jobs: {Types.Frame?}={}
 for owner,worker in workers do
  local samples: {Entry}={}
  for _,entry in worker.samples do samples[#samples+1]=entry end
  local data=buffer.create(#samples*Types.SampleBytes)
  for index,entry in samples do
   Types.WriteSample(data,(index-1)*Types.SampleBytes,entry.id,entry.lifetime,entry.snapshotAt :: number,entry.interval,entry.position :: Vector3,entry.velocity :: Vector3)
  end
  table.clear(worker.samples)
  if #changesByOwner[owner]==0 and #samples==0 and #plan.grants[owner]==0 then continue end
  local job: Types.Frame={epoch=epoch.id,now=now,changes=changesByOwner[owner],samples=data,grants=plan.grants[owner],measure=measure}
  jobs[owner]=job
  worker.job=job
  epoch.pending+=1
  epoch.inputBytes+=buffer.len(data)
  epoch.messages+=1
 end
 debug.profileend()
 if epoch.pending==0 then return end
 currentEpoch=epoch
 debug.profilebegin("BoidsRender.Dispatch")
 for owner,worker in workers do
  local job=jobs[owner]
  if job then worker.actor:SendMessage("Frame",job) end
 end
 debug.profileend()
 if measure then epoch.coordinatorMs=(os.clock()-started)*1000 end
end
BoidsRenderer.SetMeasurementsEnabled=Measurements.SetEnabled
BoidsRenderer.ResetMeasurements=Measurements.Reset
BoidsRenderer.GetMeasurements=Measurements.Read
function BoidsRenderer.Start(viewingCameraObserver: ((CFrame,number)->())?,options: Types.Options?): ()
 if isStarted then return end
 local actorCount=if options and options.actorCount~=nil then options.actorCount else 8
 assert(actorCount%1==0 and actorCount>=1 and actorCount<=32,"render actorCount must be an integer in [1,32]")
 isStarted=true
 onViewingCamera=viewingCameraObserver
 scheduler=Scheduler.New(actorCount)
 clientQueryIndexEnabled=QueryIndexConfig.IsEnabledForClient()
 BoidFolder=Instance.new("Folder")
 BoidFolder.Name="BoidFolder"
 BoidFolder.Parent=workspace
 BoidRoot=Instance.new("Part")
 BoidRoot.Name="BoidRoot"
 BoidRoot.Anchored=true
 BoidRoot.CanCollide=false
 BoidRoot.CanTouch=false
 BoidRoot.CanQuery=false
 BoidRoot.Transparency=1
 BoidRoot.CFrame=CFrame.identity
 BoidRoot.Size=Vector3.one
 BoidRoot.Parent=BoidFolder
 local pool=Instance.new("Folder")
 pool.Name="BoidsRenderActors"
 pool.Parent=Players.LocalPlayer.PlayerScripts
 for owner=1,actorCount do
  local actor=Instance.new("Actor")
  actor.Name="Render_"..owner
  local reply=Instance.new("BindableEvent")
  reply.Name="Reply"
  reply.Parent=actor
  local worker: Worker={actor=actor,owner=owner,ready=false,changes={},samples={},indexedEpoch=0}
  workers[owner]=worker
  reply.Event:Connect(function(kind: string,token: number,value: unknown): ()
   if kind=="Ready" then worker.ready=true
   return end
   if kind=="Done" then settleWorker(worker,value :: Types.Result)
   return end
   local pending=pendingRequests[token]
   if pending then pendingRequests[token]=nil
   pending.receive(value) end
  end)
  local runner=script.Worker:Clone()
  local reference=Instance.new("ObjectValue")
  reference.Name="Modules"
  reference.Value=script
  reference.Parent=runner
  runner.Parent=actor
  actor.Parent=pool
  runner.Enabled=true
 end
 RunService.RenderStepped:Connect(onRenderStepped)
 task.delay(5,function(): ()
  for _,worker in workers do if not worker.ready then fail("Render Actor failed startup readiness")
  return end end
 end)
end
BoidsRenderer.ConsumeCellSnapshot=consumeCellSnapshot
BoidsRenderer.ReceiveNewBoidBatch=receiveNewBoidBatch
BoidsRenderer.ReceiveDeleteBoidBatch=receiveDeleteBoidBatch
BoidsRenderer.ReceiveDeleteGroup=receiveDeleteGroup
return BoidsRenderer
