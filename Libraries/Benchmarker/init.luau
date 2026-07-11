--!strict
--!native

--[[ Benchmarker
Description:
	Rolling-window numeric statistics helper. Tracks average, median, min, max,
	standard deviation, and optional stale counts using buffer-backed lazy heaps.

Public API:
	newBenchmarker(windowLength: number?, staleThreshold: number?): Benchmarker
	push(benchmarker: Benchmarker, item: number): ()
	getMin(benchmarker: Benchmarker): number?
	getMax(benchmarker: Benchmarker): number?
	getAvg(benchmarker: Benchmarker): number
	getMed(benchmarker: Benchmarker): number
	getSD(benchmarker: Benchmarker): number
	printStats(benchmarker: Benchmarker): ()
	clear(benchmarker: Benchmarker): ()
]]

local module = {}

local Dependencies = script.Dependencies

local SlidingHeaps = require(Dependencies.SlidingHeaps.Value)
local LazyHeaps = require(Dependencies.SlidingHeaps.Value.Parent)

type LazyHeap = LazyHeaps.LazyHeap
type SlidingHeap = SlidingHeaps.SlidingHeap

local VALUE_SIZE: number = 8
local ID_SIZE: number = 4
local SIDE_SIZE: number = 1

local SIDE_NONE: number = 0
local SIDE_LOWER: number = 1
local SIDE_UPPER: number = 2

local MAX_WINDOW_LENGTH: number = 500000

local DEFAULT_WINDOW_LENGTH: number = 50000

export type Benchmarker = {
	windowLength: number,
	
	isValid: (id: number)->boolean,
	
	lowerHeap: LazyHeap,
	upperHeap: LazyHeap,
	minHeap: LazyHeap,
	maxHeap: LazyHeap,
	
	values: buffer,
	activeIds: buffer,
	sides: buffer,
	
	streamCount: number,
	itemCount: number,
	
	lowerSize: number,
	upperSize: number,
	
	staleThreshold: number?,
	staleCount: number,
	
	itemSum: number,
	itemSqrSum: number,
	
	avg: number,
	med: number,
	min: number,
	max: number,
	SD: number
}

local function maxHeapCompare(num1: number, num2: number): number
	return num2 - num1
end

local function idToSlot(id: number, windowLength: number): number
	return id % windowLength
end

function module.newBenchmarker(windowLength: number?, staleThreshold: number?): Benchmarker
	windowLength = math.clamp(windowLength or DEFAULT_WINDOW_LENGTH, 1, MAX_WINDOW_LENGTH)
	
	local activeIds: buffer = buffer.create(windowLength * ID_SIZE)
	local function isValid(id: number): boolean
		return buffer.readu32(activeIds, idToSlot(id, windowLength :: number) * ID_SIZE) == id
	end
	
	local benchmarker: Benchmarker = {
		windowLength = windowLength,
		
		isValid = isValid,
		
		lowerHeap = LazyHeaps.newLazyHeap(isValid, maxHeapCompare, nil, windowLength),
		upperHeap = LazyHeaps.newLazyHeap(isValid, nil, nil, windowLength),
		minHeap = LazyHeaps.newLazyHeap(isValid, nil, nil, windowLength),
		maxHeap = LazyHeaps.newLazyHeap(isValid, maxHeapCompare, nil, windowLength),
		
		values = buffer.create(windowLength * VALUE_SIZE),
		activeIds = activeIds,
		sides = buffer.create(windowLength * SIDE_SIZE),
		
		streamCount = 0,
		itemCount = 0,
		
		lowerSize = 0,
		upperSize = 0,
		
		staleThreshold = staleThreshold,
		staleCount = 0,
				
		itemSum = 0,
		itemSqrSum = 0,
		
		avg = 0,
		med = 0,
		min = math.huge,
		max = -math.huge,
		SD = 0
	}
	
	return benchmarker
end

function module.getMin(benchmarker:Benchmarker): number?
	return benchmarker.min
end

function module.getMax(benchmarker:Benchmarker): number?
	return benchmarker.max
end

function module.getAvg(benchmarker:Benchmarker): number
	return benchmarker.avg
end

function module.getMed(benchmarker:Benchmarker): number
	return benchmarker.med
end

function module.getSD(benchmarker:Benchmarker): number
	return benchmarker.SD
end

local function moveLowerToUpper(benchmarker: Benchmarker)
	local item: number?, id: number? = LazyHeaps.pop(benchmarker.lowerHeap)

	LazyHeaps.push(benchmarker.upperHeap, item :: number, id :: number)

	benchmarker.lowerSize -= 1
	benchmarker.upperSize += 1

	local slot: number = idToSlot(id :: number, benchmarker.windowLength)
	buffer.writeu8(benchmarker.sides, slot * SIDE_SIZE, SIDE_UPPER)
end

local function moveUpperToLower(benchmarker: Benchmarker)
	local item: number?, id: number? = LazyHeaps.pop(benchmarker.upperHeap)

	LazyHeaps.push(benchmarker.lowerHeap, item :: number, id :: number)

	benchmarker.upperSize -= 1
	benchmarker.lowerSize += 1

	local slot: number = idToSlot(id :: number, benchmarker.windowLength)
	buffer.writeu8(benchmarker.sides, slot * SIDE_SIZE, SIDE_LOWER)
end

local function rebalance(benchmarker: Benchmarker)
	while benchmarker.lowerSize > benchmarker.upperSize + 1 do
		moveLowerToUpper(benchmarker)
	end

	while benchmarker.upperSize > benchmarker.lowerSize do
		moveUpperToLower(benchmarker)
	end
end

local function updateStats(benchmarker: Benchmarker)
	local itemCount: number = benchmarker.itemCount
	if itemCount == 0 then
		benchmarker.avg = 0
		benchmarker.med = 0
		benchmarker.min = 0
		benchmarker.max = 0
		benchmarker.SD = 0
		return
	end
	
	-- calculate new average
	benchmarker.avg = benchmarker.itemSum / itemCount
	
	-- calculate new standard deviation
	benchmarker.SD = math.sqrt(math.max(benchmarker.itemSqrSum / itemCount - benchmarker.avg ^ 2, 0))
	
	-- calculate new max/min
	benchmarker.min = LazyHeaps.peek(benchmarker.minHeap) or 0
	benchmarker.max = LazyHeaps.peek(benchmarker.maxHeap) or 0
	
	-- calculate new median
	local lowerTop: number = LazyHeaps.peek(benchmarker.lowerHeap) :: number
	if benchmarker.itemCount % 2 == 1 then
		benchmarker.med = lowerTop
	else
		local upperTop: number = LazyHeaps.peek(benchmarker.upperHeap) :: number
		benchmarker.med = (lowerTop + upperTop) / 2
	end
end

local function rebuildHeaps(benchmarker: Benchmarker)
	local windowLength: number = benchmarker.windowLength

	benchmarker.lowerHeap = LazyHeaps.newLazyHeap(benchmarker.isValid, maxHeapCompare, nil, windowLength)
	benchmarker.upperHeap = LazyHeaps.newLazyHeap(benchmarker.isValid, nil, nil, windowLength)

	benchmarker.minHeap = LazyHeaps.newLazyHeap(benchmarker.isValid, nil, nil, windowLength)
	benchmarker.maxHeap = LazyHeaps.newLazyHeap(benchmarker.isValid, maxHeapCompare, nil, windowLength)

	benchmarker.lowerSize = 0
	benchmarker.upperSize = 0

	local firstActiveId: number = benchmarker.streamCount - benchmarker.itemCount

	for slot: number = 0, windowLength - 1 do
		local idOffset: number = slot * ID_SIZE
		local valueOffset: number = slot * VALUE_SIZE
		local sideOffset: number = slot * SIDE_SIZE

		local id: number = buffer.readu32(benchmarker.activeIds, idOffset)

		if id >= firstActiveId and id < benchmarker.streamCount then
			local value: number = buffer.readf64(benchmarker.values, valueOffset)

			LazyHeaps.push(benchmarker.lowerHeap, value, id)
			LazyHeaps.push(benchmarker.minHeap, value, id)
			LazyHeaps.push(benchmarker.maxHeap, value, id)

			buffer.writeu8(benchmarker.sides, sideOffset, SIDE_LOWER)
			benchmarker.lowerSize += 1
		else
			buffer.writeu8(benchmarker.sides, sideOffset, SIDE_NONE)
		end
	end

	rebalance(benchmarker)
	updateStats(benchmarker)
end
function module.push(benchmarker: Benchmarker, item: number)
	local lowerHeap: LazyHeap, upperHeap: LazyHeap = benchmarker.lowerHeap, benchmarker.upperHeap
	local windowLength: number = benchmarker.windowLength
	local currentId: number = benchmarker.streamCount
	local slot: number = idToSlot(currentId, windowLength)

	local valueOffset: number = slot * VALUE_SIZE
	local idOffset: number = slot * ID_SIZE
	local sideOffset: number = slot * SIDE_SIZE
	
	-- push out expired value from window
	if benchmarker.itemCount == windowLength then
		local expiredValue: number = buffer.readf64(benchmarker.values, valueOffset)
		local expiredSide: number = buffer.readu8(benchmarker.sides, sideOffset)
		
		if benchmarker.staleThreshold and expiredValue >= benchmarker.staleThreshold then
			benchmarker.staleCount -= 1
		end
		benchmarker.itemSum -= expiredValue
		benchmarker.itemSqrSum -= expiredValue ^ 2

		if expiredSide == SIDE_LOWER then
			benchmarker.lowerSize -= 1
		else
			benchmarker.upperSize -= 1
		end
	else
		benchmarker.itemCount += 1
	end

	-- update bookkeeping
	buffer.writef64(benchmarker.values, valueOffset, item)
	buffer.writeu32(benchmarker.activeIds, idOffset, currentId)
	
	if benchmarker.staleThreshold and item >= benchmarker.staleThreshold then
		benchmarker.staleCount += 1
	end
	benchmarker.itemSum += item
	benchmarker.itemSqrSum += item * item
	
	-- push new value onto correct side
	local lowerTop: number?
	if benchmarker.lowerSize > 0 then
		lowerTop = LazyHeaps.peek(benchmarker.lowerHeap)
	end
	if not lowerTop or item <= lowerTop then
		LazyHeaps.push(benchmarker.lowerHeap, item, currentId)
		buffer.writeu8(benchmarker.sides, sideOffset, SIDE_LOWER)
		benchmarker.lowerSize += 1
	else
		LazyHeaps.push(benchmarker.upperHeap, item, currentId)
		buffer.writeu8(benchmarker.sides, sideOffset, SIDE_UPPER)
		benchmarker.upperSize += 1
	end
	
	-- uses same lazy invalidation as other heaps, so don't need to do anything more here
	LazyHeaps.push(benchmarker.minHeap, item, currentId)
	LazyHeaps.push(benchmarker.maxHeap, item, currentId)
	
	rebalance(benchmarker)
	updateStats(benchmarker)
	
	benchmarker.streamCount += 1
	
	if benchmarker.streamCount % benchmarker.windowLength == 0 then
		rebuildHeaps(benchmarker)
	end
end

function module.printStats(benchmarker: Benchmarker)
	local msg: string = `TOTAL: {benchmarker.itemCount} | AVG: {benchmarker.avg} | MED: {benchmarker.med} | MIN: {benchmarker.min} | MAX: {benchmarker.max} | SD: {benchmarker.SD }`
	
	if benchmarker.staleThreshold then
		msg ..= ` | STALE: {benchmarker.staleCount}`
	end
	
	if benchmarker.staleCount > 0 then
		warn(msg)
	else
		print(msg)
	end
	--print(`Avg: {module.getAvg(benchmarker)}, Med: {module.getMed(benchmarker)}, Min: {module.getMin(benchmarker)}, Max: {module.getMax(benchmarker)}`)
end

function module.clear(benchmarker: Benchmarker)
	-- clear stuff
	
	benchmarker.itemCount = 0

	benchmarker.itemSum = 0
	benchmarker.itemSqrSum = 0

	benchmarker.avg = 0
	benchmarker.med = 0
	benchmarker.min = math.huge
	benchmarker.max = -math.huge
	
	benchmarker.SD = 0
end

return module
