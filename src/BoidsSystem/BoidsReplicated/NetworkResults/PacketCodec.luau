--!strict
--!native
-- Packet-local identity compression and columnar motion; local snapshots stay row-packed.
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


local MAX_U8: number = 2^8 - 1

-- Leave room for remote framing and the unchanged separate source timestamp.

local PACKET_HEADER_BYTES: number = 1
local COMPLETION_TIME_BYTES: number = 8

local MAX_PACKET_BYTES: number = 900 - PACKET_HEADER_BYTES - COMPLETION_TIME_BYTES
PacketCodec.MAX_PACKET_BYTES = MAX_PACKET_BYTES


local CELL_HEADER_BYTES = 8 -- i16 world origin axes, u8 count, u8 identity mode
PacketCodec.CELL_HEADER_BYTES = CELL_HEADER_BYTES
local NETWORK_POSITION_AXES_SIZE = 1
local NETWORK_VELOCITY_AXES_SIZE = 1
local POS_X_OFFSET: number = BoidStorage.BOID_ID_SIZE
local POS_Y_OFFSET: number = POS_X_OFFSET + NETWORK_POSITION_AXES_SIZE
local POS_Z_OFFSET: number = POS_Y_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_X_OFFSET: number = POS_Z_OFFSET + NETWORK_POSITION_AXES_SIZE
local VEL_Y_OFFSET: number = VEL_X_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local VEL_Z_OFFSET: number = VEL_Y_OFFSET + NETWORK_VELOCITY_AXES_SIZE
local BOID_ROW_BYTES: number = SnapshotCodec.BOID_ROW_BYTES
PacketCodec.BOID_ROW_BYTES = BOID_ROW_BYTES



-- Modes are packet-local: no roster, acknowledgement or previous packet is needed.
local EXPLICIT, PAGE, MASK, RUN = 0, 1, 2, 3
local function identityBytes(mode: number, count: number): number
	if mode == RUN then return 2 end
	if mode == MASK then return 33 end
	if mode == PAGE then return count + 1 end
	return count * 2
end

-- Find the largest fitting prefix while visiting each candidate only once.
local function selectSegment(rows: buffer, start: number, remaining: number, available: number): (number, number)
	local limit = math.min(remaining, 255, (available - CELL_HEADER_BYTES) // 6)
	local first = buffer.readu16(rows, start * BOID_ROW_BYTES)
	local previous = first - 1
	local samePage, ascending, consecutive = true, true, true
	local count, mode = 0, EXPLICIT
	for n = 1, limit do
		local id = buffer.readu16(rows, (start + n - 1) * BOID_ROW_BYTES)
		samePage = samePage and id // 256 == first // 256
		ascending = ascending and id > previous
		consecutive = consecutive and id == previous + 1
		previous = id
		local selected = EXPLICIT
		if consecutive then selected = RUN
		elseif samePage then selected = if ascending and n > 32 then MASK else PAGE end
		if CELL_HEADER_BYTES + identityBytes(selected, n) + n * 6 <= available then
			count, mode = n, selected
		end
	end
	return count, mode
end

function PacketCodec.ConvertSimulationSnapshotToPackets(simulationSnapshot: SimulationSnapshot): SnapshotPackets
	local packets: SnapshotPackets = {}
	local packet: buffer = buffer.create(MAX_PACKET_BYTES)
	local used = 0
	local function flush(): ()
		if used == 0 then return end
		local trimmed: buffer = buffer.create(used)
		buffer.copy(trimmed, 0, packet, 0, used)
		packets[#packets + 1] = trimmed
		packet, used = buffer.create(MAX_PACKET_BYTES), 0
	end
	for _, cell: CellSnapshot in simulationSnapshot do
		local start = 0
		while start < cell.boidCount do
			local count, mode = selectSegment(cell.networkBoids, start, cell.boidCount - start, MAX_PACKET_BYTES - used)
			if count == 0 then flush(); continue end
			buffer.writei16(packet, used, cell.origin.X)
			buffer.writei16(packet, used + 2, cell.origin.Y)
			buffer.writei16(packet, used + 4, cell.origin.Z)
			buffer.writeu8(packet, used + 6, count)
			buffer.writeu8(packet, used + 7, mode)
			used += CELL_HEADER_BYTES
			local first = buffer.readu16(cell.networkBoids, start * BOID_ROW_BYTES)
			if mode == RUN then buffer.writeu16(packet, used, first)
			elseif mode == PAGE or mode == MASK then buffer.writeu8(packet, used, first // 256) end
			if mode == MASK then buffer.fill(packet, used + 1, 0, 32) end
			local values = used + identityBytes(mode, count)
			for row = 0, count - 1 do
				local source = (start + row) * BOID_ROW_BYTES
				local id = buffer.readu16(cell.networkBoids, source)
				if mode == EXPLICIT then
					buffer.writeu8(packet, used + row, id % 256)
					buffer.writeu8(packet, used + count + row, id // 256)
				elseif mode == PAGE then buffer.writeu8(packet, used + 1 + row, id % 256)
				elseif mode == MASK then
					local byte = used + 1 + (id % 256) // 8
					buffer.writeu8(packet, byte, bit32.bor(buffer.readu8(packet, byte), bit32.lshift(1, id % 8)))
				end
				-- Columns expose shared velocity and position bytes to engine compression.
				for axis = 0, 5 do
					buffer.writeu8(packet, values + axis * count + row, buffer.readu8(cell.networkBoids, source + 2 + axis))
				end
			end
			used = values + count * 6
			start += count
		end
	end
	flush()
	return packets
end

-- Iteration-only contracts: generalized-for ignores the trailing nils on termination.
-- Every non-terminal yield supplies all numeric payloads.
export type CellHeaderIterator = () -> (number?, number, number, number, number)
export type BoidIterator = () -> (number?, number, number, number, number, number, number)
function PacketCodec.ForEachCellHeader(packet: BoidPacket): CellHeaderIterator
	local packetEnd = buffer.len(packet)
	local offset = 0
	return (function(): (number?, number?, number?, number?, number?)
		if offset >= packetEnd then return nil, nil, nil, nil, nil end
		local x, y, z = buffer.readi16(packet, offset), buffer.readi16(packet, offset + 2), buffer.readi16(packet, offset + 4)
		local count, mode = buffer.readu8(packet, offset + 6), buffer.readu8(packet, offset + 7)
		local rows = offset + CELL_HEADER_BYTES
		offset = rows + identityBytes(mode, count) + count * 6
		return rows, x, y, z, count
	end) :: CellHeaderIterator
end

-- Wire rows are columnar; local worker snapshots retain their packed row layout.
function PacketCodec.ForEachPacketBoid(packet: BoidPacket, offset: number, count: number): BoidIterator
	local mode = buffer.readu8(packet, offset - 1)
	local values = offset + identityBytes(mode, count)
	local row, bit = 0, 0
	return (function(): (number?, number?, number?, number?, number?, number?, number?)
		if row >= count then return nil, nil, nil, nil, nil, nil, nil end
		local id: number
		if mode == RUN then id = buffer.readu16(packet, offset) + row
		elseif mode == PAGE then id = buffer.readu8(packet, offset) * 256 + buffer.readu8(packet, offset + 1 + row)
		elseif mode == MASK then
			while bit32.band(buffer.readu8(packet, offset + 1 + bit // 8), bit32.lshift(1, bit % 8)) == 0 do bit += 1 end
			id = buffer.readu8(packet, offset) * 256 + bit
			bit += 1
		else id = buffer.readu8(packet, offset + row) + buffer.readu8(packet, offset + count + row) * 256 end
		local index = values + row
		row += 1
		return id,
			dequantizePositionAxis(buffer.readu8(packet, index), MAX_U8),
			dequantizePositionAxis(buffer.readu8(packet, index + count), MAX_U8),
			dequantizePositionAxis(buffer.readu8(packet, index + count * 2), MAX_U8),
			Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, index + count * 3)),
			Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, index + count * 4)),
			Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, index + count * 5))
	end) :: BoidIterator
end

local function readBoid(packet: buffer, offset: number): (number, number, number, number, number, number, number)
	return
		buffer.readu16(packet, offset),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_X_OFFSET), MAX_U8),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_Y_OFFSET), MAX_U8),
		dequantizePositionAxis(buffer.readu8(packet, offset + POS_Z_OFFSET), MAX_U8),
		Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, offset + VEL_X_OFFSET)),
		Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, offset + VEL_Y_OFFSET)),
		Quantization.DequantizeSnapshotVelocityAxis(buffer.readu8(packet, offset + VEL_Z_OFFSET))
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
