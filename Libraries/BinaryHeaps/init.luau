--!strict
--!native

--[[ BinaryHeaps
Description:
	A simple implementation of a BinaryHeap. Stores the heap in buffers.

Public API: (self explanatory, follows common patterns for a binary heap api)
	size(binaryHeap:BinaryHeap):number
	empty(binaryHeap:BinaryHeap):boolean
	newBinaryHeap(compareWith:(priority1:number, priority2:number)->number, list, initialCapacity):BinaryHeap
	push(binaryHeap:BinaryHeap, priority:number, value:number)
	pop(binaryHeap:BinaryHeap):(number?, number?)
	peek(binaryHeap:BinaryHeap):(number?, number?)
	peekValue(binaryHeap:BinaryHeap):number?
	clear(binaryHeap:BinaryHeap)
]]

local module = {}

local SLOT_SIZE: number = 8
local INITIAL_CAPACITY: number = 4

-- Expects priority-value pair
export type BinaryHeapEntry = {number}

export type BinaryHeap = {
	priorities: buffer,
	values: buffer,

	capacity: number,
	compareWith:(priority1: number, priority2: number)-> number,
	size: number
}

------------------------------------ PRIVATE functions

local function defaultCompareWith(priority1: number, priority2: number): number
	return priority1 - priority2
end

local function getHeapPriority(binaryHeap: BinaryHeap, index: number): number
	return buffer.readf64(binaryHeap.priorities, index * SLOT_SIZE)
end

local function getHeapValue(binaryHeap: BinaryHeap, index: number): number
	return buffer.readf64(binaryHeap.values, index * SLOT_SIZE)
end

local function getHeapPair(binaryHeap: BinaryHeap, index: number): (number, number)
	local offset: number = index * SLOT_SIZE
	return
		buffer.readf64(binaryHeap.priorities, offset),
		buffer.readf64(binaryHeap.values, offset)
end

local function ensureCapacity(binaryHeap: BinaryHeap, requiredIndex: number)
	if (requiredIndex < binaryHeap.capacity) then
		return
	end

	local capacity: number = binaryHeap.capacity
	if (capacity < 1) then
		capacity = 1
	end

	while capacity <= requiredIndex do
		capacity *= 2
	end

	local oldBufferSize: number = binaryHeap.capacity * SLOT_SIZE
	local newBufferSize: number = capacity * SLOT_SIZE

	local newPriorities: buffer = buffer.create(newBufferSize)
	buffer.copy(newPriorities, 0, binaryHeap.priorities, 0, oldBufferSize)
	binaryHeap.priorities = newPriorities

	local newValues: buffer = buffer.create(newBufferSize)
	buffer.copy(newValues, 0, binaryHeap.values, 0, oldBufferSize)
	binaryHeap.values = newValues

	binaryHeap.capacity = capacity
end

local function setHeapPair(binaryHeap: BinaryHeap, index: number, priority: number, value: number)
	ensureCapacity(binaryHeap, index)

	local offset: number = index * SLOT_SIZE
	buffer.writef64(binaryHeap.priorities, offset, priority)
	buffer.writef64(binaryHeap.values, offset, value)
end

local function parent(index: number): number?
	if index <= 0 then
		return nil
	end

	return (index - 1) // 2
end

local function left(binaryHeap: BinaryHeap, index: number): number?
	local leftIndex: number = index * 2 + 1
	if leftIndex < binaryHeap.size then
		return leftIndex
	end
	return nil
end

local function right(binaryHeap: BinaryHeap, index: number): number?
	local rightIndex: number = index * 2 + 2
	if rightIndex < binaryHeap.size then
		return rightIndex
	end
	return nil
end

local function swap(binaryHeap: BinaryHeap, index1: number, index2: number)
	local priority1: number, value1: number = getHeapPair(binaryHeap, index1)
	local priority2: number, value2: number = getHeapPair(binaryHeap, index2)

	setHeapPair(binaryHeap, index1, priority2, value2)
	setHeapPair(binaryHeap, index2, priority1, value1)
end

local function upwardsHeapify(binaryHeap: BinaryHeap, index: number)
	local parentIndex: number? = parent(index)
	if parentIndex and binaryHeap.compareWith(getHeapPriority(binaryHeap, parentIndex), getHeapPriority(binaryHeap, index)) > 0 then
		swap(binaryHeap, index, parentIndex)
		upwardsHeapify(binaryHeap, parentIndex)
	end
end

local function downwardsHeapify(binaryHeap: BinaryHeap, index: number)
	local smallest: number = index
	local leftIndex: number? = left(binaryHeap, index)
	local rightIndex: number? = right(binaryHeap, index)

	if leftIndex and binaryHeap.compareWith(getHeapPriority(binaryHeap, smallest), getHeapPriority(binaryHeap, leftIndex)) > 0 then
		smallest = leftIndex
	end
	if rightIndex and binaryHeap.compareWith(getHeapPriority(binaryHeap, smallest), getHeapPriority(binaryHeap, rightIndex)) > 0 then
		smallest = rightIndex
	end
	if index ~= smallest then
		swap(binaryHeap, smallest, index)
		downwardsHeapify(binaryHeap, smallest)
	end
end

------------------------------------ PUBLIC functions

function module.newBinaryHeap(compareWith: ((priority1: number, priority2: number)->number)?, list: {BinaryHeapEntry}?, initialCapacity: number?): BinaryHeap
	local capacity: number = initialCapacity or INITIAL_CAPACITY
	if list then
		capacity = math.max(capacity, #list)
	end

	local bufferSize: number = capacity * SLOT_SIZE
	local binaryHeap: BinaryHeap = {
		priorities = buffer.create(bufferSize),
		values = buffer.create(bufferSize),

		capacity = capacity,
		compareWith = compareWith or defaultCompareWith,
		size = 0
	}

	if not list then
		return binaryHeap
	end

	for index: number, heapEntry: BinaryHeapEntry in list do
		setHeapPair(binaryHeap, index - 1, heapEntry[1], heapEntry[2])
	end
	binaryHeap.size = #list

	if binaryHeap.size > 1 then
		for index: number = (binaryHeap.size - 2) // 2, 0, -1 do
			downwardsHeapify(binaryHeap, index)
		end
	end

	return binaryHeap
end

function module.size(binaryHeap: BinaryHeap): number
	return binaryHeap.size
end

function module.empty(binaryHeap: BinaryHeap): boolean
	return binaryHeap.size == 0
end

function module.push(binaryHeap: BinaryHeap, priority: number, value: number)
	local newIndex: number = binaryHeap.size
	setHeapPair(binaryHeap, newIndex, priority, value)
	binaryHeap.size += 1
	upwardsHeapify(binaryHeap, newIndex)
end

function module.pop(binaryHeap: BinaryHeap): (number?, number?)
	if binaryHeap.size == 0 then
		return nil, nil
	end

	local smallestPriority: number, smallestValue: number = getHeapPair(binaryHeap, 0)

	binaryHeap.size -= 1
	if binaryHeap.size > 0 then
		local lastPriority: number, lastValue: number = getHeapPair(binaryHeap, binaryHeap.size)
		setHeapPair(binaryHeap, 0, lastPriority, lastValue)
		downwardsHeapify(binaryHeap, 0)
	end

	return smallestPriority, smallestValue
end

function module.peek(binaryHeap: BinaryHeap): (number?, number?)
	if binaryHeap.size == 0 then
		return nil, nil
	end

	return getHeapPair(binaryHeap, 0)
end

function module.peekValue(binaryHeap: BinaryHeap): number?
	if binaryHeap.size == 0 then
		return nil
	end

	return getHeapValue(binaryHeap, 0)
end

function module.clear(binaryHeap: BinaryHeap)
	binaryHeap.size = 0
end

return module