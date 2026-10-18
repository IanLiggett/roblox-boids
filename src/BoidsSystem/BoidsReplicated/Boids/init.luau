--!native
--!strict

--[[ Boids
Description:
	Server-side boid simulation coordinator. Owns groups and cells, stores boids
	in paged buffers, schedules cell jobs across parallel Actors, merges worker
	results, and broadcasts snapshot packets to clients.

Public API:
	Start(options: RuntimeConfig.Options?): (): explicitly starts the configured singleton
	newGroup(defaultBoidModel: BoidModel): Group
	destroyGroup(group: Group): ()
	newBoid(group: Group, position: Vector3, velocity: Vector3, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number, model: BoidModel?): number?
	deleteBoid(group: Group, boidId: number): ()
	setTarget(group: Group, target: Target, debugs: boolean?): ()
	setPath(group: Group, path: {PathNode}, switchToClosestNode: boolean?, loops: boolean?, debugs: boolean?, pathArrivalRadius: number?): ()
	addGravityWell(position: Vector3, strength: number, influenceRadius: number, groups: {Group}?): number
	removeGravityWell(gravityWellId: number, groups: {Group}?): boolean
	setLODPreset(preset: "low" | "medium" | "high"): boolean
	getLODPreset(): "low" | "medium" | "high"
]]

local RunService = game:GetService("RunService")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local BoidsReplicated = script.Parent

local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local LODConfig = require(BoidsReplicated.LODConfig)
local SimulationReplication = require(BoidsReplicated.SimulationReplication)
local NetworkResults = require(BoidsReplicated.NetworkResults)
local DebugPresentation = require(BoidsReplicated.DebugPresentation)

local Schedulers = require(script.Scheduler)
local BoidUpdates = require(script.BoidBatches)
local JobBuilder = require(script.JobBuilder)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local RuntimeConfig = require(BoidsReplicated.RuntimeConfig)
local ActorsInitializer = require(script.ActorsInitializer)
local Diagnostics = require(script.Diagnostics)
local Cells = require(script.Cells)
local IdAllocator = require(script.IdAllocator)
local ResultCommit = require(script.ResultCommit)

local Dependencies = BoidsReplicated.Dependencies
local Benchmarkers = require(Dependencies.Benchmarker.Value)
local ClientRendererBridge = require(BoidsReplicated.ClientRendererBridge)

local Boids = {}
local isStarted = false

local BoidModels = SharedTypes.BoidModels
type BoidModel = SharedTypes.BoidModel

type Page = SharedTypes.Page
type PagedBuffer = SharedTypes.PagedBuffer

type HeapNode<T> = SharedTypes.HeapNode
type Scheduler<T> = SharedTypes.Scheduler<T>
type Schedulee<T> = SharedTypes.Schedulee<T>

type Benchmarker = Benchmarkers.Benchmarker

type BoidsStatsBatch = SharedTypes.BoidsStatsBatch

type Target = SharedTypes.Target
type PathNode = SharedTypes.PathNode
type GravityWell = SharedTypes.GravityWell
type LODPresetName = LODConfig.PresetName

type ActorState = ActorsInitializer.ActorState

type Cell = SharedTypes.Cell
type Group = SharedTypes.Group


local groupPositionSources: {[number]: {path: {PathNode}?, target: Target?}} = {}

-- Signed gravity-like fields are stored once and replicated to Actors on mutation, never per job.
local globalGravityWells: {[number]: GravityWell} = {}
local groupGravityWells: {[number]: {[number]: GravityWell}} = {}

-- Group IDs remain partitioned; individual boid IDs share the full u16 space.
local ID_PARTITION_SIZE = 2^15
local isClientSimulation = RunService:IsClient()
local nextGroupId = if isClientSimulation then ID_PARTITION_SIZE else 0
local nextGravityWellId = 0

-- loose line in sand, it will schedule cells until passing this threshold. It's fine if it schedules a large cell all at once, but this helps make sure that many smaller cells don't get rate limited too hard if boids are spread out
-- at 100 boids per frame that supports 6000 boids at 1 hz


-- Retained as a compatibility value; JobBuilder applies the per-group budget.

local ACTORS_COUNT = 8
local DEFAULT_PATH_ARRIVAL_RADIUS = 48

local U8_SIZE = 1
local U16_SIZE = 2
local U32_SIZE = 4

-- IDs are globally unique while live, so this avoids a group search in the hit-report path.
local boidGroupById: {[number]: Group} = {}
local observedObstacleBoidId: number? = nil
local boidSightById: {[number]: number} = {}
-- Generic lifecycle metadata for local observers such as query indexing.
local boidModelById: {[number]: BoidModel} = {}
type CreatedObserver = (boidId: number, position: Vector3, model: BoidModel) -> ()
local createdObservers: {[number]: CreatedObserver} = {}
local nextCreatedObserverId = 0
local pendingDeletionIds: {[number]: Group} = {}
local retiringGroups: {[Group]: boolean} = {}
local retiringGroupIds: {[number]: boolean} = {}
local boidLifetimes: {[number]: number} = {}
local nextLifetime = 0
local function newLifetime(): number
	nextLifetime += 1
	return nextLifetime
end
local pendingDeletionOrder: {number} = {}
type DeletedObserver = (boidIds: {number}) -> ()
local deletedObservers: {[number]: DeletedObserver} = {}
local nextDeletedObserverId = 0

function Boids.SubscribeDeleted(observer: DeletedObserver): () -> ()
	nextDeletedObserverId += 1
	local observerId = nextDeletedObserverId
	deletedObservers[observerId] = observer
	return function()
		deletedObservers[observerId] = nil
	end
end

function Boids.SubscribeCreated(observer: CreatedObserver): () -> ()
	nextCreatedObserverId += 1
	local observerId = nextCreatedObserverId
	createdObservers[observerId] = observer
	return function()
		createdObservers[observerId] = nil
	end
end

local function emitCreated(boidId: number, position: Vector3, model: BoidModel)
	for _, observer in createdObservers do
		local ok, err = pcall(observer, boidId, position, model)
		if not ok then
			warn("Boids creation observer failed: " .. tostring(err))
		end
	end
end

local function emitDeleted(boidIds: {number})
	for _, observer in deletedObservers do
		local ok, err = pcall(observer, boidIds)
		if not ok then
			warn("Boids deletion observer failed: " .. tostring(err))
		end
	end
end

local function resolvePositionSource(source: Target): Vector3
	if typeof(source) == "Instance" then
		assert(source:IsA("BasePart"), "A dynamic position source must be a BasePart")
		return source.Position
	end

	assert(type(source) == "table", "A position source must be a BasePart or a table containing Position")
	local position = source.Position
	if typeof(position) == "Vector3" then
		return position
	end
	return resolvePositionSource(position)
end

local function resolvePathNode(node: PathNode): Vector3
	return resolvePositionSource(node) + node.offset
end

function Boids.SetLODPreset(preset: LODPresetName): boolean
	return LODConfig.SetPreset(preset)
end

-- These trusted configuration APIs do not send remotes or alter rendering.
function Boids.SetViewerObservers(viewerId: number, cameraEnabled: boolean, fixedPositions: {Vector3}): ()
	JobBuilder.SetViewerObservers(viewerId, cameraEnabled, fixedPositions)
end

function Boids.ResetViewerObservers(viewerId: number): ()
	JobBuilder.ResetViewerObservers(viewerId)
end

function Boids.GetLODPreset(): LODPresetName
	return LODConfig.GetPresetName()
end

function Boids.SetTarget(group:Group, target:Target, debugs:boolean?)
	local targetPosition = resolvePositionSource(target)
	DebugPresentation.SetTarget(group.lifetime, if debugs then targetPosition else nil)

	group.usesPath = false
	groupPositionSources[group.id] = { target = target }
	for _, actor:ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("NewGroupTarget", group.id, target, group.lifetime)
	end
	SimulationReplication.ServerSetTarget(group.id, target)
end

function Boids.SetPath(group: Group, path: {PathNode}, switchToClosestNode: boolean?, loops: boolean?, debugs: boolean?, pathArrivalRadius: number?)
	assert(#path > 0, "A boid path must contain at least one node")
	assert(#path <= 255, "A boid path can contain at most 255 nodes")

	for nodeIndex: number = 1, #path do
		resolvePathNode(path[nodeIndex])
	end

	if pathArrivalRadius ~= nil then
		assert(pathArrivalRadius > 0, "Path arrival radius must be greater than zero")
		group.pathArrivalRadius = pathArrivalRadius
	end

	local actorPath: {PathNode} = table.clone(path)
	groupPositionSources[group.id] = { path = actorPath }
	group.currentPathId = group.currentPathId % 255 + 1
	group.usesPath = true
	group.pathLoops = loops == true

	local debugPositions: {Vector3}? = nil
	if debugs then
		debugPositions = {}
		for _, node in actorPath do table.insert(debugPositions, resolvePathNode(node)) end
	end
	DebugPresentation.SetPath(group.lifetime, group.id, debugPositions)

	for _, actor: ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage(
			"NewGroupPath",
			group.id,
			actorPath,
			group.currentPathId,
			switchToClosestNode == true,
			group.pathLoops,
			group.pathArrivalRadius,
			group.lifetime
		)
	end
	SimulationReplication.ServerSetPath(group.id, actorPath, switchToClosestNode == true, group.pathLoops, group.pathArrivalRadius)
end

function Boids.AddGravityWell(position: Vector3, strength: number, influenceRadius: number, groups: {Group}?, explicitId: number?): number
	assert(typeof(position) == "Vector3", "A gravity well position must be a Vector3")
	assert(strength == strength and strength > -math.huge and strength < math.huge, "Gravity well strength must be a finite number")
	assert(influenceRadius == influenceRadius and influenceRadius > 0 and influenceRadius < math.huge, "Gravity well influence radius must be a finite positive number")

	local gravityWellId: number
	if explicitId ~= nil then
		assert(explicitId > 0 and explicitId % 1 == 0, "Gravity well id must be a positive integer")
		gravityWellId = explicitId
		nextGravityWellId = math.max(nextGravityWellId, gravityWellId)
	else
		nextGravityWellId += 1
		gravityWellId = nextGravityWellId
	end

	local gravityWell: GravityWell = {
		id = gravityWellId,
		position = position,
		strength = strength,
		influenceRadius = influenceRadius,
	}

	local replicatedGroupIds: {number}? = nil
	if groups then
		replicatedGroupIds = table.create(#groups)
		for index, group: Group in groups do
			table.insert(replicatedGroupIds, group.id)
			local wells = groupGravityWells[group.id]
			if not wells then
				wells = {}
				groupGravityWells[group.id] = wells
			end
			wells[gravityWell.id] = gravityWell

			for _, actor: ActorState in ActorsInitializer.actors do
				(actor.instance.Parent :: Actor):SendMessage("NewGroupGravityWell", group.id, gravityWell, group.lifetime)
			end
		end
	else
		globalGravityWells[gravityWell.id] = gravityWell
		for _, actor: ActorState in ActorsInitializer.actors do
			(actor.instance.Parent :: Actor):SendMessage("NewGlobalGravityWell", gravityWell)
		end
	end

	SimulationReplication.ServerAddGravityWell(gravityWell, replicatedGroupIds)
	return gravityWell.id
end

function Boids.RemoveGravityWell(gravityWellId: number, groups: {Group}?): boolean
	assert(type(gravityWellId) == "number", "Gravity well id must be a number")

	if groups then
		local removed = false
		local replicatedGroupIds: {number} = {}
		for _, group: Group in groups do
			local wells = groupGravityWells[group.id]
			if not wells or not wells[gravityWellId] then
				continue
			end

			wells[gravityWellId] = nil
			if next(wells) == nil then
				groupGravityWells[group.id] = nil
			end

			for _, actor: ActorState in ActorsInitializer.actors do
				(actor.instance.Parent :: Actor):SendMessage("RemoveGroupGravityWell", group.id, gravityWellId, group.lifetime)
			end
			table.insert(replicatedGroupIds, group.id)
			removed = true
		end
		if removed then
			SimulationReplication.ServerRemoveGravityWell(gravityWellId, replicatedGroupIds)
		end
		return removed
	end

	if not globalGravityWells[gravityWellId] then
		return false
	end

	globalGravityWells[gravityWellId] = nil
	for _, actor: ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("RemoveGlobalGravityWell", gravityWellId)
	end
	SimulationReplication.ServerRemoveGravityWell(gravityWellId)
	return true
end


local groups: SharedTypes.GroupRegistry = {}
local addBoidToCell = Cells.AddBoid
Boids.addBoidToCell = addBoidToCell

function Boids.NewGroup(defaultBoidModel: BoidModel, explicitId: number?, renderColor: Color3?):Group	
	assert(isStarted, "Boids.Start must precede group creation")
	local id: number = explicitId or nextGroupId
	assert(id >= 0 and id < 2^16 and id % 1 == 0, "Boid group id must be a u16 integer")
	assert(not groups[id], `Boid group {id} already exists`)
	assert(not retiringGroupIds[id], "Group teardown has not settled")
	local group: Group = {
		lifetime = newLifetime(),
		id = id,
		defaultBoidModel = defaultBoidModel,
		renderColor = renderColor,
		activeCells = {},
		cellCount = 0,
		
		scheduler = Schedulers.NewScheduler<<Cell>>(Cells.WakeTime, Cells.IsDue),
		boidsStatsBatch = BoidUpdates.NewBoidsStatsUpdate(id, 200, (1/60)*3, (1/60), defaultBoidModel, renderColor),
		
		boidCount = 0,
		sightSum = 0,
		averageSight = 0,
		
		jobMsStats = Benchmarkers.newBenchmarker(100),
		neighborItersPerJob = Benchmarkers.newBenchmarker(100),
		jobSendStats = Benchmarkers.newBenchmarker(100),
		jobReceiveStats = Benchmarkers.newBenchmarker(100),
		
		cellsPerSecond = Benchmarkers.newBenchmarker(15),
		boidsPerSecond = Benchmarkers.newBenchmarker(15),
		cellsThisSecond = 0,
		boidsThisSecond = 0,

		currentPathId = 0,
		usesPath = false,
		pathLoops = false,
		pathArrivalRadius = DEFAULT_PATH_ARRIVAL_RADIUS,
	}
	if explicitId == nil then
		nextGroupId += 1
	end
	
	groups[id] = group
	SimulationReplication.ServerRegisterGroup(id, defaultBoidModel, renderColor)
	
	return group
end

local destroyGroupNow: (Group) -> ()
function Boids.DestroyGroup(group: Group): ()
	destroyGroupNow(group)
end


local freeBoidIds: IdAllocator.Allocator = IdAllocator.New()
local serverBoidIds: buffer = buffer.create(8192)
-- Each queued/pending spawn holds a reservation, including duplicate replay rows.
local serverReservations: {[number]: number} = {}

local function setServerOwned(id: number, isOwned: boolean): ()
	local offset = math.floor(id / 8)
	local mask = bit32.lshift(1, id % 8)
	local previous = buffer.readu8(serverBoidIds, offset)
	buffer.writeu8(serverBoidIds, offset, if isOwned then bit32.bor(previous, mask) else bit32.band(previous, bit32.bnot(mask)))
end

function Boids.ReserveServerBoidId(id: number): ()
	assert(isClientSimulation and id >= 0 and id < 2^16 and id % 1 == 0, "Expected client server-ID reservation")
	serverReservations[id] = (serverReservations[id] or 0) + 1
	IdAllocator.Reserve(freeBoidIds, id)
end

function Boids.ReleaseServerBoidId(id: number): ()
	local count = assert(serverReservations[id], "Missing server-ID reservation")
	serverReservations[id] = if count > 1 then count - 1 else nil
	if count == 1 and not boidLifetimes[id] then IdAllocator.Release(freeBoidIds, id) end
end

local function claimBoidId(explicitId: number?): number?
	if explicitId ~= nil then
		assert(explicitId >= 0 and explicitId < 2^16 and explicitId % 1 == 0, "Boid id must be a u16 integer")
		assert(not boidLifetimes[explicitId], `Boid {explicitId} is live or still settling deletion`)
		IdAllocator.Reserve(freeBoidIds, explicitId)
		setServerOwned(explicitId, true)
		return explicitId
	end

	local id = IdAllocator.Take(freeBoidIds, isClientSimulation)
	if id ~= nil and not isClientSimulation then setServerOwned(id, true) end
	return id
end

local function returnBoidId(id:number)
	setServerOwned(id, false)
	if not serverReservations[id] then IdAllocator.Release(freeBoidIds, id) end
end

function Boids.NewBoid(
	group:Group,
	position:Vector3, velocity:Vector3,
	maxSpeed:number, minSpeed:number,
	sight:number, avoidance:number, separation:number, repulsion:number, repulsionStrength:number,
	alignment:number, cohesion:number,
	targetBias:number,
	model:BoidModel?,
	explicitId: number?
):number?
	assert(groups[group.id] == group, "Cannot spawn into a retired group")
	local boidId:number? = claimBoidId(explicitId)
	if not boidId then
		warn("Unable to create new boid, id's exhausted")
		return nil
	end
	
	minSpeed = math.min(maxSpeed, minSpeed)
	local resolvedModel: BoidModel = model or group.defaultBoidModel
	boidLifetimes[boidId] = newLifetime()
	BoidUpdates.AddBoidToBatch(group.boidsStatsBatch, boidId, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias, resolvedModel, boidLifetimes[boidId])
	
	local cellId:number = Quantization.GetNumericalKey(Quantization.ConvertCoordsToGrid(position.X, position.Y, position.Z))
	addBoidToCell(group, cellId, position, velocity, boidId, Quantization.CurrentSimTick())
	boidGroupById[boidId] = group
	boidSightById[boidId] = sight
	boidModelById[boidId] = resolvedModel
	
	group.boidCount += 1
	group.sightSum += sight
	group.averageSight = group.sightSum / group.boidCount

	SimulationReplication.ServerRegisterBoid(
		group.id,
		boidId,
		position,
		velocity,
		maxSpeed,
		minSpeed,
		sight,
		avoidance,
		separation,
		repulsion,
		repulsionStrength,
		alignment,
		cohesion,
		targetBias,
		resolvedModel
	)
	emitCreated(boidId, position, resolvedModel)
	
	return boidId
end

local broadcastDeletedBoids: (boidIds: {number}) -> ()

local function deleteBoidNow(boidId: number): boolean
	local group: Group? = boidGroupById[boidId]
	local boidEntry = BoidStorage.BoidRegistry[boidId]
	if not group or not boidEntry then
		return false
	end

	local cell: Cell? = group.activeCells[boidEntry.cellId]
	if not cell then
		return false
	end

	-- A worker owns this cell while it is scheduled. Waiting avoids overwriting
	-- this authoritative removal when that worker's snapshot is merged back.
	local schedulee = group.scheduler.schedulees[cell.id]
	if schedulee and schedulee.alreadyScheduled then
		return false
	end

	local page: Page? = BoidStorage.PageRegistry[boidEntry.pageId]
	if not page or not BoidStorage.deleteBoidAtSlot(page, boidEntry.slot, cell.pages) then
		return false
	end

	cell.boidCount -= 1
	group.boidCount -= 1
	group.sightSum -= boidSightById[boidId] or 0
	group.averageSight = if group.boidCount > 0 then group.sightSum / group.boidCount else 0

	if observedObstacleBoidId == boidId then Boids.SetObstacleObservation(nil) end
	BoidStorage.BoidRegistry[boidId] = nil
	boidGroupById[boidId] = nil
	boidSightById[boidId] = nil
	boidModelById[boidId] = nil
	pendingDeletionIds[boidId] = nil
	BoidUpdates.RemoveBoid(group.boidsStatsBatch, boidId)

	if cell.boidCount <= 0 then
		Cells.Remove(group, cell)
	end

	return true
end

local function hasCommittingJob(group: Group): boolean
	for _, actor in ActorsInitializer.actors do
		local execution = actor.execution
		if execution and execution.group == group and execution.phase == "completing" then return true end
	end
	return false
end

local function finishDestroyedGroup(group: Group): ()
	if not retiringGroups[group] then return end
	retiringGroups[group] = nil
	local ids: {number} = {}
	for id, owner in boidGroupById do
		if owner == group then
			table.insert(ids, id)
			BoidStorage.BoidRegistry[id] = nil
			boidGroupById[id], boidSightById[id], boidModelById[id], pendingDeletionIds[id] = nil, nil, nil, nil
		end
	end
	BoidUpdates.DestroyBatch(group.boidsStatsBatch)
	for _, cell in group.activeCells do
		Cells.Remove(group, cell)
	end
	table.clear(group.activeCells)
	table.clear(group.scheduler.schedulees)
	Schedulers.RebuildSchedulerHeap(group.scheduler)
	group.cellCount, group.boidCount, group.sightSum, group.averageSight = 0, 0, 0, 0
	groupPositionSources[group.id] = nil

	DebugPresentation.GroupRemoved(group.lifetime)
	groupGravityWells[group.id] = nil
	for _, actor in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("RetireGroup", group.id, group.lifetime)
	end
	broadcastDeletedBoids(ids)
	if RunService:IsServer() then
		SimulationReplication.ServerDestroyGroup(group.id)
	else
		ClientRendererBridge.ReceiveDeleteGroup(group.id)
	end
	retiringGroups[group], retiringGroupIds[group.id] = nil, nil
end

function destroyGroupNow(group: Group): ()
	if groups[group.id] ~= group then return end
	if observedObstacleBoidId ~= nil and boidGroupById[observedObstacleBoidId] == group then
		Boids.SetObstacleObservation(nil)
	end
	retiringGroups[group], retiringGroupIds[group.id] = true, true
	groups[group.id] = nil
	ActorsInitializer.CancelGroup(group)
	if not hasCommittingJob(group) then finishDestroyedGroup(group) end
end

function Boids.DeleteBoid(group: Group, boidId: number): boolean
	if boidGroupById[boidId] ~= group then
		return false
	end

	local deleted = deleteBoidNow(boidId)
	if deleted then
		broadcastDeletedBoids({boidId})
	end
	return deleted
end

function Boids.IsGroupRetiring(groupId: number): boolean
	return retiringGroupIds[groupId] == true
end

function Boids.IsDeletionPending(boidId: number): boolean
	return pendingDeletionIds[boidId] ~= nil or (boidLifetimes[boidId] ~= nil and boidGroupById[boidId] == nil)
end

function Boids.QueueDeleteBoid(boidId: number)
	if not boidGroupById[boidId] or pendingDeletionIds[boidId] then
		return
	end

	pendingDeletionIds[boidId] = boidGroupById[boidId]
	table.insert(pendingDeletionOrder, boidId)
end

-- Server snapshots feed this client-only target. The Actor worker blends it
-- into normal steering; storage is never snapped or overwritten from network.
function Boids.SetReconciliationTargets(targets: {{boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number}})
	if not RunService:IsClient() or #targets == 0 then return end
	if RuntimeMetrics.State.mode == "detailed" then
		RuntimeMetrics.Add(RuntimeMetrics.State, "correctionMessages", #ActorsInitializer.actors)
	end
	local liveTargets = {}
	for _, target in targets do
		local lifetime = boidLifetimes[target.boidId]
		if lifetime and not pendingDeletionIds[target.boidId] then
			table.insert(liveTargets, {boidId=target.boidId, position=target.position, velocity=target.velocity, snapshotTime=target.snapshotTime, lifetime=lifetime})
		end
	end
	for _, actor: ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("SetBoidReconciliationTargets", liveTargets)
	end
end

function Boids.SetReconciliationTarget(boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number)
	Boids.SetReconciliationTargets({ { boidId = boidId, position = position, velocity = velocity, snapshotTime = snapshotTime } })
end

function Boids.GetRuntimeSummary(): SharedTypes.RuntimeSummary
	return Diagnostics.ReadSummary(groups, #ActorsInitializer.actors)
end

function Boids.GetRuntimeDiagnostics(): SharedTypes.RuntimeDiagnostics
	return Diagnostics.Read(groups, ActorsInitializer.actors, Cells.IsDue, RuntimeMetrics.State.mode == "detailed")
end

function Boids.GetRuntimeMetrics(sinceTotals: {[string]: number}?): SharedTypes.RuntimeMetrics
	return JobBuilder.GetRuntimeMetrics(sinceTotals)
end
function Boids.SubscribePostMerge(observer: (batch: ResultCommit.CompletedBoidBatch) -> ()): () -> ()
	return ResultCommit.SubscribePostMerge(observer)
end

-- Returns the packed simulation state, not the renderer state. This is used by
-- telemetry to compare a client replica against its latest server snapshot.
function Boids.GetBoidState(boidId: number): (Vector3?, Vector3?)
	local group: Group? = boidGroupById[boidId]
	local entry = BoidStorage.BoidRegistry[boidId]
	if not group or not entry then
		return nil, nil
	end

	local cell: Cell? = group.activeCells[entry.cellId]
	local page: Page? = BoidStorage.PageRegistry[entry.pageId]
	if not cell or not page then
		return nil, nil
	end

	local position = cell.origin + Vector3.new(BoidStorage.ReadPosition(page.data, entry.slot))
	local velocity = Vector3.new(BoidStorage.ReadVelocity(page.data, entry.slot)) * BoidStorage.ReadSpeed(page.data, entry.slot)
	return position, velocity
end

-- Value-only read of settled coordinator storage; never schedules or advances a boid.
function Boids.GetBoidObservation(boidId: number): SharedTypes.BoidObservation?
	local group = boidGroupById[boidId]
	local entry = BoidStorage.BoidRegistry[boidId]
	if not group or not entry or not groups[group.id] then return nil end
	local cell = group.activeCells[entry.cellId]
	local page = BoidStorage.PageRegistry[entry.pageId]
	if not cell or not page then return nil end
	local node = BoidStorage.ReadPathNode(page.data, entry.slot)
	return {
		boidId = boidId, groupId = group.id, cellId = entry.cellId, cellOrigin = cell.origin,
		position = cell.origin + Vector3.new(BoidStorage.ReadPosition(page.data, entry.slot)),
		velocity = Vector3.new(BoidStorage.ReadVelocity(page.data, entry.slot)) * BoidStorage.ReadSpeed(page.data, entry.slot),
		pathNodeIndex = if group.usesPath and node > 0 then node else nil,
		lastSimulationTick = BoidStorage.ReadLastTick(page.data, entry.slot),
		currentTick = Quantization.CurrentSimTick(), sampledAt = workspace:GetServerTimeNow(),
	}
end

-- Trusted local diagnostic configuration; scenario observation owns permissions/lifetime.
function Boids.SetObstacleObservation(boidId: number?): ()
	assert(boidId == nil or (isClientSimulation and boidId >= 0 and boidId <= 65535 and boidId % 1 == 0),
		"Obstacle observation requires a client boid ID")
	local group = if boidId ~= nil then boidGroupById[boidId] else nil
	observedObstacleBoidId = if group and groups[group.id] then boidId else nil
	ResultCommit.SetObstacleObservation(observedObstacleBoidId, if observedObstacleBoidId ~= nil and group then group.id else nil)
end

function Boids.GetObstacleObservation(): SharedTypes.ObstacleObservation?
	local id = observedObstacleBoidId
	if id == nil then return nil end
	local group = boidGroupById[id]
	if not group or not groups[group.id] or not BoidStorage.BoidRegistry[id] then
		Boids.SetObstacleObservation(nil)
		return nil
	end
	return ResultCommit.GetObstacleObservation()
end

local function observePosition(value: any): Vector3?
	if typeof(value) == "Vector3" then return value end
	if typeof(value) == "Instance" then
		if value:IsA("BasePart") and value:IsDescendantOf(workspace) then return value.Position end
		return nil
	end
	if type(value) == "table" then return observePosition(value.Position) end
	return nil
end

function Boids.GetGroupObservation(groupId: number): SharedTypes.GroupObservation?
	local group = groups[groupId]
	if not group then return nil end
	local source = groupPositionSources[groupId]
	local path: {{index: number, position: Vector3?}} = {}
	local unavailableCount = 0
	for index, node in (if source then source.path else nil) or {} do
		local position = observePosition(node.Position)
		if not position then unavailableCount += 1 end
		table.insert(path, { index = index, position = if position then position + node.offset else nil })
	end
	local target = if source and source.target then observePosition(source.target) else nil
	if source and source.target and not target then unavailableCount += 1 end
	local wells: {GravityWell} = {}
	for _, well in globalGravityWells do table.insert(wells, table.clone(well)) end
	for _, well in groupGravityWells[groupId] or {} do table.insert(wells, table.clone(well)) end
	return {
		groupId = groupId, usesPath = group.usesPath, loops = group.pathLoops,
		pathArrivalRadius = group.pathArrivalRadius, path = path, target = target,
		gravityWells = wells, unavailableCount = unavailableCount,
	}
end

function Boids.HasBoid(boidId: number): boolean
	return boidGroupById[boidId] ~= nil
end

function Boids.IsServerBoid(boidId: number): boolean
	local group = boidGroupById[boidId]
	return group ~= nil and groups[group.id] == group
		and bit32.band(buffer.readu8(serverBoidIds, math.floor(boidId / 8)), bit32.lshift(1, boidId % 8)) ~= 0
		and not Boids.IsDeletionPending(boidId)
end

function Boids.GetBoidModel(boidId: number): BoidModel?
	return boidModelById[boidId]
end

function Boids.ForEachBoid(observer: (boidId: number, position: Vector3, model: BoidModel) -> ())
	for boidId, model in boidModelById do
		local position = select(1, Boids.GetBoidState(boidId))
		if position then
			observer(boidId, position, model)
		end
	end
end

function broadcastDeletedBoids(boidIds: {number})
	if #boidIds == 0 then return end
	local lifetimes: {[number]: number} = {}
	local removed: {[number]: boolean} = {}
	for _, id in boidIds do
		lifetimes[id] = boidLifetimes[id]
		removed[id] = true
	end
	NetworkResults.DiscardBoids(removed)
	local retirements: {{boidId: number, lifetime: number}} = {}
	for _, id in boidIds do table.insert(retirements, {boidId = id, lifetime = lifetimes[id]}) end
	for _, actor in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("RetireBoids", retirements)
	end
	local startIndex = 1
	while startIndex <= #boidIds do
		local count = math.min(#boidIds - startIndex + 1, 65535)
		local packet = buffer.create(U16_SIZE + count * U16_SIZE)
		buffer.writeu16(packet, 0, count)

		for offset = 0, count - 1 do
			buffer.writeu16(packet, U16_SIZE + offset * U16_SIZE, boidIds[startIndex + offset])
		end

		if RunService:IsServer() then
			if startIndex == 1 then SimulationReplication.ServerDeleteBoids(boidIds) end
		else
			ClientRendererBridge.ReceiveDeleteBoidBatch(packet, lifetimes)
		end
		startIndex += count
	end
	emitDeleted(boidIds)
	for _, id in boidIds do
		boidLifetimes[id] = nil
		returnBoidId(id)
	end
end

local function flushQueuedDeletions()
	for group in retiringGroups do
		if not hasCommittingJob(group) then finishDestroyedGroup(group) end
	end
	if #pendingDeletionOrder == 0 then
		return
	end

	local deletedBoidIds: {number} = {}
	local retryIndex = 1
	for _, boidId: number in pendingDeletionOrder do
		if not pendingDeletionIds[boidId] or pendingDeletionIds[boidId] ~= boidGroupById[boidId] then
			pendingDeletionIds[boidId] = nil
		elseif deleteBoidNow(boidId) then
			table.insert(deletedBoidIds, boidId)
			pendingDeletionIds[boidId] = nil
		elseif boidGroupById[boidId] then
			pendingDeletionOrder[retryIndex] = boidId
			retryIndex += 1
		else
			pendingDeletionIds[boidId] = nil
		end
	end

	for index = retryIndex, #pendingDeletionOrder do
		pendingDeletionOrder[index] = nil
	end

	if #deletedBoidIds > 0 then
		broadcastDeletedBoids(deletedBoidIds)
	end
end

function Boids.Start(options: RuntimeConfig.Options?): ()
	if isStarted then return end
	local config = RuntimeConfig.Resolve(options)
	isStarted = true
	ActorsInitializer.InitializeBoidActors(config.actorCount)
	SimulationReplication.SetServerStateReader(function(boidId: number): (Vector3?, Vector3?)
		if Boids.IsDeletionPending(boidId) then return nil, nil end
		return Boids.GetBoidState(boidId)
	end)
	NetworkResults.StartServer()
	SimulationReplication.StartServer()
	BoidUpdates.Start()
	RunService.Heartbeat:Connect(flushQueuedDeletions)
	JobBuilder.Start(groups, config.targetActorJobMs)
end

return Boids
