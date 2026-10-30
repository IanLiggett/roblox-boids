--!native
--!strict

--[[ Boids Stats Batch
Description:
	Batches static boid configuration for worker Actors and broadcasts compact
	spawn/model data to clients.

Public API:
	BOID_STATS_ROW_SIZE: number
	readBoidRow(data: buffer, index: number): (number, number, number, number, number, number, number, number, number, number, number)
	newBoidsStatsUpdate(groupId: number, batchSize: number?, lifetime: number?, inactivityThreshold: number?, defaultBoidModel: BoidModel): BoidsStatsBatch
	addBoidToBatch(batch: BoidsStatsBatch, boidId: number, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number, boidModel: BoidModel?): ()
	sendBatch(batch: BoidsStatsBatch): ()

Single-buffer AoS layout:
	Each boid is one fixed-size row inside `data`.

	Offset  Size  Field
	0       u16   boidId
	2       u8    maxSpeed
	3       u8    minSpeed
	4       u8    sight
	5       u8    avoidance
	6       u8    separation
	7       u8    repulsion
	8       u8    repulsionStrength
	9       u8    alignment
	10      u8    cohesion
	11      u8    targetBias
	12-15   pad   unused, keeps row aligned to 16 bytes
]]

local RunService = game:GetService("RunService")
local BoidReplicated = script.Parent.Parent

local SharedTypes = require(BoidReplicated.SharedTypes)
local ActorsInitializer = require(script.Parent.ActorsInitializer)
local StatsCodec = require(script.Parent.StatsCodec)

type ActorState = ActorsInitializer.ActorState
type NetworkBoidsBatch = SharedTypes.NetworkBoidsBatch

local BoidModels = SharedTypes.BoidModels
type BoidModel = SharedTypes.BoidModel

type BoidsStatsBatch = SharedTypes.BoidsStatsBatch

local ClientRendererBridge = require(BoidReplicated.ClientRendererBridge)
local BoidBatches = {}


local batches: {BoidsStatsBatch} = {}

local BOID_ID_OFFSET = 0
local MAX_SPEED_OFFSET = 2
local MIN_SPEED_OFFSET = 3
local SIGHT_OFFSET = 4
local AVOIDANCE_OFFSET = 5
local SEPARATION_OFFSET = 6
local REPULSION_OFFSET = 7
local REPULSION_STRENGTH_OFFSET = 8
local ALIGNMENT_OFFSET = 9
local COHESION_OFFSET = 10
local TARGET_BIAS_OFFSET = 11

local BOID_STATS_ROW_SIZE = StatsCodec.ROW_BYTES
BoidBatches.BOID_STATS_ROW_SIZE = BOID_STATS_ROW_SIZE



export type ActorBoidsBatch = StatsCodec.ActorBoidsBatch

local nextBatchId = 0

local function rowOffset(index: number): number
	return index * BOID_STATS_ROW_SIZE
end

local function writeBoidRow(data: buffer, index: number, boidId: number, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number): ()
	StatsCodec.WriteBoidRow(data, index, boidId, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias)
end

function BoidBatches.ReadBoidRow(data: buffer, index: number): (number, number, number, number, number, number, number, number, number, number, number)
	return StatsCodec.ReadBoidRow(data, index)
end

local function trimBuffer(buf: buffer, size: number):buffer
	local trimmed: buffer = buffer.create(size)
	if size > 0 then
		buffer.copy(trimmed, 0, buf, 0, size)
	end
	return trimmed
end

local function makeTrimmedStatsBuffer(batch: BoidsStatsBatch): buffer
	local byteCount: number = batch.boidCount * BOID_STATS_ROW_SIZE
	
	return trimBuffer(batch.data, byteCount)
end

local function makeNetworkIdsBuffer(data: buffer, boidCount: number): buffer
	local ids: buffer = buffer.create(boidCount * 2)

	local sourceOffset: number
	for index: number = 0, boidCount - 1 do
		sourceOffset = rowOffset(index)
		buffer.writeu16(ids, index * 2, buffer.readu16(data, sourceOffset + BOID_ID_OFFSET))
	end

	return ids
end

function BoidBatches.NewBoidsStatsUpdate(groupId: number, batchSize: number?, lifetime: number?, inactivityThreshold: number?, defaultBoidModel: BoidModel, renderColor: Color3?): BoidsStatsBatch
	batchSize = batchSize or 100
	local now:number = workspace:GetServerTimeNow()

	local boidStatsUpdate: BoidsStatsBatch = {
		id = nextBatchId,
		lifetimes = {},
		groupId = groupId,
		defaultModel = defaultBoidModel or BoidModels.Boid,
		renderColor = renderColor,

		boidCount = 0,
		batchSize = batchSize,
		lifetime = lifetime or (1 / 60) * 5,
		inactivityThreshold = inactivityThreshold or (1 / 60),

		lastSend = now,
		lastAddition = now,

		boidModels = buffer.create(batchSize),
		data = buffer.create(batchSize * BOID_STATS_ROW_SIZE),
	}

	batches[boidStatsUpdate.id] = boidStatsUpdate
	nextBatchId += 1

	return boidStatsUpdate
end

function BoidBatches.AddBoidToBatch(
	batch: BoidsStatsBatch,
	boidId: number,
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
	boidModel:BoidModel?,
	lifetime: number
): ()
	assert(batches[batch.id] == batch, "Cannot append to a retired stats batch")
	if batch.boidCount >= batch.batchSize then
		BoidBatches.SendBatch(batch)
	end
	
	local index: number = batch.boidCount

	writeBoidRow(
		batch.data,
		index,
		boidId,
		maxSpeed,
		minSpeed,
		sight,
		avoidance,
		separation,
		repulsion,
		repulsionStrength,
		alignment,
		cohesion,
		targetBias
	)
	buffer.writeu8(batch.boidModels, index, boidModel or batch.defaultModel)

	batch.lifetimes[boidId] = lifetime
	batch.boidCount += 1
	batch.lastAddition = workspace:GetServerTimeNow()

	if batch.boidCount >= batch.batchSize then
		BoidBatches.SendBatch(batch)
	end
end

function BoidBatches.RemoveBoid(batch: BoidsStatsBatch, boidId: number): ()
	batch.lifetimes[boidId] = nil
	for index = batch.boidCount - 1, 0, -1 do
		if buffer.readu16(batch.data, rowOffset(index)) == boidId then
			local last = batch.boidCount - 1
			if index ~= last then
				buffer.copy(batch.data, rowOffset(index), batch.data, rowOffset(last), BOID_STATS_ROW_SIZE)
				buffer.writeu8(batch.boidModels, index, buffer.readu8(batch.boidModels, last))
			end
			batch.boidCount = last
		end
	end
end

function BoidBatches.DestroyBatch(batch: BoidsStatsBatch): ()
	if batches[batch.id] ~= batch then return end
	batches[batch.id] = nil
	table.clear(batch.lifetimes)
	batch.boidCount = 0
end

function BoidBatches.SendBatch(batch: BoidsStatsBatch): ()
	if batches[batch.id] ~= batch then return end
	local boidCount: number = batch.boidCount
	if boidCount <= 0 then
		return
	end

	local sendData: buffer = makeTrimmedStatsBuffer(batch)
	
	-- Actor transport stringifies sparse numeric keys; align lifetimes with dense rows.
	local lifetimes: {number} = {}
	for row = 0, boidCount - 1 do
		lifetimes[row + 1] = batch.lifetimes[buffer.readu16(sendData, rowOffset(row))]
	end
	local actorBatch: ActorBoidsBatch = {
		groupId = batch.groupId,
		lifetimes = lifetimes,
		boidCount = batch.boidCount,
		data = sendData
	}

	for _, actor: ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("NewBoidsStatsBatch", actorBatch)
	end

	local networkBoidsBatch: NetworkBoidsBatch = {
		lifetimes = table.clone(batch.lifetimes),
		groupId = batch.groupId,
		boidCount = boidCount,
		boidModels = trimBuffer(batch.boidModels, batch.boidCount),
		boidIds = makeNetworkIdsBuffer(sendData, boidCount),
		renderColor = batch.renderColor,
	}

	batch.boidCount = 0
	table.clear(batch.lifetimes)
	batch.lastSend = workspace:GetServerTimeNow()

	-- Server lifecycle is replicated by SimulationReplication. Only locally
	-- simulated boids call this process's renderer directly.
	if RunService:IsClient() then
		ClientRendererBridge.ReceiveNewBoidBatch(networkBoidsBatch)
	end

end

local function flushInactiveBatches(): ()
	local now = workspace:GetServerTimeNow()

	for _, batch: BoidsStatsBatch in batches do
		if batch.boidCount <= 0 then
			continue
		end

		local age = now - batch.lastSend
		local inactivity = now - batch.lastAddition

		if age >= batch.lifetime or inactivity >= batch.inactivityThreshold then
			BoidBatches.SendBatch(batch)
		end
	end
end

local isStarted = false
function BoidBatches.Start(): ()
	if isStarted then return end
	isStarted = true
	RunService.Heartbeat:Connect(flushInactiveBatches)
end

return BoidBatches
