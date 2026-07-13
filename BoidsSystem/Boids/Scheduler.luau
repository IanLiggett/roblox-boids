--!strict
--!native

--[[ Scheduler
Description:
	Generic heap-backed scheduler for entities with numeric ids. Uses lazy heap
	invalidation to enqueue schedulees cheaply while discarding stale heap nodes
	when they reach the top.

Public API:
	newScheduler<T>(wakeTimeCalculator: (Schedulee<T>) -> number, scheduleeValidator: (Schedulee<T>, number) -> boolean, compare: ((number, number) -> number)?): Scheduler<T>
	newSchedulee<T>(scheduler: Scheduler<T>, entity: T & { id: number }, interval: number): Schedulee<T>
	enqueueSchedulee<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>): ()
	scheduleSchedulee<T>(schedulee: Schedulee<T>): ()
	releaseSchedulee<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>): ()
	markScheduleeCompleted<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>, completionTime: number): ()
	getNextSchedulee<T>(scheduler: Scheduler<T>, now: number): Schedulee<T>?
	peekNextWakeTime<T>(scheduler: Scheduler<T>): number?
	rebuildSchedulerHeap<T>(scheduler: Scheduler<T>): ()
]]

local module = {}

local BoidsReplicated = game:GetService("ReplicatedStorage"):WaitForChild("BoidsReplicated") :: typeof(script.Parent.Parent.BoidsReplicated)

local Dependencies = BoidsReplicated.Dependencies

local BinaryHeaps = require(Dependencies.BinaryHeaps.Value)

type ScheduleeEntityShape<T> = T & {
	id: number
}

export type HeapNode = {
	scheduleeId: number,
	version: number,
	wakeTime: number,
}

export type Schedulee<T> = {
	entity: ScheduleeEntityShape<T>,
	alreadyScheduled: boolean,

	lastUpdated: number,
	nextDue: number,
	
	interval: number,
	intervalMultiplier: number,

	heapVersion: number,
}

export type Scheduler<T> = {
	schedulees: {[number]: Schedulee<T>},

	heap: BinaryHeaps.BinaryHeap,
	heapNodes: {[number]: HeapNode},
	nextHeapNodeId: number,

	wakeTimeCalculator: (Schedulee<T>) -> number,
	scheduleeValidator: (Schedulee<T>, number) -> boolean,
}

function module.newScheduler<T>(
	wakeTimeCalculator: (Schedulee<T>) -> number,
	scheduleeValidator: (Schedulee<T>, number) -> boolean,
	compare: ((wakeTime1: number, wakeTime2: number)->number)?
): Scheduler<T>
	local heapNodes: {[number]: HeapNode} = {}

	local heap: BinaryHeaps.BinaryHeap = BinaryHeaps.newBinaryHeap(compare)

	return {
		schedulees = {},

		heap = heap,
		heapNodes = heapNodes,
		nextHeapNodeId = 0,

		wakeTimeCalculator = wakeTimeCalculator,
		scheduleeValidator = scheduleeValidator,
	}
end

local function scheduleeJitter(id: number): number
	return (id % 997) / 997 * 0.5
end

function module.newSchedulee<T>(scheduler: Scheduler<T>, entity: ScheduleeEntityShape<T>, interval: number): Schedulee<T>
	local now: number = workspace:GetServerTimeNow()

	local schedulee: Schedulee<T> = {
		entity = entity,
		alreadyScheduled = false,

		nextDue = now + scheduleeJitter(entity.id),
		lastUpdated = now,
		
		interval = interval,
		intervalMultiplier = 1,

		heapVersion = 0,
	}

	scheduler.schedulees[entity.id] = schedulee
	module.enqueueSchedulee(scheduler, schedulee)

	return schedulee
end

function module.effectiveInterval<T>(schedulee: Schedulee<T>): number
	return schedulee.interval * schedulee.intervalMultiplier
end

function module.setIntervalMultiplier<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>, multiplier: number, now: number)
	multiplier = math.max(1, multiplier // 1)

	const oldInterval = module.effectiveInterval(schedulee)
	if schedulee.intervalMultiplier == multiplier then
		return
	end

	schedulee.intervalMultiplier = multiplier

	const newInterval = module.effectiveInterval(schedulee)
	const targetDue = schedulee.lastUpdated + newInterval

	if newInterval < oldInterval then
		schedulee.nextDue = math.min(schedulee.nextDue, targetDue)
	else
		schedulee.nextDue = math.max(schedulee.nextDue, targetDue)
	end

	if not schedulee.alreadyScheduled then
		module.enqueueSchedulee(scheduler, schedulee)
	else
		schedulee.heapVersion += 1
	end
end

function module.scheduleSchedulee<T>(schedulee: Schedulee<T>)
	schedulee.alreadyScheduled = true
	schedulee.heapVersion += 1
end

function module.enqueueSchedulee<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>)
	schedulee.heapVersion += 1

	scheduler.nextHeapNodeId += 1
	local nodeId: number = scheduler.nextHeapNodeId
	local wakeTime: number = scheduler.wakeTimeCalculator(schedulee)

	scheduler.heapNodes[nodeId] = {
		scheduleeId = schedulee.entity.id,
		version = schedulee.heapVersion,
		wakeTime = wakeTime,
	}

	BinaryHeaps.push(scheduler.heap, wakeTime, nodeId)
end

function module.releaseSchedulee<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>)
	schedulee.alreadyScheduled = false
	module.enqueueSchedulee(scheduler, schedulee)
end

function module.markScheduleeCompleted<T>(scheduler: Scheduler<T>, schedulee: Schedulee<T>, completionTime: number)
	local interval: number = schedulee.interval

	schedulee.lastUpdated = completionTime

	repeat
		schedulee.nextDue += interval
	until schedulee.nextDue > completionTime

	module.releaseSchedulee(scheduler, schedulee)
end

local function findNextValidSchedulee<T>(scheduler: Scheduler<T>): (Schedulee<T>?, HeapNode?, number?)
	local heapNodes: {[number]: HeapNode} = scheduler.heapNodes
	local schedulees: {[number]: Schedulee<T>} = scheduler.schedulees

	local wakeTime: number?
	local nodeId: number?
	local node: HeapNode?
	local schedulee: Schedulee<T>?

	while true do
		wakeTime, nodeId = BinaryHeaps.peek(scheduler.heap)
		if not nodeId then
			return nil, nil, nil
		end

		node = heapNodes[nodeId]
		if not node then
			BinaryHeaps.pop(scheduler.heap)
			continue
		end

		schedulee = schedulees[node.scheduleeId]
		if not schedulee or node.version ~= schedulee.heapVersion then
			BinaryHeaps.pop(scheduler.heap)
			heapNodes[nodeId] = nil
			continue
		end

		return schedulee, node, nodeId
	end
end

function module.getNextSchedulee<T>(scheduler: Scheduler<T>, now: number): Schedulee<T>?
	local schedulee: Schedulee<T>?
	local node: HeapNode?
	local nodeId: number?

	while true do
		schedulee, node, nodeId = findNextValidSchedulee(scheduler)
		if not node or not schedulee or not nodeId or node.wakeTime > now then
			return nil
		end

		BinaryHeaps.pop(scheduler.heap)
		scheduler.heapNodes[nodeId] = nil

		if scheduler.scheduleeValidator(schedulee, now) then
			return schedulee
		end
	end
end

function module.peekNextWakeTime<T>(scheduler: Scheduler<T>): number?
	local schedulee: Schedulee<T>?
	local node: HeapNode?

	schedulee, node = findNextValidSchedulee(scheduler)

	return node and node.wakeTime or nil
end

function module.rebuildSchedulerHeap<T>(scheduler: Scheduler<T>)
	BinaryHeaps.clear(scheduler.heap)
	table.clear(scheduler.heapNodes)
	scheduler.nextHeapNodeId = 0

	for _, schedulee: Schedulee<T> in scheduler.schedulees do
		if not schedulee.alreadyScheduled then
			module.enqueueSchedulee(scheduler, schedulee)
		end
	end
end

return module
