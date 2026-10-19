--!native
--!strict
--[[ Sparse 32-stud broad phase for exact boid sphere queries. ]]
local Quantization = require(script.Parent.Quantization)

local BoidQueryIndex = {}
BoidQueryIndex.CELL_SIZE = 32

export type Hit = {
	boidId: number,
	position: Vector3,
	distance: number,
	normal: Vector3,
}

export type Metrics = {
	entryCount: number,
	queryCount: number,
	candidateCount: number,
	exactTestCount: number,
	p50Ms: number,
	p95Ms: number,
}

export type Index = {
	Update: (self: Index, boidId: number, position: Vector3, radius: number) -> (),
	Remove: (self: Index, boidId: number) -> (),
	Raycast: (self: Index, origin: Vector3, direction: Vector3, sweepRadius: number?, ignoredBoidIds: {[number]: boolean}?) -> Hit?,
	QueryRadius: (self: Index, center: Vector3, radius: number, ignoredBoidIds: {[number]: boolean}?) -> {Hit},
	GetEntry: (self: Index, boidId: number) -> {position: Vector3, radius: number}?,
	GetMetrics: (self: Index) -> Metrics,
	GetCount: (self: Index) -> number,
}

type Entry = {
	position: Vector3,
	radius: number,
	cellKey: number,
	slot: number,
}

type Bucket = {
	boidIds: {number},
	slotByBoidId: {[number]: number},
}

type PrivateIndex = {
	entries: {[number]: Entry},
	buckets: {[number]: Bucket},
	maxRadius: number,
	count: number,
	queryEpoch: number,
	seenEpochByBoidId: {[number]: number},
	seenEpochByCellKey: {[number]: number},
	queryTimesMs: {number},
	queryTimeCursor: number,
	querySampleCount: number,
	queryCount: number,
	candidateCount: number,
	exactTestCount: number,
}

local Index = {}
Index.__index = Index

local CELL_SIZE = BoidQueryIndex.CELL_SIZE
local EPSILON = 1e-7
local METRIC_SAMPLE_COUNT = 120

local function cellCoordinates(position: Vector3): (number, number, number)
	return math.floor(position.X / CELL_SIZE), math.floor(position.Y / CELL_SIZE), math.floor(position.Z / CELL_SIZE)
end

local function cellKey(x: number, y: number, z: number): number
	return Quantization.GetNumericalKey(x, y, z)
end

local function removeFromBucket(self: PrivateIndex, boidId: number, entry: Entry): ()
	local bucket = self.buckets[entry.cellKey]
	if not bucket then
		return
	end
	local slot = entry.slot
	local lastSlot = #bucket.boidIds
	local movedBoidId = bucket.boidIds[lastSlot]
	bucket.boidIds[slot] = movedBoidId
	bucket.slotByBoidId[movedBoidId] = slot
	self.entries[movedBoidId].slot = slot
	bucket.boidIds[lastSlot] = nil
	bucket.slotByBoidId[boidId] = nil
	if lastSlot == 1 then
		self.buckets[entry.cellKey] = nil
	end
end

local function insertIntoBucket(self: PrivateIndex, boidId: number, entry: Entry): ()
	local bucket = self.buckets[entry.cellKey]
	if not bucket then
		bucket = { boidIds = {}, slotByBoidId = {} }
		self.buckets[entry.cellKey] = bucket
	end
	entry.slot = #bucket.boidIds + 1
	bucket.boidIds[entry.slot] = boidId
	bucket.slotByBoidId[boidId] = entry.slot
end

function BoidQueryIndex.new(): Index
	return setmetatable({
		entries = {},
		buckets = {},
		maxRadius = 0,
		count = 0,
		queryEpoch = 0,
		seenEpochByBoidId = {},
		seenEpochByCellKey = {},
		queryTimesMs = table.create(METRIC_SAMPLE_COUNT, 0),
		queryTimeCursor = 0,
		querySampleCount = 0,
		queryCount = 0,
		candidateCount = 0,
		exactTestCount = 0,
	}, Index) :: Index
end

function Index.Update(self: PrivateIndex, boidId: number, position: Vector3, radius: number): ()
	if boidId % 1 ~= 0 or typeof(position) ~= "Vector3" or radius <= 0 then
		return
	end
	local x, y, z = cellCoordinates(position)
	local nextCellKey = cellKey(x, y, z)
	local entry = self.entries[boidId]
	if not entry then
		entry = { position = position, radius = radius, cellKey = nextCellKey, slot = 0 }
		self.entries[boidId] = entry
		self.count += 1
		insertIntoBucket(self, boidId, entry)
	else
		if entry.cellKey ~= nextCellKey then
			removeFromBucket(self, boidId, entry)
			entry.cellKey = nextCellKey
			insertIntoBucket(self, boidId, entry)
		end
		entry.position = position
		entry.radius = radius
	end
	if radius > self.maxRadius then
		self.maxRadius = radius
	end
end

function Index.Remove(self: PrivateIndex, boidId: number): ()
	local entry = self.entries[boidId]
	if not entry then
		return
	end
	removeFromBucket(self, boidId, entry)
	self.entries[boidId] = nil
	self.count -= 1
end

function Index.GetEntry(self: PrivateIndex, boidId: number): {position: Vector3, radius: number}?
	local entry = self.entries[boidId]
	if not entry then
		return nil
	end
	return { position = entry.position, radius = entry.radius }
end

function Index.GetCount(self: PrivateIndex): number
	return self.count
end

local function beginQuery(self: PrivateIndex): number
	self.queryEpoch += 1
	if self.queryEpoch > 1000000000 then
		self.queryEpoch = 1
		table.clear(self.seenEpochByBoidId)
		table.clear(self.seenEpochByCellKey)
	end
	return self.queryEpoch
end

local function recordQuery(self: PrivateIndex, startedAt: number, candidates: number, exactTests: number): ()
	self.queryCount += 1
	self.candidateCount += candidates
	self.exactTestCount += exactTests
	self.queryTimeCursor = self.queryTimeCursor % METRIC_SAMPLE_COUNT + 1
	self.querySampleCount = math.min(self.querySampleCount + 1, METRIC_SAMPLE_COUNT)
	self.queryTimesMs[self.queryTimeCursor] = (os.clock() - startedAt) * 1000
end

local function visitBucket(self: PrivateIndex, x: number, y: number, z: number, epoch: number, visit: (number, Entry) -> ()): ()
	local key = cellKey(x, y, z)
	if self.seenEpochByCellKey[key] == epoch then
		return
	end
	self.seenEpochByCellKey[key] = epoch
	local bucket = self.buckets[key]
	if not bucket then
		return
	end
	for _, boidId in bucket.boidIds do
		if self.seenEpochByBoidId[boidId] ~= epoch then
			self.seenEpochByBoidId[boidId] = epoch
			local entry = self.entries[boidId]
			if entry then
				visit(boidId, entry)
			end
		end
	end
end

local function segmentIntersectsExpandedCell(origin: Vector3, direction: Vector3, x: number, y: number, z: number, expansion: number): boolean
	local minX, minY, minZ = x * CELL_SIZE - expansion, y * CELL_SIZE - expansion, z * CELL_SIZE - expansion
	local maxX, maxY, maxZ = (x + 1) * CELL_SIZE + expansion, (y + 1) * CELL_SIZE + expansion, (z + 1) * CELL_SIZE + expansion
	local tEnter, tExit = 0, 1
	local function clip(originAxis: number, directionAxis: number, minimum: number, maximum: number): boolean
		if math.abs(directionAxis) <= EPSILON then
			return originAxis >= minimum and originAxis <= maximum
		end
		local t0 = (minimum - originAxis) / directionAxis
		local t1 = (maximum - originAxis) / directionAxis
		if t0 > t1 then
			t0, t1 = t1, t0
		end
		tEnter = math.max(tEnter, t0)
		tExit = math.min(tExit, t1)
		return tEnter <= tExit
	end
	return clip(origin.X, direction.X, minX, maxX)
		and clip(origin.Y, direction.Y, minY, maxY)
		and clip(origin.Z, direction.Z, minZ, maxZ)
end

local function visitSegmentCells(self: PrivateIndex, origin: Vector3, direction: Vector3, expansion: number, epoch: number, visit: (number, Entry) -> ()): ()
	local endPosition = origin + direction
	local x, y, z = cellCoordinates(origin)
	local endX, endY, endZ = cellCoordinates(endPosition)
	local radiusCells = math.ceil(expansion / CELL_SIZE)
	local function visitExpanded(baseX: number, baseY: number, baseZ: number): ()
		for offsetX = -radiusCells, radiusCells do
			for offsetY = -radiusCells, radiusCells do
				for offsetZ = -radiusCells, radiusCells do
					local cellX, cellY, cellZ = baseX + offsetX, baseY + offsetY, baseZ + offsetZ
					if segmentIntersectsExpandedCell(origin, direction, cellX, cellY, cellZ, expansion) then
						visitBucket(self, cellX, cellY, cellZ, epoch, visit)
					end
				end
			end
		end
	end

	local stepX = if direction.X > 0 then 1 elseif direction.X < 0 then -1 else 0
	local stepY = if direction.Y > 0 then 1 elseif direction.Y < 0 then -1 else 0
	local stepZ = if direction.Z > 0 then 1 elseif direction.Z < 0 then -1 else 0
	local tDeltaX = if stepX == 0 then math.huge else CELL_SIZE / math.abs(direction.X)
	local tDeltaY = if stepY == 0 then math.huge else CELL_SIZE / math.abs(direction.Y)
	local tDeltaZ = if stepZ == 0 then math.huge else CELL_SIZE / math.abs(direction.Z)
	local boundaryX = if stepX > 0 then (x + 1) * CELL_SIZE else x * CELL_SIZE
	local boundaryY = if stepY > 0 then (y + 1) * CELL_SIZE else y * CELL_SIZE
	local boundaryZ = if stepZ > 0 then (z + 1) * CELL_SIZE else z * CELL_SIZE
	local tMaxX = if stepX == 0 then math.huge else (boundaryX - origin.X) / direction.X
	local tMaxY = if stepY == 0 then math.huge else (boundaryY - origin.Y) / direction.Y
	local tMaxZ = if stepZ == 0 then math.huge else (boundaryZ - origin.Z) / direction.Z

	while true do
		visitExpanded(x, y, z)
		if x == endX and y == endY and z == endZ then
			break
		end
		local nextT = math.min(tMaxX, tMaxY, tMaxZ)
		if nextT > 1 + EPSILON then
			break
		end
		if tMaxX <= nextT + EPSILON then
			x += stepX
			tMaxX += tDeltaX
		end
		if tMaxY <= nextT + EPSILON then
			y += stepY
			tMaxY += tDeltaY
		end
		if tMaxZ <= nextT + EPSILON then
			z += stepZ
			tMaxZ += tDeltaZ
		end
	end
end

function Index.Raycast(self: PrivateIndex, origin: Vector3, direction: Vector3, sweepRadius: number?, ignoredBoidIds: {[number]: boolean}?): Hit?
	local startedAt = os.clock()
	local length = direction.Magnitude
	if length <= EPSILON or sweepRadius ~= nil and sweepRadius < 0 then
		recordQuery(self, startedAt, 0, 0)
		return nil
	end
	local unitDirection = direction / length
	local radius = sweepRadius or 0
	local nearest: Hit? = nil
	local candidates, exactTests = 0, 0
	local epoch = beginQuery(self)
	visitSegmentCells(self, origin, direction, self.maxRadius + radius, epoch, function(boidId: number, entry: Entry)
		if ignoredBoidIds and ignoredBoidIds[boidId] then
			return
		end
		candidates += 1
		exactTests += 1
		local combinedRadius = entry.radius + radius
		local offset = origin - entry.position
		local b = offset:Dot(unitDirection)
		local c = offset:Dot(offset) - combinedRadius * combinedRadius
		local discriminant = b * b - c
		if discriminant < 0 then
			return
		end
		local distance = -b - math.sqrt(discriminant)
		if distance < 0 then
			distance = 0
		end
		if distance > length or nearest and distance >= nearest.distance then
			return
		end
		local hitPosition = origin + unitDirection * distance
		local normalOffset = hitPosition - entry.position
		local normal = if normalOffset.Magnitude > EPSILON then normalOffset.Unit else -unitDirection
		nearest = { boidId = boidId, position = hitPosition, distance = distance, normal = normal }
	end)
	recordQuery(self, startedAt, candidates, exactTests)
	return nearest
end

function Index.QueryRadius(self: PrivateIndex, center: Vector3, radius: number, ignoredBoidIds: {[number]: boolean}?): {Hit}
	local startedAt = os.clock()
	if radius < 0 then
		recordQuery(self, startedAt, 0, 0)
		return {}
	end
	local epoch = beginQuery(self)
	local minX, minY, minZ = cellCoordinates(center - Vector3.new(radius + self.maxRadius, radius + self.maxRadius, radius + self.maxRadius))
	local maxX, maxY, maxZ = cellCoordinates(center + Vector3.new(radius + self.maxRadius, radius + self.maxRadius, radius + self.maxRadius))
	local hits: {Hit} = {}
	local candidates, exactTests = 0, 0
	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				visitBucket(self, x, y, z, epoch, function(boidId: number, entry: Entry)
					if ignoredBoidIds and ignoredBoidIds[boidId] then
						return
					end
					candidates += 1
					exactTests += 1
					local delta = entry.position - center
					local distance = delta.Magnitude
					if distance <= radius + entry.radius then
						local normal = if distance > EPSILON then delta / distance else Vector3.yAxis
						table.insert(hits, { boidId = boidId, position = entry.position, distance = distance, normal = normal })
					end
				end)
			end
		end
	end
	table.sort(hits, function(a: Hit, b: Hit): boolean
		return a.distance < b.distance
	end)
	recordQuery(self, startedAt, candidates, exactTests)
	return hits
end

function Index.GetMetrics(self: PrivateIndex): Metrics
	local count = self.querySampleCount
	local samples: {number} = table.create(count) :: {number}
	for index = 1, count do
		samples[index] = self.queryTimesMs[index]
	end
	table.sort(samples)
	return {
		entryCount = self.count,
		queryCount = self.queryCount,
		candidateCount = self.candidateCount,
		exactTestCount = self.exactTestCount,
		p50Ms = if count > 0 then samples[math.max(1, math.ceil(count * 0.5))] else 0,
		p95Ms = if count > 0 then samples[math.max(1, math.ceil(count * 0.95))] else 0,
	}
end

return BoidQueryIndex
