--!strict

--[[ SharedTypes
Description:
	Shared type definitions and boid model ids used by server, Actor workers,
	replicated storage helpers, and client rendering code.

Public API:
	Exported types: Page, PagedBuffer, Target, BoidPacket, SnapshotPackets,
	CellSnapshot, SimulationSnapshot, JobCell, Job, NetworkBoidsBatch,
	BoidModelName, and BoidModel.
	BoidModels: frozen map of model names to numeric ids
	BoidModelNames: reverse lookup from numeric ids to model names
]]

local module = {}

export type Page = {
	id: number,
	setId: number,

	index: number,
	size: number,

	deadCount: number,
	firstDeadWord: number,
	cursor: number,

	data: buffer,
	dead: buffer,
}

export type PagedBuffer = {
	id: number,
	pages: {Page},
	openPages:{[number]: boolean},
	pendingPages:{[number]: boolean},

	pageCount: number
}

export type Target = {
	Position: Vector3
}

export type BoidPacket = buffer
export type SnapshotPackets = {BoidPacket}

export type CellSnapshot = {
	origin: Vector3,
	boidCount: number,

	networkBoids: buffer
}
export type SimulationSnapshot = {[number]: CellSnapshot}

export type JobCell = {
	id: number,
	origin: Vector3,
	
	networkTick: number,
	networkInterval: number,
	
	pages: PagedBuffer,
	pageCount: number,
	boidCount: number,
}

export type Job = {
	id: number,
	groupId: number,
	
	snapshotPackets: SnapshotPackets?,
	
	jobCells:{[number]:JobCell},
	movedBoids:{[number]:{number | Vector3}},
	
	cellCount: number,
	
	startTime: number,
	completionTime: number,
	estimatedCost: number,
	
	averageSight: number,
	
	-- benchmarking
	neighborIterations: number
}

export type NetworkBoidsBatch = {
	groupId: number,
	boidCount: number,
	boidModels: buffer,
	boidIds: buffer,
}


module.BoidModels = {
	Boid = 1,
	BoidSphere = 2,
	Predator = 3,
}

type BoidModels = typeof(module.BoidModels)

export type BoidModelName = keyof<BoidModels>
export type BoidModel = index<BoidModels, BoidModelName>

module.BoidModelNames = {}
for k, v in module.BoidModels :: any do
	module.BoidModelNames[v] = k
end

table.freeze(module.BoidModels)

return module
