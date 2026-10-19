--!native
--!strict

--[[ JobHandler
Description:
	Parallel Actor worker for boid simulation jobs. Receives cell jobs from the
	server scheduler, updates boid movement and flocking state, records boids
	that moved between cells, and builds network snapshot packets.

Runtime Message API:
	NewJob(job: Job, bindableEvent: BindableEvent): returns job results through bindableEvent
	NewBoidsStatsBatch(batch: ActorBoidsBatch): caches static boid parameters by boid id
	NewGroupTarget(groupId: number, target: Target): stores the current target for a group
	NewGroupPath(groupId, path, pathId, switchToClosestNode, loops): caches a complete group path
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")
-- WorkerCore runs from an Actor clone, not its source package hierarchy.
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local StatsCodec = require(BoidsReplicated.Boids.StatsCodec)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local SnapshotCodec = require(BoidsReplicated.SnapshotCodec)
local ObstacleDiagnostics = require(BoidsReplicated.Boids.ObstacleDiagnostics)
local WorkerCore = {}


type SimulationSnapshot = SharedTypes.SimulationSnapshot
type CellSnapshot = SharedTypes.CellSnapshot

type Job = SharedTypes.Job
type JobCell = SharedTypes.JobCell
type Target = SharedTypes.Target
type PathNode = SharedTypes.PathNode
type GravityWell = SharedTypes.GravityWell
type GroupPath = {
	nodes: {PathNode},
	id: number,
	switchToClosestNode: boolean,
	loops: boolean,
	arrivalRadiusSq: number,
}
type Page = SharedTypes.Page
type PagedBuffer = SharedTypes.PagedBuffer
type SnapshotGroupsBySourceCell = SharedTypes.SnapshotGroupsBySourceCell

type ActorBoidsBatch = StatsCodec.ActorBoidsBatch

local writeQuantizedPositionU8 = Quantization.WriteQuantizedPositionU8
local writeQuantizedVelocityU8 = Quantization.WriteQuantizedVelocityU8
local writeQuantizedPositionU16 = Quantization.WriteQuantizedPositionU16
local writeQuantizedVelocityU16 = Quantization.WriteQuantizedVelocityU16

local readQuantizedPositionU8 = Quantization.ReadQuantizedPositionU8
local readQuantizedVelocityU8 = Quantization.ReadQuantizedVelocityU8
local readQuantizedPositionU16 = Quantization.ReadQuantizedPositionU16
local readQuantizedVelocityU16 = Quantization.ReadQuantizedVelocityU16

local writeLastTick = Quantization.WriteLastTick
local readLastTick = Quantization.ReadLastTick
local currentSimTick = Quantization.CurrentSimTick
local tickDeltaSeconds = Quantization.TickDeltaSeconds

local CELL_SIZE:number = Quantization.CELL_SIZE
local MAX_U8: number = Quantization.MAX_U8_INT

local NORM_VELOCITY_MIN:number = Quantization.NORM_VELOCITY_MIN
local NORM_VELOCITY_RANGE:number = Quantization.NORM_VELOCITY_RANGE
local VELOCITY_MIN:number = Quantization.VELOCITY_MIN
local VELOCITY_RANGE:number = Quantization.VELOCITY_RANGE


local U8_POS_DEQUANTIZE_SCALE: number = CELL_SIZE / MAX_U8
local U8_VEL_DEQUANTIZE_SCALE: number = NORM_VELOCITY_RANGE / MAX_U8


local NON_NAN = Vector3.new(0.01, 0.01, 0.01)

local U8_SIZE = 1
local U16_SIZE = 2
local U32_SIZE = 4

local ROW_BYTES = BoidStorage.BOID_ROW_BYTES
local BOID_ID_OFFSET = BoidStorage.BOID_ID_OFFSET
local POS_X_OFFSET = BoidStorage.POS_X_OFFSET
local POS_Y_OFFSET = BoidStorage.POS_Y_OFFSET
local POS_Z_OFFSET = BoidStorage.POS_Z_OFFSET
local VEL_X_OFFSET = BoidStorage.VEL_X_OFFSET
local VEL_Y_OFFSET = BoidStorage.VEL_Y_OFFSET
local VEL_Z_OFFSET = BoidStorage.VEL_Z_OFFSET
local SPEED_OFFSET = BoidStorage.SPEED_OFFSET

-- add repulsion threshold and scaling stats that other boids multiply their avoidance by to affect how strongly they avoid this boid
type ReconciliationTarget = {
	position: Vector3,
	velocity: Vector3,
	snapshotTime: number,
	expiresAt: number,
}

type BoidStats = {
	maxSpeed:number,
	minSpeed:number,
	sight:number,
	avoidance:number,
	separation:number,
	repulsion:number,
	repulsionStrength:number,
	alignment:number,
	cohesion:number,
	targetBias:number,
	reconciliation: ReconciliationTarget,
}

type Bucket = {
	liveIndices: {number},
	centerOfMass: Vector3,
	velocity: Vector3,
	boidCount: number
}

type CellScratch = {
	ids: {number},
	positions: {Vector3},
	velocities: {Vector3},
	lastTicks: {number},
	pathNodes: {number},
	pathVersions: {number},
	pagesByIndex: {Page},
	slotsByIndex: {number},
	bucketXs: {number},
	bucketYs: {number},
	bucketZs: {number},
	liveIndices: {number},
}

local groupTargets:{[number]:Target} = {}
local groupPaths: {[number]: GroupPath} = {}
local globalGravityWells: {[number]: GravityWell} = {}
local groupGravityWells: {[number]: {[number]: GravityWell}} = {}

local globalBoidsStats:{[number]:BoidStats} = {}
local pendingReconciliationTargets: {[number]: ReconciliationTarget} = {}

-- Lifecycle tokens are process-local metadata, separate from packed simulation
-- rows/codecs. Tombstones prevent delayed stats/control messages reviving caches.
local retiredBoids: {[number]: number} = {}
local statsLifetimes: {[number]: number} = {}
local pendingTargetLifetimes: {[number]: number} = {}
local groupLifetimes: {[number]: number} = {}
local retiredGroups: {[number]: number} = {}
local function acceptGroupLifetime(groupId: number, lifetime: number): boolean
	if lifetime <= (retiredGroups[groupId] or -1) or lifetime < (groupLifetimes[groupId] or -1) then return false end
	if groupLifetimes[groupId] ~= lifetime then
		groupTargets[groupId], groupPaths[groupId], groupGravityWells[groupId] = nil, nil, nil
		groupLifetimes[groupId] = lifetime
	end
	return true
end

local function clearBuckets(buckets: {[number]: Bucket}, activeBucketRecords: {Bucket}, bucketRecordPool: {Bucket}): ()
	for i = 1, #activeBucketRecords do
		local bucket = activeBucketRecords[i]
		table.clear(bucket.liveIndices)
		bucket.boidCount = 0
		bucketRecordPool[#bucketRecordPool + 1] = bucket
		activeBucketRecords[i] = nil
	end
	table.clear(buckets)
end

local function acquireBucket(liveIndex: number, position: Vector3, velocity: Vector3, activeBucketRecords: {Bucket}, bucketRecordPool: {Bucket}): Bucket
	local bucket = bucketRecordPool[#bucketRecordPool]
	if bucket then
		bucketRecordPool[#bucketRecordPool] = nil
		bucket.liveIndices[1] = liveIndex
		bucket.centerOfMass = position
		bucket.velocity = velocity
		bucket.boidCount = 1
	else
		bucket = {liveIndices = {liveIndex}, centerOfMass = position, velocity = velocity, boidCount = 1}
	end
	activeBucketRecords[#activeBucketRecords + 1] = bucket
	return bucket
end

-- this may be slower than simply passing over localBoidPositions once and deserializing it
-- Scans individual boids only. Bucket aggregates remain in the caller because
-- their weighted behavior is intentionally different from direct interactions.
local function accumulateDirectNeighbors(
	liveIndex: number,
	candidateIndices: {number},
	candidateCount: number,
	position: Vector3,
	sight: number,
	avoidance: number,
	ids: {number},
	positions: {Vector3},
	velocities: {Vector3},
	maximumInteractions: number,
	detailedMetrics: boolean
): (Vector3, Vector3, Vector3, number, number, number, number)
	local closeness = Vector3.zero
	local averageVelocity = Vector3.zero
	local centerOfMass = Vector3.zero
	local separationCount = 0
	local alignmentCount = 0
	local cohesionCount = 0
	local iterationCount = 0

	for candidateIndex: number = 1, candidateCount do
		local otherLiveIndex = candidateIndices[candidateIndex]
		if detailedMetrics then iterationCount += 1 end
		if liveIndex == otherLiveIndex then
			continue
		end

		local otherBoidStats = globalBoidsStats[ids[otherLiveIndex]]
		if not otherBoidStats then
			continue
		end

		local repulsionDistance = avoidance + otherBoidStats.repulsion
		local otherPosition = positions[otherLiveIndex]
		local vectorTo = position - otherPosition
		local distanceSq = vectorTo:Dot(vectorTo)
		if distanceSq > math.max(sight, repulsionDistance) ^ 2 then
			continue
		end

		if distanceSq < repulsionDistance ^ 2 and distanceSq > 0 then
			closeness += vectorTo.Unit
				* math.max(repulsionDistance - math.sqrt(distanceSq), 0)
				* otherBoidStats.repulsionStrength
			separationCount += 1
		else
			averageVelocity += velocities[otherLiveIndex]
			centerOfMass += otherPosition
			alignmentCount += 1
			cohesionCount += 1
		end

		if separationCount + alignmentCount >= maximumInteractions then
			break
		end
	end

	return closeness, averageVelocity, centerOfMass, separationCount, alignmentCount, cohesionCount, iterationCount
end

local function retrieveLocalBoidPosition(deserializedPositions:{Vector3}, localBoidPositions:buffer, boidIndex:number):Vector3
	if not deserializedPositions[boidIndex] then
		deserializedPositions[boidIndex] = Vector3.new(readQuantizedPositionU8(localBoidPositions, boidIndex))
	end
	return deserializedPositions[boidIndex]
end

local function retrieveBoidVelocity(deserializedVelocities:{Vector3}, boidVelocities:buffer, boidIndex:number):Vector3
	if not deserializedVelocities[boidIndex] then
		deserializedVelocities[boidIndex] = Vector3.new(readQuantizedVelocityU8(boidVelocities, boidIndex, NORM_VELOCITY_MIN, NORM_VELOCITY_RANGE)).Unit
	end
	return deserializedVelocities[boidIndex]
end

local MAX_SEEN = 100

-- Snapshot reconciliation is data-driven rather than a simulation mode. Every
-- boid has an inert target record, so this adds no per-boid mode branch.
local RECONCILIATION_EXPIRY_SECONDS = 6
local RECONCILIATION_POSITION_GAIN = 0.45
local RECONCILIATION_VELOCITY_GAIN = 1.1

-- Obstacle avoidance is a compact committed detour. A clear tangent becomes
-- packed per-boid state so the target force cannot undo it on the next update.
local OBSTACLE_MIN_LOOK_AHEAD = 24
local OBSTACLE_REACTION_SECONDS = 2
local OBSTACLE_LOOK_AHEAD_PADDING = 4
local OBSTACLE_MAX_LOOK_AHEAD = 1024
local OBSTACLE_CLEARANCE_MARGIN = 2
-- The margin avoids treating packed-heading quantization noise as forward alignment.
local OBSTACLE_CONTINUATION_DOT_THRESHOLD = 0.1
local OBSTACLE_SOFT_ACCELERATION_SCALE = 0.75

local obstacleRaycastParams = RaycastParams.new()
obstacleRaycastParams.IgnoreWater = true
obstacleRaycastParams.RespectCanCollide = true

local function getObstacleLookAhead(speed: number, dt: number): number
	return math.min(
		math.max(speed * dt, speed * OBSTACLE_REACTION_SECONDS, OBSTACLE_MIN_LOOK_AHEAD)
			+ OBSTACLE_LOOK_AHEAD_PADDING,
		OBSTACLE_MAX_LOOK_AHEAD
	)
end

local function findEscapeDirection(
	boidId: number,
	worldPosition: Vector3,
	normal: Vector3,
	preferredDirection: Vector3,
	goalDirection: Vector3,
	committedDirection: Vector3?,
	lookAhead: number,
	requiredClearance: number,
	observation: SharedTypes.ObstacleObservation?
): (Vector3, number)
	local tangentA = preferredDirection - normal * preferredDirection:Dot(normal)
	local tangentAMagnitudeSq = tangentA:Dot(tangentA)
	if tangentAMagnitudeSq <= 1e-8 then
		tangentA = normal:Cross(Vector3.yAxis)
		tangentAMagnitudeSq = tangentA:Dot(tangentA)
		if tangentAMagnitudeSq <= 1e-8 then
			tangentA = normal:Cross(Vector3.xAxis)
			tangentAMagnitudeSq = tangentA:Dot(tangentA)
		end
		if boidId % 2 == 0 then
			tangentA = -tangentA
		end
	end
	tangentA /= math.sqrt(tangentAMagnitudeSq)
	local tangentB = normal:Cross(tangentA)

	local bestDirection = Vector3.zero
	local bestScore = -math.huge
	local candidateDirection: Vector3
	local candidateHit: RaycastResult?
	local clearance: number
	local score: number
	local candidateContinues: boolean

	for candidateIndex = 1, 4 do
		if candidateIndex == 1 then
			candidateDirection = tangentA
		elseif candidateIndex == 2 then
			candidateDirection = -tangentA
		elseif candidateIndex == 3 then
			candidateDirection = tangentB
		else
			candidateDirection = -tangentB
		end

		candidateHit = workspace:Raycast(worldPosition, candidateDirection * lookAhead, obstacleRaycastParams)
		clearance = if candidateHit then candidateHit.Distance else lookAhead
		candidateContinues = committedDirection == nil
			or candidateDirection:Dot(committedDirection) > OBSTACLE_CONTINUATION_DOT_THRESHOLD
		if clearance >= requiredClearance and candidateContinues then
			score = clearance + candidateDirection:Dot(goalDirection) * lookAhead * 0.25
			-- A committed detour never reverses to a different tangent class.
			-- Path progress and clearance rank candidates that preserve its heading.
			if score > bestScore then
				bestScore = score
				bestDirection = candidateDirection
				if observation then observation.selectedCandidateIndex = candidateIndex end
			end
		end
		if observation then
			ObstacleDiagnostics.RecordProbe(observation, "Escape", worldPosition, candidateDirection * lookAhead, candidateHit, candidateIndex)
			local isClear = clearance >= requiredClearance
			table.insert(observation.candidates, {
				index = candidateIndex, direction = candidateDirection, clearance = clearance,
				requiredClearance = requiredClearance,
				alignment = if committedDirection then candidateDirection:Dot(committedDirection) else nil,
				canContinue = candidateContinues, isClear = isClear,
				isEligible = isClear and candidateContinues,
				score = if isClear and candidateContinues then score else nil, isSelected = false,
			})
		end
	end
	if observation and observation.selectedCandidateIndex then
		observation.candidates[observation.selectedCandidateIndex].isSelected = true
	end

	return bestDirection, 4
end

local function getObstacleResponse(
	boidId: number,
	worldPosition: Vector3,
	velocity: Vector3,
	speed: number,
	dt: number,
	preferredDirection: Vector3,
	maxSpeed: number,
	observation: SharedTypes.ObstacleObservation?
): (Vector3, Vector3, number, number, boolean)
	if speed <= 1e-4 or dt <= 0 then
		return Vector3.zero, Vector3.zero, 0, 0, false
	end

	local lookAhead = getObstacleLookAhead(speed, dt)
	local forwardHit = workspace:Raycast(worldPosition, velocity / speed * lookAhead, obstacleRaycastParams)
	if observation then ObstacleDiagnostics.RecordProbe(observation, "Forward", worldPosition, velocity / speed * lookAhead, forwardHit, nil) end
	if not forwardHit then
		if observation then observation.reason = "ForwardClear" end
		return Vector3.zero, Vector3.zero, 1, 0, false
	end

	local escapeDirection, escapeRays = findEscapeDirection(
		boidId,
		worldPosition,
		forwardHit.Normal,
		preferredDirection,
		preferredDirection,
		nil,
		lookAhead,
		speed * dt + OBSTACLE_CLEARANCE_MARGIN,
		observation
	)
	if escapeDirection:Dot(escapeDirection) > 1e-8 then
		if observation then observation.reason = "DetourStarted" end
		return Vector3.zero, escapeDirection, 1, escapeRays, false
	end

	if observation then observation.reason = "SoftFallback" end
	local threat = math.clamp((lookAhead - forwardHit.Distance) / lookAhead, 0, 1)
	return forwardHit.Normal * maxSpeed * OBSTACLE_SOFT_ACCELERATION_SCALE * threat,
		Vector3.zero, 1, escapeRays, true
end

local function readData(data: buffer, slot: number): (number, Vector3, Vector3, number, number, number)
	return 
		BoidStorage.ReadBoidId(data, slot),
		Vector3.new(BoidStorage.ReadPosition(data, slot)),
		Vector3.new(BoidStorage.ReadVelocity(data, slot)) * BoidStorage.ReadSpeed(data, slot),
		BoidStorage.ReadLastTick(data, slot),
		BoidStorage.ReadPathNode(data, slot),
		BoidStorage.ReadPathVersion(data, slot)
end

local function writeNewData(data: buffer, slot: number, position: Vector3, velocity: Vector3, speed: number, currentTick: number, pathNode: number, pathVersion: number): ()
	BoidStorage.WritePosition(data, slot, position.X, position.Y, position.Z)
	BoidStorage.WriteVelocity(data, slot, velocity.X, velocity.Y, velocity.Z)
	BoidStorage.WriteSpeed(data, slot, speed)
	BoidStorage.WriteLastTick(data, slot, currentTick)
	BoidStorage.WritePathNode(data, slot, pathNode)
	BoidStorage.WritePathVersion(data, slot, pathVersion)
end

local function findBucket(bx: number, by: number, bz: number): number
	return bx + by * 1024 + bz * 1048576
end

type BucketSearch = {{number}}

local bucketSearchCache: {[number]: BucketSearch} = {}

local function getBucketSearch(searchRadius: number): BucketSearch
	local cached: BucketSearch? = bucketSearchCache[searchRadius]
	if cached then
		return cached
	end

	local offsets: {{number}} = {}
	local offsetCount: number = 0

	for dx: number = -searchRadius, searchRadius do
		for dy: number = -searchRadius, searchRadius do
			for dz: number = -searchRadius, searchRadius do
				local chebyshevDistance: number = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
				local distanceSq: number = dx * dx + dy * dy + dz * dz
				
				offsetCount += 1
				table.insert(offsets, {
					dx,
					dy,
					dz,
					chebyshevDistance,
					distanceSq,
				})
			end
		end
	end

	table.sort(offsets, function(a: {number}, b: {number}): boolean
		if a[4] ~= b[4] then
			return a[4] < b[4]
		end

		return a[5] < b[5]
	end)

	local search: BucketSearch = {}
	
	for _, offset: {number} in offsets do
		offset[4] = nil
		offset[5] = nil
		table.insert(search, offset)
	end

	bucketSearchCache[searchRadius] = search
	return search
end

local function isGravityWellRelevantToCell(gravityWell: GravityWell, cellOrigin: Vector3): boolean
	local cellMax = cellOrigin + Vector3.new(CELL_SIZE, CELL_SIZE, CELL_SIZE)
	local position = gravityWell.position
	local nearest = Vector3.new(
		math.clamp(position.X, cellOrigin.X, cellMax.X),
		math.clamp(position.Y, cellOrigin.Y, cellMax.Y),
		math.clamp(position.Z, cellOrigin.Z, cellMax.Z)
	)
	local offset = position - nearest
	return offset:Dot(offset) <= gravityWell.influenceRadius * gravityWell.influenceRadius
end

local function getRelevantGravityWells(groupId: number, cellOrigin: Vector3): {GravityWell}
	local relevant: {GravityWell} = {}
	for _, gravityWell: GravityWell in globalGravityWells do
		if isGravityWellRelevantToCell(gravityWell, cellOrigin) then
			table.insert(relevant, gravityWell)
		end
	end

	local groupWells = groupGravityWells[groupId]
	if groupWells then
		for _, gravityWell: GravityWell in groupWells do
			if isGravityWellRelevantToCell(gravityWell, cellOrigin) then
				table.insert(relevant, gravityWell)
			end
		end
	end
	return relevant
end

local function findClosestNode(path: {Vector3}, origin: Vector3, position: Vector3, pathCount: number): number
	local closestNode: number = 1
	local closestDistanceSq: number = math.huge
	local worldPosition: Vector3 = origin + position
	local vectorTo: Vector3
	local distanceSq: number
	
	for nodeIndex: number = 1, pathCount do
		vectorTo = path[nodeIndex] - worldPosition
		distanceSq = vectorTo:Dot(vectorTo)
		if distanceSq < closestDistanceSq then
			closestDistanceSq = distanceSq
			closestNode = nodeIndex
		end
	end
	
	return closestNode
end

-- BasePart.Position is Read Parallel, so workers resolve dynamic references once
-- per job rather than forcing callers to resubmit a moving target or path.
local function resolvePositionSource(source: Target): Vector3
	if typeof(source) == "Instance" then
		return (source :: BasePart).Position
	end

	local position = source.Position
	if typeof(position) == "Vector3" then
		return position
	end
	return resolvePositionSource(position)
end

local function resolvePathNode(node: PathNode): Vector3
	return resolvePositionSource(node) + node.offset
end

local function newObstacleObservation(
	request: SharedTypes.ObstacleCaptureRequest, groupId: number, cellId: number,
	tick: number, capturedAt: number, position: Vector3, velocity: Vector3,
	dt: number, preferredDirection: Vector3, committedDirection: Vector3
): SharedTypes.ObstacleObservation
	local speed = velocity.Magnitude
	return {
		boidId = request.boidId, groupId = groupId, cellId = cellId,
		generation = request.generation, jobOrder = request.jobOrder,
		simulationTick = tick, capturedAt = capturedAt, position = position,
		incomingVelocity = velocity, speed = speed, dt = dt, targetDirection = preferredDirection,
		lookAhead = getObstacleLookAhead(speed, dt),
		requiredClearance = speed * dt + OBSTACLE_CLEARANCE_MARGIN,
		continuationThreshold = OBSTACLE_CONTINUATION_DOT_THRESHOLD,
		committedBefore = committedDirection, committedAfter = committedDirection,
		reason = if dt <= 0 then "NotEvaluatedZeroDelta" elseif speed <= 1e-4 then "NotEvaluatedZeroSpeed" else "NotEvaluated",
		softAcceleration = Vector3.zero, resultDirection = Vector3.zero, displacement = Vector3.zero,
		probes = {}, candidates = {},
	}
end

local function runJob(job: Job, bindableEvent: BindableEvent, frameTick: number, messageSentTime: number): ()
	local executionStart = os.clock()
	local jobReceiveTime = workspace:GetServerTimeNow() - messageSentTime
	-- Scratch belongs to this invocation; only cells in this job reuse it.
	local cellScratch: CellScratch = {
		ids = {}, positions = {}, velocities = {}, lastTicks = {}, pathNodes = {}, pathVersions = {},
		pagesByIndex = {}, slotsByIndex = {}, bucketXs = {}, bucketYs = {}, bucketZs = {}, liveIndices = {},
	}
	local bucketRecordPool: {Bucket} = {}
	local activeBucketRecords: {Bucket} = {}
	local detailedMetrics = job.detailedMetrics
	local obstacleRequest = job.obstacleRequest
	local observedBoidId = if obstacleRequest then obstacleRequest.boidId else nil
	local measurement: SharedTypes.WorkerMeasurement = {
		detailed = detailedMetrics,
		executionMs = 0,
		snapshotMs = 0,
		scheduledBoids = 0,
		observedBoids = 0,
		processedBoids = 0,
		skippedBoids = 0,
		survivingBoids = 0,
		migratedBoids = 0,
		returnedSourceBoids = 0,
		candidateExaminations = 0,
		acceptedDirectInteractions = 0,
		aggregateBucketVisits = 0,
		acceptedAggregatePopulation = 0,
		obstacleForwardRays = 0,
		obstacleEscapeRays = 0,
		obstacleDetourStarts = 0,
		obstacleDetourUpdates = 0,
		obstacleSoftFallbacks = 0,
		pages = 0,
		inputBufferBytes = 0,
		outputBufferBytes = 0,
	}
	local snapshotStart = 0
	
	debug.profilebegin("Boids.WorkerCore.RunJob")
	
	--print(`WORKER START job={job.id}, cells={job.cellCount}`)
	
	local simulationSnapshot: SimulationSnapshot	
	local snapshotGroups: SnapshotGroupsBySourceCell = {}

	local movedBoids: {[number]: {number | Vector3}} = job.movedBoids
	local movedCell: {number | Vector3}

	local jobCells: {JobCell} = job.jobCells
	local pagedBuffer: PagedBuffer
	local pages: {Page}
	
	local cellBoidCount: number
	local origin: Vector3, newOrigin: Vector3, newCellId: number

	local cellSnapshot: CellSnapshot, movedCellSnapshot: CellSnapshot
	local shouldEmitSnapshot: boolean
	
	local targetSource: Target? = groupTargets[job.groupId]
	local target: Vector3 = if targetSource then resolvePositionSource(targetSource) else Vector3.zero
	local activePath: GroupPath? = if job.usesPath then groupPaths[job.groupId] else nil
	local path: {Vector3}? = nil
	local pathCount: number = 0
	if activePath then
		pathCount = #activePath.nodes
		path = table.create(pathCount) :: {Vector3}
		for nodeIndex: number, node: PathNode in activePath.nodes do
			path[nodeIndex] = resolvePathNode(node)
		end
	end
	local usesPath: boolean = pathCount > 0
	local pathArrivalRadiusSq: number = if activePath then activePath.arrivalRadiusSq else 0
	local targetLocal: Vector3, toTarget: Vector3

	local currentTick: number = currentSimTick()
	local jobTime: number = workspace:GetServerTimeNow()
	job.simulationTick = currentTick

	local data: buffer, newData: buffer, otherData: buffer

	local offset: number, otherOffset: number
	local boidId: number
	local pathNode: number, pathVersion: number
	local lastTick: number

	local position: Vector3, worldPosition: Vector3
	local velocity: Vector3, networkVelocity: Vector3
	local speed: number

	local x: number, y: number, z: number
	local dt: number, steeringDt: number

	local boidStats: BoidStats
	local maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number

	local closeness: Vector3
	local vectorTo: Vector3, distanceSq: number
	local avgVelocity: Vector3
	local centerOfMass: Vector3
	local acceleration: Vector3, targetAcceleration: Vector3, gravityAcceleration: Vector3, reconciliationAcceleration: Vector3
	local reconciliationTarget: ReconciliationTarget
	local reconciliationPosition: Vector3
	local reconciliationWeight: number
	local repulsionDistance: number

	local separationCount: number, alignmentCount: number, cohesionCount: number

	local maxAccelerationScale: number = 2
	local maxAcceleration: number

	local otherBoidIndex: number, otherBoidStats: BoidStats, otherPageIds: buffer
	local otherPosition: Vector3, otherVelocity: Vector3

	local deserializedPositions: {Vector3}, deserializedVelocities: {Vector3}
	
	local isBucketting: boolean
	local obstacleAcceleration: Vector3
	local obstacleDirection: Vector3
	local usesObstacleDetour: boolean
	local obstacleSoftFallback: boolean
	local obstacleDetourStarted: boolean, obstacleDetourUpdated: boolean
	local obstacleForwardRays: number, obstacleEscapeRays: number

	local representativeSight = job.averageSight
	local bucketSize = representativeSight
	local maxSight = representativeSight * 2
	--local bucketSearch: BucketSearch = getBucketSearch(math.ceil(maxSight / bucketSize))
	local bucketSearch: BucketSearch = getBucketSearch(1)
	
	-- benchmarking
	local neighborIterations: number = 0
	
	local buckets: {[number]: Bucket} = {}
	-- A job may cover several cells; filter wells once per cell instead of once per boid.
	local gravityWellsByCell: {[number]: {GravityWell}} = {}
	
	local ids: {number}, positions: {Vector3}, velocities: {Vector3}, lastTicks: {number}, pathNodes: {number}, pathVersions: {number}, pagesByIndex: {Page}, slotsByIndex: {number}, bucketXs: {number}, bucketYs: {number}, bucketZs: {number}

	for jobCellIndex: number = 1, #jobCells do
		local jobCell: JobCell = jobCells[jobCellIndex]
		measurement.scheduledBoids += jobCell.scheduledBoidCount
		jobCell.processedBoidCount = 0
		isBucketting = jobCell.boidCount > MAX_SEEN
		
		if isBucketting then
			clearBuckets(buckets, activeBucketRecords, bucketRecordPool)
		end
		
		cellBoidCount = jobCell.boidCount
		origin = jobCell.origin
		pagedBuffer = jobCell.pages
		pages = pagedBuffer.pages

		local relevantGravityWells = gravityWellsByCell[jobCell.id]
		if not relevantGravityWells then
			relevantGravityWells = getRelevantGravityWells(job.groupId, origin)
			gravityWellsByCell[jobCell.id] = relevantGravityWells
		end
		
		targetLocal = target - origin
		
		--shouldEmitSnapshot = jobCell.networkTick % jobCell.networkInterval == 0
		shouldEmitSnapshot = jobCell.emitSnapshot
		
		ids = cellScratch.ids
		positions = cellScratch.positions
		velocities = cellScratch.velocities
		lastTicks = cellScratch.lastTicks
		pathNodes = cellScratch.pathNodes
		pathVersions = cellScratch.pathVersions
		pagesByIndex = cellScratch.pagesByIndex
		slotsByIndex = cellScratch.slotsByIndex
		bucketXs = cellScratch.bucketXs
		bucketYs = cellScratch.bucketYs
		bucketZs = cellScratch.bucketZs
		local liveIndices = cellScratch.liveIndices
		
		-- must rework a bit to make this work
		--deserializedPositions = table.create(cellBoidCount) :: {Vector3}
		--deserializedVelocities = table.create(cellBoidCount) :: {Vector3}
		
		-- plan to attempt to remove ids later by having client track state identically to server, may require sending dead buffer (much smaller)
		-- removing ids may be far more complicated than its worth
		if shouldEmitSnapshot then
			if detailedMetrics then snapshotStart = os.clock() end
			simulationSnapshot = {}
			
			snapshotGroups[jobCell.id] = simulationSnapshot
			
			cellSnapshot = SnapshotCodec.GetOrCreateCellSnapshot(
				simulationSnapshot,
				jobCell.id,
				origin,
				cellBoidCount
			)
			if detailedMetrics then measurement.snapshotMs += (os.clock() - snapshotStart) * 1000 end
		end
		
		local nextLiveIndex: number = 0
		local bucketKey: number

		local bx: number, by: number, bz: number
		for _, page: Page in pages do
			if detailedMetrics then
				measurement.pages += 1
				measurement.inputBufferBytes += buffer.len(page.data) + buffer.len(page.dead)
			end
			data = page.data
			
			local bucket: Bucket
			local bitIndex: number, boidIndex: number
			for baseSlot: number, liveMask: number in (BoidStorage.LiveWords(page)) do
				while liveMask ~= 0 do
					bitIndex = bit32.countrz(liveMask)
					boidIndex = baseSlot + bitIndex
					liveMask = bit32.band(liveMask, liveMask - 1)

					nextLiveIndex += 1

					offset = boidIndex * ROW_BYTES

					boidId, position, velocity, lastTick, pathNode, pathVersion = readData(data, boidIndex)

					ids[nextLiveIndex] = boidId
					liveIndices[nextLiveIndex] = nextLiveIndex
					positions[nextLiveIndex] = position
					velocities[nextLiveIndex] = velocity

					lastTicks[nextLiveIndex] = lastTick
					pathNodes[nextLiveIndex] = pathNode
					pathVersions[nextLiveIndex] = pathVersion

					pagesByIndex[nextLiveIndex] = page
					slotsByIndex[nextLiveIndex] = boidIndex

					if not isBucketting then
						continue
					end
					
					bx = position.X // bucketSize
					by = position.Y // bucketSize
					bz = position.Z // bucketSize

					bucketXs[nextLiveIndex] = bx
					bucketYs[nextLiveIndex] = by
					bucketZs[nextLiveIndex] = bz

					bucketKey = findBucket(bx, by, bz)

					bucket = buckets[bucketKey]
					if not bucket then
							bucket = acquireBucket(nextLiveIndex, position, velocity, activeBucketRecords, bucketRecordPool)
						buckets[bucketKey] = bucket

						continue
					end

					table.insert(bucket.liveIndices, nextLiveIndex)
					bucket.boidCount += 1

					local aggregateWeight: number = 1 / bucket.boidCount
					bucket.centerOfMass += (position - bucket.centerOfMass) * aggregateWeight
					bucket.velocity += (velocity - bucket.velocity) * aggregateWeight
				end
			end
		end

		local liveCount: number = nextLiveIndex
		measurement.observedBoids += liveCount
		local boidIndex: number
		local page: Page
		local currentBucketKey: number, neighborKey: number, neighborBucket: Bucket
		local otherBoidCount: number
		for liveIndex: number = 1, liveCount do
			boidId, position, velocity, lastTick, pathNode, pathVersion, page, boidIndex, bx, by, bz =
				ids[liveIndex], positions[liveIndex], velocities[liveIndex], lastTicks[liveIndex], pathNodes[liveIndex], pathVersions[liveIndex], pagesByIndex[liveIndex], slotsByIndex[liveIndex], bucketXs[liveIndex], bucketYs[liveIndex], bucketZs[liveIndex]

			boidStats = globalBoidsStats[boidId]
			if not boidStats then
				if obstacleRequest and boidId == observedBoidId then
					local skipped = newObstacleObservation(obstacleRequest, job.groupId, jobCell.id, currentTick, jobTime,
						origin + position, velocity, 0, Vector3.zero, BoidStorage.ReadObstacleDirection(page.data, boidIndex))
					skipped.reason = "NotEvaluatedMissingStats"
					job.obstacleObservation = skipped
				end
				measurement.skippedBoids += 1
				continue
			end
			measurement.processedBoids += 1
			jobCell.processedBoidCount += 1

			maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias =
				boidStats.maxSpeed, boidStats.minSpeed, boidStats.sight, boidStats.avoidance, boidStats.separation, boidStats.repulsion, boidStats.repulsionStrength, boidStats.alignment, boidStats.cohesion, boidStats.targetBias
			speed = velocity.Magnitude

			closeness = Vector3.zero
			avgVelocity = Vector3.zero
			centerOfMass = Vector3.zero

			separationCount = 0
			alignmentCount = 0
			cohesionCount = 0

			if isBucketting then
				currentBucketKey = findBucket(bx, by, bz)
				for _, searchOffset: {number} in bucketSearch do
					neighborKey = findBucket(
						bx + searchOffset[1],
						by + searchOffset[2],
						bz + searchOffset[3]
					)
					neighborBucket = buckets[neighborKey]
					if not neighborBucket then
						continue
					end

					if neighborKey == currentBucketKey then
						local directCloseness, directAverageVelocity, directCenterOfMass,
							directSeparationCount, directAlignmentCount, directCohesionCount,
							directIterationCount = accumulateDirectNeighbors(
								liveIndex,
								neighborBucket.liveIndices,
								#neighborBucket.liveIndices,
								position,
								sight,
								avoidance,
								ids,
								positions,
								velocities,
								MAX_SEEN,
								detailedMetrics
							)
						closeness += directCloseness
						avgVelocity += directAverageVelocity
						centerOfMass += directCenterOfMass
						separationCount += directSeparationCount
						alignmentCount += directAlignmentCount
						cohesionCount += directCohesionCount
						neighborIterations += directIterationCount
						if detailedMetrics then
							measurement.candidateExaminations += directIterationCount
							measurement.acceptedDirectInteractions += directSeparationCount + directAlignmentCount
						end
					else
						if detailedMetrics then
							neighborIterations += 1
							measurement.aggregateBucketVisits += 1
						end

						otherPosition, otherVelocity, otherBoidCount = neighborBucket.centerOfMass, neighborBucket.velocity, neighborBucket.boidCount

						vectorTo = (position - otherPosition)
						distanceSq = vectorTo:Dot(vectorTo)
						if distanceSq > sight^2 then
							continue
						end

						if detailedMetrics then measurement.acceptedAggregatePopulation += otherBoidCount end

						if distanceSq < avoidance^2 and distanceSq > 0 then
							closeness += vectorTo.Unit * math.max(avoidance - math.sqrt(distanceSq), 0) * neighborBucket.boidCount
							separationCount += neighborBucket.boidCount
						else
							avgVelocity += otherVelocity * neighborBucket.boidCount
							centerOfMass += otherPosition * neighborBucket.boidCount
							alignmentCount += neighborBucket.boidCount
							cohesionCount += neighborBucket.boidCount
						end
					end

					-- consider removing this check later if it makes sense to
					if separationCount + alignmentCount >= MAX_SEEN then
						break
					end
				end
			else
				local directIterationCount: number
				closeness, avgVelocity, centerOfMass,
					separationCount, alignmentCount, cohesionCount,
					directIterationCount = accumulateDirectNeighbors(
						liveIndex,
						liveIndices,
						liveCount,
						position,
						sight,
						avoidance,
						ids,
						positions,
						velocities,
						MAX_SEEN,
						detailedMetrics
					)
				neighborIterations += directIterationCount
				if detailedMetrics then
					measurement.candidateExaminations += directIterationCount
					measurement.acceptedDirectInteractions += separationCount + alignmentCount
				end
			end

			if alignmentCount > 0 then
				avgVelocity /= alignmentCount
			end
			if cohesionCount > 0 then
				centerOfMass /= cohesionCount
			end
			if separationCount > 0 then
				closeness /= separationCount
			end

			dt = tickDeltaSeconds(currentTick, lastTick)
			steeringDt = math.min(dt, 10)

			targetAcceleration = Vector3.zero
			if usesPath and activePath and path then
				if pathVersion ~= activePath.id then
					pathVersion = activePath.id
					if activePath.switchToClosestNode then
						pathNode = findClosestNode(path, origin, position, pathCount)
					else
						pathNode = 1
					end
				elseif pathNode < 1 or pathNode > pathCount then
					pathNode = 1
				end

				targetLocal = path[pathNode] - origin
				toTarget = targetLocal - position
				if toTarget:Dot(toTarget) <= pathArrivalRadiusSq and (pathNode < pathCount or activePath.loops) then
					pathNode = if pathNode < pathCount then pathNode + 1 else 1
					targetLocal = path[pathNode] - origin
					toTarget = targetLocal - position
				end
			else
				toTarget = targetLocal - position
			end

			if toTarget:Dot(toTarget) > 1 then
				targetAcceleration = (toTarget.Unit * maxSpeed) * targetBias
			end

			-- A server packet sets this target outside the hot job path. Its
			-- expiry weight makes the default target inert without a mode branch.
			reconciliationTarget = boidStats.reconciliation
			reconciliationWeight = math.clamp(reconciliationTarget.expiresAt - jobTime, 0, 1)
			reconciliationPosition = reconciliationTarget.position
				+ reconciliationTarget.velocity * math.max(jobTime - reconciliationTarget.snapshotTime, 0)
			reconciliationAcceleration = (
				(reconciliationPosition - (origin + position)) * RECONCILIATION_POSITION_GAIN
				+ (reconciliationTarget.velocity - velocity) * RECONCILIATION_VELOCITY_GAIN
			) * reconciliationWeight

			-- Gravity changes the velocity direction, so all movement remains aligned with facing.
			gravityAcceleration = Vector3.zero
			if #relevantGravityWells > 0 then
				worldPosition = origin + position
				for _, gravityWell: GravityWell in relevantGravityWells do
					vectorTo = gravityWell.position - worldPosition
					distanceSq = vectorTo:Dot(vectorTo)
					if distanceSq > 1e-8 and distanceSq <= gravityWell.influenceRadius * gravityWell.influenceRadius then
						-- Inverse-square gravitational acceleration: a = strength / r^2 toward the well.
						gravityAcceleration += vectorTo * (gravityWell.strength / (distanceSq * math.sqrt(distanceSq)))
					end
				end
			end

			local preferredObstacleDirection = if toTarget:Dot(toTarget) > 1e-8
				then toTarget.Unit
				else velocity / math.max(speed, 1e-4)
			worldPosition = origin + position
			obstacleAcceleration = Vector3.zero
			obstacleForwardRays = 0
			obstacleEscapeRays = 0
			obstacleSoftFallback = false
			obstacleDetourStarted = false
			obstacleDetourUpdated = false
			usesObstacleDetour = false
			local rejoiningPath = false
			obstacleDirection = BoidStorage.ReadObstacleDirection(page.data, boidIndex)
			local hadObstacleDetour = obstacleDirection:Dot(obstacleDirection) > 1e-8
			local observation: SharedTypes.ObstacleObservation? = nil
			if obstacleRequest and boidId == observedBoidId then
				observation = newObstacleObservation(obstacleRequest, job.groupId, jobCell.id, currentTick, jobTime,
					worldPosition, velocity, dt, preferredObstacleDirection, obstacleDirection)
			end

			if dt > 0 and speed > 1e-4 and hadObstacleDetour then
				local lookAhead = getObstacleLookAhead(speed, dt)
				local targetDistance = toTarget.Magnitude
				local targetRay = if targetDistance > 1e-4
					then toTarget * math.min(OBSTACLE_MAX_LOOK_AHEAD / targetDistance, 1)
					else Vector3.zero
				local targetHit = if targetRay:Dot(targetRay) > 1e-8
					then workspace:Raycast(worldPosition, targetRay, obstacleRaycastParams)
					else nil
				if observation and targetRay:Dot(targetRay) > 1e-8 then
					ObstacleDiagnostics.RecordProbe(observation, "Target", worldPosition, targetRay, targetHit, nil)
				end
				-- A distant hit is unrelated to this local detour; resume normal path steering.
				if not targetHit or targetHit.Distance > lookAhead then
					BoidStorage.WriteObstacleDirection(page.data, boidIndex, Vector3.zero)
					obstacleDirection = Vector3.zero
					if observation then
						observation.reason = if targetRay:Dot(targetRay) <= 1e-8 then "ReleasedNoTargetRay"
							elseif not targetHit then "ReleasedTargetClear" else "ReleasedBeyondHorizon"
					end
					rejoiningPath = toTarget:Dot(toTarget) > 1e-8
				else
					local headingHit = workspace:Raycast(worldPosition, obstacleDirection * lookAhead, obstacleRaycastParams)
					if observation then
						ObstacleDiagnostics.RecordProbe(observation, "Heading", worldPosition, obstacleDirection * lookAhead, headingHit, nil)
						observation.reason = if headingHit then "DetourDistantHit" else "DetourHeadingClear"
					end
					obstacleForwardRays = 1
					local requiredClearance = speed * dt + OBSTACLE_CLEARANCE_MARGIN
					if headingHit and headingHit.Distance <= requiredClearance then
						local escapeDirection, escapeRays = findEscapeDirection(
							boidId,
							worldPosition,
							headingHit.Normal,
							obstacleDirection,
							preferredObstacleDirection,
							obstacleDirection,
							lookAhead,
							requiredClearance,
							observation
						)
						obstacleEscapeRays = escapeRays
						if escapeDirection:Dot(escapeDirection) > 1e-8 then
							if observation then observation.reason = "DetourChanged" end
							obstacleDirection = escapeDirection
							BoidStorage.WriteObstacleDirection(page.data, boidIndex, obstacleDirection)
						end
						if observation and escapeDirection:Dot(escapeDirection) <= 1e-8 then observation.reason = "RetainedHeadingFallback" end
						-- If no safe forward candidate exists, retain the committed heading
						-- and allow best-effort movement instead of reversing along the wall.
						obstacleDetourUpdated = true
					else
						-- A farther hit is visible but cannot block this update's movement.
						obstacleDetourUpdated = true
					end
					usesObstacleDetour = obstacleDirection:Dot(obstacleDirection) > 1e-8
				end
			end

			if not usesObstacleDetour and not hadObstacleDetour and obstacleDirection:Dot(obstacleDirection) <= 1e-8 then
				obstacleAcceleration, obstacleDirection, obstacleForwardRays, obstacleEscapeRays, obstacleSoftFallback = getObstacleResponse(
					boidId,
					worldPosition,
					velocity,
					speed,
					dt,
					preferredObstacleDirection,
					maxSpeed,
					observation
				)
				if obstacleDirection:Dot(obstacleDirection) > 1e-8 then
					BoidStorage.WriteObstacleDirection(page.data, boidIndex, obstacleDirection)
					usesObstacleDetour = true
					obstacleDetourStarted = true
				end
			end

			if detailedMetrics then
				measurement.obstacleForwardRays += obstacleForwardRays
				measurement.obstacleEscapeRays += obstacleEscapeRays
				if obstacleDetourStarted then measurement.obstacleDetourStarts += 1 end
				if obstacleDetourUpdated then measurement.obstacleDetourUpdates += 1 end
				if obstacleSoftFallback then measurement.obstacleSoftFallbacks += 1 end
			end

			acceleration =
				closeness * separation +
				(avgVelocity - velocity) * alignment +
				targetAcceleration +
				reconciliationAcceleration +
				gravityAcceleration +
				obstacleAcceleration
			
			local toCenter: Vector3 = centerOfMass - position
			local toCenterMagnitudeSq: number = toCenter:Dot(toCenter)
			if toCenterMagnitudeSq > 1e-8 then
				acceleration += (toCenter / math.sqrt(toCenterMagnitudeSq)) * cohesion
			end
			--if centerOfMass:Dot(centerOfMass) > 0 then
			--	acceleration += (centerOfMass - position).Unit * cohesion
			--end

			maxAcceleration = maxSpeed * maxAccelerationScale
			if acceleration:Dot(acceleration) > maxAcceleration * maxAcceleration then
				acceleration = acceleration.Unit * maxAcceleration
			end

			if usesObstacleDetour then
				-- A committed escape owns movement until the target ray is locally clear.
				-- Keep the detour decisive instead of carrying a speed deficit into the turn.
				speed = maxSpeed
				velocity = obstacleDirection
			elseif rejoiningPath then
				-- Resume the current path immediately once its local corridor is clear.
				speed = maxSpeed
				velocity = toTarget.Unit
			else
				velocity += acceleration * steeringDt
				speed = math.clamp(velocity.Magnitude, minSpeed, maxSpeed)
				velocity = velocity.Unit
			end

			if observation then
				observation.committedAfter = obstacleDirection
				observation.softAcceleration = obstacleAcceleration
				observation.resultDirection = velocity
				observation.displacement = velocity * speed * dt
				job.obstacleObservation = observation
			end
			position += velocity * speed * dt
			x, y, z = position.X, position.Y, position.Z
			if  x < 0 or x >= CELL_SIZE
				or y < 0 or y >= CELL_SIZE
				or z < 0 or z >= CELL_SIZE
			then
				measurement.migratedBoids += 1
				worldPosition = origin + position

				local gx:number, gy:number, gz:number = Quantization.ConvertCoordsToGrid(
					worldPosition.X,
					worldPosition.Y,
					worldPosition.Z
				)

				newOrigin = Vector3.new(gx, gy, gz)
				newCellId = Quantization.GetNumericalKey(gx, gy, gz)

				networkVelocity = velocity * speed

				movedCell = movedBoids[newCellId]
				if not movedCell then
					movedCell = {}
					movedBoids[newCellId] = movedCell
				end

				table.insert(movedCell, boidId)
				table.insert(movedCell, worldPosition)
				table.insert(movedCell, networkVelocity)
				table.insert(movedCell, pathNode :: number | Vector3)
				table.insert(movedCell, pathVersion :: number | Vector3)
				table.insert(movedCell, BoidStorage.ReadObstacleDirectionCode(page.data, boidIndex) :: number | Vector3)

				if shouldEmitSnapshot then
					if detailedMetrics then snapshotStart = os.clock() end
					movedCellSnapshot = SnapshotCodec.GetOrCreateCellSnapshot(
						simulationSnapshot,
						newCellId,
						newOrigin,
						1
					)

					SnapshotCodec.AppendBoid(
						movedCellSnapshot,
						boidId,
						worldPosition - newOrigin,
						networkVelocity
					)
					if detailedMetrics then measurement.snapshotMs += (os.clock() - snapshotStart) * 1000 end
				end

				if BoidStorage.deleteBoidAtSlot(page, boidIndex, pagedBuffer) then
					jobCell.boidCount -= 1
				end

				continue
			end

			writeNewData(page.data, boidIndex, position, velocity, speed, currentTick, pathNode, pathVersion)

			if shouldEmitSnapshot then
				if detailedMetrics then snapshotStart = os.clock() end
				SnapshotCodec.AppendBoidReserved(
					cellSnapshot,
					boidId,
					position,
					velocity * speed
				)
				if detailedMetrics then measurement.snapshotMs += (os.clock() - snapshotStart) * 1000 end
			end
		end
	end
	
	measurement.survivingBoids = measurement.processedBoids - measurement.migratedBoids
	for _, cell in jobCells do measurement.returnedSourceBoids += cell.boidCount end
	if detailedMetrics then
		-- Returned page buffers retain their allocation size; include snapshot capacity.
		measurement.outputBufferBytes = measurement.inputBufferBytes
		for _, snapshot in snapshotGroups do
			for _, cell in snapshot do measurement.outputBufferBytes += buffer.len(cell.networkBoids) end
		end
	end
	job.measurement = measurement
	job.snapshotGroups = snapshotGroups
	job.neighborIterations = neighborIterations
	measurement.executionMs = (os.clock() - executionStart) * 1000
	job.completionTime = workspace:GetServerTimeNow()
	
	debug.profileend()

	bindableEvent:Fire(job, jobReceiveTime)
end

function WorkerCore.Start(actor: Actor): ()

actor:BindToMessageParallel("NewJob", function(job: Job, reply: BindableEvent, frameTick: number, sentTime: number): ()
	-- Both success and failure acknowledge completion only after all scratch access
	-- ends. The coordinator retains this reply even when it rejects late results.
	local ok, err = pcall(runJob, job, reply, frameTick, sentTime)
	if not ok then
		warn("Boids WorkerCore job failed: " .. tostring(err))
		reply:Fire(nil, 0, tostring(err))
	end
end)

actor:BindToMessage("NewBoidsStatsBatch", function(batch:ActorBoidsBatch): ()
	local data: buffer = batch.data
	
	local boidId:number, maxSpeed:number, minSpeed:number, sight:number, avoidance:number, separation:number,  repulsion:number, repulsionStrength:number, alignment:number, cohesion:number, targetBias:number
	for index: number = 0, batch.boidCount - 1 do
		boidId, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias = StatsCodec.ReadBoidRow(data, index)
		
		local lifetime = assert(batch.lifetimes[index + 1], "Missing boid lifetime")
		if lifetime <= (retiredBoids[boidId] or -1) or lifetime < (statsLifetimes[boidId] or -1) or lifetime < (pendingTargetLifetimes[boidId] or -1) then continue end
		local pending = if pendingTargetLifetimes[boidId] == lifetime then pendingReconciliationTargets[boidId] else nil
		local current = if statsLifetimes[boidId] == lifetime then globalBoidsStats[boidId] else nil
		local reconciliation = pending or (if current then current.reconciliation else nil) or {
			position = Vector3.zero,
			velocity = Vector3.zero,
			snapshotTime = 0,
			expiresAt = 0,
		}
		pendingReconciliationTargets[boidId], pendingTargetLifetimes[boidId] = nil, nil
		statsLifetimes[boidId] = lifetime

		globalBoidsStats[boidId] = {
			maxSpeed = maxSpeed,
			minSpeed = minSpeed,
			sight = sight,
			avoidance = avoidance,
			separation = (separation / 255),
			repulsion = repulsion,
			repulsionStrength = (repulsionStrength / 255),
			alignment = (alignment / 255),
			cohesion = (cohesion / 255),
			targetBias = (targetBias / 255),
			reconciliation = reconciliation,
		}
	end
end)

local function setReconciliationTarget(boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number, lifetime: number): ()
	if lifetime <= (retiredBoids[boidId] or -1) or lifetime < (statsLifetimes[boidId] or -1) or lifetime < (pendingTargetLifetimes[boidId] or -1) then return end
	local boidStats = globalBoidsStats[boidId]
	local current = if boidStats and statsLifetimes[boidId] == lifetime then boidStats.reconciliation
		elseif pendingTargetLifetimes[boidId] == lifetime then pendingReconciliationTargets[boidId] else nil
	-- Preserve accepted ordering even if Actor controls arrive around stats setup.
	if current and snapshotTime <= current.snapshotTime then return end
	local target: ReconciliationTarget = { position = position, velocity = velocity, snapshotTime = snapshotTime, expiresAt = snapshotTime + RECONCILIATION_EXPIRY_SECONDS }
	if boidStats and statsLifetimes[boidId] == lifetime then
		boidStats.reconciliation = target
	else
		pendingReconciliationTargets[boidId], pendingTargetLifetimes[boidId] = target, lifetime
	end
end

actor:BindToMessage("SetBoidReconciliationTarget", setReconciliationTarget)
actor:BindToMessage("SetBoidReconciliationTargets", function(targets: {{boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number, lifetime: number}}): ()
	for _, target in targets do
		setReconciliationTarget(target.boidId, target.position, target.velocity, target.snapshotTime, target.lifetime)
	end
end)

actor:BindToMessage("NewGroupTarget", function(groupId:number, target:Target, lifetime: number): ()
	if not acceptGroupLifetime(groupId, lifetime) then return end
	groupTargets[groupId] = target
end)

actor:BindToMessage("NewGroupPath", function(
	groupId: number,
	path: {PathNode},
	pathId: number,
	switchToClosestNode: boolean,
	loops: boolean,
	pathArrivalRadius: number,
	lifetime: number
): ()
	if not acceptGroupLifetime(groupId, lifetime) then return end
	groupPaths[groupId] = {
		nodes = path,
		id = pathId,
		switchToClosestNode = switchToClosestNode,
		loops = loops,
		arrivalRadiusSq = pathArrivalRadius * pathArrivalRadius,
	}
end)

actor:BindToMessage("NewGlobalGravityWell", function(gravityWell: GravityWell): ()
	globalGravityWells[gravityWell.id] = gravityWell
end)

actor:BindToMessage("RemoveGlobalGravityWell", function(gravityWellId: number): ()
	globalGravityWells[gravityWellId] = nil
end)

actor:BindToMessage("NewGroupGravityWell", function(groupId: number, gravityWell: GravityWell, lifetime: number): ()
	if not acceptGroupLifetime(groupId, lifetime) then return end
	local wells = groupGravityWells[groupId]
	if not wells then
		wells = {}
		groupGravityWells[groupId] = wells
	end
	wells[gravityWell.id] = gravityWell
end)

actor:BindToMessage("RemoveGroupGravityWell", function(groupId: number, gravityWellId: number, lifetime: number): ()
	if not acceptGroupLifetime(groupId, lifetime) then return end
	local wells = groupGravityWells[groupId]
	if not wells then
		return
	end
	wells[gravityWellId] = nil
	if next(wells) == nil then
		groupGravityWells[groupId] = nil
	end
end)

actor:BindToMessage("RetireBoids", function(retirements: {{boidId: number, lifetime: number}}): ()
	for _, retirement in retirements do
		local id, lifetime = retirement.boidId, retirement.lifetime
		retiredBoids[id] = math.max(retiredBoids[id] or -1, lifetime)
		if (statsLifetimes[id] or -1) <= lifetime then
			globalBoidsStats[id], statsLifetimes[id] = nil, nil
		end
		if (pendingTargetLifetimes[id] or -1) <= lifetime then
			pendingReconciliationTargets[id], pendingTargetLifetimes[id] = nil, nil
		end
	end
end)

actor:BindToMessage("RetireGroup", function(groupId: number, lifetime: number): ()
	retiredGroups[groupId] = math.max(retiredGroups[groupId] or -1, lifetime)
	if (groupLifetimes[groupId] or -1) <= lifetime then
		groupTargets[groupId], groupPaths[groupId], groupGravityWells[groupId], groupLifetimes[groupId] = nil, nil, nil, nil
	end
end)

end

return WorkerCore
