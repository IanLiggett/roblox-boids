--!strict
--!native
-- Pure packet layout/encoding/decoding. Reuses the canonical cell-row codec.
local SharedTypes = require(script.Parent.Parent.SharedTypes)
local Quantization = require(script.Parent.Parent.Quantization)
local BoidStorage = require(script.Parent.Parent.BoidStorage)
local SnapshotCodec = require(script.Parent.Parent.SnapshotCodec)
local PacketCodec = {}
type SimulationSnapshot = SharedTypes.SimulationSnapshot
type SnapshotPackets = SharedTypes.SnapshotPackets
type BoidPacket = SharedTypes.BoidPacket
type CellSnapshot = SharedTypes.CellSnapshot
local dequantizePositionAxis = Quantization.dequantizePositionAxis
local dequantizeVelocityAxis = Quantization.dequantizeVelocityAxis

local U8_SIZE: number = 1
local U16_SIZE: number = 2

local MAX_U8: number = 2^8 - 1

-- Budgeting estimate:
-- origin Vector3 ~= 12 bytes, plus 1 byte-ish for count/header.

local PACKET_HEADER_BYTES: number = 1
local COMPLETION_TIME_BYTES: number = 8

local MAX_PACKET_BYTES: number = 980 - PACKET_HEADER_BYTES - COMPLETION_TIME_BYTES
PacketCodec.MAX_PACKET_BYTES = MAX_PACKET_BYTES


local ORIGIN_AXES_SIZE: number = U16_SIZE
local CELL_BOID_COUNT_SIZE: number = U16_SIZE

local NETWORK_POSITION_AXES_SIZE: number = 1
local NETWORK_VELOCITY_AXES_SIZE: number = 1


local ORIGIN_X_OFFSET: number = 0
local ORIGIN_Y_OFFSET: number = ORIGIN_AXES_SIZE
local ORIGIN_Z_OFFSET: number = ORIGIN_Y_OFFSET + ORIGIN_AXES_SIZE
local CELL_BOID_COUNT_OFFSET: number = ORIGIN_Z_OFFSET + ORIGIN_AXES_SIZE
local CELL_HEADER_BYTES: number = CELL_BOID_COUNT_OFFSET + CELL_BOID_COUNT_SIZE
PacketCodec.CELL_HEADER_BYTES = CELL_HEADER_BYTES


local BOID_ID_OFFSET: number = 0
local POS_X_OFFSET: number = BoidStorage.BOID_ID_SIZE
local POS_Y_OFFSET: number = POS_X_OFFSET + NETWORK_POSITION_AXES_SIZE
local POS_Z_OFFSET: number = POS_Y_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_X_OFFSET: number = POS_Z_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_Y_OFFSET: number = VEL_X_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local VEL_Z_OFFSET: number = VEL_Y_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local BOID_ROW_BYTES: number = SnapshotCodec.BOID_ROW_BYTES
PacketCodec.BOID_ROW_BYTES = BOID_ROW_BYTES


local VELOCITY_MIN: number = Quantization.VELOCITY_MIN
local VELOCITY_RANGE: number = Quantization.VELOCITY_RANGE

function PacketCodec.ConvertSimulationSnapshotToPackets(simulationSnapshot: SimulationSnapshot): SnapshotPackets
	local packets: SnapshotPackets = {}

	local currentPacket: BoidPacket = buffer.create(MAX_PACKET_BYTES)
	local currentPacketBytes: number = 0
	
	local totalBoids: number
	local startBoid: number
	local remainingPacketBytes: number
		
	local function pushTrimmedPacket(): ()
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
	
	local function ensureRoom(requiredBytes: number): ()
		if currentPacketBytes > 0 and currentPacketBytes + requiredBytes > MAX_PACKET_BYTES then
			pushTrimmedPacket()
		end
		
		if requiredBytes > MAX_PACKET_BYTES then
			error(`Single packet chunk too large: {requiredBytes} > {MAX_PACKET_BYTES}`)
		end
	end
	
	local function writeCellHeader(origin: Vector3, chunkBoidCount: number): ()
		buffer.writei16(currentPacket, currentPacketBytes, origin.X)
		buffer.writei16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE, origin.Y)
		buffer.writei16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE * 2, origin.Z)
		buffer.writeu16(currentPacket, currentPacketBytes + ORIGIN_AXES_SIZE * 3, chunkBoidCount)
		
		currentPacketBytes += CELL_HEADER_BYTES
	end
	
	local function writeBoidSegment(src: buffer, boidCount: number, srcOffset: number): ()
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

-- Iteration-only contracts: generalized-for ignores the trailing nils on termination.
-- Every non-terminal yield supplies all numeric payloads.
export type CellHeaderIterator = () -> (number?, number, number, number, number)
export type BoidIterator = () -> (number?, number, number, number, number, number, number)
function PacketCodec.ForEachCellHeader(packet: BoidPacket): CellHeaderIterator
	local packetEnd: number = buffer.len(packet) - 1
	local offset: number = 0
	local boidsOffset: number
	
	local ox: number, oy: number, oz: number, boidCount: number
	return (function(): (number?, number?, number?, number?, number?)
		if offset >= packetEnd then
			return nil, nil, nil, nil, nil
		end
		
		ox, oy, oz, boidCount = readCellHeader(packet, offset)
		
		boidsOffset = offset + CELL_HEADER_BYTES
		offset = boidsOffset + boidCount * BOID_ROW_BYTES
		
		return boidsOffset, ox, oy, oz, boidCount
	end) :: CellHeaderIterator
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

function PacketCodec.ForEachBoid(packet: BoidPacket, offset: number, boidCount: number): BoidIterator
	local packetEnd: number = offset + boidCount * BOID_ROW_BYTES
	
	return (function(): (number?, number?, number?, number?, number?, number?, number?)
		if offset >= packetEnd then
			return nil, nil, nil, nil, nil, nil, nil
		end
		
		offset += BOID_ROW_BYTES
		return readBoid(packet, offset - BOID_ROW_BYTES)
	end) :: BoidIterator
end


PacketCodec.NewCellSnapshot = SnapshotCodec.NewCellSnapshot
PacketCodec.GetOrCreateCellSnapshot = SnapshotCodec.GetOrCreateCellSnapshot
PacketCodec.AppendBoid = SnapshotCodec.AppendBoid
return PacketCodec
