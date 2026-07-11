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

local module = {}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoidReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(script.Parent.Parent.BoidsReplicated)

local SharedTypes = require(BoidReplicated.SharedTypes)
local ActorsInitializer = require(script.Parent.ActorsInitializer)

type ActorState = ActorsInitializer.ActorState
type NetworkBoidsBatch = SharedTypes.NetworkBoidsBatch

local BoidModels = SharedTypes.BoidModels
type BoidModel = SharedTypes.BoidModel

local newBoidBatchRemote = BoidReplicated.Remotes.NewBoidBatch

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

local BOID_STATS_ROW_SIZE = 16
module.BOID_STATS_ROW_SIZE = BOID_STATS_ROW_SIZE

export type BoidsStatsBatch = {
	id: number,
	groupId: number,
	defaultModel: BoidModel,

	boidCount: number,
	batchSize: number,
	lifetime: number,
	inactivityThreshold: number,

	lastSend: number,
	lastAddition: number,

	boidModels: buffer,
	data: buffer,
}

export type ActorBoidsBatch = {
	boidCount: number,
	data: buffer
}

local nextBatchId = 0

local function rowOffset(index: number): number
	return index * BOID_STATS_ROW_SIZE
end

local function writeBoidRow(
	data: buffer,
	index: number,
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
	targetBias: number
)
	local offset: number = rowOffset(index)

	buffer.writeu16(data, offset + BOID_ID_OFFSET, boidId)
	buffer.writeu8(data, offset + MAX_SPEED_OFFSET, maxSpeed)
	buffer.writeu8(data, offset + MIN_SPEED_OFFSET, minSpeed)
	buffer.writeu8(data, offset + SIGHT_OFFSET, sight)
	buffer.writeu8(data, offset + AVOIDANCE_OFFSET, avoidance)
	buffer.writeu8(data, offset + SEPARATION_OFFSET, separation)
	buffer.writeu8(data, offset + REPULSION_OFFSET, repulsion)
	buffer.writeu8(data, offset + REPULSION_STRENGTH_OFFSET, repulsionStrength)
	buffer.writeu8(data, offset + ALIGNMENT_OFFSET, alignment)
	buffer.writeu8(data, offset + COHESION_OFFSET, cohesion)
	buffer.writeu8(data, offset + TARGET_BIAS_OFFSET, targetBias)
end

function module.readBoidRow(data:buffer, index:number): (number, number, number, number, number, number, number, number, number, number, number)
	local offset: number = rowOffset(index)
	
	return
		buffer.readu16(data, offset + BOID_ID_OFFSET),
		buffer.readu8(data, offset + MAX_SPEED_OFFSET),
		buffer.readu8(data, offset + MIN_SPEED_OFFSET),
		buffer.readu8(data, offset + SIGHT_OFFSET),
		buffer.readu8(data, offset + AVOIDANCE_OFFSET),
		buffer.readu8(data, offset + SEPARATION_OFFSET),
		buffer.readu8(data, offset + REPULSION_OFFSET),
		buffer.readu8(data, offset + REPULSION_STRENGTH_OFFSET),
		buffer.readu8(data, offset + ALIGNMENT_OFFSET),
		buffer.readu8(data, offset + COHESION_OFFSET),
		buffer.readu8(data, offset + TARGET_BIAS_OFFSET)
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

function module.newBoidsStatsUpdate(groupId: number, batchSize: number?, lifetime: number?, inactivityThreshold: number?, defaultBoidModel: BoidModel): BoidsStatsBatch
	batchSize = batchSize or 100
	local now:number = workspace:GetServerTimeNow()

	local boidStatsUpdate: BoidsStatsBatch = {
		id = nextBatchId,
		groupId = groupId,
		defaultModel = defaultBoidModel or BoidModels.Boid,

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

function module.addBoidToBatch(
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
	boidModel:BoidModel?
)
	if batch.boidCount >= batch.batchSize then
		module.sendBatch(batch)
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

	batch.boidCount += 1
	batch.lastAddition = workspace:GetServerTimeNow()

	if batch.boidCount >= batch.batchSize then
		module.sendBatch(batch)
	end
end

function module.sendBatch(batch: BoidsStatsBatch)
	local boidCount: number = batch.boidCount
	if boidCount <= 0 then
		return
	end

	local sendData: buffer = makeTrimmedStatsBuffer(batch)
	
	local actorBatch: ActorBoidsBatch = {
		boidCount = batch.boidCount,
		data = sendData
	}

	for _, actor: ActorState in ActorsInitializer.actors do
		(actor.instance.Parent :: Actor):SendMessage("NewBoidsStatsBatch", actorBatch)
	end

	local networkBoidsBatch: NetworkBoidsBatch = {
		groupId = batch.groupId,
		boidCount = boidCount,
		boidModels = trimBuffer(batch.boidModels, batch.boidCount),
		boidIds = makeNetworkIdsBuffer(sendData, boidCount),
	}

	newBoidBatchRemote:FireAllClients(networkBoidsBatch)

	batch.boidCount = 0
	batch.lastSend = workspace:GetServerTimeNow()
end

RunService.Heartbeat:Connect(function()
	local now = workspace:GetServerTimeNow()

	for _, batch: BoidsStatsBatch in batches do
		if batch.boidCount <= 0 then
			continue
		end

		local age = now - batch.lastSend
		local inactivity = now - batch.lastAddition

		if age >= batch.lifetime or inactivity >= batch.inactivityThreshold then
			module.sendBatch(batch)
		end
	end
end)

return module
