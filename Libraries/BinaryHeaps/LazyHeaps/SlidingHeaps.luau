--!strict
--!native

--[[ SlidingHeaps
Description:
	Lazy heap variant for a fixed-size sliding window of numeric values. New
	pushes invalidate values that fall out of the window.

Public API:
	newSlidingHeap(windowLength: number?, compareWith: ((number, number) -> number)?, list: {BinaryHeapEntry}?): SlidingHeap
	size(slidingHeap: SlidingHeap): number
	empty(slidingHeap: SlidingHeap): boolean
	push(slidingHeap: SlidingHeap, value: number): number?
	pop(slidingHeap: SlidingHeap): number?
	peek(slidingHeap: SlidingHeap): number?
	clear(slidingHeap: SlidingHeap): ()
]]

local module = {}

local LazyHeaps = require(script.Parent)
type LazyHeap = LazyHeaps.LazyHeap
type BinaryHeapEntry = LazyHeaps.BinaryHeapEntry

local SLOT_SIZE: number = 8
local ID_SIZE: number = 4
local MAX_WINDOW_LENGTH: number = 500000

local DEFAULT_WINDOW_LENGTH: number = 50000

export type SlidingHeap = {
	windowLength: number,
	streamCount: number,
	
	activeIds: buffer,
	history: buffer
} & LazyHeap

local function streamIdToSlot(id: number, windowLength: number): number
	return id % windowLength
end

function module.newSlidingHeap(windowLength: number?, compareWith: ((item1: number, item2: number)->number)?, list: {BinaryHeapEntry}?): SlidingHeap
	windowLength = windowLength or DEFAULT_WINDOW_LENGTH
	if windowLength < 2 or windowLength > MAX_WINDOW_LENGTH then
		error(`{windowLength} is not a valid window length`)
	end
	
	local activeIds: buffer = buffer.create(windowLength * ID_SIZE)
	local function isValid(id: number): boolean
		return buffer.readu32(activeIds, streamIdToSlot(id, windowLength :: number) * ID_SIZE) == id
	end
	
	local slidingHeap: SlidingHeap = LazyHeaps.newLazyHeap(isValid, compareWith, list, windowLength) :: SlidingHeap
	slidingHeap.activeIds = activeIds
	slidingHeap.history = buffer.create(windowLength * SLOT_SIZE)
	slidingHeap.windowLength = windowLength
	slidingHeap.streamCount = 0
	
	return slidingHeap
end

module.size = LazyHeaps.size
module.empty = LazyHeaps.empty

function module.push(slidingHeap: SlidingHeap, value: number): number?
	local windowLength: number = slidingHeap.windowLength
	local currentId: number = slidingHeap.streamCount
	local slot: number = streamIdToSlot(currentId, windowLength)
	local historyOffset: number = slot * SLOT_SIZE
	
	local expiredValue: number?
	if currentId >= windowLength then
		expiredValue = buffer.readf64(slidingHeap.history, historyOffset)
	end
	
	buffer.writef64(slidingHeap.history, historyOffset, value)
	buffer.writeu32(slidingHeap.activeIds, slot * ID_SIZE, currentId)
	
	LazyHeaps.push(slidingHeap, value, currentId)
	
	slidingHeap.streamCount += 1
	
	return expiredValue
end

function module.pop(slidingHeap: SlidingHeap): number?
	local value: number?, _ = LazyHeaps.pop(slidingHeap)
	return value
end

function module.peek(slidingHeap: SlidingHeap): number?
	local value: number?, _ = LazyHeaps.peek(slidingHeap)
	return value
end

function module.size(slidingHeap: SlidingHeap): number
	return slidingHeap.size
end

function module.clear(slidingHeap: SlidingHeap)
	slidingHeap.streamCount = 0
	LazyHeaps.clear(slidingHeap)
end

return module
