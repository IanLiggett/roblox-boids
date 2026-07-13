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
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)

local Schedulers = require(script.Scheduler)
local BoidUpdates = require(script.BoidBatches)

local Dependencies = BoidsReplicated.Dependencies
local Benchmarkers = require(Dependencies.Benchmarker.Value)

local BoidModels = SharedTypes.BoidModels
type BoidModel = SharedTypes.BoidModel

type Page = BoidStorage.Page
type PagedBuffer = BoidStorage.PagedBuffer

type HeapNode<T> = Schedulers.HeapNode
type Scheduler<T> = Schedulers.Scheduler<T>
type Schedulee<T> = Schedulers.Schedulee<T>

type Benchmarker = Benchmarkers.Benchmarker

type BoidsStatsBatch = BoidUpdates.BoidsStatsBatch

type Target = SharedTypes.Target

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

export type Cell = {
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
local STALENESS_MULTIPLIER:number = 1.5

local DESIRED_MAX_BOIDS = 40000
local MAX_BOIDS_PER_FRAME:number = (DESIRED_MAX_BOIDS / DEFAULT_CELL_UPDATE_INTERVAL) // 60
module.MAX_BOIDS_PER_FRAME = MAX_BOIDS_PER_FRAME

local ACTORS_COUNT = 8

local U8_SIZE = 1
local U16_SIZE = 2
local U32_SIZE = 4

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
	const effectiveInterval = Schedulers.effectiveInterval(schedulee)
	return math.min(
		schedulee.nextDue,
		schedulee.lastUpdated + effectiveInterval * STALENESS_MULTIPLIER
	)
end

local function cellValidator(schedulee: Schedulee<Cell>, now: number): boolean
	return not schedulee.alreadyScheduled
		and schedulee.entity.boidCount > 0
		and now >= computeCellWakeTime(schedulee)
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
module.groupsScheduler = groupsScheduler

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
		networkInterval = 4,

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
	local cell: Cell = group.activeCells[cellId]
	if not cell then
		local origin = Vector3.new(Quantization.convertCoordsToGrid(position.X, position.Y, position.Z))
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
module.addBoidToCell = addBoidToCell

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

return module
