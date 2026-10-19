--!strict

local BoidsReplicated = script.Parent
local Dependencies = BoidsReplicated.Dependencies

local BinaryHeaps = require(Dependencies.BinaryHeaps.Value :: typeof(game.ReplicatedStorage.ExternalLibraries.BinaryHeaps))
local Benchmarkers = require(Dependencies.Benchmarker.Value :: typeof(game.ReplicatedStorage.ExternalLibraries.Benchmarker))
local SharedTypes = {}


export type ObstacleCaptureRequest = { boidId: number, generation: number, jobOrder: number }

export type ObstacleProbe = {
	role: "Forward" | "Target" | "Heading" | "Escape",
	origin: Vector3, vector: Vector3, didHit: boolean, candidateIndex: number?,
	hitPosition: Vector3?, hitDistance: number?, hitNormal: Vector3?,
}

export type ObstacleCandidate = {
	index: number, direction: Vector3, clearance: number, requiredClearance: number,
	alignment: number?, canContinue: boolean, isClear: boolean, isEligible: boolean,
	score: number?, isSelected: boolean,
}

export type ObstacleObservation = {
	boidId: number, groupId: number, cellId: number, generation: number, jobOrder: number,
	simulationTick: number, capturedAt: number, position: Vector3,
	incomingVelocity: Vector3, speed: number, dt: number, targetDirection: Vector3,
	lookAhead: number, requiredClearance: number, continuationThreshold: number,
	committedBefore: Vector3, committedAfter: Vector3, reason: string,
	softAcceleration: Vector3, resultDirection: Vector3, displacement: Vector3,
	selectedCandidateIndex: number?,
	probes: {ObstacleProbe}, candidates: {ObstacleCandidate},
}

export type BoidObservation = {
	boidId: number, groupId: number, cellId: number, cellOrigin: Vector3,
	position: Vector3, velocity: Vector3, pathNodeIndex: number?, lastSimulationTick: number,
	currentTick: number, sampledAt: number,
}

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


export type BoidsStatsBatch = {
	id: number,
	lifetimes: {[number]: number},
	groupId: number,
	defaultModel: BoidModel,
	renderColor: Color3?,

	boidCount: number,
	batchSize: number,
	lifetime: number,
	inactivityThreshold: number,

	lastSend: number,
	lastAddition: number,

	boidModels: buffer,
	data: buffer,
}


export type ScheduleeEntityShape<T> = T & {
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


export type Group = {
	id: number,
	lifetime: number,
	defaultBoidModel: BoidModel,
	renderColor: Color3?,
	activeCells: {[number]:Cell},
	cellCount: number,

	scheduler: Scheduler<Cell>,
	boidsStatsBatch: BoidsStatsBatch,

	boidCount: number,
	sightSum: number,
	averageSight: number,

	jobMsStats: Benchmarkers.Benchmarker,
	neighborItersPerJob: Benchmarkers.Benchmarker,
	jobSendStats: Benchmarkers.Benchmarker,
	jobReceiveStats: Benchmarkers.Benchmarker,
	
	cellsPerSecond: Benchmarkers.Benchmarker,
	boidsPerSecond: Benchmarkers.Benchmarker,
	cellsThisSecond: number,
	boidsThisSecond: number,

	currentPathId: number,
	usesPath: boolean,
	pathLoops: boolean,
	pathArrivalRadius: number,
}

-- Coordinator-owned live group registry; cell schedulers remain heap-backed.
export type GroupRegistry = {[number]: Group}

export type PlayerLODState = {
	lastPosition: Vector3?,
	lastFullRefresh: number,
	touchedCells: {[string]: Cell},
}

export type Cell = {
	id: number,
	groupId: number,
	origin: Vector3,
	boidCount: number,

	pages: PagedBuffer,

	networkTick: number,
	networkInterval: number,
}


-- A static position dictionary and a BasePart both expose Position. Targets
-- can therefore follow a moving part without callers resending them.
export type Target = {Position: Vector3 | BasePart} | BasePart

-- Runtime path nodes are records; Position may reference a moving BasePart.
export type PathNode = {
	Position: Vector3 | BasePart,
	offset: Vector3,
}

export type GravityWell = {
	id: number,
	position: Vector3,
	strength: number,
	influenceRadius: number,
}

export type GroupObservation = {
	groupId: number, usesPath: boolean, loops: boolean, pathArrivalRadius: number,
	path: {{index: number, position: Vector3?}}, target: Vector3?,
	gravityWells: {GravityWell}, unavailableCount: number,
}

export type BoidPacket = buffer
export type SnapshotPackets = {BoidPacket}

export type CellSnapshot = {
	origin: Vector3,
	boidCount: number,

	networkBoids: buffer
}

export type SimulationSnapshot = {[number]: CellSnapshot}

export type SnapshotGroupsBySourceCell = {[number] : SimulationSnapshot}

export type JobCell = {
	id: number,
	origin: Vector3,
	
	networkTick: number,
	networkInterval: number,
	
	emitSnapshot: boolean,
	
	pages: PagedBuffer,
	pageCount: number,
	scheduledBoidCount: number,
	processedBoidCount: number,
	boidCount: number
}


export type MeasurementMode = "minimal" | "detailed"
export type WorkerMeasurement = {
	detailed: boolean,
	executionMs: number,
	snapshotMs: number,
	scheduledBoids: number,
	observedBoids: number,
	processedBoids: number,
	skippedBoids: number,
	survivingBoids: number,
	migratedBoids: number,
	returnedSourceBoids: number,
	candidateExaminations: number,
	acceptedDirectInteractions: number,
	aggregateBucketVisits: number,
	acceptedAggregatePopulation: number,
	obstacleForwardRays: number,
	obstacleEscapeRays: number,
	obstacleDetourStarts: number,
	obstacleDetourUpdates: number,
	obstacleSoftFallbacks: number,
	pages: number,
	inputBufferBytes: number,
	outputBufferBytes: number,
}
export type RuntimeCounterName = "scheduledJobs" | "scheduledBoids" | "completedJobs" | "completedScheduledBoids" | "processedBoids" | "skippedBoids" | "survivingBoids" | "migratedBoids" | "observedBoids" | "returnedSourceBoids" | "countMismatches" | "timedOutJobs" | "discardedJobs" | "mergeFailures" | "outstandingJobs" | "peakOutstandingJobs" | "workerExecutionMs" | "workerSnapshotMs" | "jobBuildMs" | "dispatchMs" | "resultHandlingMs" | "mergeMs" | "observerPreparationMs" | "observerCallbacksMs" | "snapshotDeliveryMs" | "packetizationMs" | "schedulerMs" | "inboundDelayMs" | "outboundDelayMs" | "jobTurnaroundMs" | "detailedJobs" | "candidateExaminations" | "acceptedDirectInteractions" | "aggregateBucketVisits" | "acceptedAggregatePopulation" | "obstacleForwardRays" | "obstacleEscapeRays" | "obstacleDetourStarts" | "obstacleDetourUpdates" | "obstacleSoftFallbacks" | "pages" | "occupiedSlots" | "inputBufferBytes" | "outputBufferBytes" | "correctionMessages" | "dispatchPumps" | "dispatchPumpMs" | "heartbeatDispatches" | "completionDispatches" | "timerDispatches" | "dispatchBudgetStops" | "dispatchNoActorStops" | "dispatchNoDueStops"
export type LatencySummary = {
	sampleCount: number,
	totalSamples: number,
	windowSamples: number,
	droppedSamples: number,
	p50: number?,
	p95: number?,
	p99: number?,
	maximum: number?,
}
export type RuntimeMetrics = {
	mode: MeasurementMode,
	counters: {[RuntimeCounterName]: number},
	latency: {[string]: LatencySummary},
	latencyTotals: {[string]: number},
	latencyCapacity: number,
}

-- Full Job records cross the Actor boundary; coordinator ownership is enforced by the execution/commit lifecycle.
export type Job = {
	obstacleRequest: ObstacleCaptureRequest?,
	obstacleObservation: ObstacleObservation?,
	detailedMetrics: boolean,
	id: number,
	groupId: number,
	jobCells: {JobCell},
	usesPath: boolean,
	movedBoids: {[number]: {number | Vector3}},
	cellCount: number,
	startTime: number,
	completionTime: number,
	simulationTick: number,
	estimatedCost: number,
	averageSight: number,
	neighborIterations: number,
	-- WorkerCore fills these only when the submitted full job completes.
	measurement: WorkerMeasurement?,
	snapshotGroups: SnapshotGroupsBySourceCell?
}

-- Narrow structural views used by result and storage annotations. Active dispatch
-- still sends the full Job, including its paged-buffer allocation bookkeeping.
export type WorkerPage = {
	id: number,
	size: number,
	deadCount: number,
	firstDeadWord: number,
	cursor: number,
	data: buffer,
	dead: buffer,
}

export type WorkerPagedBuffer = {
	pages: {WorkerPage},
	pageCount: number,
}

export type WorkerJobCell = {
	id: number,
	origin: Vector3,
	emitSnapshot: boolean,
	pages: WorkerPagedBuffer,
	pageCount: number,
	scheduledBoidCount: number,
	processedBoidCount: number,
	boidCount: number,
}

export type WorkerJobResult = {
	obstacleObservation: ObstacleObservation?,
	measurement: WorkerMeasurement,
	snapshotGroups: SnapshotGroupsBySourceCell,
	simulationTick: number,
	jobCells: {WorkerJobCell},
	movedBoids: {[number]: {number | Vector3}},
	completionTime: number,
	neighborIterations: number,
}

export type NetworkBoidsBatch = {
	lifetimes: {[number]: number},
	groupId: number,
	boidCount: number,
	boidModels: buffer,
	boidIds: buffer,
	renderColor: Color3?,
}


SharedTypes.BoidModels = {
	Boid = 1,
	BoidSphere = 2,
	Predator = 3,
}

type BoidModels = typeof(SharedTypes.BoidModels)

export type BoidModelName = keyof<BoidModels>
export type BoidModel = index<BoidModels, BoidModelName>

SharedTypes.BoidModelNames = {}
for k, v in SharedTypes.BoidModels :: {[BoidModelName]: BoidModel} do
	SharedTypes.BoidModelNames[v] = k
end

table.freeze(SharedTypes.BoidModels)


-- Independent diagnostic values; no schedulees, Actor handles, buffers or callbacks.
export type NumericStatsSummary = {
	sampleCount: number, average: number, median: number,
	minimum: number?, maximum: number?, standardDeviation: number,
	staleThreshold: number?, staleCount: number,
}
export type RuntimeSummary = {groupCount: number, population: number, cellCount: number, actorCount: number}
export type GroupDiagnostics = {
	groupId: number, jobMs: NumericStatsSummary, neighborWorkPerJob: NumericStatsSummary?,
	inboundMs: NumericStatsSummary, outboundMs: NumericStatsSummary,
	cellsPerSecond: NumericStatsSummary, boidsPerSecond: NumericStatsSummary,
}
export type ActorDiagnostics = {
	index: number, idleSeconds: NumericStatsSummary,
	completedJobs: number, processedBoids: number, workerExecutionMs: number,
}
export type RuntimeDiagnostics = {
	sampledAt: number, summary: RuntimeSummary,
	cells: {total: number, valid: number, scheduled: number, maxPopulation: number, oldestAge: number, oldestId: number},
	groups: {GroupDiagnostics}, actors: {ActorDiagnostics},
}

return SharedTypes
