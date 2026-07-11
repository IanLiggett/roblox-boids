--!native
--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTableRegistry = game:GetService("SharedTableRegistry")

local ActorsManagerModule = ServerScriptService:QueryDescendants(">> .actors-manager-module")[1]

if not script:IsDescendantOf(ActorsManagerModule) then
	return
end

local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(game:GetService("ServerScriptService").BoidsSystem.BoidsReplicated)

local BoidBatches = require(ServerScriptService.BoidsSystem.Boids.BoidBatches)
local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local NetworkResults = require(BoidsReplicated.NetworkResults)

type SimulationSnapshot = SharedTypes.SimulationSnapshot
type CellSnapshot = SharedTypes.CellSnapshot

type Job = SharedTypes.Job
type JobCell = SharedTypes.JobCell
type Target = SharedTypes.Target
type Page = SharedTypes.Page
type PagedBuffer = SharedTypes.PagedBuffer

type ActorBoidsBatch = BoidBatches.ActorBoidsBatch

local writeQuantizedPositionU8 = Quantization.writeQuantizedPositionU8
local writeQuantizedVelocityU8 = Quantization.writeQuantizedVelocityU8
local writeQuantizedPositionU16 = Quantization.writeQuantizedPositionU16
local writeQuantizedVelocityU16 = Quantization.writeQuantizedVelocityU16

local readQuantizedPositionU8 = Quantization.readQuantizedPositionU8
local readQuantizedVelocityU8 = Quantization.readQuantizedVelocityU8
local readQuantizedPositionU16 = Quantization.readQuantizedPositionU16
local readQuantizedVelocityU16 = Quantization.readQuantizedVelocityU16

local writeLastTick = Quantization.writeLastTick
local readLastTick = Quantization.readLastTick
local currentSimTick = Quantization.currentSimTick
local tickDeltaSeconds = Quantization.tickDeltaSeconds

local CELL_SIZE:number = Quantization.CELL_SIZE
local MAX_U8: number = Quantization.MAX_U8_INT

local NORM_VELOCITY_MIN:number = Quantization.NORM_VELOCITY_MIN
local NORM_VELOCITY_RANGE:number = Quantization.NORM_VELOCITY_RANGE
local VELOCITY_MIN:number = Quantization.VELOCITY_MIN
local VELOCITY_RANGE:number = Quantization.VELOCITY_RANGE


local U8_POS_DEQUANTIZE_SCALE: number = CELL_SIZE / MAX_U8
local U8_VEL_DEQUANTIZE_SCALE: number = NORM_VELOCITY_RANGE / MAX_U8


local actor:Actor = script.Parent :: any

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
	targetBias:number
}

type Bucket = {
	liveIndices: {number},
	centerOfMass: Vector3,
	velocity: Vector3,
	boidCount: number
}

local groupTargets:{[number]:Target} = {}

local globalBoidsStats:{[number]:BoidStats} = {}

-- this may be slower than simply passing over localBoidPositions once and deserializing it
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

local Rays = {
	Vector3.new(0, 0, -1),
	Vector3.new(1, 0, -3),
	Vector3.new(-1, 0, -3),
	Vector3.new(0, 1, -3),
	Vector3.new(0, -1, -3)
}

local function readData(data: buffer, slot: number): (number, Vector3, Vector3, number, number, number)
	return 
		BoidStorage.readBoidId(data, slot),
		Vector3.new(BoidStorage.readPosition(data, slot)),
		Vector3.new(BoidStorage.readVelocity(data, slot)) * BoidStorage.readSpeed(data, slot),
		BoidStorage.readLastTick(data, slot),
		BoidStorage.readPathNode(data, slot),
		BoidStorage.readPathVersion(data, slot)
end

local function writeNewData(data: buffer, slot: number, position: Vector3, velocity: Vector3, speed: number, currentTick: number, pathNode: number, pathVersion: number)
	BoidStorage.writePosition(data, slot, position.X, position.Y, position.Z)
	BoidStorage.writeVelocity(data, slot, velocity.X, velocity.Y, velocity.Z)
	BoidStorage.writeSpeed(data, slot, speed)
	BoidStorage.writeLastTick(data, slot, currentTick)
	BoidStorage.writePathNode(data, slot, pathNode)
	BoidStorage.writePathVersion(data, slot, pathVersion)
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

	--local x: {number} = table.create(offsetCount) :: {number}
	--local y: {number} = table.create(offsetCount) :: {number}
	--local z: {number} = table.create(offsetCount) :: {number}

	--for index: number, offset: {number} in offsets do
	--	x[index] = offset[1]
	--	y[index] = offset[2]
	--	z[index] = offset[3]
	--end

	--local search: BucketSearch = {
	--	x = x,
	--	y = y,
	--	z = z,
	--	count = offsetCount,
	--}
	
	local search: BucketSearch = {}
	
	for _, offset: {number} in offsets do
		offset[4] = nil
		offset[5] = nil
		table.insert(search, offset)
	end

	bucketSearchCache[searchRadius] = search
	return search
end

actor:BindToMessageParallel("NewJob", function(job:Job, bindableEvent:BindableEvent)
	--print(`WORKER START job={job.id}, cells={job.cellCount}`)
	
	local simulationSnapshot: SimulationSnapshot = {}
	local snapshotByCellId: {[number]: CellSnapshot} = {}

	local movedBoids: {[number]: {number | Vector3}} = job.movedBoids
	local movedCell: {number | Vector3}

	local jobCells: {[number]: JobCell} = job.jobCells
	local pagedBuffer: PagedBuffer
	local pages: {Page}
	
	local cellBoidCount: number
	local origin: Vector3, newOrigin: Vector3, newCellId: number

	local cellSnapshot: CellSnapshot, movedCellSnapshot: CellSnapshot
	local shouldEmitSnapshot: boolean

	local target: Vector3 = groupTargets[job.groupId] and groupTargets[job.groupId].Position or Vector3.zero
	local targetLocal: Vector3, toTarget: Vector3

	local currentTick: number = currentSimTick()

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
	local acceleration: Vector3, targetAcceleration: Vector3
	local repulsionDistance: number

	local separationCount: number, alignmentCount: number, cohesionCount: number

	local maxAccelerationScale: number = 2
	local maxAcceleration: number

	local otherBoidIndex: number, otherBoidStats: BoidStats, otherPageIds: buffer
	local otherPosition: Vector3, otherVelocity: Vector3

	local deserializedPositions: {Vector3}, deserializedVelocities: {Vector3}
	
	local isBucketting: boolean
	
	local raycastResult: RaycastResult?
	local normal: Vector3
	local boidCFrame: CFrame

	local representativeSight = job.averageSight
	local bucketSize = representativeSight
	local maxSight = representativeSight * 2
	--local bucketSearch: BucketSearch = getBucketSearch(math.ceil(maxSight / bucketSize))
	local bucketSearch: BucketSearch = getBucketSearch(1)
	
	-- benchmarking
	local neighborIterations: number = 0
	
	local buckets: {[number]: Bucket} = {}
	
	local ids: {number}, positions: {Vector3}, velocities: {Vector3}, lastTicks: {number}, pathNodes: {number}, pathVersions: {number}, pagesByIndex: {Page}, slotsByIndex: {number}, bucketXs: {number}, bucketYs: {number}, bucketZs: {number}

	for _, jobCell:JobCell in jobCells do
		isBucketting = jobCell.boidCount > MAX_SEEN
		--isBucketting = true
		
		if isBucketting then
			table.clear(buckets)
		end
		
		cellBoidCount = jobCell.boidCount
		origin = jobCell.origin
		pagedBuffer = jobCell.pages
		pages = pagedBuffer.pages
		
		targetLocal = target - origin
		
		shouldEmitSnapshot = jobCell.networkTick % jobCell.networkInterval == 0
		
		ids = table.create(cellBoidCount) :: {number}
		positions = table.create(cellBoidCount) :: {Vector3}
		velocities = table.create(cellBoidCount) :: {Vector3}

		lastTicks = table.create(cellBoidCount) :: {number}
		pathNodes = table.create(cellBoidCount) :: {number}
		pathVersions = table.create(cellBoidCount) :: {number}

		pagesByIndex = table.create(cellBoidCount) :: {Page}
		slotsByIndex = table.create(cellBoidCount) :: {number}

		bucketXs = table.create(cellBoidCount) :: {number}
		bucketYs = table.create(cellBoidCount) :: {number}
		bucketZs = table.create(cellBoidCount) :: {number}
		
		-- must rework a bit to make this work
		--deserializedPositions = table.create(cellBoidCount) :: {Vector3}
		--deserializedVelocities = table.create(cellBoidCount) :: {Vector3}
		
		-- plan to attempt to remove ids later by having client track state identically to server, may require sending dead buffer (much smaller)
		-- removing ids may be far more complicated than its worth
		if shouldEmitSnapshot then
			cellSnapshot = NetworkResults.getOrCreateCellSnapshot(
				simulationSnapshot,
				snapshotByCellId,
				jobCell.id,
				origin,
				cellBoidCount
			)
		end
		
		local nextLiveIndex: number = 0
		local bucketKey: number

		local bx: number, by: number, bz: number
		for _, page: Page in pages do
			data = page.data
			
			local bucket: Bucket
			local bitIndex: number, boidIndex: number
			for baseSlot: number, liveMask: number in BoidStorage.liveWords(page) :: () -> (number, number) do
				while liveMask ~= 0 do
					bitIndex = bit32.countrz(liveMask)
					boidIndex = baseSlot + bitIndex
					liveMask = bit32.band(liveMask, liveMask - 1)

					nextLiveIndex += 1

					offset = boidIndex * ROW_BYTES

					boidId, position, velocity, lastTick, pathNode, pathVersion = readData(data, boidIndex)

					ids[nextLiveIndex] = boidId
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
						bucket = {
							liveIndices = {nextLiveIndex},
							centerOfMass = position,
							velocity = velocity,
							boidCount = 1
						}
						buckets[bucketKey] = bucket
						
						continue
					end
					
					
					
					table.insert(bucket.liveIndices, nextLiveIndex)
				end
			end
			
			local liveCount: number = nextLiveIndex
			local boidIndex: number
			local page: Page
			local neighborKey: number, neighborBucket: {number}
			for liveIndex: number = 1, liveCount do
				boidId, position, velocity, lastTick, pathNode, pathVersion, page, boidIndex, bx, by, bz = 
					ids[liveIndex], positions[liveIndex], velocities[liveIndex], lastTicks[liveIndex], pathNodes[liveIndex], pathVersions[liveIndex], pagesByIndex[liveIndex], slotsByIndex[liveIndex], bucketXs[liveIndex], bucketYs[liveIndex], bucketZs[liveIndex]
				
				boidStats = globalBoidsStats[boidId]
				if not boidStats then
					continue
				end
				
				maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias =
					boidStats.maxSpeed, boidStats.minSpeed, boidStats.sight, boidStats.avoidance, boidStats.separation, boidStats.repulsion, boidStats.repulsionStrength, boidStats.alignment, boidStats.cohesion, boidStats.targetBias

				closeness = Vector3.zero
				avgVelocity = Vector3.zero
				centerOfMass = Vector3.zero

				separationCount = 0
				alignmentCount = 0
				cohesionCount = 0
				
				if isBucketting then
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

						for _, otherLiveIndex: number in neighborBucket do
							neighborIterations += 1

							if liveIndex == otherLiveIndex then
								continue
							end

							otherBoidStats = globalBoidsStats[ids[otherLiveIndex]]
							if not otherBoidStats then
								continue
							end

							repulsionDistance = avoidance + otherBoidStats.repulsion
							otherPosition, otherVelocity = positions[otherLiveIndex], velocities[otherLiveIndex]

							vectorTo = (position - otherPosition)
							distanceSq = vectorTo:Dot(vectorTo)
							if distanceSq > math.max(sight, repulsionDistance)^2 then
								continue
							end

							if distanceSq < repulsionDistance^2 and distanceSq > 0 then
								closeness += vectorTo.Unit * math.max(repulsionDistance - math.sqrt(distanceSq), 0) * otherBoidStats.repulsionStrength
								separationCount += 1
							else
								avgVelocity += otherVelocity
								centerOfMass += otherPosition
								alignmentCount += 1
								cohesionCount += 1
							end

							if separationCount + alignmentCount >= MAX_SEEN then
								break
							end
						end

						-- consider removing this check later if it makes sense to
						if separationCount + alignmentCount >= MAX_SEEN then
							break
						end
					end
				else
					for otherLiveIndex: number = 1, liveCount do
						neighborIterations += 1

						if liveIndex == otherLiveIndex then
							continue
						end

						otherBoidStats = globalBoidsStats[ids[otherLiveIndex]]
						if not otherBoidStats then
							continue
						end

						repulsionDistance = avoidance + otherBoidStats.repulsion
						otherPosition, otherVelocity = positions[otherLiveIndex], velocities[otherLiveIndex]

						vectorTo = (position - otherPosition)
						distanceSq = vectorTo:Dot(vectorTo)
						if distanceSq > math.max(sight, repulsionDistance)^2 then
							continue
						end

						if distanceSq < repulsionDistance^2 and distanceSq > 0 then
							closeness += vectorTo.Unit * math.max(repulsionDistance - math.sqrt(distanceSq), 0) * otherBoidStats.repulsionStrength
							separationCount += 1
						else
							avgVelocity += otherVelocity
							centerOfMass += otherPosition
							alignmentCount += 1
							cohesionCount += 1
						end
						
						if separationCount + alignmentCount >= MAX_SEEN then
							break
						end
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
				steeringDt = math.min(dt, 0.1)

				targetAcceleration = Vector3.zero
				toTarget = targetLocal - position
				if toTarget:Dot(toTarget) > 1 then
					targetAcceleration = (toTarget.Unit * maxSpeed) * targetBias
				end

				acceleration =
					closeness * separation +
					(avgVelocity - velocity) * alignment +
					targetAcceleration

				if centerOfMass:Dot(centerOfMass) > 0 then
					acceleration += (centerOfMass - position).Unit * cohesion
				end

				maxAcceleration = maxSpeed * maxAccelerationScale
				if acceleration:Dot(acceleration) > maxAcceleration * maxAcceleration then
					acceleration = acceleration.Unit * maxAcceleration
				end

				velocity += acceleration * steeringDt

				--speed = velocity.Magnitude
				--boidCFrame = CFrame.lookAt(position, position + velocity)
				--for _, ray:Vector3 in Rays do
				--	ray = boidCFrame:VectorToWorldSpace(ray.Unit)

				--	raycastResult = workspace:Raycast(origin + position, ray * speed)
				--	if raycastResult then
				--		normal = raycastResult.Normal
				--		velocity +=
				--			(velocity - 2 * (velocity:Dot(normal)) * normal) * (speed - raycastResult.Distance)^1
				--		--(boidPosition - raycastResult.Position)
				--	end
				--end

				-- clamp speed
				speed = math.clamp(velocity.Magnitude, minSpeed, maxSpeed)
				velocity = velocity.Unit

				position += velocity * speed * dt
				x, y, z = position.X, position.Y, position.Z
				if  x < 0 or x >= CELL_SIZE
					or y < 0 or y >= CELL_SIZE
					or z < 0 or z >= CELL_SIZE
				then
					worldPosition = origin + position

					local gx:number, gy:number, gz:number = Quantization.convertCoordsToGrid(
						worldPosition.X,
						worldPosition.Y,
						worldPosition.Z
					)

					newOrigin = Vector3.new(gx, gy, gz)
					newCellId = Quantization.getNumericalKey(gx, gy, gz)

					networkVelocity = velocity * speed

					movedCell = movedBoids[newCellId]
					if not movedCell then
						movedCell = {}
						movedBoids[newCellId] = movedCell
					end

					table.insert(movedCell, boidId)
					table.insert(movedCell, worldPosition)
					table.insert(movedCell, networkVelocity)

					if shouldEmitSnapshot then
						movedCellSnapshot = NetworkResults.getOrCreateCellSnapshot(
							simulationSnapshot,
							snapshotByCellId,
							newCellId,
							newOrigin,
							1
						)

						NetworkResults.appendBoid(
							movedCellSnapshot,
							boidId,
							worldPosition - newOrigin,
							networkVelocity
						)
					end

					if BoidStorage.deleteBoidAtSlot(page, boidIndex, pagedBuffer) then
						jobCell.boidCount -= 1
					end

					continue
				end

				writeNewData(page.data, boidIndex, position, velocity, speed, currentTick, pathNode, pathVersion)

				if shouldEmitSnapshot then
					NetworkResults.appendBoid(
						cellSnapshot,
						boidId,
						position,
						velocity * speed
					)
				end
			end
		end
	end
	
	job.completionTime = workspace:GetServerTimeNow()
	job.snapshotPackets = NetworkResults.convertSimulationSnapshotToPackets(simulationSnapshot)
	job.neighborIterations = neighborIterations

	bindableEvent:Fire(job)
end)

actor:BindToMessageParallel("NewBoidsStatsBatch", function(batch:ActorBoidsBatch)
	local data: buffer = batch.data
	
	local boidId:number, maxSpeed:number, minSpeed:number, sight:number, avoidance:number, separation:number,  repulsion:number, repulsionStrength:number, alignment:number, cohesion:number, targetBias:number
	for index: number = 0, batch.boidCount - 1 do
		boidId, maxSpeed, minSpeed, sight, avoidance, separation, repulsion, repulsionStrength, alignment, cohesion, targetBias = BoidBatches.readBoidRow(data, index)
		
		globalBoidsStats[boidId] = {
			maxSpeed = maxSpeed,
			minSpeed = minSpeed,
			sight = sight,
			avoidance = avoidance,
			separation = separation,
			repulsion = repulsion,
			repulsionStrength = repulsionStrength,
			alignment = alignment,
			cohesion = cohesion,
			targetBias = targetBias
		}
	end
end)

actor:BindToMessage("NewGroupTarget", function(groupId:number, target:Target)
	groupTargets[groupId] = target
end)
