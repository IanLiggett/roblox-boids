--!strict
-- Server queue lifetime, source-time batching and the existing global send budget.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local BoidsReplicated = script.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local PacketCodec = require(script.Parent.PacketCodec)
local TransportMetrics = require(script.Parent.TransportMetrics)
local ServerTransport = {}
local metrics = RuntimeMetrics.State
type SimulationSnapshot = SharedTypes.SimulationSnapshot
type BoidPacket = SharedTypes.BoidPacket
type CellSnapshot = SharedTypes.CellSnapshot
local MAX_PACKET_BYTES = PacketCodec.MAX_PACKET_BYTES
local CELL_HEADER_BYTES = PacketCodec.CELL_HEADER_BYTES
local BOID_ROW_BYTES = PacketCodec.BOID_ROW_BYTES
type PendingSnapshotChunk = {
	cellId: number,
	snapshot: CellSnapshot,
	time: number,
	queuedAt: number,
}

type PlayerPacketAccumulator = {
	chunks: {PendingSnapshotChunk},

	oldestPendingTime: number?,
	lastFlushTime: number,

	estimatedBytes: number,
}

local boidJobUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.BoidJobUpdate

local playerAccumulators:{[number]: PlayerPacketAccumulator} = {}

local TARGET_REMOTE_CALLS_PER_SECOND: number = 300
local MAX_PACKET_TOKENS: number = TARGET_REMOTE_CALLS_PER_SECOND
local packetTokens: number = MAX_PACKET_TOKENS

local MAX_PACKET_AGE: number = 1 / 4

local function estimateCellSnapshotBytes(cellSnapshot: CellSnapshot): number
	return CELL_HEADER_BYTES + cellSnapshot.boidCount * BOID_ROW_BYTES
end

local function getOrCreateAccumulator(userId: number): PlayerPacketAccumulator
	local state: PlayerPacketAccumulator? = playerAccumulators[userId]
	if state then
		return state
	end

	state = {
		chunks = {},

		oldestPendingTime = nil,
		lastFlushTime = 0,

		estimatedBytes = 0,
	} :: PlayerPacketAccumulator

	playerAccumulators[userId] = state

	return state
end

local function clearAccumulator(state: PlayerPacketAccumulator): ()
	table.clear(state.chunks)

	state.oldestPendingTime = nil
	state.estimatedBytes = 0
end

local function shouldFlushPlayer(state: PlayerPacketAccumulator, now: number): boolean
	if not state.oldestPendingTime then
		return false
	end

	if state.estimatedBytes >= MAX_PACKET_BYTES then
		return true
	end

	if now - state.oldestPendingTime >= MAX_PACKET_AGE then
		return true
	end

	return false
end

local function enqueueChunk(playerState: PlayerPacketAccumulator, cellId: number, cellSnapshot: CellSnapshot, now: number): ()
	if cellSnapshot.boidCount <= 0 then
		return
	end

	table.insert(playerState.chunks, {
		cellId = cellId,
		snapshot = cellSnapshot,
		time = now,
		queuedAt = workspace:GetServerTimeNow(),
	})

	if not playerState.oldestPendingTime then
		playerState.oldestPendingTime = workspace:GetServerTimeNow()
	end

	playerState.estimatedBytes += estimateCellSnapshotBytes(cellSnapshot)
end

local function flushPlayer(userId: number, state: PlayerPacketAccumulator): ()
	if #state.chunks <= 0 then
		clearAccumulator(state)
		return
	end

	if packetTokens < 1 then
		return
	end

	-- The existing packet has one source-time argument. Only rows with the same
	-- source time may share it; queue/send time never substitutes for state age.
	local snapshotsByTime: {[number]: SimulationSnapshot} = {}
	local sourceTimes: {number} = {}
	for _, chunk: PendingSnapshotChunk in state.chunks do
		local snapshots = snapshotsByTime[chunk.time]
		if not snapshots then
			snapshots = {}
			snapshotsByTime[chunk.time] = snapshots
			table.insert(sourceTimes, chunk.time)
		end
		-- Dense lists retain partial chunks with the same source cell ID.
		table.insert(snapshots, chunk.snapshot)
	end
	table.sort(sourceTimes)

	local player: Player? = Players:GetPlayerByUserId(userId)
	for _, sourceTime in sourceTimes do
		if not player or packetTokens < 1 then break end
		local packetStart = os.clock()
		debug.profilebegin("Boids.Packetization")
		local packets = PacketCodec.ConvertSimulationSnapshotToPackets(snapshotsByTime[sourceTime])
		debug.profileend()
		RuntimeMetrics.Add(metrics, "packetizationMs", (os.clock() - packetStart) * 1000)
		for _, packet: BoidPacket in packets do
			-- Preserve the global budget and drop unsent unreliable backlog.
			if packetTokens < 1 then break end
			packetTokens -= 1
			TransportMetrics.RecordSent(buffer.len(packet))
			boidJobUpdate:FireClient(player, packet, sourceTime)
		end
	end

	state.lastFlushTime = workspace:GetServerTimeNow()
	clearAccumulator(state)
end

-- Remove retired rows before a recipient queue can send them. Snapshot buffers may be shared by recipients; never mutate them.
function ServerTransport.DiscardBoids(removed: {[number]: boolean}): ()
	for _, state in playerAccumulators do
		local kept: {PendingSnapshotChunk} = {}
		local bytes = 0
		for _, chunk in state.chunks do
			local cell = chunk.snapshot
			local count = 0
			for row = 0, cell.boidCount - 1 do
				if not removed[buffer.readu16(cell.networkBoids, row * BOID_ROW_BYTES)] then count += 1 end
			end
			if count > 0 then
				local snapshot = cell
				if count ~= cell.boidCount then
					local rows = buffer.create(count * BOID_ROW_BYTES)
					local writeOffset = 0
					for row = 0, cell.boidCount - 1 do
						local offset = row * BOID_ROW_BYTES
						if not removed[buffer.readu16(cell.networkBoids, offset)] then
							buffer.copy(rows, writeOffset, cell.networkBoids, offset, BOID_ROW_BYTES)
							writeOffset += BOID_ROW_BYTES
						end
					end
					snapshot = {origin = cell.origin, networkBoids = rows, boidCount = count}
				end
				table.insert(kept, {cellId = chunk.cellId, snapshot = snapshot, time = chunk.time, queuedAt = chunk.queuedAt})
				bytes += estimateCellSnapshotBytes(snapshot)
			end
		end
		state.chunks = kept
		state.estimatedBytes = bytes
		state.oldestPendingTime = if kept[1] then kept[1].queuedAt else nil
	end
end

function ServerTransport.EnqueueSimulationSnapshotForPlayers(players: {number}, simulationSnapshot: SimulationSnapshot, now: number): ()
	for _, userId: number in players do
		if not Players:GetPlayerByUserId(userId) then continue end
		local state = getOrCreateAccumulator(userId)

		for cellId, cellSnapshot in simulationSnapshot do
			enqueueChunk(state, cellId, cellSnapshot, now)
		end
	end
end

local serverStarted = false
function ServerTransport.StartServer(): ()
	if not RunService:IsServer() or serverStarted then return end
	serverStarted = true
	Players.PlayerRemoving:Connect(function(player: Player): ()
		playerAccumulators[player.UserId] = nil
	end)
	RunService.PostSimulation:Connect(function(dt: number): ()
		packetTokens = math.min(
			MAX_PACKET_TOKENS,
			packetTokens + TARGET_REMOTE_CALLS_PER_SECOND * dt
		)

		local now: number = workspace:GetServerTimeNow()

		for userId: number, state: PlayerPacketAccumulator in playerAccumulators do
			if not shouldFlushPlayer(state, now) then
				continue
			end

			flushPlayer(userId, state)
		end
	end)
end


return ServerTransport
