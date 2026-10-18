--!strict
-- Pure compact snapshot construction shared by Actor workers and packet transport.
local SharedTypes = require(script.Parent.SharedTypes)
local Quantization = require(script.Parent.Quantization)
local BoidStorage = require(script.Parent.BoidStorage)

local SnapshotCodec = {}
local MAX_U8 = 255
SnapshotCodec.BOID_ROW_BYTES = BoidStorage.BOID_ID_SIZE + 6

type CellSnapshot = SharedTypes.CellSnapshot
type SimulationSnapshot = SharedTypes.SimulationSnapshot

local function capacity(snapshot: CellSnapshot): number
	return buffer.len(snapshot.networkBoids) // SnapshotCodec.BOID_ROW_BYTES
end

local function ensureCapacity(snapshot: CellSnapshot, required: number): ()
	if capacity(snapshot) >= required then return end
	local nextCapacity = math.max(capacity(snapshot), 1)
	while nextCapacity < required do nextCapacity *= 2 end
	local replacement = buffer.create(nextCapacity * SnapshotCodec.BOID_ROW_BYTES)
	local used = snapshot.boidCount * SnapshotCodec.BOID_ROW_BYTES
	if used > 0 then buffer.copy(replacement, 0, snapshot.networkBoids, 0, used) end
	snapshot.networkBoids = replacement
end

function SnapshotCodec.NewCellSnapshot(capacityHint: number, origin: Vector3): CellSnapshot
	return { origin = origin, boidCount = 0, networkBoids = buffer.create(math.max(capacityHint, 1) * SnapshotCodec.BOID_ROW_BYTES) }
end

function SnapshotCodec.GetOrCreateCellSnapshot(snapshot: SimulationSnapshot, cellId: number, origin: Vector3, capacityHint: number?): CellSnapshot
	local result = snapshot[cellId]
	if result then return result end
	result = SnapshotCodec.NewCellSnapshot(capacityHint or 1, origin)
	snapshot[cellId] = result
	return result
end

local function appendBoidUnchecked(snapshot: CellSnapshot, boidId: number, localPosition: Vector3, velocity: Vector3): ()
	local index = snapshot.boidCount
	local offset = index * SnapshotCodec.BOID_ROW_BYTES
	local data = snapshot.networkBoids
	buffer.writeu16(data, offset, boidId)
	buffer.writeu8(data, offset + 2, Quantization.quantizePositionAxis(localPosition.X, MAX_U8))
	buffer.writeu8(data, offset + 3, Quantization.quantizePositionAxis(localPosition.Y, MAX_U8))
	buffer.writeu8(data, offset + 4, Quantization.quantizePositionAxis(localPosition.Z, MAX_U8))
	buffer.writeu8(data, offset + 5, Quantization.quantizeVelocityAxis(velocity.X, Quantization.VELOCITY_MIN, Quantization.VELOCITY_RANGE, MAX_U8))
	buffer.writeu8(data, offset + 6, Quantization.quantizeVelocityAxis(velocity.Y, Quantization.VELOCITY_MIN, Quantization.VELOCITY_RANGE, MAX_U8))
	buffer.writeu8(data, offset + 7, Quantization.quantizeVelocityAxis(velocity.Z, Quantization.VELOCITY_MIN, Quantization.VELOCITY_RANGE, MAX_U8))
	snapshot.boidCount = index + 1
end

function SnapshotCodec.AppendBoidReserved(snapshot: CellSnapshot, boidId: number, localPosition: Vector3, velocity: Vector3): ()
	assert(snapshot.boidCount < capacity(snapshot), "AppendBoidReserved requires sufficient capacity")
	appendBoidUnchecked(snapshot, boidId, localPosition, velocity)
end

function SnapshotCodec.AppendBoid(snapshot: CellSnapshot, boidId: number, localPosition: Vector3, velocity: Vector3): ()
	ensureCapacity(snapshot, snapshot.boidCount + 1)
	appendBoidUnchecked(snapshot, boidId, localPosition, velocity)
end

function SnapshotCodec.TrimUnusedCapacity(snapshot: CellSnapshot): ()
	local used = snapshot.boidCount * SnapshotCodec.BOID_ROW_BYTES
	if buffer.len(snapshot.networkBoids) == used then return end
	local replacement = buffer.create(used)
	if used > 0 then buffer.copy(replacement, 0, snapshot.networkBoids, 0, used) end
	snapshot.networkBoids = replacement
end

return SnapshotCodec