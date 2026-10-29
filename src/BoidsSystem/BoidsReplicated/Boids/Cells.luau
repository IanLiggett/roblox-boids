--!strict
-- Coordinator-owned cell creation, insertion and removal. Packed storage remains separate.
local BoidsReplicated = script.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local LODConfig = require(BoidsReplicated.LODConfig)
local DebugPresentation = require(BoidsReplicated.DebugPresentation)
local Schedulers = require(script.Parent.Scheduler)
local Cells = {}
type Group = SharedTypes.Group
type Cell = SharedTypes.Cell
type Schedulee<T> = SharedTypes.Schedulee<T>
local DEFAULT_CELL_UPDATE_INTERVAL = 1
local STALENESS_MULTIPLIER = 1.5

local function computeCellWakeTime(schedulee: Schedulee<Cell>): number
	const effectiveInterval = Schedulers.EffectiveInterval(schedulee)
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

local function newCell(group:Group, origin:Vector3, cellId:number?):Cell
	cellId = cellId or Quantization.GetNumericalKey(origin.X, origin.Y, origin.Z)
	local cell:Cell = {
		id = cellId,
		groupId = group.id,
		origin = origin,
		boidCount = 0,

		pages = BoidStorage.NewPagedBuffer(),

	} :: Cell
	DebugPresentation.CellCreated(group.lifetime, cellId, origin)
	group.activeCells[cellId] = cell
	group.cellCount += 1
	
	--print(`CELLS: {group.cellCount}`)
	
	const now: number = workspace:GetServerTimeNow()
	
	const schedulee:Schedulee<Cell> = Schedulers.NewSchedulee(group.scheduler, cell, DEFAULT_CELL_UPDATE_INTERVAL)
	local simulationConfig = LODConfig.GetSimulationConfig(LODConfig.GetSimulationKindForGroup(group.id))
	Schedulers.SetIntervalMultiplierSoft(schedulee, simulationConfig.backgroundIntervalMultiplier, now)
	

	return cell
end

local function addBoidToCell(
	group: Group,
	cellId: number,
	position: Vector3,
	velocity: Vector3,
	boidId: number,
	currentTick: number,
	pathNode: number?,
	pathVersion: number?,
	obstacleDirectionCode: number?
)
	local cell: Cell = group.activeCells[cellId]
	if not cell then
		local origin = Vector3.new(Quantization.ConvertCoordsToGrid(position.X, position.Y, position.Z))
		cell = newCell(group, origin, cellId)
	end

	local localPosition = position - cell.origin

	BoidStorage.InsertBoid(
		cell.pages,
		localPosition.X,
		localPosition.Y,
		localPosition.Z,
		velocity.X,
		velocity.Y,
		velocity.Z,
		Quantization.CurrentSimTick(),
		boidId,
		cell.id,
		pathNode,
		pathVersion,
		obstacleDirectionCode
	)

	local wasEmpty:boolean = cell.boidCount <= 0
	cell.boidCount += 1

	local schedulee = group.scheduler.schedulees[cellId]
	if schedulee and wasEmpty and not schedulee.alreadyScheduled then
		Schedulers.EnqueueSchedulee(group.scheduler, schedulee)
	end
end

function Cells.Remove(group: Group, cell: Cell): ()
 assert(group.activeCells[cell.id] == cell, "Cannot remove a replaced cell")
 DebugPresentation.CellRemoved(group.lifetime, cell.id)
 group.activeCells[cell.id] = nil
 group.cellCount -= 1
 group.scheduler.schedulees[cell.id] = nil
 BoidStorage.DeletePagedBuffer(cell.pages.id)
end
Cells.Create = newCell
Cells.AddBoid = addBoidToCell
Cells.WakeTime = computeCellWakeTime
Cells.IsDue = cellValidator
return Cells
