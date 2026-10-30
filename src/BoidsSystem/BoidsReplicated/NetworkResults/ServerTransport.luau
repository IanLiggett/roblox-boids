--!strict
-- Coordinator selection, source-time batching and per-recipient send accounting.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local BoidsReplicated = script.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local LODConfig = require(BoidsReplicated.LODConfig)
local ViewerLOD = require(BoidsReplicated.Boids.JobBuilder.ViewerLOD)
local PacketCodec = require(script.Parent.PacketCodec)
local PredictionState = require(script.Parent.PredictionState)
local TransportMetrics = require(script.Parent.TransportMetrics)
local ServerTransport = {}
local metrics = RuntimeMetrics.State
type SimulationSnapshot = SharedTypes.SimulationSnapshot
type Accumulator = {prediction: PredictionState.State, oldestPendingTime: number?, nextReadyTime: number, minSendIntervalSeconds: number, tokens: number}

local boidJobUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.BoidJobUpdate
local accumulators: {[number]: Accumulator} = {}
-- Temporary measurement ceiling; supplied operating limit is 500/client/s.
local CALLS_PER_CLIENT_PER_SECOND = 50000
local MAX_PACKET_AGE = 0.075

local function getAccumulator(userId: number): Accumulator
	local state = accumulators[userId]
	if state then return state end
	local created: Accumulator = {prediction = PredictionState.New(), oldestPendingTime = nil, nextReadyTime = 0, minSendIntervalSeconds = LODConfig.GetNetworkConfig().minSendIntervalSeconds, tokens = CALLS_PER_CLIENT_PER_SECOND}
	accumulators[userId] = created
	return created
end

local function refreshInterval(state: Accumulator, interval: number): ()
	if interval == state.minSendIntervalSeconds then return end
	state.minSendIntervalSeconds = interval
	state.nextReadyTime = 0
end

local function updateGauges(userId: number, state: Accumulator): ()
	TransportMetrics.SetRecipientState(userId, state.prediction.baselineCount, PredictionState.GetBufferBytes(state.prediction), state.prediction.count)
end

local function flushPlayer(userId: number, state: Accumulator, flushPartial: boolean): ()
	local player = Players:GetPlayerByUserId(User.fromId(userId))
	if not player then return end
	local prediction = state.prediction
	local packetStart = os.clock()
	debug.profilebegin("Boids.Packetization")
	local now = workspace:GetServerTimeNow()
	local byTime, times, nextReadyTime = PredictionState.BuildSnapshots(prediction, now, state.minSendIntervalSeconds)
	state.nextReadyTime = nextReadyTime
	local droppedPackets = 0
	for _, sourceTime in times do
		local packets = PacketCodec.ConvertSimulationSnapshotToPackets(byTime[sourceTime])
		for _, packet in packets do
			if state.tokens < 1 then
				droppedPackets += 1
				continue
			end
			-- Full source-time packets may leave immediately. Other source times'
			-- partial packets retain their batching deadline instead of piggybacking.
			if not flushPartial and buffer.len(packet) + PacketCodec.CELL_HEADER_BYTES + PacketCodec.BOID_ROW_BYTES <= PacketCodec.MAX_PACKET_BYTES then
				state.nextReadyTime = math.min(state.nextReadyTime, now)
				continue
			end
			state.tokens -= 1
			boidJobUpdate:FireClient(player, packet, sourceTime)
			local rows = PredictionState.RecordSent(prediction, packet, sourceTime, workspace:GetServerTimeNow())
			TransportMetrics.RecordSent(userId, buffer.len(packet), rows, math.max(0, workspace:GetServerTimeNow() - (state.oldestPendingTime :: number)) * 1000)
		end
	end
	if droppedPackets > 0 then
		TransportMetrics.RecordCapDrop(userId, droppedPackets, prediction.count)
		PredictionState.ClearPending(prediction)
	end
	if prediction.count == 0 then state.oldestPendingTime = nil; state.nextReadyTime = 0 end
	updateGauges(userId, state)
	debug.profileend()
	RuntimeMetrics.Add(metrics, "packetizationMs", (os.clock() - packetStart) * 1000)
end

function ServerTransport.DiscardBoids(removed: {[number]: boolean}): ()
	for userId, state in accumulators do
		for id in removed do PredictionState.Discard(state.prediction, id) end
		if state.prediction.count == 0 then state.oldestPendingTime = nil; state.nextReadyTime = 0 end
		updateGauges(userId, state)
	end
end

function ServerTransport.EnqueueSimulationSnapshotForPlayers(players: {number}, snapshot: SimulationSnapshot, sourceTime: number): ()
	local started = os.clock()
	debug.profilebegin("Boids.NetworkErrorSelection")
	local candidates, comparisons, selected = 0, 0, 0
	-- Decode each candidate once across recipients; no per-boid records or storage rescan.
	local states: {Accumulator} = {}
	local userIds: {number} = {}
	local positionErrors: {number} = {}
	local velocityErrors: {number} = {}
	local queuedAt = workspace:GetServerTimeNow()
	local interval = LODConfig.GetNetworkConfig().minSendIntervalSeconds
	for _, cell in snapshot do
		table.clear(states)
		table.clear(userIds)
		table.clear(positionErrors)
		table.clear(velocityErrors)
		for _, userId in players do
			if not Players:GetPlayerByUserId(User.fromId(userId)) then continue end
			local positionSq, velocitySq = ViewerLOD.GetNetworkTolerances(userId, cell.origin)
			if not positionSq then continue end
			local index = #states + 1
			states[index] = getAccumulator(userId)
			refreshInterval(states[index], interval)
			userIds[index] = userId
			positionErrors[index] = positionSq
			velocityErrors[index] = velocitySq :: number
		end
		local recipientCount = #states
		if recipientCount == 0 then continue end
		local rowOffset = 0
		for id, px, py, pz, vx, vy, vz in PacketCodec.ForEachBoid(cell.networkBoids, 0, cell.boidCount) do
			candidates += 1
			local worldX, worldY, worldZ = cell.origin.X + px, cell.origin.Y + py, cell.origin.Z + pz
			for index = 1, recipientCount do
				local state = states[index]
				comparisons += 1
				if PredictionState.Consider(state.prediction, id, worldX, worldY, worldZ, vx, vy, vz, sourceTime, positionErrors[index], velocityErrors[index], cell.origin, cell.networkBoids, rowOffset) then
					selected += 1
					if not state.oldestPendingTime then state.oldestPendingTime = queuedAt end
					state.nextReadyTime = math.min(state.nextReadyTime, PredictionState.GetReadyTime(state.prediction, id, state.minSendIntervalSeconds))
				elseif state.prediction.count == 0 then
					state.oldestPendingTime = nil
				end
			end
			rowOffset += PacketCodec.BOID_ROW_BYTES
		end
		for index = 1, recipientCount do updateGauges(userIds[index], states[index]) end
	end
	TransportMetrics.RecordSelection(candidates, comparisons, selected, (os.clock() - started) * 1000)
	debug.profileend()
	for _, userId in players do
		local state = accumulators[userId]
		if state and queuedAt >= state.nextReadyTime and (state.prediction.rowsByTime[sourceTime] or 0) * PacketCodec.BOID_ROW_BYTES + PacketCodec.CELL_HEADER_BYTES + PacketCodec.BOID_ROW_BYTES > PacketCodec.MAX_PACKET_BYTES then
			flushPlayer(userId, state, false)
		end
	end
end

local serverStarted = false
function ServerTransport.StartServer(): ()
	if not RunService:IsServer() or serverStarted then return end
	serverStarted = true
	TransportMetrics.Configure(CALLS_PER_CLIENT_PER_SECOND, MAX_PACKET_AGE)
	Players.PlayerRemoving:Connect(function(player: Player): ()
		accumulators[player.UserId] = nil
		TransportMetrics.RemoveRecipient(player.UserId)
	end)
	RunService.PostSimulation:Connect(function(dt: number): ()
		local now = workspace:GetServerTimeNow()
		local interval = LODConfig.GetNetworkConfig().minSendIntervalSeconds
		for userId, state in accumulators do
			state.tokens = math.min(CALLS_PER_CLIENT_PER_SECOND, state.tokens + CALLS_PER_CLIENT_PER_SECOND * dt)
			refreshInterval(state, interval)
			if state.oldestPendingTime and now >= state.nextReadyTime and now - state.oldestPendingTime >= MAX_PACKET_AGE then flushPlayer(userId, state, true) end
		end
	end)
end

return ServerTransport
