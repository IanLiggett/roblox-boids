--!strict
--!native

--[[
SimulationReplication
=====================
Replicates the authoritative server simulation's low-frequency control state to
each client. Clients instantiate the same Boids coordinator locally; the
existing server snapshot packets are then consumed only as reconciliation
targets, never as the primary rendering source.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BoidsReplicated = script.Parent
local SharedTypes = require(script.Parent.SharedTypes)
local NetworkResults = require(script.Parent.NetworkResults)
local CorrectionIntake = require(script.CorrectionIntake)
local Replay = require(script.Replay)
local Bootstrap = require(script.Bootstrap)
local RuntimeTypes = require(script.Parent.RuntimeTypes)
local SimulationReplication = {}


local Remotes = BoidsReplicated.Remotes
local simulationState: RemoteEvent = Remotes.SimulationState
local requestSimulationState: RemoteEvent = Remotes.RequestSimulationState
local boidJobUpdate: UnreliableRemoteEvent = Remotes.BoidJobUpdate

type Target = SharedTypes.Target
type PathNode = SharedTypes.PathNode
type Group = SharedTypes.Group
type ReplicatedTarget = {
	kind: "position",
	position: Vector3,
} | {
	kind: "part",
	targetId: string,
}

type BoidsApi = RuntimeTypes.Replication

local SPAWN_ROW_BYTES = 37
local SPAWN_BATCH_SIZE = 64

local BOID_ID_OFFSET = 0
local POSITION_X_OFFSET = 2
local POSITION_Y_OFFSET = 6
local POSITION_Z_OFFSET = 10
local VELOCITY_X_OFFSET = 14
local VELOCITY_Y_OFFSET = 18
local VELOCITY_Z_OFFSET = 22
local MAX_SPEED_OFFSET = 26
local MIN_SPEED_OFFSET = 27
local SIGHT_OFFSET = 28
local AVOIDANCE_OFFSET = 29
local SEPARATION_OFFSET = 30
local REPULSION_OFFSET = 31
local REPULSION_STRENGTH_OFFSET = 32
local ALIGNMENT_OFFSET = 33
local COHESION_OFFSET = 34
local TARGET_BIAS_OFFSET = 35
local MODEL_OFFSET = 36

export type BoidSpawnRecord = Replay.BoidSpawnRecord

type PathState = {
	nodes: {PathNode},
	switchToClosestNode: boolean,
	loops: boolean,
	arrivalRadius: number,
}

type GravityWellState = {
	id: number,
	position: Vector3,
	strength: number,
	influenceRadius: number,
}

type GroupState = {
	id: number,
	defaultModel: number,
	renderColor: Color3?,
	boids: {[number]: BoidSpawnRecord},
	target: ReplicatedTarget?,
	path: PathState?,
	groupWells: {[number]: GravityWellState},
	pendingSpawns: {BoidSpawnRecord},
}

local serverGroups: {[number]: GroupState} = {}
local serverGlobalWells: {[number]: GravityWellState} = {}
local serverReplayExtension: ((Player) -> ())? = nil
local clientStateExtension: ((string, unknown, unknown, unknown, unknown) -> ())? = nil

local clientStarted = false
local clientGroupsById: {[number]: Group} = {}
local clientCorrections: CorrectionIntake.Intake? = nil
SimulationReplication.clientStarted = false

local function clonePath(path: {PathNode}): {PathNode}
	local copy: {PathNode} = {}
	for _, node in path do table.insert(copy, {Position = node.Position, offset = node.offset}) end
	return copy
end

local function encodeSpawnRecords(records: {BoidSpawnRecord}, first: number, last: number): buffer
	local count = last - first + 1
	local data = buffer.create(count * SPAWN_ROW_BYTES)
	local row = 0

	for index = first, last do
		local record = records[index]
		local offset = row * SPAWN_ROW_BYTES

		buffer.writeu16(data, offset + BOID_ID_OFFSET, record.id)
		buffer.writef32(data, offset + POSITION_X_OFFSET, record.position.X)
		buffer.writef32(data, offset + POSITION_Y_OFFSET, record.position.Y)
		buffer.writef32(data, offset + POSITION_Z_OFFSET, record.position.Z)
		buffer.writef32(data, offset + VELOCITY_X_OFFSET, record.velocity.X)
		buffer.writef32(data, offset + VELOCITY_Y_OFFSET, record.velocity.Y)
		buffer.writef32(data, offset + VELOCITY_Z_OFFSET, record.velocity.Z)
		buffer.writeu8(data, offset + MAX_SPEED_OFFSET, record.maxSpeed)
		buffer.writeu8(data, offset + MIN_SPEED_OFFSET, record.minSpeed)
		buffer.writeu8(data, offset + SIGHT_OFFSET, record.sight)
		buffer.writeu8(data, offset + AVOIDANCE_OFFSET, record.avoidance)
		buffer.writeu8(data, offset + SEPARATION_OFFSET, record.separation)
		buffer.writeu8(data, offset + REPULSION_OFFSET, record.repulsion)
		buffer.writeu8(data, offset + REPULSION_STRENGTH_OFFSET, record.repulsionStrength)
		buffer.writeu8(data, offset + ALIGNMENT_OFFSET, record.alignment)
		buffer.writeu8(data, offset + COHESION_OFFSET, record.cohesion)
		buffer.writeu8(data, offset + TARGET_BIAS_OFFSET, record.targetBias)
		buffer.writeu8(data, offset + MODEL_OFFSET, record.model)

		row += 1
	end

	return data
end

local function fireSpawnRecords(fire: (string, number, buffer) -> (), groupId: number, records: {BoidSpawnRecord}): ()
	local first = 1
	while first <= #records do
		local last = math.min(first + SPAWN_BATCH_SIZE - 1, #records)
		fire("Boids", groupId, encodeSpawnRecords(records, first, last))
		first = last + 1
	end
end

local serverStateReader: Replay.StateReader? = nil

-- Bound by the existing running coordinator; replay never requires a runtime.
function SimulationReplication.SetServerStateReader(readState: Replay.StateReader): ()
	if not RunService:IsServer() then return end
	assert(not serverStateReader, "Server replay state reader is already registered")
	serverStateReader = readState
end

local function getServerGroup(groupId: number): GroupState
	local groupState = serverGroups[groupId]
	assert(groupState, `Cannot replicate unknown boid group {groupId}`)
	return groupState
end

function SimulationReplication.ServerRegisterGroup(groupId: number, defaultModel: number, renderColor: Color3?): ()
	if not RunService:IsServer() then
		return
	end

	assert(not serverGroups[groupId], `Boid group {groupId} is already replicated`)
	serverGroups[groupId] = {
		id = groupId,
		defaultModel = defaultModel,
		renderColor = renderColor,
		boids = {},
		groupWells = {},
		pendingSpawns = {},
	}

	simulationState:FireAllClients("Group", groupId, defaultModel, renderColor)
end

function SimulationReplication.ServerRegisterBoid(
	groupId: number,
	boidId: number,
	position: Vector3,
	velocity: Vector3,
	maxSpeed: number,
	minSpeed: number,
	sight: number,
	avoidance: number,
	separation: number,
	repulsion: number,
	repulsionStrength: number,
	alignment: number,
	cohesion: number,
	targetBias: number,
	model: number
): ()
	if not RunService:IsServer() then
		return
	end

	local groupState = getServerGroup(groupId)
	local record: BoidSpawnRecord = {
		id = boidId,
		position = position,
		velocity = velocity,
		maxSpeed = maxSpeed,
		minSpeed = minSpeed,
		sight = sight,
		avoidance = avoidance,
		separation = separation,
		repulsion = repulsion,
		repulsionStrength = repulsionStrength,
		alignment = alignment,
		cohesion = cohesion,
		targetBias = targetBias,
		model = model,
	}
	groupState.boids[boidId] = record
	table.insert(groupState.pendingSpawns, record)
end

local nextTargetId = 0

local function serializeTarget(target: Target): ReplicatedTarget
	if typeof(target) == "Instance" then
		assert(target:IsA("BasePart"), "A dynamic target must be a BasePart")
		local targetId = target:GetAttribute("BoidsTargetId")
		if type(targetId) ~= "string" then
			nextTargetId += 1
			targetId = "BoidsTarget_" .. nextTargetId
			target:SetAttribute("BoidsTargetId", targetId)
		end
		return {
			kind = "part",
			targetId = targetId :: string,
		}
	end

	assert(type(target) == "table" and typeof(target.Position) == "Vector3", "A static target must contain a Vector3 Position")
	return {
		kind = "position",
		position = target.Position,
	}
end

function SimulationReplication.ServerSetTarget(groupId: number, target: Target): ()
	if not RunService:IsServer() then
		return
	end

	local groupState = getServerGroup(groupId)
	groupState.target = serializeTarget(target)
	groupState.path = nil
	simulationState:FireAllClients("Target", groupId, groupState.target)
end

function SimulationReplication.ServerSetPath(groupId: number, path: {PathNode}, switchToClosestNode: boolean, loops: boolean, arrivalRadius: number): ()
	if not RunService:IsServer() then
		return
	end

	local groupState = getServerGroup(groupId)
	groupState.target = nil
	groupState.path = {
		nodes = clonePath(path),
		switchToClosestNode = switchToClosestNode,
		loops = loops,
		arrivalRadius = arrivalRadius,
	}
	simulationState:FireAllClients("Path", groupId, groupState.path)
end

function SimulationReplication.ServerAddGravityWell(gravityWell: GravityWellState, groupIds: {number}?): ()
	if not RunService:IsServer() then
		return
	end

	if groupIds then
		for _, groupId in groupIds do
			local groupState = getServerGroup(groupId)
			groupState.groupWells[gravityWell.id] = gravityWell
			simulationState:FireAllClients("GroupWell", groupId, gravityWell)
		end
	else
		serverGlobalWells[gravityWell.id] = gravityWell
		simulationState:FireAllClients("GlobalWell", gravityWell)
	end
end

function SimulationReplication.ServerRemoveGravityWell(gravityWellId: number, groupIds: {number}?): boolean
	if not RunService:IsServer() then
		return false
	end

	if groupIds then
		local removed = false
		for _, groupId in groupIds do
			local groupState = getServerGroup(groupId)
			if groupState.groupWells[gravityWellId] then
				groupState.groupWells[gravityWellId] = nil
				simulationState:FireAllClients("RemoveGroupWell", groupId, gravityWellId)
				removed = true
			end
		end
		return removed
	end

	if not serverGlobalWells[gravityWellId] then
		return false
	end
	serverGlobalWells[gravityWellId] = nil
	simulationState:FireAllClients("RemoveGlobalWell", gravityWellId)
	return true
end

function SimulationReplication.ServerDeleteBoids(boidIds: {number}): ()
	if not RunService:IsServer() or #boidIds == 0 then
		return
	end

	local removed: {[number]: boolean} = {}
	for _, boidId in boidIds do removed[boidId] = true end
	for _, groupState in serverGroups do
		for _, boidId in boidIds do groupState.boids[boidId] = nil end
		local pending: {BoidSpawnRecord} = {}
		for _, record in groupState.pendingSpawns do
			if not removed[record.id] then table.insert(pending, record) end
		end
		groupState.pendingSpawns = pending
	end
	NetworkResults.DiscardBoids(removed)
	simulationState:FireAllClients("DeleteBoids", boidIds, workspace:GetServerTimeNow())
end

function SimulationReplication.ServerDestroyGroup(groupId: number): ()
	if not RunService:IsServer() or not serverGroups[groupId] then
		return
	end

	serverGroups[groupId] = nil
	simulationState:FireAllClients("DestroyGroup", groupId)
end

-- One explicit extension preserves control-plane order without importing policy.
function SimulationReplication.SetServerReplayExtension(replay: (Player) -> ()): ()
	assert(not serverReplayExtension, "Server replay extension already registered")
	serverReplayExtension = replay
end

function SimulationReplication.SetClientStateExtension(consume: (string, unknown, unknown, unknown, unknown) -> ()): ()
	assert(not clientStarted, "Client state extension must register before intake starts")
	assert(not clientStateExtension, "Client state extension already registered")
	clientStateExtension = consume
end

-- Independent values from the acceptance owner; diagnostics choose sample policy.
function SimulationReplication.ForEachClientCorrection(observer: (number, Vector3, Vector3, number) -> ()): ()
 if clientCorrections then clientCorrections.ForEachAccepted(observer) end
end

local function sendFullState(player: Player): ()
	local readState = assert(serverStateReader, "Server replay state reader is not registered")
	simulationState:FireClient(player, "Begin")

	local groupIds: {number} = {}
	for groupId in serverGroups do
		table.insert(groupIds, groupId)
	end
	table.sort(groupIds)

	for _, groupId in groupIds do
		local groupState = serverGroups[groupId]
		simulationState:FireClient(player, "Group", groupState.id, groupState.defaultModel, groupState.renderColor)

		if groupState.target then
			simulationState:FireClient(player, "Target", groupState.id, groupState.target)
		end
		if groupState.path then
			simulationState:FireClient(player, "Path", groupState.id, groupState.path)
		end

		local fire = function(kind: string, replicatedGroupId: number, data: buffer): ()
			simulationState:FireClient(player, kind, replicatedGroupId, data)
		end
		fireSpawnRecords(fire, groupState.id, Replay.CopyBoids(groupState.boids, readState))

		for _, gravityWell in groupState.groupWells do
			simulationState:FireClient(player, "GroupWell", groupState.id, gravityWell)
		end
	end

	for _, gravityWell in serverGlobalWells do
		simulationState:FireClient(player, "GlobalWell", gravityWell)
	end

	if serverReplayExtension then serverReplayExtension(player) end

	simulationState:FireClient(player, "Complete")
end

local serverStarted = false
function SimulationReplication.StartServer(): ()
	if not RunService:IsServer() or serverStarted then return end
	assert(serverStateReader, "Server state reader must be bound before replication starts")
	serverStarted = true
	local bootstrap: Bootstrap.Admission = Bootstrap.New(sendFullState)
	requestSimulationState.OnServerEvent:Connect(function(player: Player): ()
		bootstrap.Request(player, workspace:GetServerTimeNow())
	end)
	Players.PlayerRemoving:Connect(bootstrap.Forget :: (Player, Enum.PlayerExitReason) -> ())

	RunService.Heartbeat:Connect(function(): ()
		for _, groupState in serverGroups do
			if #groupState.pendingSpawns > 0 then
				local records: {BoidSpawnRecord} = groupState.pendingSpawns
				groupState.pendingSpawns = {}

				local fire = function(kind: string, groupId: number, data: buffer): ()
					simulationState:FireAllClients(kind, groupId, data)
				end
				fireSpawnRecords(fire, groupState.id, records)
			end
		end
	end)
end

type PendingClientSpawn = {group: Group, data: buffer, offset: number}
local function applySpawnRow(boids: BoidsApi, group: Group, data: buffer, offset: number): ()
	local boidId = buffer.readu16(data, offset + BOID_ID_OFFSET)
	boids.NewBoid(
		group,
		Vector3.new(
		buffer.readf32(data, offset + POSITION_X_OFFSET),
		buffer.readf32(data, offset + POSITION_Y_OFFSET),
		buffer.readf32(data, offset + POSITION_Z_OFFSET)
		),
		Vector3.new(
		buffer.readf32(data, offset + VELOCITY_X_OFFSET),
		buffer.readf32(data, offset + VELOCITY_Y_OFFSET),
		buffer.readf32(data, offset + VELOCITY_Z_OFFSET)
		),
		buffer.readu8(data, offset + MAX_SPEED_OFFSET),
		buffer.readu8(data, offset + MIN_SPEED_OFFSET),
		buffer.readu8(data, offset + SIGHT_OFFSET),
		buffer.readu8(data, offset + AVOIDANCE_OFFSET),
		buffer.readu8(data, offset + SEPARATION_OFFSET),
		buffer.readu8(data, offset + REPULSION_OFFSET),
		buffer.readu8(data, offset + REPULSION_STRENGTH_OFFSET),
		buffer.readu8(data, offset + ALIGNMENT_OFFSET),
		buffer.readu8(data, offset + COHESION_OFFSET),
		buffer.readu8(data, offset + TARGET_BIAS_OFFSET),
		buffer.readu8(data, offset + MODEL_OFFSET),
		boidId
	)
end

local function applySpawnBatch(boids: BoidsApi, groups: {[number]: Group}, groupId: number, data: buffer, pending: {[number]: PendingClientSpawn}): ()
	if typeof(data) ~= "buffer" or buffer.len(data) == 0 or buffer.len(data) % SPAWN_ROW_BYTES ~= 0 then return end
	local group = groups[groupId]
	if not group then return end
	for row = 0, buffer.len(data) // SPAWN_ROW_BYTES - 1 do
		local offset = row * SPAWN_ROW_BYTES
		local id = buffer.readu16(data, offset + BOID_ID_OFFSET)
		if boids.IsDeletionPending(id) then
			pending[id] = {group=group, data=data, offset=offset}
		elseif not boids.HasBoid(id) then
			applySpawnRow(boids, group, data, offset)
		end
	end
end

local function findTargetPart(targetId: string): BasePart?
	for _, instance in workspace:GetDescendants() do
		if instance:IsA("BasePart") and instance:GetAttribute("BoidsTargetId") == targetId then
			return instance
		end
	end
	return nil
end

function SimulationReplication.GetClientGroup(groupId: number): Group?
	return clientGroupsById[groupId]
end

function SimulationReplication.StartClient(boids: BoidsApi): ()
	if not RunService:IsClient() or clientStarted then
		return
	end
	clientStarted = true
	SimulationReplication.clientStarted = true

	local groups: {[number]: Group} = clientGroupsById
	local pendingTargets: {[number]: ReplicatedTarget} = {}
	local pendingSpawns: {[number]: PendingClientSpawn} = {}
	local corrections: CorrectionIntake.Intake = CorrectionIntake.New(boids)
	clientCorrections = corrections
	local boidGroups: {[number]: number} = {}

	local function applyTarget(groupId: number, target: ReplicatedTarget): ()
		local group = groups[groupId]
		if not group then
			return
		end

		if target.kind == "position" then
			pendingTargets[groupId] = nil
			boids.SetTarget(group, { Position = target.position })
			return
		end

		local targetPart: BasePart? = findTargetPart(target.targetId)
		if targetPart then
			pendingTargets[groupId] = nil
			boids.SetTarget(group, targetPart)
		else
			pendingTargets[groupId] = target
		end
	end

	local function applyPendingForPart(instance: Instance): ()
		if not instance:IsA("BasePart") then
			return
		end

		local targetId = instance:GetAttribute("BoidsTargetId")
		if type(targetId) ~= "string" then
			return
		end

		for groupId, target in pendingTargets do
			if target.kind == "part" and target.targetId == targetId then
				applyTarget(groupId, target)
			end
		end
	end

	workspace.DescendantAdded:Connect(function(instance: Instance): ()
		applyPendingForPart(instance)
		if instance:IsA("BasePart") and type(instance:GetAttribute("BoidsTargetId")) ~= "string" then
			instance:GetAttributeChangedSignal("BoidsTargetId"):Once(function(): ()
				applyPendingForPart(instance)
			end)
		end
	end)

	-- These positional payloads are authored by the server publishers above.
	-- Branch assertions describe those contracts; they add no validation or authority.
	-- Extension payloads stay opaque, including while reliable commands are deferred.
	local function applyState(kind: unknown, a: unknown, b: unknown, c: unknown, d: unknown): ()
		if kind == "Begin" then
			-- Informational markers bracket one reliable bootstrap. They never
			-- reset live state; duplicate spawns/scenarios retain existing handling.
		elseif kind == "Complete" then
			-- Completion means replay messages were delivered, not that deferred
			-- local deletion/spawns, Actor stats or streaming geometry are settled.
		elseif kind == "Group" then
			local groupId: number = a :: number
			if not groups[groupId] then
				groups[groupId] = boids.NewGroup(b :: number, groupId, c :: Color3?)
			end
		elseif kind == "Boids" then
			applySpawnBatch(boids, groups, a :: number, b :: buffer, pendingSpawns)
			if typeof(b) == "buffer" and buffer.len(b) % SPAWN_ROW_BYTES == 0 then
				for offset = 0, buffer.len(b) - 1, SPAWN_ROW_BYTES do boidGroups[buffer.readu16(b, offset)] = a :: number end
			end
		elseif kind == "Target" then
			if type(a) == "number" and type(b) == "table" then
				applyTarget(a, b :: ReplicatedTarget)
			end
		elseif kind == "Path" then
			local group = groups[a :: number]
			if group and type(b) == "table" and type(b.nodes) == "table" then
				pendingTargets[a :: number] = nil
				boids.SetPath(group, (b :: PathState).nodes, (b :: PathState).switchToClosestNode, (b :: PathState).loops, false, (b :: PathState).arrivalRadius)
			end
		elseif kind == "GlobalWell" then
			if type(a) == "table" then
				boids.AddGravityWell((a :: GravityWellState).position, (a :: GravityWellState).strength, (a :: GravityWellState).influenceRadius, nil, (a :: GravityWellState).id)
			end
		elseif kind == "GroupWell" then
			local group = groups[a :: number]
			if group and type(b) == "table" then
				boids.AddGravityWell((b :: GravityWellState).position, (b :: GravityWellState).strength, (b :: GravityWellState).influenceRadius, {group}, (b :: GravityWellState).id)
			end
		elseif kind == "RemoveGlobalWell" then
			boids.RemoveGravityWell(a :: number)
		elseif kind == "RemoveGroupWell" then
			local group = groups[a :: number]
			if group then
				boids.RemoveGravityWell(b :: number, {group})
			end
		elseif kind == "DeleteBoids" then
			if type(a) == "table" then
				for _, boidId in a :: {number} do
					pendingSpawns[boidId], boidGroups[boidId] = nil, nil
					corrections.Retire(boidId, if type(b) == "number" then b else nil)
					boids.QueueDeleteBoid(boidId)
				end
			end
		elseif kind == "DestroyGroup" then
			local group = groups[a :: number]
			for id, groupId in boidGroups do
				if groupId == a then
					corrections.Retire(id, nil)
					pendingSpawns[id], boidGroups[id] = nil, nil
				end
			end
			if group then
				boids.DestroyGroup(group)
				groups[a :: number] = nil
				pendingTargets[a :: number] = nil
			end
		elseif clientStateExtension then
			clientStateExtension(kind :: string, a, b, c, d)
		end
	end

	-- A replacement reliable group must wait for any already-committing old
	-- lifetime to settle. Preserve reliable command order while it is deferred.
	local stateQueue: {{unknown}} = {}
	local draining = false
	local function drainState(): ()
		if draining then return end
		draining = true
		while stateQueue[1] do
			local message: {unknown} = stateQueue[1]
			if message[1] == "Group" and boids.IsGroupRetiring(message[2] :: number) then break end
			table.remove(stateQueue, 1)
			applyState(table.unpack(message, 1, 5))
		end
		draining = false
	end
	simulationState.OnClientEvent:Connect(function(kind: string, a: unknown, b: unknown, c: unknown, d: unknown): ()
		table.insert(stateQueue, {kind, a, b, c, d})
		drainState()
	end)
	RunService.Heartbeat:Connect(function(): ()
		drainState()
		for id, pending in pendingSpawns do
			if groups[pending.group.id] ~= pending.group then
				pendingSpawns[id] = nil
			elseif not boids.IsDeletionPending(id) then
				pendingSpawns[id] = nil
				if not boids.HasBoid(id) then applySpawnRow(boids, pending.group, pending.data, pending.offset) end
			end
		end
	end)

	boidJobUpdate.OnClientEvent:Connect(corrections.Consume)

	requestSimulationState:FireServer()
end

return SimulationReplication
