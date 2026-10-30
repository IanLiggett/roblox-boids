--!strict
--!native
-- Coordinator-owned recipient history. Packed pages avoid one object per baseline;
-- dense pending rows own their bytes rather than retaining entire worker snapshots.
local PacketCodec = require(script.Parent.PacketCodec)
local SharedTypes = require(script.Parent.Parent.SharedTypes)
local PredictionState = {}

local PAGE_ROWS = 256
local BASELINE_BYTES = 41 -- validity, six f32 axes, f64 source time, f64 send time
local PENDING_BYTES = 22 -- canonical row, three i16 origin axes, f64 source time
local ROW_BYTES = PacketCodec.BOID_ROW_BYTES

export type State = {
	pages: {[number]: buffer},
	pageCount: number,
	baselineCount: number,
	pending: buffer,
	capacity: number,
	count: number,
	slotById: {[number]: number},
	rowsByTime: {[number]: number},
}

function PredictionState.New(): State
	return {pages = {}, pageCount = 0, baselineCount = 0, pending = buffer.create(0), capacity = 0, count = 0, slotById = {}, rowsByTime = {}}
end

local function baselineOffset(id: number): number
	return (id % PAGE_ROWS) * BASELINE_BYTES
end

local function removePending(state: State, id: number): ()
	local slot = state.slotById[id]
	if not slot then return end
	local lastSlot = state.count
	local time = buffer.readf64(state.pending, (slot - 1) * PENDING_BYTES + 14)
	local remaining = state.rowsByTime[time] - 1
	state.rowsByTime[time] = if remaining > 0 then remaining else nil
	if slot ~= lastSlot then
		buffer.copy(state.pending, (slot - 1) * PENDING_BYTES, state.pending, (lastSlot - 1) * PENDING_BYTES, PENDING_BYTES)
		state.slotById[buffer.readu16(state.pending, (slot - 1) * PENDING_BYTES)] = slot
	end
	state.slotById[id] = nil
	state.count -= 1
end

-- Returns whether this candidate crosses an error threshold. Baselines are
-- decoded wire state, so unchanged encoded velocity cannot retrigger by itself.
function PredictionState.Consider(
	state: State, id: number, px: number, py: number, pz: number, vx: number, vy: number, vz: number, sourceTime: number,
	positionErrorSq: number, velocityErrorSq: number, origin: Vector3, rows: buffer, rowOffset: number
): boolean
	local slot = state.slotById[id]
	if slot and sourceTime <= buffer.readf64(state.pending, (slot - 1) * PENDING_BYTES + 14) then return false end
	local page = state.pages[id // PAGE_ROWS]
	local offset = baselineOffset(id)
	if page and buffer.readu8(page, offset) ~= 0 then
		local sentAt = buffer.readf64(page, offset + 25)
		if sourceTime <= sentAt then return false end
		local lastVx = buffer.readf32(page, offset + 13)
		local lastVy = buffer.readf32(page, offset + 17)
		local lastVz = buffer.readf32(page, offset + 21)
		local age = sourceTime - sentAt
		local dx = px - (buffer.readf32(page, offset + 1) + lastVx * age)
		local dy = py - (buffer.readf32(page, offset + 5) + lastVy * age)
		local dz = pz - (buffer.readf32(page, offset + 9) + lastVz * age)
		local dvx, dvy, dvz = vx - lastVx, vy - lastVy, vz - lastVz
		if dx * dx + dy * dy + dz * dz <= positionErrorSq and dvx * dvx + dvy * dvy + dvz * dvz <= velocityErrorSq then
			removePending(state, id)
			return false
		end
	end
	if slot then
		local oldTime = buffer.readf64(state.pending, (slot - 1) * PENDING_BYTES + 14)
		local remaining = state.rowsByTime[oldTime] - 1
		state.rowsByTime[oldTime] = if remaining > 0 then remaining else nil
	else
		state.count += 1
		slot = state.count
		state.slotById[id] = slot
		if state.count > state.capacity then
			state.capacity = math.max(16, state.capacity * 2)
			local replacement = buffer.create(state.capacity * PENDING_BYTES)
			buffer.copy(replacement, 0, state.pending)
			state.pending = replacement
		end
	end
	local pendingOffset = (slot - 1) * PENDING_BYTES
	state.rowsByTime[sourceTime] = (state.rowsByTime[sourceTime] or 0) + 1
	buffer.copy(state.pending, pendingOffset, rows, rowOffset, ROW_BYTES)
	buffer.writei16(state.pending, pendingOffset + 8, origin.X)
	buffer.writei16(state.pending, pendingOffset + 10, origin.Y)
	buffer.writei16(state.pending, pendingOffset + 12, origin.Z)
	buffer.writef64(state.pending, pendingOffset + 14, sourceTime)
	return true
end

function PredictionState.Discard(state: State, id: number): ()
	removePending(state, id)
	local page = state.pages[id // PAGE_ROWS]
	local offset = baselineOffset(id)
	if page and buffer.readu8(page, offset) ~= 0 then
		buffer.writeu8(page, offset, 0)
		state.baselineCount -= 1
	end
end

function PredictionState.GetReadyTime(state: State, id: number, minSendIntervalSeconds: number): number
	local page = state.pages[id // PAGE_ROWS]
	local offset = baselineOffset(id)
	if not page or buffer.readu8(page, offset) == 0 then return -math.huge end
	return buffer.readf64(page, offset + 33) + minSendIntervalSeconds
end

function PredictionState.BuildSnapshots(state: State, now: number, minSendIntervalSeconds: number): ({[number]: SharedTypes.SimulationSnapshot}, {number}, number)
	local byTime: {[number]: SharedTypes.SimulationSnapshot} = {}
	local cellsByTime: {[number]: {[number]: SharedTypes.CellSnapshot}} = {}
	local times: {number} = {}
	local nextReadyTime = math.huge
	for slot = 0, state.count - 1 do
		local offset = slot * PENDING_BYTES
		local readyTime = PredictionState.GetReadyTime(state, buffer.readu16(state.pending, offset), minSendIntervalSeconds)
		if now < readyTime then
			nextReadyTime = math.min(nextReadyTime, readyTime)
			continue
		end
		local time = buffer.readf64(state.pending, offset + 14)
		local cells = cellsByTime[time]
		if not cells then
			cells = {}
			cellsByTime[time] = cells
			byTime[time] = {}
			times[#times + 1] = time
		end
		local ox, oy, oz = buffer.readi16(state.pending, offset + 8), buffer.readi16(state.pending, offset + 10), buffer.readi16(state.pending, offset + 12)
		-- Three signed i16 axes fit exactly in a 48-bit numeric key.
		local key = (ox + 32768) * 4294967296 + (oy + 32768) * 65536 + oz + 32768
		local cell = cells[key]
		if not cell then
			cell = PacketCodec.NewCellSnapshot(4, Vector3.new(ox, oy, oz))
			cells[key] = cell
			table.insert(byTime[time], cell)
		end
		local required = (cell.boidCount + 1) * ROW_BYTES
		if required > buffer.len(cell.networkBoids) then
			local replacement = buffer.create(buffer.len(cell.networkBoids) * 2)
			buffer.copy(replacement, 0, cell.networkBoids)
			cell.networkBoids = replacement
		end
		buffer.copy(cell.networkBoids, cell.boidCount * ROW_BYTES, state.pending, offset, ROW_BYTES)
		cell.boidCount += 1
	end
	table.sort(times)
	return byTime, times, nextReadyTime
end

-- Called only after the packet was handed to FireClient, never on enqueue.
function PredictionState.RecordSent(state: State, packet: buffer, sourceTime: number, sentAt: number): number
	local count = 0
	for offset, ox, oy, oz, boidCount in PacketCodec.ForEachCellHeader(packet) do
		for id, px, py, pz, vx, vy, vz in PacketCodec.ForEachBoid(packet, offset, boidCount) do
			local pageIndex = id // PAGE_ROWS
			local page = state.pages[pageIndex]
			if not page then
				page = buffer.create(PAGE_ROWS * BASELINE_BYTES)
				state.pages[pageIndex] = page
				state.pageCount += 1
			end
			local base = baselineOffset(id)
			if buffer.readu8(page, base) == 0 then state.baselineCount += 1 end
			buffer.writeu8(page, base, 1)
			buffer.writef32(page, base + 1, ox + px)
			buffer.writef32(page, base + 5, oy + py)
			buffer.writef32(page, base + 9, oz + pz)
			buffer.writef32(page, base + 13, vx)
			buffer.writef32(page, base + 17, vy)
			buffer.writef32(page, base + 21, vz)
			buffer.writef64(page, base + 25, sourceTime)
			buffer.writef64(page, base + 33, sentAt)
			removePending(state, id)
			count += 1
		end
	end
	return count
end

function PredictionState.ClearPending(state: State): ()
	state.count = 0
	table.clear(state.slotById)
	table.clear(state.rowsByTime)
end

function PredictionState.GetBufferBytes(state: State): number
	return state.pageCount * PAGE_ROWS * BASELINE_BYTES + buffer.len(state.pending)
end

return PredictionState
