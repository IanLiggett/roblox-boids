--!strict
--!native

--[[ NetworkResults
Description:
	Builds compact network snapshot buffers from simulated cell snapshots and
	provides iterators for reading those buffers on the client.

Public API:
	MAX_PACKET_BYTES: number
	BOID_ROW_BYTES: number
	newCellSnapshot(capacity: number, origin: Vector3): CellSnapshot
	getOrCreateCellSnapshot(simulationSnapshot: SimulationSnapshot, snapshotByCellId: {[number]: CellSnapshot}, cellId: number, origin: Vector3, capacityHint: number?): CellSnapshot
	appendBoid(cellSnapshot: CellSnapshot, boidId: number, localPosition: Vector3, velocity: Vector3): ()
	convertSimulationSnapshotToPackets(simulationSnapshot: SimulationSnapshot): SnapshotPackets
	forEachCellHeader(packet: BoidPacket): () -> (number?, number?, number?, number?, number?)
	forEachBoid(packet: BoidPacket, offset: number, boidCount: number): () -> (number?, number?, number?, number?, number?, number?, number?)
]]

local module = {}

local SharedTypes = require(script.Parent.SharedTypes)
local Quantization = require(script.Parent.Quantization)
local BoidStorage = require(script.Parent.BoidStorage)

type SimulationSnapshot = SharedTypes.SimulationSnapshot
type SnapshotPackets = SharedTypes.SnapshotPackets
type BoidPacket = SharedTypes.BoidPacket
type CellSnapshot = SharedTypes.CellSnapshot

local quantizePositionAxis = Quantization.quantizePositionAxis
local quantizeVelocityAxis = Quantization.quantizeVelocityAxis
local dequantizePositionAxis = Quantization.dequantizePositionAxis
local dequantizeVelocityAxis = Quantization.dequantizeVelocityAxis

local CELL_SIZE: number = Quantization.CELL_SIZE

local U8_SIZE: number = 1
local U16_SIZE: number = 2

local MAX_U8: number = 2^8 - 1

-- Budgeting estimate:
-- origin Vector3 ~= 12 bytes, plus 1 byte-ish for count/header.
-- The actual Roblox table serialization has some overhead, so lower this later
-- if unreliable remotes reject/lose too much.
-- UPDATE: it's not perfect, gotta debug this

local PACKET_HEADER_BYTES: number = 1
local COMPLETION_TIME_BYTES: number = 8

local MAX_PACKET_BYTES: number = 980 - PACKET_HEADER_BYTES - COMPLETION_TIME_BYTES
module.MAX_PACKET_BYTES = MAX_PACKET_BYTES


local ORIGIN_AXES_SIZE: number = U16_SIZE
local CELL_BOID_COUNT_SIZE: number = U16_SIZE

local NETWORK_POSITION_AXES_SIZE: number = 1
local NETWORK_VELOCITY_AXES_SIZE: number = 1


local ORIGIN_X_OFFSET: number = 0
local ORIGIN_Y_OFFSET: number = ORIGIN_AXES_SIZE
local ORIGIN_Z_OFFSET: number = ORIGIN_Y_OFFSET + ORIGIN_AXES_SIZE
local CELL_BOID_COUNT_OFFSET: number = ORIGIN_Z_OFFSET + ORIGIN_AXES_SIZE
local CELL_HEADER_BYTES = CELL_BOID_COUNT_OFFSET + CELL_BOID_COUNT_SIZE


local BOID_ID_OFFSET: number = 0
local POS_X_OFFSET: number = BoidStorage.BOID_ID_SIZE
local POS_Y_OFFSET: number = POS_X_OFFSET + NETWORK_POSITION_AXES_SIZE
local POS_Z_OFFSET: number = POS_Y_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_X_OFFSET: number = POS_Z_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_Y_OFFSET: number = VEL_X_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local VEL_Z_OFFSET: number = VEL_Y_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local BOID_ROW_BYTES: number = VEL_Z_OFFSET + NETWORK_VELOCITY_AXES_SIZE
module.BOID_ROW_BYTES = BOID_ROW_BYTES


local VELOCITY_MIN: number = Quantization.VELOCITY_MIN
local VELOCITY_RANGE: number = Quantization.VELOCITY_RANGE

local function boidCapacity(snapshot: CellSnapshot): number
	return buffer.len(snapshot.networkBoids) // BOID_ROW_BYTES
end

local function ensureCellSnapshotCapacity(snapshot: CellSnapshot, requiredBoidCount: number)
	local currentCapacity = boidCapacity(snapshot)
	if currentCapacity >= requiredBoidCount then
		return
	end

	local newCapacity: number = math.max(currentCapacity, 1)
	while newCapacity < requiredBoidCount do
		newCapacity *= 2
	end

	local oldBuffer: buffer = snapshot.networkBoids
	local newBuffer: buffer = buffer.create(newCapacity * BOID_ROW_BYTES)

	local usedBytes = snapshot.boidCount * BOID_ROW_BYTES
	if usedBytes > 0 then
		buffer.copy(newBuffer, 0, oldBuffer, 0, usedBytes)
	end

	snapshot.networkBoids = newBuffer
end

function module.newCellSnapshot(capacity: number, origin: Vector3): CellSnapshot
	capacity = math.max(capacity, 1)

	return {
		origin = origin,
		boidCount = 0,

		networkBoids = buffer.create(capacity * BOID_ROW_BYTES),
	}
end

function module.getOrCreateCellSnapshot(
	simulationSnapshot: SimulationSnapshot,
	snapshotByCellId: {[number]: CellSnapshot},
	cellId: number,
	origin: Vector3,
	capacityHint: number?
): CellSnapshot
	local snapshot:CellSnapshot? = snapshotByCellId[cellId]
	if snapshot then
		return snapshot
	end

	snapshot = module.newCellSnapshot(capacityHint or 1, origin)
	snapshotByCellId[cellId] = snapshot
	table.insert(simulationSnapshot, snapshot)

	return snapshot
end

function module.appendBoid(
	cellSnapshot: CellSnapshot,
	boidId: number,
	localPosition: Vector3,
	velocity: Vector3
)
	local index = cellSnapshot.boidCount
	local requiredCount = index + 1

	ensureCellSnapshotCapacity(cellSnapshot, requiredCount)

	local buf = cellSnapshot.networkBoids
	local offset = index * BOID_ROW_BYTES

	buffer.writeu16(buf, offset, boidId)

	buffer.writeu8(buf, offset + POS_X_OFFSET, quantizePositionAxis(localPosition.X, MAX_U8))
	buffer.writeu8(buf, offset + POS_Y_OFFSET, quantizePositionAxis(localPosition.Y, MAX_U8))
	buffer.writeu8(buf, offset + POS_Z_OFFSET, quantizePositionAxis(localPosition.Z, MAX_U8))

	buffer.writeu8(buf, offset + VEL_X_OFFSET, quantizeVelocityAxis(velocity.X, VELOCITY_MIN, VELOCITY_RANGE, MAX_U8))
	buffer.writeu8(buf, offset + VEL_Y_OFFSET, quantizeVelocityAxis(velocity.Y, VELOCITY_MIN, VELOCITY_RANGE, MAX_U8))
	buffer.writeu8(buf, offset + VEL_Z_OFFSET, quantizeVelocityAxis(velocity.Z, VELOCITY_MIN, VELOCITY_RANGE, MAX_U8))

	cellSnapshot.boidCount = requiredCount
end

function module.convertSimulationSnapshotToPackets(simulationSnapshot: SimulationSnapshot): SnapshotPackets
	local packets: SnapshotPackets = {}

	local currentPacket: BoidPacket = buffer.create(MAX_PACKET_BYTES)
	local currentPacketBytes: number = 0
	
	local totalBoids: number
	local startBoid: number
	local remainingPacketBytes: number
		
	local function pushTrimmedPacket()
		if currentPacketBytes == 0 then
			return
		end
		
		local trimmed: buffer = buffer.create(currentPacketBytes)
		buffer.copy(trimmed, 0, currentPacket, 0, currentPacketBytes)
		table.insert(packets, trimmed)
		
		currentPacket = buffer.create(MAX_PACKET_BYTES)
		currentPacketBytes = 0
		remainingPacketBytes = MAX_PACKET_BYTES
	end
	
	local function ensureRoom(requiredBytes: number)
		if currentPacketBytes > 0 and currentPacketBytes + requiredBytes > MAX_PACKET_BYTES then
			pushTrimmedPacket()
		end
		
		if requiredBytes > MAX_PACKET_BYTES then
			error(`Single packet chunk too large: {requiredBytes} > {MAX_PACKET_BYTES}`)
		end
	end
	
	local function writeCellHeader(origin: Vector3, chunkBoidCount: number)
		buffer.writei16(currentPacket, currentPacketBytes, origin.X)
		buffer.writei16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE, origin.Y)
		buffer.writei16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE * 2, origin.Z)
		buffer.writeu16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE * 3, chunkBoidCount)
		
		currentPacketBytes += CELL_HEADER_BYTES
	end
	
	local function writeBoidSegment(src: buffer, boidCount: number, srcOffset: number)
		local byteCount: number = boidCount * BOID_ROW_BYTES
		buffer.copy(currentPacket, currentPacketBytes, src, srcOffset * BOID_ROW_BYTES, byteCount)
		currentPacketBytes += byteCount
		startBoid += boidCount
	end
	
	local origin: Vector3
	local sourceBoids: buffer
	local availableBoids: number, boidsInChunk: number
	
	for _, cellSnapshot: CellSnapshot in simulationSnapshot do
		totalBoids = cellSnapshot.boidCount
		if totalBoids <= 0 then
			continue
		end
		
		origin = cellSnapshot.origin
		sourceBoids = cellSnapshot.networkBoids
		startBoid = 0

		while startBoid < totalBoids do
			remainingPacketBytes = MAX_PACKET_BYTES - currentPacketBytes
			if remainingPacketBytes < CELL_HEADER_BYTES + BOID_ROW_BYTES then
				pushTrimmedPacket()
			end

			availableBoids = (remainingPacketBytes - CELL_HEADER_BYTES) // BOID_ROW_BYTES
			if availableBoids <= 0 then
				pushTrimmedPacket()
				continue
			end

			boidsInChunk = math.min(totalBoids - startBoid, availableBoids)
			
			ensureRoom(CELL_HEADER_BYTES + boidsInChunk * BOID_ROW_BYTES)
			
			writeCellHeader(origin, boidsInChunk)
			writeBoidSegment(sourceBoids, boidsInChunk, startBoid)
		end
	end

	pushTrimmedPacket()

	return packets
end


local function readCellHeader(packet: BoidPacket, offset: number): (number, number, number, number)
	return
		buffer.readi16(packet, offset + ORIGIN_X_OFFSET),
		buffer.readi16(packet, offset + ORIGIN_Y_OFFSET),
		buffer.readi16(packet, offset + ORIGIN_Z_OFFSET),
		buffer.readu16(packet, offset + CELL_BOID_COUNT_OFFSET)
end

function module.forEachCellHeader(packet: BoidPacket): ()->(number?, number?, number?, number?, number?)
	local packetEnd: number = buffer.len(packet) - 1
	local offset: number = 0
	local boidsOffset: number
	
	local ox: number, oy: number, oz: number, boidCount: number
	return function(): (number?, number?, number?, number?, number?)
		if offset >= packetEnd then
			return nil, nil, nil, nil, nil
		end
		
		ox, oy, oz, boidCount = readCellHeader(packet, offset)
		
		boidsOffset = offset + CELL_HEADER_BYTES
		offset = boidsOffset + boidCount * BOID_ROW_BYTES
		
		return boidsOffset, ox, oy, oz, boidCount
	end
end

local function readBoid(packet: buffer, offset: number): (number, number, number, number, number, number, number)
	return
		buffer.readu16(packet, offset),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_X_OFFSET), MAX_U8),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_Y_OFFSET), MAX_U8),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_Z_OFFSET), MAX_U8),
		dequantizeVelocityAxis(buffer.readu8(packet, offset + VEL_X_OFFSET), VELOCITY_MIN, VELOCITY_RANGE, MAX_U8),
		dequantizeVelocityAxis(buffer.readu8(packet, offset + VEL_Y_OFFSET), VELOCITY_MIN, VELOCITY_RANGE, MAX_U8),
		dequantizeVelocityAxis(buffer.readu8(packet, offset + VEL_Z_OFFSET), VELOCITY_MIN, VELOCITY_RANGE, MAX_U8)
end

function module.forEachBoid(packet: BoidPacket, offset: number, boidCount: number)
	local packetEnd: number = offset + boidCount * BOID_ROW_BYTES
	
	return function(): (number?, number?, number?, number?, number?, number?, number?)
		if offset >= packetEnd then
			return nil, nil, nil, nil, nil, nil, nil
		end
		
		offset += BOID_ROW_BYTES
		return readBoid(packet, offset - BOID_ROW_BYTES)
	end
end

return module
