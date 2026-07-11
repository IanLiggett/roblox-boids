--!native
--!strict

--[[ Boids
Description:
	Server-side boid simulation coordinator. Owns groups and cells, stores boids
	in paged buffers, schedules cell jobs across parallel Actors, merges worker
	results, and broadcasts snapshot packets to clients.

Public API:
	newGroup(defaultBoidModel: BoidModel): Group
	destroyGroup(group: Group): ()
	newBoid(group: Group, position: Vector3, velocity: Vector3, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number, model: BoidModel?): number?
	deleteBoid(group: Group, boidId: number): ()
	setTarget(group: Group, target: Target, debugs: boolean?): ()
]]

local module = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

export type BoidsReplicated = typeof(script.Parent.BoidsReplicated)

local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(script.Parent.BoidsReplicated)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local Quantization = require(BoidsReplicated.Quantization)

local BoidUpdates = require(script.BoidBatches)
local ActorsInitializer = require(script.ActorsInitializer)
local Schedulers = require(script.Scheduler)

local Dependencies = BoidsReplicated.Dependencies
local BinaryHeaps = require(Dependencies.BinaryHeaps.Value)
local Benchmarkers = require(Dependencies.Benchmarker.Value)

local BoidModels = SharedTypes.BoidModels
type BoidModel = SharedTypes.BoidModel

type HeapNode<T> = Schedulers.HeapNode
type Scheduler<T> = Schedulers.Scheduler<T>
type Schedulee<T> = Schedulers.Schedulee<T>

type Page = SharedTypes.Page
type PagedBuffer = SharedTypes.PagedBuffer

type Benchmarker = Benchmarkers.Benchmarker

type BoidsStatsBatch = BoidUpdates.BoidsStatsBatch

type Job = SharedTypes.Job
type JobCell = SharedTypes.JobCell
type Target = SharedTypes.Target

ActorsInitializer.initializeBoidActors()
type ActorState = ActorsInitializer.ActorState


export type Group = {
	id: number,
	activeCells: {[number]:Cell},
	cellCount: number,

	scheduler: Scheduler<Cell>,
	boidsStatsBatch: BoidsStatsBatch,
	
	boidCount: number,
	sightSum: number,
	averageSight: number,
	
	benchmarker:Benchmarker
}

type Cell = {
	id: number,
	groupId: number,
	origin: Vector3,
	boidCount: number,
	
	pages: PagedBuffer,
	
	networkTick: number,
	networkInterval: number,
	
	visualizer: Model?,
}

local TargetParts = {}

local nextGroupId = 0

-- loose line in sand, it will schedule cells until passing this threshold. It's fine if it schedules a large cell all at once, but this helps make sure that many smaller cells don't get rate limited too hard if boids are spread out
-- at 100 boids per frame that supports 6000 boids at 1 hz

local DEFAULT_CELL_UPDATE_INTERVAL:number = 1.0
local MAX_ALLOWED_CELL_STALENESS:number = 1.5

local DESIRED_MAX_BOIDS = 40000
local MAX_BOIDS_PER_FRAME:number = (DESIRED_MAX_BOIDS / DEFAULT_CELL_UPDATE_INTERVAL) // 60

local ACTORS_COUNT = 8

local U8_SIZE = 1
local U16_SIZE = 2
local U32_SIZE = 4

local boidJobUpdate:UnreliableRemoteEvent = BoidsReplicated.Remotes.BoidJobUpdate
local deleteGroupRemote:RemoteEvent = BoidsReplicated.Remotes.DeleteGroup

local GridVisualizersFolder = Instance.new("Folder", workspace)
GridVisualizersFolder.Name = "GridVisualizers"

function module.setTarget(group:Group, target:Target, debugs:boolean?)
	if debugs then
		if TargetParts[group.id] then
			TargetParts[group.id]:Destroy()
		end
		
		local TargetPart = Instance.new("Part")
		TargetPart.Shape = Enum.PartType.Ball
		TargetPart.Anchored = true
		TargetPart.CanCollide = false
		TargetPart.CanQuery = true
		TargetPart.CanTouch = false
		TargetPart.Transparency = 0.4
		TargetPart.Color = Color3.new(0, 0.333333, 1)
		TargetPart.Size = Vector3.new(50, 50, 50)
		TargetPart.Position = target.Position
		TargetPart.Parent = workspace
		TargetParts[group.id] = TargetPart
	end
	
	for _, actor:ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("NewGroupTarget", group.id, target)
	end
end


local function computeCellWakeTime(schedulee: Schedulee<Cell>): number
	return math.min(
		schedulee.nextDue,
		schedulee.lastUpdated + MAX_ALLOWED_CELL_STALENESS
	)
end

local function cellValidator(schedulee: Schedulee<Cell>, now: number): boolean
	return not schedulee.alreadyScheduled
		and schedulee.entity.boidCount > 0
		and now >= computeCellWakeTime(schedulee)
end

local function computeCellCost(cell:Cell):number
	return math.max(cell.boidCount, 1) ^ 2
end

local function getNextCellWakeTime(group:Group):number
	local wakeTime:number? = Schedulers.peekNextWakeTime(group.scheduler)
	if wakeTime then
		return wakeTime
	end
	return 0
end

local function computeGroupWakeTime(schedulee:Schedulee<Group>):number
	return getNextCellWakeTime(schedulee.entity)
end

local function groupValidator(schedulee: Schedulee<Group>, now: number): boolean
	return schedulee.entity.cellCount > 0
		and now >= computeGroupWakeTime(schedulee)
end

local groupsScheduler:Scheduler<Group>; groupsScheduler = Schedulers.newScheduler<<Group>>(computeGroupWakeTime, groupValidator)

function module.newGroup(defaultBoidModel: BoidModel):Group	
	local id: number = nextGroupId
	local group: Group = {
		id = id,
		activeCells = {},
		cellCount = 0,
		
		scheduler = Schedulers.newScheduler<<Cell>>(computeCellWakeTime, cellValidator),
		boidsStatsBatch = BoidUpdates.newBoidsStatsUpdate(id, 200, (1/60)*3, (1/60), defaultBoidModel),
		
		boidCount = 0,
		sightSum = 0,
		averageSight = 0,
		
		benchmarker = Benchmarkers.newBenchmarker(3000)
	}
	nextGroupId += 1
	
	Schedulers.newSchedulee(groupsScheduler, group, (1/60))
	
	return group
end

function module.destroyGroup(group: Group)
	groupsScheduler.schedulees[group.id] = nil
	
	deleteGroupRemote:FireAllClients(group.id)
end


local function createCellOutline(origin: Vector3): Model
	local cellSize = Quantization.CELL_SIZE
	local thickness = 0.5

	local model = Instance.new("Model")
	model.Name = `CellOutline_{origin.X}_{origin.Y}_{origin.Z}`

	local corners = {
		origin + Vector3.new(0, 0, 0),
		origin + Vector3.new(cellSize, 0, 0),
		origin + Vector3.new(cellSize, cellSize, 0),
		origin + Vector3.new(0, cellSize, 0),
		origin + Vector3.new(0, 0, cellSize),
		origin + Vector3.new(cellSize, 0, cellSize),
		origin + Vector3.new(cellSize, cellSize, cellSize),
		origin + Vector3.new(0, cellSize, cellSize),
	}

	local edges = {
		{1, 2}, {2, 3}, {3, 4}, {4, 1}, -- bottom face
		{5, 6}, {6, 7}, {7, 8}, {8, 5}, -- top face
		{1, 5}, {2, 6}, {3, 7}, {4, 8}, -- vertical edges
	}

	for _, edge in edges do
		local p1 = corners[edge[1]]
		local p2 = corners[edge[2]]
		local midpoint = (p1 + p2) / 2
		local length = (p2 - p1).Magnitude

		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 0.5
		part.Color = Color3.new(0, 1, 0)
		part.Material = Enum.Material.Neon
		part.Size = Vector3.new(thickness, thickness, length)
		part.CFrame = CFrame.lookAt(midpoint, p2)
		part.Parent = model
	end

	model.Parent = GridVisualizersFolder
	return model
end

local function newCell(group:Group, origin:Vector3, cellId:number?):Cell
	cellId = cellId or Quantization.getNumericalKey(origin.X, origin.Y, origin.Z)
	local cell:Cell = {
		id = cellId,
		groupId = group.id,
		origin = origin,
		boidCount = 0,
		
		pages = BoidStorage.newPagedBuffer(),
		
		networkTick = 1,
		networkInterval = 6,
		
		visualizer = nil-- createCellOutline(origin),
	}
	group.activeCells[cellId] = cell
	group.cellCount += 1
	
	Schedulers.newSchedulee(group.scheduler, cell, DEFAULT_CELL_UPDATE_INTERVAL)
	
	return cell
end

local function addBoidToCell(
	group: Group,
	cellId: number,
	position: Vector3,
	velocity: Vector3,
	boidId: number,
	currentTick: number
)
	local cell = group.activeCells[cellId]
	if not cell then
		local origin = Vector3.new(
			Quantization.convertCoordsToGrid(position.X, position.Y, position.Z)
		)

		cell = newCell(group, origin, cellId)
	end

	local localPosition = position - cell.origin

	BoidStorage.insertBoid(
		cell.pages,
		localPosition.X,
		localPosition.Y,
		localPosition.Z,
		velocity.X,
		velocity.Y,
		velocity.Z,
		Quantization.currentSimTick(),
		boidId,
		cell.id
	)

	local wasEmpty:boolean = cell.boidCount <= 0
	cell.boidCount += 1

	local schedulee = group.scheduler.schedulees[cellId]
	if schedulee and wasEmpty and not schedulee.alreadyScheduled then
		Schedulers.enqueueSchedulee(group.scheduler, schedulee)
	end
end

local MAX_BOIDS = 2^16

local freeBoidIds:buffer = buffer.create(MAX_BOIDS * U16_SIZE)
for i = 0, MAX_BOIDS - 1 do
	buffer.writeu16(freeBoidIds, i * U16_SIZE, i)
end
local nextFreeIndex = 0

local function claimBoidId():number?
	if nextFreeIndex / U16_SIZE >= MAX_BOIDS then
		return nil
	end
	
	local id:number = buffer.readu16(freeBoidIds, nextFreeIndex)
	nextFreeIndex += U16_SIZE
	return id
end

local function returnBoidId(id:number)
	buffer.writeu16(freeBoidIds, nextFreeIndex - U16_SIZE, id)
	nextFreeIndex -= U16_SIZE
end

function module.newBoid(
	group:Group,
	position:Vector3, velocity:Vector3,
	maxSpeed:number, minSpeed:number,
	sight:number, avoidance:number, separation:number, repulsion:number, repulsionStrength:number,
	alignment:number, cohesion:number,
	targetBias:number,
	model:BoidModel?
):number?
	local boidId:number? = claimBoidId()
	if not boidId then
		warn("Unable to create new boid, id's exhausted")
		return nil
	end
	
	minSpeed = math.min(maxSpeed, minSpeed)
	BoidUpdates.addBoidToBatch(group.boidsStatsBatch, boidId, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias, model)
	
	local cellId:number = Quantization.getNumericalKey(Quantization.convertCoordsToGrid(position.X, position.Y, position.Z))
	addBoidToCell(group, cellId, position, velocity, boidId, workspace:GetServerTimeNow())
	
	group.boidCount += 1
	group.sightSum += sight
	group.averageSight = group.sightSum / group.boidCount
	
	return boidId
end

function module.deleteBoid(group: Group, boidId: number)
	-- update group sightSum/avg sight/boid count
	-- find boid location and remove (boidstorage does that)
	-- tell client? batch deletion to avoid packet spam
	-- or let client dynamically remove boids if it stopped getting updates for it, but probably not worth it
end


local TARGET_ACTOR_JOB_MS = 10

local nextJobId = 0

local lastScheduledByCell: {[number]: number} = {}
local lastReturnedByCell: {[number]: number} = {}
local scheduledCountByCell: {[number]: number} = {}
local returnedCountByCell: {[number]: number} = {}


local function buildJob(group: Group, currentTick: number, targetCost: number, boidsRemaining: number): (Job, number)
	local scheduler = group.scheduler

	local job: Job = {
		id = nextJobId,
		groupId = group.id,

		jobCells = {},
		movedBoids = {},

		cellCount = 0,

		startTime = workspace:GetServerTimeNow(),
		completionTime = -1,
		estimatedCost = 0,
		
		averageSight = group.averageSight,
		
		neighborIterations = 0
	}

	nextJobId += 1
	
	local boidsScheduled:number = 0
	
	local nextSchedulee:Schedulee<Cell>?, nextCell:Cell, cost:number, cellBoidCount:number
	while targetCost > job.estimatedCost and boidsRemaining - boidsScheduled > 0 do
		nextSchedulee = Schedulers.getNextSchedulee(scheduler, currentTick)
		if not nextSchedulee then
			break
		end

		nextCell = nextSchedulee.entity
		cost = computeCellCost(nextCell)
		if cost + job.estimatedCost > targetCost and job.cellCount > 0 then
			Schedulers.enqueueSchedulee(scheduler, nextSchedulee)
			break
		end

		cellBoidCount = nextCell.boidCount

		job.estimatedCost += cost
		boidsScheduled += cellBoidCount

		job.jobCells[nextCell.id] = {
			id = nextCell.id,
			origin = nextCell.origin,
			
			networkTick = nextCell.networkTick,
			networkInterval = nextCell.networkInterval,
			
			pages = nextCell.pages,
			pageCount = nextCell.pages.pageCount,
			boidCount = cellBoidCount,
		}

		Schedulers.scheduleSchedulee(nextSchedulee)
		BoidStorage.markPagesPending(nextCell.pages)

		job.cellCount += 1
	end

	return job, boidsScheduled
end

local MIN_JOB_WORK = 8
local MAX_JOB_WORK = 200
const DEFAULT_MS_PER_WORK_UNIT = 0.05

local testParts:{[number]:BasePart} = {}
local neighborIterationsStats = Benchmarkers.newBenchmarker(1000)

local function handleJobResults(groupSchedulee:Schedulee<Group>, actor:ActorState, job:Job, jobResults:Job, returnedCells:{[number]:boolean})
	if not groupsScheduler.schedulees[groupSchedulee.entity.id] then
		warn("running job returned for nonexistant group")
		return
	end
	
	local completionTime:number = jobResults.completionTime
	local measuredMs:number = (completionTime - job.startTime) * 1000
	local measuredMsPerWorkUnit:number = measuredMs / job.estimatedCost

	if measuredMsPerWorkUnit ~= measuredMsPerWorkUnit or measuredMsPerWorkUnit <= 0 then
		measuredMsPerWorkUnit = actor.avgMsPerWorkUnit
		if measuredMsPerWorkUnit <= 0 then
			measuredMsPerWorkUnit = DEFAULT_MS_PER_WORK_UNIT
		end
	end
 
	actor.avgMsPerWorkUnit = actor.avgMsPerWorkUnit * 0.8 + measuredMsPerWorkUnit * 0.2
	actor.targetJobWork = math.clamp(
		TARGET_ACTOR_JOB_MS / actor.avgMsPerWorkUnit,
		MIN_JOB_WORK,
		MAX_JOB_WORK
	)
	
	local group:Group = groupSchedulee.entity
	
	Benchmarkers.push(group.benchmarker, measuredMs)
	Benchmarkers.push(neighborIterationsStats, jobResults.neighborIterations)
	
	if jobResults.snapshotPackets then
		for _, packet in jobResults.snapshotPackets do
			boidJobUpdate:FireAllClients(packet, jobResults.completionTime)
		end
	end
	
	local function updateDebugBoid(boidId: number, worldPosition: Vector3, velocity: Vector3)
		local boid = testParts[boidId]

		if not boid then
			local rng: Random = Random.new(group.id)
			
			boid = Instance.new("Part")
			boid.Anchored = true
			boid.CanCollide = false
			boid.CanQuery = false
			boid.CanTouch = false
			boid.Size = Vector3.new(1, 1, 3)
			boid.Parent = workspace
			boid.Color = Color3.new((rng:NextNumber() + 0.5) / 2, (rng:NextNumber() + 0.5) / 2, (rng:NextNumber() + 0.5) / 2)
			testParts[boidId] = boid
		end

		local dir = velocity.Magnitude > 0.001 and velocity.Unit or Vector3.zAxis
		boid.CFrame = CFrame.lookAt(worldPosition, worldPosition + dir)
	end
	
	local cell:Cell
	for _, jobCell:JobCell in jobResults.jobCells do
		returnedCells[jobCell.id] = true
		cell = group.activeCells[jobCell.id]
		if not cell then
			warn(`Returned cell {jobCell.id} no longer exists`)
			continue
		end
				
		local originalJobCell:JobCell? = job.jobCells[jobCell.id]
		if originalJobCell then
			cell.boidCount = cell.boidCount - originalJobCell.boidCount + jobCell.boidCount
		else
			cell.boidCount = jobCell.boidCount
		end
		
		BoidStorage.overwriteWithJobResults(cell.pages, jobCell.pages, jobCell.pageCount)
		
		if cell.boidCount <= 0 then
			if cell.visualizer then
				cell.visualizer:Destroy()
			end
			group.activeCells[cell.id] = nil
			group.cellCount -= 1
			group.scheduler.schedulees[cell.id] = nil
			BoidStorage.deletePagedBuffer(cell.pages.id)
			
			continue
		end
		
		cell.networkTick += 1
		
		-- for debugging
		--for _, page in jobCell.pages.pages do
		--	local data: buffer = page.data
			
		--	local bitIndex:number, boidIndex:number
		--	for baseSlot:number, liveMask:number in BoidStorage.liveWords(page) :: ()->(number, number) do
		--		while liveMask ~= 0 do
		--			bitIndex = bit32.countrz(liveMask)
		--			boidIndex = baseSlot + bitIndex
		--			liveMask = bit32.band(liveMask, liveMask - 1)
					
		--			local boidId = BoidStorage.readBoidId(data, boidIndex)
		--			updateDebugBoid(
		--				boidId, 
		--				Vector3.new(BoidStorage.readPosition(data, boidIndex)) + cell.origin, 
		--				Vector3.new(BoidStorage.readVelocity(data, boidIndex))
		--			)
		--		end
		--	end
		--end
	end
	
	local id:number, position:Vector3, velocity:Vector3
	for dstCellId: number, movedBoids: {number | Vector3} in jobResults.movedBoids do
		for i = 1, #movedBoids, 3 do
			id = movedBoids[i] :: number
			position = movedBoids[i + 1] :: Vector3
			velocity = movedBoids[i + 2] :: Vector3

			addBoidToCell(group, dstCellId, position, velocity, id, completionTime)
			--updateDebugBoid(id, position, velocity)
		end
	end
end

-- if tables of data are passed instead of compressing to buffers, no extra processing would be required. Maybe faster, test
local function runJob(groupSchedulee:Schedulee<Group>, actor:ActorState, job:Job)
	local group:Group = groupSchedulee.entity
	local scheduler:Scheduler<Cell> = group.scheduler
	local actorInstance:Actor = actor.instance.Parent :: Actor
	
	local bindableEvent:BindableEvent = Instance.new("BindableEvent")
	
	actor.ready = false
	
	local returned:boolean = false
	local function releaseOriginalCells()
		for cellId: number, _ in job.jobCells do
			local schedulee = scheduler.schedulees[cellId]
			if schedulee then
				Schedulers.releaseSchedulee(scheduler, schedulee)
			end
		end
	end
	
	actorInstance:SendMessage("NewJob", job, bindableEvent)
	bindableEvent.Event:Once(function(jobResults: Job)
		if returned then
			return
		end
		returned = true
		
		actor.ready = true
		bindableEvent:Destroy()

		local returnedCells:{[number]:boolean} = {}
		local completionTime:number = jobResults.completionTime

		local ok, err = pcall(function()
			handleJobResults(groupSchedulee, actor, job, jobResults, returnedCells)
		end)

		if not ok then
			warn(`handleJobResults error for job {job.id}: {err}`)
		end

		local schedulee:Schedulee<Cell>?
		local interval:number
		for cellId:number, _ in job.jobCells do
			schedulee = scheduler.schedulees[cellId]
			if not schedulee then
				continue
			end

			if returnedCells[cellId] then
				Schedulers.markScheduleeCompleted(scheduler, schedulee, completionTime)
			else
				warn(`Job {job.id} returned but omitted scheduled cell {cellId}`)
				
				Schedulers.releaseSchedulee(scheduler, schedulee)
			end
		end
	end)
	
	task.delay(5, function()
		if returned then
			return
		end

		returned = true
		actor.ready = true
		bindableEvent:Destroy()

		warn(`Job {job.id} never returned; releasing {job.cellCount} cells`)
		releaseOriginalCells()
	end)
end

local function getNextGroupWithWork(now: number): Schedulee<Group>?
	local bestGroupSchedulee: Schedulee<Group>? = nil
	local bestWakeTime = math.huge
	
	local group:Group, wakeTime:number?
	for _, groupSchedulee: Schedulee<Group> in groupsScheduler.schedulees do
		group = groupSchedulee.entity
		if group.cellCount <= 0 then
			continue
		end

		wakeTime = Schedulers.peekNextWakeTime(group.scheduler)
		if not wakeTime then
			continue
		end

		if wakeTime <= now and wakeTime < bestWakeTime then
			bestWakeTime = wakeTime
			bestGroupSchedulee = groupSchedulee
		end
	end

	return bestGroupSchedulee
end

local function assignWorkForFrame(currentTick: number)
	--local frameBudgetRemaining = MAX_FRAME_COST
	local frameBudgetRemaining = 1000000
	local boidBudgetRemaining = MAX_BOIDS_PER_FRAME
	
	local groupSchedulee:Schedulee<Group>?
	for _, actor: ActorState in ActorsInitializer.actors do
		if frameBudgetRemaining <= 0 or boidBudgetRemaining <= 0 then
			break
		end

		if not actor.ready then
			continue
		end
		
		local actorBudget = math.min(actor.targetJobWork, frameBudgetRemaining)
		
		local attempts:number = 0
		local maxGroupAttempts:number = 8
		
		while attempts < maxGroupAttempts do
			attempts += 1
			
			groupSchedulee = getNextGroupWithWork(currentTick)
			if not groupSchedulee then
				break
			end

			local job, boidsScheduled = buildJob(
				groupSchedulee.entity,
				currentTick,
				actorBudget,
				boidBudgetRemaining
			)

			if job.estimatedCost > 0 and boidsScheduled > 0 then
				boidBudgetRemaining -= boidsScheduled
				frameBudgetRemaining -= job.estimatedCost
				runJob(groupSchedulee, actor, job)
				
				Schedulers.markScheduleeCompleted(groupsScheduler, groupSchedulee, workspace:GetServerTimeNow())
				break
			end

			warn(`Group {groupSchedulee.entity.id} selected but built no job`)
			
			Schedulers.releaseSchedulee(groupsScheduler, groupSchedulee)
		end
	end
end

local lastCleanup:number = os.clock()
local cleanupInterval = 30
-- uses heuristic to determine when to clean up invalid group scheduler's heap nodes due to lazy invalidation
local function cleanupGroupHeaps()
	lastCleanup = os.clock()
	
	local group:Group
	for _, groupSchedulee:Schedulee<Group> in groupsScheduler.schedulees do
		group = groupSchedulee.entity
		if BinaryHeaps.size(group.scheduler.heap) > group.cellCount * 4 + 64 then
			Schedulers.rebuildSchedulerHeap(group.scheduler)
		end
	end
end

game:GetService("RunService").Heartbeat:Connect(function(dt)
	local currentTick:number = workspace:GetServerTimeNow()
	
	if os.clock() - lastCleanup > cleanupInterval then
		cleanupGroupHeaps()
	end
	
	assignWorkForFrame(currentTick)
end)

local function printStats()
	print(`NEIGHBOR ITERATIONS PER JOB:`)
	Benchmarkers.printStats(neighborIterationsStats)
end

task.spawn(function()
	while task.wait(5) do
		printStats()
	end
end)

--local debugAccum = 0

--game:GetService("RunService").Heartbeat:Connect(function(dt)
--	debugAccum += dt
--	if debugAccum < 1 then
--		return
--	end
--	debugAccum = 0

--	local maxCellBoids = 0
--	local scheduledCells = 0
--	local validCells = 0
--	local totalCells = 0
--	local readyActors = 0
--	local staleCells = 0

--	for _, actor in ActorsInitializer.actors do
--		if actor.ready then
--			readyActors += 1
--		end
--	end
	
--	local now:number = workspace:GetServerTimeNow()
	
--	local oldestCellAge:number = 0
--	local oldestCellId:number = 0
--	for _, groupSchedulee in groupsScheduler.schedulees do
--		for _, cellSchedulee in groupSchedulee.entity.scheduler.schedulees do
--			local cell = cellSchedulee.entity
--			totalCells += 1
--			maxCellBoids = math.max(maxCellBoids, cell.boidCount)

--			if cellSchedulee.alreadyScheduled then
--				scheduledCells += 1
--			end

--			if cellValidator(cellSchedulee) then
--				validCells += 1
--			end
			
--			local age = now - cellSchedulee.lastUpdated
--			if age > oldestCellAge then
--				oldestCellAge = age
--				oldestCellId = cell.id
--			end
			
--			if age > 2 then
--				staleCells += 1
--			end
--		end
--	end
	
--	warn(`cells total={totalCells}, valid={validCells}, scheduled={scheduledCells}, readyActors={readyActors}, oldestAge={oldestCellAge}, staleCells={staleCells}`)
--	for i, actor in ActorsInitializer.actors do
--		print(`actor {i}: ready={actor.ready}, avgMs={actor.avgMsPerWorkUnit}, targetWork={actor.targetJobWork}`)
--	end
--end)

return module
