--!strict
-- Runtime-owned diagnostic reads. Callers receive independent values only.
local BoidsReplicated = script.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local ActorsInitializer = require(script.Parent.ActorsInitializer)
local Benchmarkers = require(BoidsReplicated.Dependencies.Benchmarker.Value :: typeof(game.ReplicatedStorage.ExternalLibraries.Benchmarker))

local Diagnostics = {}

local function copyStats(stats: Benchmarkers.Benchmarker): SharedTypes.NumericStatsSummary
	return {
		sampleCount = stats.itemCount, average = stats.avg, median = stats.med,
		minimum = if stats.itemCount > 0 then stats.min else nil,
		maximum = if stats.itemCount > 0 then stats.max else nil,
		standardDeviation = stats.SD, staleThreshold = stats.staleThreshold, staleCount = stats.staleCount,
	}
end

function Diagnostics.ReadSummary(groups: SharedTypes.GroupRegistry, actorCount: number): SharedTypes.RuntimeSummary
	local groupCount, population, cellCount = 0, 0, 0
	for _, group in groups do
		groupCount += 1
		population += group.boidCount
		cellCount += group.cellCount
	end
	return {groupCount = groupCount, population = population, cellCount = cellCount, actorCount = actorCount}
end

function Diagnostics.Read(
	groups: SharedTypes.GroupRegistry,
	actors: {ActorsInitializer.ActorState},
	isCellDue: (SharedTypes.Schedulee<SharedTypes.Cell>, number) -> boolean,
	hasDetailedMetrics: boolean
): SharedTypes.RuntimeDiagnostics
	local now = workspace:GetServerTimeNow()
	local result: SharedTypes.RuntimeDiagnostics = {
		sampledAt = now, summary = Diagnostics.ReadSummary(groups, #actors),
		cells = {total = 0, valid = 0, scheduled = 0, maxPopulation = 0, oldestAge = 0, oldestId = 0},
		groups = {}, actors = {},
	}
	for index, actor in actors do
		table.insert(result.actors, {
			index = index, idleSeconds = copyStats(actor.timeIdleStats),
			completedJobs = actor.completedJobs, processedBoids = actor.processedBoids,
			workerExecutionMs = actor.workerExecutionMs,
		})
	end
	for _, group in groups do
		for _, cellSchedulee in group.scheduler.schedulees do
			local cells = result.cells
			cells.total += 1
			cells.maxPopulation = math.max(cells.maxPopulation, cellSchedulee.entity.boidCount)
			if cellSchedulee.alreadyScheduled then cells.scheduled += 1 end
			if isCellDue(cellSchedulee, now) then cells.valid += 1 end
			local age = now - cellSchedulee.lastUpdated
			if age > cells.oldestAge then cells.oldestAge, cells.oldestId = age, cellSchedulee.entity.id end
		end
		table.insert(result.groups, {
			groupId = group.id, jobMs = copyStats(group.jobMsStats),
			neighborWorkPerJob = if hasDetailedMetrics then copyStats(group.neighborItersPerJob) else nil,
			inboundMs = copyStats(group.jobSendStats), outboundMs = copyStats(group.jobReceiveStats),
			cellsPerSecond = copyStats(group.cellsPerSecond), boidsPerSecond = copyStats(group.boidsPerSecond),
		})
	end
	return result
end

return Diagnostics
