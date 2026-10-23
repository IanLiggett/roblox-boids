--!strict

--[[ BoidsRenderer
Description:
	Client-side boid renderer. Receives spawn batches and unreliable simulation
	snapshots, instantiates boid models, smooths/extrapolates render state, and
	applies visible boid CFrames through per-boid Motor6D transforms.

Runtime API:
	Start(): (): creates the root and installs selected callbacks once
	receiveNewBoidBatch(networkBoidsBatch: NetworkBoidsBatch): creates render models
	receiveDeleteBoidBatch(packet: buffer): removes rendered boids
	receiveDeleteGroup(groupId: number): removes rendered group state

The shared local simulation calls these methods directly. No BindableEvent transport is
used, so buffer/table payloads are not deep-copied before rendering.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Camera: Camera = workspace.CurrentCamera :: Camera

-- The type anchor remains in the edit-time hierarchy; bootstrap relocates the same package.
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local PacketCodec = require(BoidsReplicated.NetworkResults.PacketCodec)
local LODConfig = require(BoidsReplicated.LODConfig)
local BoidCollisionConfig = require(BoidsReplicated.BoidCollisionConfig)
local BoidQueryIndex = require(BoidsReplicated.BoidQueryIndex)
local QueryIndexConfig = require(BoidsReplicated.QueryIndexConfig)

local Measurements = require(script.Measurements)
local BoidsRenderer = {}
local isStarted = false
local onViewingCamera: ((CFrame, number) -> ())? = nil


type BoidModel = SharedTypes.BoidModel
type BoidModelName = SharedTypes.BoidModelName
type NetworkBoidsBatch = SharedTypes.NetworkBoidsBatch

local BoidFolder: Folder
local BoidRoot: Part
local function createRenderRoot(): ()
	BoidFolder = Instance.new("Folder")
	BoidFolder.Name = "BoidFolder"
	BoidFolder.Parent = workspace
	
	-- A fixed identity-space anchor lets every boid use its world render CFrame as
	-- a Motor6D Transform without moving the root itself.
	BoidRoot = Instance.new("Part")
	BoidRoot.Name = "BoidRoot"
	BoidRoot.Anchored = true
	BoidRoot.CanCollide = false
	BoidRoot.CanTouch = false
	BoidRoot.CanQuery = false
	BoidRoot.Transparency = 1
	BoidRoot.Size = Vector3.one
	BoidRoot.CFrame = CFrame.identity
	BoidRoot.Parent = BoidFolder
end

local BoidModelsStorage = script.Parent.BoidModels

local boidsByGroup = {}
local groupFolders:{[number]: Folder} = {}
local groupIdByBoid: {[number]: number} = {}
local spawnLifetimes: {[number]: number} = {}
local retiredLifetimes: {[number]: number} = {}

local renderMotors: {Motor6D} = {}
local renderTransforms: {CFrame} = {}

local renderIndexByBoid: {[number]: number} = {}
local boidIdByRenderIndex: {number} = {}

local boidModelById: {[number]: number} = {}
local groupColors = {}
local renderedCountByGroup: {[number]: number} = {}
local clientQueryIndexEnabled = false
local clientQueryIndex: BoidQueryIndex.Index? = nil
local clientQueryIndexNeedsSeed = false
local seedClientQueryIndex: (() -> ())? = nil

local function getClientQueryIndex(): BoidQueryIndex.Index?
	if not clientQueryIndexEnabled then
		return nil
	end
	if not clientQueryIndex then
		clientQueryIndex = BoidQueryIndex.new()
		clientQueryIndexNeedsSeed = true
	end
	if clientQueryIndexNeedsSeed and seedClientQueryIndex then
		clientQueryIndexNeedsSeed = false
		seedClientQueryIndex()
	end
	return clientQueryIndex
end

local latestAtByIndex: {number} = {}
local latestPositionByIndex: {Vector3} = {}
local latestVelocityByIndex: {Vector3} = {}
local renderPositionByIndex: {Vector3} = {}
local renderVelocityByIndex: {Vector3} = {}
local nextRenderTimeByIndex: {number} = {}
local lastNetworkIntervalByIndex: {number} = {}
local facingByIndex: {Vector3} = {}
local hasLatestByIndex: {boolean} = {}
local hasRenderByIndex: {boolean} = {}

type RenderCell = {
	key: number,
	origin: Vector3,
	renderIndices: {number},
	slotByRenderIndex: {[number]: number},
	nextDueTime: number,
	scheduledInterval: number,
	resumeSlot: number,
	deferredSince: number?,
	agingIndex: number?,
}

type RenderCellByKey = {[number]: RenderCell}
type RenderCellIndexByKey = {[number]: number}
type RenderCellKeyByBoid = {[number]: number}
type RenderCellSet = {[number]: boolean}

local renderCellsByKey: RenderCellByKey = {}
local activeRenderCells: {RenderCell} = {}
local activeRenderCellIndexByKey: RenderCellIndexByKey = {}
local renderCellKeyByBoid: RenderCellKeyByBoid = {}
local agingRenderCells: {RenderCell} = {}
local nextAgingRenderCellIndex: number = 1

-- Renderer cells intentionally subdivide the unchanged simulation/query cells.
local RENDER_CELL_SIZE: number = 32
local CELL_HALF_SIZE: number = RENDER_CELL_SIZE * 0.5
local CELL_BOUND_RADIUS: number = RENDER_CELL_SIZE * math.sqrt(3) * 0.5
local AGING_THRESHOLD: number = 0.5
-- Aging guarantees eventual distant-cell progress without consuming the near-first budget.
local AGING_BUDGET_RATIO: number = 0.1

local function removeAgingRenderCell(cell: RenderCell): ()
	local agingIndex: number? = cell.agingIndex
	if not agingIndex then
		return
	end

	local lastIndex: number = #agingRenderCells
	local movedCell: RenderCell = agingRenderCells[lastIndex]
	agingRenderCells[agingIndex] = movedCell
	movedCell.agingIndex = agingIndex
	agingRenderCells[lastIndex] = nil
	cell.agingIndex = nil
	if nextAgingRenderCellIndex > #agingRenderCells then
		nextAgingRenderCellIndex = 1
	end
end

local function addAgingRenderCell(cell: RenderCell): ()
	if cell.agingIndex then
		return
	end

	agingRenderCells[#agingRenderCells + 1] = cell
	cell.agingIndex = #agingRenderCells
end

local function removeActiveRenderCell(cell: RenderCell): ()
	removeAgingRenderCell(cell)
	local activeIndex: number? = activeRenderCellIndexByKey[cell.key]
	if not activeIndex then
		return
	end

	local lastIndex: number = #activeRenderCells
	local movedCell: RenderCell = activeRenderCells[lastIndex]
	activeRenderCells[activeIndex] = movedCell
	activeRenderCellIndexByKey[movedCell.key] = activeIndex
	activeRenderCells[lastIndex] = nil
	activeRenderCellIndexByKey[cell.key] = nil
	renderCellsByKey[cell.key] = nil
end

local function removeBoidFromRenderCell(boidId: number): ()
	local cellKey: number? = renderCellKeyByBoid[boidId]
	if not cellKey then
		return
	end

	local cell: RenderCell? = renderCellsByKey[cellKey]
	local renderIndex: number? = renderIndexByBoid[boidId]
	renderCellKeyByBoid[boidId] = nil
	if not cell or not renderIndex then
		return
	end

	local slot: number? = cell.slotByRenderIndex[renderIndex]
	if not slot then
		return
	end

	local lastSlot: number = #cell.renderIndices
	local movedRenderIndex: number = cell.renderIndices[lastSlot]
	cell.renderIndices[slot] = movedRenderIndex
	cell.slotByRenderIndex[movedRenderIndex] = slot
	cell.renderIndices[lastSlot] = nil
	cell.slotByRenderIndex[renderIndex] = nil

	if #cell.renderIndices == 0 then
		removeActiveRenderCell(cell)
	end
end

local function updateRenderCellIndex(boidId: number, previousIndex: number, nextIndex: number): ()
	if previousIndex == nextIndex then
		return
	end

	local cellKey: number? = renderCellKeyByBoid[boidId]
	local cell: RenderCell? = if cellKey then renderCellsByKey[cellKey] else nil
	if not cell then
		return
	end

	local slot: number? = cell.slotByRenderIndex[previousIndex]
	if not slot then
		return
	end

	cell.renderIndices[slot] = nextIndex
	cell.slotByRenderIndex[previousIndex] = nil
	cell.slotByRenderIndex[nextIndex] = slot
end

local function assignBoidToRenderCell(boidId: number, position: Vector3): ()
	local renderIndex: number? = renderIndexByBoid[boidId]
	if not renderIndex then
		return
	end

	local origin: Vector3 = Vector3.new(
		(position.X // RENDER_CELL_SIZE) * RENDER_CELL_SIZE,
		(position.Y // RENDER_CELL_SIZE) * RENDER_CELL_SIZE,
		(position.Z // RENDER_CELL_SIZE) * RENDER_CELL_SIZE
	)
	local cellKey: number = Quantization.GetNumericalKey(origin.X, origin.Y, origin.Z)
	if renderCellKeyByBoid[boidId] == cellKey then
		return
	end

	removeBoidFromRenderCell(boidId)

	local existing: RenderCell? = renderCellsByKey[cellKey]
	local cell: RenderCell = if existing then existing else {
			key = cellKey,
			origin = origin,
			renderIndices = {},
			slotByRenderIndex = {},
			nextDueTime = workspace:GetServerTimeNow(),
			scheduledInterval = 0,
			resumeSlot = 1,
		}
	if not existing then
		renderCellsByKey[cellKey] = cell
		activeRenderCells[#activeRenderCells + 1] = cell
		activeRenderCellIndexByKey[cellKey] = #activeRenderCells
	end

	local slot: number = #cell.renderIndices + 1
	cell.renderIndices[slot] = renderIndex
	cell.slotByRenderIndex[renderIndex] = slot
	renderCellKeyByBoid[boidId] = cellKey
end


local U16_SIZE: number = 2

-- Smooth authoritative corrections over much of a boid's expected update interval.
-- Extrapolation remains capped below, so a stale snapshot cannot make the render
-- state drift without bound.
local POSITION_CORRECTION_HALF_LIFE: number = 0.75
local NETWORK_INTERVAL_CORRECTION_RATIO: number = 0.75
local MAX_POSITION_CORRECTION_HALF_LIFE: number = 6
-- Facing follows the already-smoothed render trajectory, not the new snapshot velocity.
local ORIENTATION_CORRECTION_HALF_LIFE: number = 0.1 --1
local SNAP_DISTANCE: number = 0.05
local SNAP_DISTANCE_SQUARED: number = SNAP_DISTANCE * SNAP_DISTANCE
local MAX_EXTRAPOLATION: number = 24

local clientLOD = LODConfig.GetActive().client

local function exponentialDecayAlpha(dt: number, halfLife: number): number
	if halfLife <= 0 then
		return 0
	end

	return 0.5 ^ (dt / halfLife)
end

local function initRenderState(index: number, now: number): ()
	latestAtByIndex[index] = 0
	latestPositionByIndex[index] = Vector3.zero
	latestVelocityByIndex[index] = Vector3.zero
	renderPositionByIndex[index] = Vector3.zero
	renderVelocityByIndex[index] = Vector3.zero
	nextRenderTimeByIndex[index] = now
	lastNetworkIntervalByIndex[index] = 0
	facingByIndex[index] = Vector3.zero
	hasLatestByIndex[index] = false
	hasRenderByIndex[index] = false
end

type CompiledRenderBand = {
	range: number,
	interval: number,
}

type DueRenderCell = {
	cell: RenderCell,
	distance: number,
}

type FrameRenderWork = {
	budget: number,
	attempted: number,
	dirtyTransformCount: number,
	scheduledCellCount: number,
	scheduledCells: RenderCellSet,
}

local compiledClientConfig: LODConfig.ClientConfig? = nil
local compiledRenderBands: {CompiledRenderBand} = {}
local compiledOffscreenInterval: number = 0
local compiledPeripheralLodDistanceScale: number = 0

local function refreshCompiledRenderSchedule(clientConfig: LODConfig.ClientConfig): boolean
	if compiledClientConfig == clientConfig then
		return false
	end

	compiledClientConfig = clientConfig
	compiledRenderBands = table.create(#clientConfig.visibleRenderBands) :: {CompiledRenderBand}
	for index, band: LODConfig.RenderBand in clientConfig.visibleRenderBands do
		compiledRenderBands[index] = {
			range = band.range,
			interval = 1 / band.hertz,
		}
	end
	compiledOffscreenInterval = 1 / clientConfig.offscreenHertz
	compiledPeripheralLodDistanceScale = clientConfig.peripheralLodDistanceScale
	return true
end

local function getCellCenterDistance(cell: RenderCell): number
	local cellCenter: Vector3 = cell.origin + Vector3.one * CELL_HALF_SIZE
	return (cellCenter - Camera.CFrame.Position).Magnitude
end

local function getCellRenderInterval(cell: RenderCell): number
	local cellCenter: Vector3 = cell.origin + Vector3.one * CELL_HALF_SIZE
	local cameraToCell: Vector3 = cellCenter - Camera.CFrame.Position
	local centerDistance: number = cameraToCell.Magnitude
	local lookDirection: Vector3 = Camera.CFrame.LookVector
	local forwardDot: number = cameraToCell:Dot(lookDirection)
	local coneCosine: number = math.cos(math.rad(Camera.FieldOfView * 0.5))

	local visible: boolean = centerDistance <= CELL_BOUND_RADIUS
	if not visible then
		local viewThreshold: number = centerDistance * coneCosine - CELL_BOUND_RADIUS
		visible = forwardDot >= viewThreshold
	end
	if not visible then
		return compiledOffscreenInterval
	end

	local nearestDistance: number = math.max(0, centerDistance - CELL_BOUND_RADIUS)
	local forwardCosine: number = if centerDistance > 0 then forwardDot / centerDistance else 1
	local edgeProgress: number = math.clamp((1 - forwardCosine) / math.max(0.0001, 1 - coneCosine), 0, 1)
	local rampInput: number = math.clamp((edgeProgress - 0.75) / 0.25, 0, 1)
	local edgeRamp: number = rampInput * rampInput * (3 - 2 * rampInput)
	local effectiveDistance: number = nearestDistance * (1 + compiledPeripheralLodDistanceScale * edgeRamp)

	local low: number = 1
	local high: number = #compiledRenderBands
	local selected: number = high
	while low <= high do
		local middle: number = math.floor((low + high) * 0.5)
		if effectiveDistance <= compiledRenderBands[middle].range then
			selected = middle
			high = middle - 1
		else
			low = middle + 1
		end
	end
	return compiledRenderBands[selected].interval
end
local function renderBoid(index: number, now: number, queryIndex: BoidQueryIndex.Index?): boolean
	if not hasLatestByIndex[index] then
		return false
	end

	local nextRenderTime: number = nextRenderTimeByIndex[index]
	local dt: number = math.min(math.max(0, now - nextRenderTime), MAX_EXTRAPOLATION)
	nextRenderTimeByIndex[index] = now

	local latestPosition: Vector3 = latestPositionByIndex[index]
	local latestVelocity: Vector3 = latestVelocityByIndex[index]
	local renderPosition: Vector3
	local facing: Vector3
	if hasRenderByIndex[index] then
		renderPosition = renderPositionByIndex[index]
		facing = facingByIndex[index]
	else
		renderPosition = latestPosition
		facing = latestVelocity
	end

	local snapshotAge: number = math.clamp(now - latestAtByIndex[index], 0, MAX_EXTRAPOLATION)
	local predictedPosition: Vector3 = latestPosition + latestVelocity * snapshotAge
	local previousRenderPosition: Vector3 = renderPosition

	local visualError: Vector3 = previousRenderPosition - predictedPosition
	local lastNetworkInterval: number = lastNetworkIntervalByIndex[index]
	local correctionHalfLife: number = if lastNetworkInterval > 0 then math.clamp(lastNetworkInterval * NETWORK_INTERVAL_CORRECTION_RATIO, POSITION_CORRECTION_HALF_LIFE, MAX_POSITION_CORRECTION_HALF_LIFE) else POSITION_CORRECTION_HALF_LIFE
	local keepError: number = exponentialDecayAlpha(dt, correctionHalfLife)
	visualError *= keepError
	if visualError:Dot(visualError) <= SNAP_DISTANCE_SQUARED then
		visualError = Vector3.zero
	end

	renderPosition = predictedPosition + visualError
	local desiredMove: Vector3 = renderPosition - previousRenderPosition
	local targetLook: Vector3 = if desiredMove.Magnitude > 0.001 then desiredMove.Unit else facing

	local facingKeep: number = exponentialDecayAlpha(dt, ORIENTATION_CORRECTION_HALF_LIFE)
	facing = facing * facingKeep + targetLook * (1 - facingKeep)
	facing = if facing.Magnitude > 0.001 then facing.Unit else Vector3.zAxis

	local desiredSpeed: number = if dt > 0 then math.max(0, desiredMove:Dot(facing) / dt) else 0
	local renderVelocity: Vector3 = facing * desiredSpeed
	renderPosition = previousRenderPosition + renderVelocity * dt

	renderPositionByIndex[index] = renderPosition
	renderVelocityByIndex[index] = renderVelocity
	facingByIndex[index] = facing
	hasRenderByIndex[index] = true

	if queryIndex then
		local boidId = boidIdByRenderIndex[index]
		local model = boidId and boidModelById[boidId]
		if model then
			queryIndex:Update(boidId, renderPosition, BoidCollisionConfig.GetRadius(model))
		end
	end
	renderTransforms[index] = CFrame.lookAt(renderPosition, renderPosition + facing)
	return true
end

local dirtyRenderIndices: {number} = {}

local function completeRenderCell(cell: RenderCell, now: number): ()
	cell.resumeSlot = 1
	cell.deferredSince = nil
	removeAgingRenderCell(cell)
	cell.scheduledInterval = getCellRenderInterval(cell)
	cell.nextDueTime = now + cell.scheduledInterval
end

local function renderCell(cell: RenderCell, now: number, queryIndex: BoidQueryIndex.Index?, maxBoids: number, work: FrameRenderWork): ()
	if not work.scheduledCells[cell.key] then
		work.scheduledCells[cell.key] = true
		work.scheduledCellCount += 1
	end

	local renderedInCell: number = 0
	local slot: number = cell.resumeSlot
	while slot <= #cell.renderIndices and work.attempted < work.budget and renderedInCell < maxBoids do
		local renderIndex: number = cell.renderIndices[slot]
		cell.resumeSlot = slot + 1
		work.attempted += 1
		renderedInCell += 1
		if renderBoid(renderIndex, now, queryIndex) then
			work.dirtyTransformCount += 1
			dirtyRenderIndices[work.dirtyTransformCount] = renderIndex
		end
		slot += 1
	end

	if cell.resumeSlot > #cell.renderIndices then
		completeRenderCell(cell, now)
	elseif not cell.deferredSince then
		cell.deferredSince = now
	end
end

local function onRenderStepped(frameDt: number): ()
	local currentCamera = workspace.CurrentCamera
	if not currentCamera then
		return
	end
	Camera = currentCamera
	local measurementsEnabled = Measurements.IsEnabled()
	local measurementStart: number = if measurementsEnabled then os.clock() else 0
	debug.profilebegin("BoidsRendererMotor6D")
	clientLOD = LODConfig.GetActive().client
	local now: number = workspace:GetServerTimeNow()
	if onViewingCamera then onViewingCamera(Camera.CFrame, now) end
	local scheduleChanged: boolean = refreshCompiledRenderSchedule(clientLOD)
	if scheduleChanged then
		for _, cell: RenderCell in activeRenderCells do
			cell.nextDueTime = math.min(cell.nextDueTime, now)
		end
	end
	local queryIndex = getClientQueryIndex()


	local work: FrameRenderWork = {
		budget = clientLOD.maxRenderBoidsPerFrame,
		attempted = 0,
		dirtyTransformCount = 0,
		scheduledCellCount = 0,
		scheduledCells = {},
	}

	-- Due cells enter the aging queue even if the cap prevents their first boid.
	-- That makes the 0.5 second starvation bound apply to distant cells as well as
	-- dense cells that are being resumed across frames.
	for _, cell: RenderCell in activeRenderCells do
		if cell.resumeSlot == 1 and cell.scheduledInterval > 0 then
			local desiredInterval: number = getCellRenderInterval(cell)
			if desiredInterval < cell.scheduledInterval then
				cell.nextDueTime = now
			end
		end
		if cell.resumeSlot > 1 or cell.nextDueTime <= now then
			local deferredSince: number = cell.deferredSince or now
			if not cell.deferredSince then cell.deferredSince = deferredSince end
			if now - deferredSince >= AGING_THRESHOLD then
				addAgingRenderCell(cell)
			end
		end
	end
	-- Aged cells receive a bounded round-robin slice before normal near-first work.
	-- The reserve prevents a backlog of distant cells from consuming the cadence budget
	-- promised to nearby bands, while every aged cell still advances without starvation.
	local agingBudget: number = math.max(1, math.floor(work.budget * AGING_BUDGET_RATIO))
	local agingDeadline: number = math.min(work.budget, work.attempted + agingBudget)
	while work.attempted < agingDeadline and #agingRenderCells > 0 do
		if nextAgingRenderCellIndex > #agingRenderCells then
			nextAgingRenderCellIndex = 1
		end
		local cell: RenderCell = agingRenderCells[nextAgingRenderCellIndex]
		nextAgingRenderCellIndex += 1
		renderCell(cell, now, queryIndex, 1, work)
	end

	local dueCells: {DueRenderCell} = {}
	for _, cell: RenderCell in activeRenderCells do
		if cell.resumeSlot > 1 or cell.nextDueTime <= now then
			dueCells[#dueCells + 1] = {
			cell = cell,
			distance = getCellCenterDistance(cell),
		}
		end
	end
	table.sort(dueCells, function(left: DueRenderCell, right: DueRenderCell): boolean
		return left.distance < right.distance
	end)

	for _, due: DueRenderCell in dueCells do
		if work.attempted >= work.budget then
			break
		end
		renderCell(due.cell, now, queryIndex, math.huge, work)
	end

	for dirtyIndex = 1, work.dirtyTransformCount do
		local renderIndex: number = dirtyRenderIndices[dirtyIndex]
		renderMotors[renderIndex].Transform = renderTransforms[renderIndex]
		dirtyRenderIndices[dirtyIndex] = nil
	end

	if measurementsEnabled then
		Measurements.Record((os.clock() - measurementStart) * 1000, frameDt, #activeRenderCells, work.scheduledCellCount, work.attempted, work.dirtyTransformCount, work.budget, #agingRenderCells)
	end
	debug.profileend()
end

local function pushSnapshot(boidId: number, serverTime: number, position: Vector3, velocity: Vector3): ()
	local index: number? = renderIndexByBoid[boidId]
	if not index then
		return
	end

	local latestTime: number = latestAtByIndex[index]
	if hasLatestByIndex[index] then
		if serverTime <= latestTime then
			return
		end

		lastNetworkIntervalByIndex[index] = serverTime - latestTime
	end

	latestAtByIndex[index] = serverTime
	latestPositionByIndex[index] = position
	latestVelocityByIndex[index] = velocity
	hasLatestByIndex[index] = true
end

local lastSnapshotTimeByBoid:{[number]: number} = {}

local function acceptSnapshotRow(boidId: number, completionTime: number, px: number, py: number, pz: number, vx: number, vy: number, vz: number): ()
	-- Pre-spawn or retired rows must not seed deduplication for a later lifetime.
	if not renderIndexByBoid[boidId] then return end
	local lastTime = lastSnapshotTimeByBoid[boidId]
	if lastTime and completionTime <= lastTime then
		return
	end
	lastSnapshotTimeByBoid[boidId] = completionTime
	local position = Vector3.new(px, py, pz)
	assignBoidToRenderCell(boidId, position)
	pushSnapshot(boidId, completionTime, position, Vector3.new(vx, vy, vz))
end

local function consumeCellSnapshot(origin: Vector3, networkBoids: buffer, boidCount: number, completionTime: number): ()
	if boidCount <= 0 or buffer.len(networkBoids) < boidCount * PacketCodec.BOID_ROW_BYTES then return end
	for boidId: number, px: number, py: number, pz: number, vx: number, vy: number, vz: number in PacketCodec.ForEachBoid(networkBoids, 0, boidCount) do
		acceptSnapshotRow(boidId, completionTime, origin.X + px, origin.Y + py, origin.Z + pz, vx, vy, vz)
	end
end

-- Server corrections are consumed only by the replicated simulation as steering targets.

local nextRenderPartIndex = 1

local function registerBoid(boidId: number, boid: Model | BasePart, now: number): ()
	local part: BasePart

	if boid:IsA("Model") then
		part = boid.PrimaryPart :: BasePart
	else
		part = boid
	end
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	-- Rendered boids are permanently excluded from Roblox world queries. Dense physics
	-- query broad-phase work remains costly even for an Include-filtered ground ray.
	part.CanQuery = false

	local motor = Instance.new("Motor6D")
	motor.Name = "BoidMotor"
	motor.Part0 = BoidRoot
	motor.Part1 = part
	motor.Parent = BoidRoot

	local index:number = nextRenderPartIndex
	renderMotors[index] = motor
	renderTransforms[index] = part.CFrame

	--lastSnapshotTimeByBoid[boidId] = now
	renderIndexByBoid[boidId] = index
	boidIdByRenderIndex[index] = boidId
	initRenderState(index, now)
	--print(`Boid registered at time {now}`)

	nextRenderPartIndex += 1
	-- An index created by an early snapshot may have seeded before this spawn
	-- batch. The next query reseeds once from current Motor6D render poses.
	if clientQueryIndex then
		clientQueryIndexNeedsSeed = true
	end
end

seedClientQueryIndex = function(): ()
	local queryIndex = clientQueryIndex
	if not queryIndex then
		return
	end
	for renderIndex, boidId in boidIdByRenderIndex do
		local motor = renderMotors[renderIndex]
		local transform = renderTransforms[renderIndex]
		local part = if motor then motor.Part1 else nil
		local modelsByName: {[string]: BoidModel} = SharedTypes.BoidModels :: {[string]: BoidModel}
		local model = boidModelById[boidId] or (part and modelsByName[part.Name]) or SharedTypes.BoidModels.Boid
		local position = if part then part.Position elseif transform then transform.Position else nil
		if position then
			queryIndex:Update(boidId, position, BoidCollisionConfig.GetRadius(model))
		end
	end
end

local function unregisterBoid(boidId: number): ()
	local index = renderIndexByBoid[boidId]
	if not index then
		return
	end
	
	removeBoidFromRenderCell(boidId)

	local lastIndex = #renderMotors
	local removedMotor = renderMotors[index]
	local lastMotor = renderMotors[lastIndex]
	local lastBoidId = boidIdByRenderIndex[lastIndex]

	renderMotors[index] = lastMotor
	renderTransforms[index] = renderTransforms[lastIndex]
	boidIdByRenderIndex[index] = lastBoidId
	latestAtByIndex[index] = latestAtByIndex[lastIndex]
	latestPositionByIndex[index] = latestPositionByIndex[lastIndex]
	latestVelocityByIndex[index] = latestVelocityByIndex[lastIndex]
	renderPositionByIndex[index] = renderPositionByIndex[lastIndex]
	renderVelocityByIndex[index] = renderVelocityByIndex[lastIndex]
	nextRenderTimeByIndex[index] = nextRenderTimeByIndex[lastIndex]
	lastNetworkIntervalByIndex[index] = lastNetworkIntervalByIndex[lastIndex]
	facingByIndex[index] = facingByIndex[lastIndex]
	hasLatestByIndex[index] = hasLatestByIndex[lastIndex]
	hasRenderByIndex[index] = hasRenderByIndex[lastIndex]

	if lastBoidId then
		renderIndexByBoid[lastBoidId] = index
		updateRenderCellIndex(lastBoidId, lastIndex, index)
	end

	renderMotors[lastIndex] = nil
	renderTransforms[lastIndex] = nil
	table.remove(latestAtByIndex, lastIndex)
	table.remove(latestPositionByIndex, lastIndex)
	table.remove(latestVelocityByIndex, lastIndex)
	table.remove(renderPositionByIndex, lastIndex)
	table.remove(renderVelocityByIndex, lastIndex)
	table.remove(nextRenderTimeByIndex, lastIndex)
	table.remove(lastNetworkIntervalByIndex, lastIndex)
	table.remove(facingByIndex, lastIndex)
	table.remove(hasLatestByIndex, lastIndex)
	table.remove(hasRenderByIndex, lastIndex)
	boidIdByRenderIndex[lastIndex] = nil
	removedMotor:Destroy()

	renderIndexByBoid[boidId] = nil
	lastSnapshotTimeByBoid[boidId] = nil
	boidModelById[boidId] = nil
	if clientQueryIndex then
		clientQueryIndex:Remove(boidId)
	end

	nextRenderPartIndex -= 1
end
local totalBoidsRegistered = 0

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
		if not renderIndexByBoid[id] and (not lifetime or lifetime > (retiredLifetimes[id] or -1)) then
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
		if (lifetime and lifetime <= (retiredLifetimes[boidId] or -1)) or renderIndexByBoid[boidId] then continue end
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
		boidModelById[boidId] = model

		registerBoid(boidId, newBoidModel, now)
		renderedCountByGroup[groupId] = (renderedCountByGroup[groupId] or 0) + 1
	end

	totalBoidsRegistered += boidCount

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


export type RenderedBoidState = {
	boidId: number, groupId: number, cframe: CFrame, velocity: Vector3,
	isRendered: boolean, renderedAt: number?, snapshotAt: number?,
}
export type RenderedGroupBounds = {
	groupId: number, count: number, centroid: Vector3, minimum: Vector3,
	maximum: Vector3, sampledAt: number, oldestRenderedAt: number,
}

-- Observation records contain values only; callers never receive renderer storage.
function BoidsRenderer.GetRenderedBoidState(boidId: number): RenderedBoidState?
	local index = renderIndexByBoid[boidId]
	local groupId = groupIdByBoid[boidId]
	if not index or not groupId then
		return nil
	end
	local isRendered = hasRenderByIndex[index]
	return {
		boidId = boidId,
		groupId = groupId,
		cframe = renderTransforms[index],
		velocity = if isRendered then renderVelocityByIndex[index] else Vector3.zero,
		isRendered = isRendered,
		renderedAt = if isRendered then nextRenderTimeByIndex[index] else nil,
		snapshotAt = lastSnapshotTimeByBoid[boidId],
	}
end

function BoidsRenderer.HasRenderedGroup(groupId: number): boolean
	return boidsByGroup[groupId] ~= nil
end

-- Only the requested group is traversed, on the observer's 2 Hz schedule.
function BoidsRenderer.GetRenderedGroupBounds(groupId: number): RenderedGroupBounds?
	local group = boidsByGroup[groupId]
	if not group then
		return nil
	end
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = -minimum
	local sum = Vector3.zero
	local count = 0
	local oldestRenderedAt = math.huge
	for boidId in group do
		local index = renderIndexByBoid[boidId]
		if not index then
			continue
		end
		if not hasRenderByIndex[index] then
			continue
		end
		local position = renderTransforms[index].Position
		local radius = BoidCollisionConfig.GetRadius(boidModelById[boidId] or SharedTypes.BoidModels.Boid)
		local extent = Vector3.one * radius
		minimum = minimum:Min(position - extent)
		maximum = maximum:Max(position + extent)
		sum += position
		count += 1
		oldestRenderedAt = math.min(oldestRenderedAt, nextRenderTimeByIndex[index])
	end
	if count == 0 then
		return nil
	end
	return {
		groupId = groupId, count = count, centroid = sum / count,
		minimum = minimum, maximum = maximum,
		sampledAt = workspace:GetServerTimeNow(), oldestRenderedAt = oldestRenderedAt,
	}
end

export type RenderedGroupInfo = { groupId: number, count: number, color: Color3 }
function BoidsRenderer.GetRenderedGroupInfo(groupId: number): RenderedGroupInfo?
	if not boidsByGroup[groupId] then return nil end
	return { groupId = groupId, count = renderedCountByGroup[groupId] or 0, color = groupColors[groupId] }
end

-- On-demand rendered-pose picking deliberately ignores world geometry and query indexing.
function BoidsRenderer.PickRenderedBoid(origin: Vector3, direction: Vector3, groupId: number?, angularTolerance: number?): {boidId: number, groupId: number, position: Vector3, distance: number}?
	local limit = direction.Magnitude
	if limit <= 0 then return nil end
	local unit = direction / limit
	local bestDistance = limit
	local bestId: number? = nil
	for index, boidId in boidIdByRenderIndex do
		if groupId ~= nil and groupIdByBoid[boidId] ~= groupId then continue end
		if not hasRenderByIndex[index] then continue end
		local position = renderTransforms[index].Position
		local offset = position - origin
		local along = offset:Dot(unit)
		if along < 0 or along > limit then continue end
		local radius = math.max(BoidCollisionConfig.GetRadius(boidModelById[boidId] or SharedTypes.BoidModels.Boid), along * (angularTolerance or 0))
		local perpendicularSq = math.max(0, offset:Dot(offset) - along * along)
		if perpendicularSq > radius * radius then continue end
		local hitDistance = math.max(0, along - math.sqrt(radius * radius - perpendicularSq))
		if hitDistance < bestDistance then
			bestDistance = hitDistance
			bestId = boidId
		end
	end
	if bestId == nil then return nil end
	return { boidId = bestId, groupId = groupIdByBoid[bestId], position = renderTransforms[renderIndexByBoid[bestId]].Position, distance = bestDistance }
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

-- Value-only measurements; testing owns activation/reset/export policy.
BoidsRenderer.SetMeasurementsEnabled = Measurements.SetEnabled
BoidsRenderer.ResetMeasurements = Measurements.Reset
BoidsRenderer.GetMeasurements = Measurements.Read

function BoidsRenderer.Start(viewingCameraObserver: ((CFrame, number) -> ())?): ()
	if isStarted then return end
	isStarted = true
	onViewingCamera = viewingCameraObserver
	clientQueryIndexEnabled = QueryIndexConfig.IsEnabledForClient()
	createRenderRoot()
	RunService.RenderStepped:Connect(onRenderStepped)
end

BoidsRenderer.ConsumeCellSnapshot = consumeCellSnapshot
BoidsRenderer.ReceiveNewBoidBatch = receiveNewBoidBatch
BoidsRenderer.ReceiveDeleteBoidBatch = receiveDeleteBoidBatch
BoidsRenderer.ReceiveDeleteGroup = receiveDeleteGroup

return BoidsRenderer
