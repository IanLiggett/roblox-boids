--!strict
-- Process-local observer state, trusted configuration and simulation/network LOD policy.
local PlayersService = game:GetService("Players")
local RunService = game:GetService("RunService")
local BoidsReplicated = script.Parent.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local LODConfig = require(BoidsReplicated.LODConfig)
local ViewerLOD = {}
type Cell = SharedTypes.Cell
type Group = SharedTypes.Group
type SimulationLODConfig = LODConfig.SimulationConfig
type NetworkLODConfig = LODConfig.NetworkConfig
type ViewerObservers = {
	cameraPosition: Vector3?,
	cameraEnabled: boolean,
	fixedPositions: {Vector3},
}

local viewerObservers: {[number]: ViewerObservers} = {}
local HALF_CELL: Vector3 = Vector3.one * (Quantization.CELL_SIZE * 0.5)
local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function distanceSq(a: Vector3, b: Vector3): number
	local delta: Vector3 = a - b
	return delta:Dot(delta)
end

local function getNearestObserverDistanceSq(viewer: ViewerObservers, position: Vector3): number
	local nearestDistanceSq = math.huge
	local cameraPosition: Vector3? = viewer.cameraPosition
	if viewer.cameraEnabled and cameraPosition then
		nearestDistanceSq = distanceSq(position, cameraPosition)
	end
	for _, fixedPosition: Vector3 in viewer.fixedPositions do
		nearestDistanceSq = math.min(nearestDistanceSq, distanceSq(position, fixedPosition))
	end
	return nearestDistanceSq
end

local function distanceAlphaSq(dSq: number, nearDistance: number, farDistance: number): number
	const nearDistanceSq = nearDistance * nearDistance
	const distanceRangeSq = farDistance * farDistance - nearDistanceSq
	if distanceRangeSq <= 0 then
		return 1
	end

	return smoothstep((dSq - nearDistanceSq) / distanceRangeSq)
end

local function simMultiplierForDistanceSq(dSq: number, config: SimulationLODConfig): number
	const alpha: number = distanceAlphaSq(dSq, config.nearDistance, config.farDistance)
	return math.round(config.minIntervalMultiplier + alpha * (config.maxIntervalMultiplier - config.minIntervalMultiplier))
end

local function networkMultiplierForDistanceSq(dSq: number, config: NetworkLODConfig): number
	const alpha: number = distanceAlphaSq(dSq, config.nearDistance, config.farDistance)
	return math.round(config.minIntervalMultiplier + alpha * (config.maxIntervalMultiplier - config.minIntervalMultiplier))
end


local function stablePhase(userId: number, cellId: number, interval: number): number
	local seed = userId * 1103515245 + cellId * 12345
	return ((seed % 10000) / 10000) * interval
end

local function crossedSendBoundary(lastTime: number, now: number, interval: number, phase: number): boolean
	local previousBucket = math.floor((lastTime - phase) / interval)
	local currentBucket = math.floor((now - phase) / interval)

	return currentBucket > previousBucket
end

local function getGroupSimulationConfig(group: Group): SimulationLODConfig
	return LODConfig.GetSimulationConfig(LODConfig.GetSimulationKindForGroup(group.id))
end

local function getCellSimMultiplier(group: Group, cell: Cell): number
	local config: SimulationLODConfig = getGroupSimulationConfig(group)
	local cellCenter: Vector3 = cell.origin + HALF_CELL
	local nearestDistanceSq = math.huge
	for _, viewer: ViewerObservers in viewerObservers do
		nearestDistanceSq = math.min(nearestDistanceSq, getNearestObserverDistanceSq(viewer, cellCenter))
	end
	if nearestDistanceSq > config.farDistance * config.farDistance then
		return config.backgroundIntervalMultiplier
	end
	return math.min(config.backgroundIntervalMultiplier, simMultiplierForDistanceSq(nearestDistanceSq, config))
end

local function getDuePlayersForCell(cell: Cell, lastCellUpdateTime: number, now: number): ({number}, boolean)
	local config: NetworkLODConfig = LODConfig.GetActive().network
	const duePlayers: {number} = {}
	const cellCenter: Vector3 = cell.origin + HALF_CELL
	const farDistanceSq = config.farDistance * config.farDistance
	
	local hasDuePlayer: boolean = false
	
	local dSq: number, networkMultiplier: number, interval: number, phase: number
	for userId: number, viewer: ViewerObservers in viewerObservers do
		dSq = getNearestObserverDistanceSq(viewer, cellCenter)
		if dSq > farDistanceSq then
			continue
		end

		networkMultiplier = networkMultiplierForDistanceSq(dSq, config)
		interval = config.baseInterval * networkMultiplier
		phase = stablePhase(userId, cell.id, interval)

		if crossedSendBoundary(lastCellUpdateTime, now, interval, phase) then
			hasDuePlayer = true
			table.insert(duePlayers, userId)
		end
	end

	return duePlayers, hasDuePlayer
end

local function getOrCreateViewer(viewerId: number): ViewerObservers
	local viewer: ViewerObservers? = viewerObservers[viewerId]
	if not viewer then
		viewer = { cameraEnabled = true, fixedPositions = {} } :: ViewerObservers
		viewerObservers[viewerId] = viewer
	end
	return viewer :: ViewerObservers
end

function ViewerLOD.UpdatePlayerPosition(playerId: number, position: Vector3): ()
	getOrCreateViewer(playerId).cameraPosition = position
end

-- Configuration is process-local; scenario control owns authorization and
-- applies the same accepted configuration to the server and owning client.
function ViewerLOD.SetViewerObservers(viewerId: number, cameraEnabled: boolean, fixedPositions: {Vector3}): ()
	local viewer: ViewerObservers = getOrCreateViewer(viewerId)
	viewer.cameraEnabled = cameraEnabled
	viewer.fixedPositions = table.clone(fixedPositions)
end

function ViewerLOD.ResetViewerObservers(viewerId: number): ()
	local viewer: ViewerObservers? = viewerObservers[viewerId]
	if not viewer then
		return
	end
	viewer.cameraEnabled = true
	table.clear(viewer.fixedPositions)
end

local function startViewerTracking(): ()
	if RunService:IsServer() then
		local cameraUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.CameraUpdate
		cameraUpdate.OnServerEvent:Connect(function(player: Player, cameraCFrame: unknown): ()
			if typeof(cameraCFrame) ~= "CFrame" then
				return
			end
			local position: Vector3 = cameraCFrame.Position
			if position.X ~= position.X or position.Y ~= position.Y or position.Z ~= position.Z
				or math.abs(position.X) == math.huge or math.abs(position.Y) == math.huge or math.abs(position.Z) == math.huge then
				return
			end
			ViewerLOD.UpdatePlayerPosition(player.UserId, position)
		end)
	
		PlayersService.PlayerRemoving:Connect(function(player: Player): ()
			viewerObservers[player.UserId] = nil
		end)
	else
		local localPlayer:Player = PlayersService.LocalPlayer :: Player
		RunService.RenderStepped:Connect(function(): ()
			local camera: Camera? = workspace.CurrentCamera
			if camera then
				ViewerLOD.UpdatePlayerPosition(localPlayer.UserId, camera.CFrame.Position)
			end
		end)
	end
	
	
end


local isStarted = false
function ViewerLOD.Start(): ()
 if isStarted then return end
 isStarted = true
 startViewerTracking()
end
ViewerLOD.GetCellSimMultiplier = getCellSimMultiplier
ViewerLOD.GetDuePlayersForCell = getDuePlayersForCell
return ViewerLOD
