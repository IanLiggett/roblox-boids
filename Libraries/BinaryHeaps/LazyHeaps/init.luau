--!strict
--!native

--[[ LazyHeaps
Description:
	Binary heap wrapper that lazily removes invalid values from the top using a
	caller-provided id validator.

Public API:
	newLazyHeap(isValid: (id: number) -> boolean, compareWith: ((number, number) -> number)?, list: {BinaryHeapEntry}?, initialCapacity: number?): LazyHeap
	size(lazyHeap: LazyHeap): number
	empty(lazyHeap: LazyHeap): boolean
	push(lazyHeap: LazyHeap, priority: number, value: number): ()
	pop(lazyHeap: LazyHeap): (number?, number?)
	peek(lazyHeap: LazyHeap): (number?, number?)
	peekValue(lazyHeap: LazyHeap): number?
	clear(lazyHeap: LazyHeap): ()
]]

local module = {}

local BinaryHeaps = require(script.Parent)
type BinaryHeap = BinaryHeaps.BinaryHeap
export type BinaryHeapEntry = BinaryHeaps.BinaryHeapEntry

type Value = number

export type LazyHeap = {
	isValid: (id: number)->boolean
} & BinaryHeap

function module.newLazyHeap(isValid: (id: number)->boolean, compareWith: ((item1: number, item2: number)->number)?, list: {BinaryHeapEntry}?, initialCapacity: number?): LazyHeap
	local lazyHeap: LazyHeap = BinaryHeaps.newBinaryHeap(compareWith, list, initialCapacity) :: LazyHeap
	lazyHeap.isValid = isValid
	
	return lazyHeap
end

module.size = BinaryHeaps.size
module.empty = BinaryHeaps.empty

module.push = BinaryHeaps.push

local function cleanHeap(lazyHeap: LazyHeap)
	local id: number?
	while lazyHeap.size > 0 do
		id = BinaryHeaps.peekValue(lazyHeap)
		if id and lazyHeap.isValid(id) then
			break
		else
			BinaryHeaps.pop(lazyHeap)
		end
	end
end

function module.pop(lazyHeap: LazyHeap): (number?, number?)
	cleanHeap(lazyHeap)
	return BinaryHeaps.pop(lazyHeap)
end

function module.peek(lazyHeap: LazyHeap): (number?, number?)
	cleanHeap(lazyHeap)
	return BinaryHeaps.peek(lazyHeap)
end

function module.peekValue(lazyHeap: LazyHeap): number?
	cleanHeap(lazyHeap)
	return BinaryHeaps.peekValue(lazyHeap)
end

module.clear = BinaryHeaps.clear

return module
