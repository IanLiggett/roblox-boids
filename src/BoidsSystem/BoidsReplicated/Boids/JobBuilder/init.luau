--!strict
--!native

local RunService = game:GetService("RunService")

local BoidsReplicated = script.Parent.Parent

local SharedTypes = require(BoidsReplicated.SharedTypes)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local LODConfig = require(BoidsReplicated.LODConfig)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local ResultCommit = require(script.Parent.ResultCommit)
local ViewerLOD = require(script.ViewerLOD)
local metrics: RuntimeMetrics.State = RuntimeMetrics.State
local detailedMetrics = metrics.mode == "detailed"

local ActorsInitializer = require(script.Parent.ActorsInitializer)
local Schedulers = require(script.Parent.Scheduler)

local Dependencies = BoidsReplicated.Dependencies
local BinaryHeaps = require(Dependencies.BinaryHeaps.Value)
local Benchmarkers = require(Dependencies.Benchmarker.Value)
local JobBuilder = {}


type ActorState = ActorsInitializer.ActorState

type Schedulee<T> = SharedTypes.Schedulee<T>

type Cell = SharedTypes.Cell
type Group = SharedTypes.Group

type Job = SharedTypes.Job

type SimulationKind = LODConfig.SimulationKind

type JobRecipients = {[number]: {number}}
local groups: SharedTypes.GroupRegistry

-- Durations are elapsed time, not CPU utilization. See the measurement reference.
function JobBuilder.GetRuntimeMetrics(sinceTotals: {[string]: number}?): SharedTypes.RuntimeMetrics
	return RuntimeMetrics.Snapshot(metrics, sinceTotals)
end

-- rough approximation of new bucketing strategy's cost
local MAX_SEEN = 100
local function computeCellCost(cell: Cell): number
	local boidCount = math.max(cell.boidCount, 1)

	if boidCount > MAX_SEEN then
		return boidCount * MAX_SEEN
	end

	return boidCount * boidCount
end

local TARGET_ACTOR_JOB_MS = 4

local nextJobId = 0

local lastScheduledByCell: {[number]: number} = {}
local lastReturnedByCell: {[number]: number} = {}
local scheduledCountByCell: {[number]: number} = {}
local returnedCountByCell: {[number]: number} = {}


local function buildJob(group: Group, currentTick: number, targetCost: number, boidsRemaining: number, frameTick: number): (Job, number, JobRecipients)
	local buildStart = os.clock()
	debug.profilebegin("Boids.BuildJob")
	
	local scheduler: SharedTypes.Scheduler<Cell> = group.scheduler

	local now: number = workspace:GetServerTimeNow()
	local job: Job = {
		detailedMetrics = detailedMetrics,
		id = nextJobId,
		groupId = group.id,
		usesPath = group.usesPath,
		jobCells = {},
		movedBoids = {},
		cellCount = 0,
		startTime = now,
		completionTime = -1,
		simulationTick = -1,
		estimatedCost = 0,
		averageSight = group.averageSight,
		neighborIterations = 0,
	}

	nextJobId += 1

	local recipients: JobRecipients = {}
	local boidsScheduled:number = 0
	local duePlayers: {number}, emitSnapshot: boolean
	local nextSchedulee:Schedulee<Cell>?, nextCell:Cell, cost:number, cellBoidCount:number
	while targetCost > job.estimatedCost and boidsRemaining - boidsScheduled > 0 do
		nextSchedulee = Schedulers.GetNextSchedulee(scheduler, currentTick)
		if not nextSchedulee then
			break
		end

		nextCell = nextSchedulee.entity
		cost = computeCellCost(nextCell)
		if cost + job.estimatedCost > targetCost and job.cellCount > 0 then
			Schedulers.EnqueueSchedulee(scheduler, nextSchedulee)
			break
		end

		cellBoidCount = nextCell.boidCount

		job.estimatedCost += cost
		boidsScheduled += cellBoidCount
		
		if RunService:IsClient() then
			-- A client-side simulation always renders its own completed cell jobs.
			-- It publishes direct local cell snapshots with no remote recipients.
			emitSnapshot = true
		else
			duePlayers, emitSnapshot = ViewerLOD.GetDuePlayersForCell(nextCell, nextSchedulee.lastUpdated, now)
		end

		job.jobCells[job.cellCount + 1] = {
			id = nextCell.id,
			origin = nextCell.origin,

			networkTick = nextCell.networkTick,
			networkInterval = nextCell.networkInterval,

			emitSnapshot = emitSnapshot,

			pages = nextCell.pages,
			pageCount = nextCell.pages.pageCount,
			scheduledBoidCount = cellBoidCount,
			processedBoidCount = 0,
			boidCount = cellBoidCount,
		}
		
		if emitSnapshot and RunService:IsServer() then
			recipients[nextCell.id] = duePlayers
		end

		Schedulers.ScheduleSchedulee(nextSchedulee)
		BoidStorage.MarkPagesPending(nextCell.pages)

		job.cellCount += 1
	end
	
	debug.profileend()

	RuntimeMetrics.Add(metrics, "jobBuildMs", (os.clock() - buildStart) * 1000)
	return job, boidsScheduled, recipients
end

local function getNextGroupWithWork(now: number, boidBudgets: {[SimulationKind]: number}): Group?
	local bestGroup: Group? = nil
	local bestWakeTime = math.huge

	local wakeTime:number?
	for _, group: Group in groups do
		if group.cellCount <= 0 or boidBudgets[LODConfig.GetSimulationKindForGroup(group.id)] <= 0 then
			continue
		end

		wakeTime = Schedulers.PeekNextWakeTime(group.scheduler)
		if not wakeTime then
			continue
		end

		if wakeTime <= now and wakeTime < bestWakeTime then
			bestWakeTime = wakeTime
			bestGroup = group
		end
	end

	return bestGroup
end

local frameTick = 0
local nextActorStart = 1
local actorCount = 0

local function assignWorkForFrame(currentTick: number): ()
	frameTick += 1
	debug.profilebegin("Boids.WorkAssignment")
	
	--local frameBudgetRemaining = MAX_FRAME_COST
	local frameBudgetRemaining = 1000000
	local boidBudgets: {[SimulationKind]: number} = {
		server = LODConfig.GetSimulationConfig("server").maxBoidsPerFrame,
		clientPrediction = LODConfig.GetSimulationConfig("clientPrediction").maxBoidsPerFrame,
		clientLocal = LODConfig.GetSimulationConfig("clientLocal").maxBoidsPerFrame,
	}

	local selectedGroup: Group?
	local index: number, actor: ActorState
	for offset = 0, actorCount - 1 do
		index = (nextActorStart + offset - 1) % actorCount + 1
		actor = ActorsInitializer.actors[index]
		
		if frameBudgetRemaining <= 0 then
			break
		end

		if not ActorsInitializer.IsActorFree(actor) then
			continue
		end

		local actorBudget: number = math.min(actor.targetJobWork, frameBudgetRemaining)
		local attempts: number = 0
		local maxGroupAttempts: number = 8

		while attempts < maxGroupAttempts do
			attempts += 1

			selectedGroup = getNextGroupWithWork(currentTick, boidBudgets)
			if not selectedGroup then
				break
			end

			local group: Group = selectedGroup
			local simulationKind = LODConfig.GetSimulationKindForGroup(group.id)
			local job: Job, boidsScheduled: number, recipients: JobRecipients = buildJob(
				group,
				currentTick,
				actorBudget,
				boidBudgets[simulationKind],
				frameTick
			)

			if job.estimatedCost > 0 and boidsScheduled > 0 then
				boidBudgets[simulationKind] -= boidsScheduled
				frameBudgetRemaining -= job.estimatedCost
				ResultCommit.Run(group, actor, job, frameTick, TARGET_ACTOR_JOB_MS, recipients)

				break
			end

			warn(`Group {group.id} selected but built no job`)

		end
	end
	
	nextActorStart = (nextActorStart % actorCount) + 1
	
	debug.profileend()
end

local function collectStats(elapsed: number): ()
	if not groups then
		return
	end
	
	for _, group: Group in groups do
		
		Benchmarkers.push(group.cellsPerSecond, RuntimeMetrics.Rate(group.cellsThisSecond, elapsed))
		Benchmarkers.push(group.boidsPerSecond, RuntimeMetrics.Rate(group.boidsThisSecond, elapsed))
		
		group.cellsThisSecond = 0
		group.boidsThisSecond = 0
	end
end

local lastCleanup:number = os.clock()
local cleanupInterval = 30
-- Cell heaps retain lazy invalidation; the group registry has no heap.
local function cleanupGroupHeaps(): ()
	lastCleanup = os.clock()

	for _, group: Group in groups do
		if BinaryHeaps.size(group.scheduler.heap) > group.cellCount * 4 + 64 then
			Schedulers.RebuildSchedulerHeap(group.scheduler)
		end
	end
end

local lastStatsCollect = os.clock()
local function onHeartbeat(dt: number): ()
	local schedulerStart = os.clock()
	local now:number = workspace:GetServerTimeNow()
	
	local elapsed: number?
	lastStatsCollect, elapsed = RuntimeMetrics.PollInterval(lastStatsCollect, schedulerStart, 1)
	if elapsed then collectStats(elapsed) end
	RuntimeMetrics.Sample(metrics, "frameMs", dt * 1000)

	if os.clock() - lastCleanup > cleanupInterval then
		cleanupGroupHeaps()
	end

	assignWorkForFrame(now)
	RuntimeMetrics.Add(metrics, "schedulerMs", (os.clock() - schedulerStart) * 1000)
end

local isStarted = false
function JobBuilder.Start(registry: SharedTypes.GroupRegistry, targetActorJobMs: number): ()
	if isStarted then return end
	isStarted = true
	groups = registry
	ResultCommit.Start(registry)
	actorCount = #ActorsInitializer.actors
	assert(actorCount > 0, "Actors must be initialized before scheduling")
	TARGET_ACTOR_JOB_MS = targetActorJobMs
	lastStatsCollect, lastCleanup = os.clock(), os.clock()
	ViewerLOD.Start()
	RunService.Heartbeat:Connect(onHeartbeat)
end

JobBuilder.SetViewerObservers = ViewerLOD.SetViewerObservers
JobBuilder.ResetViewerObservers = ViewerLOD.ResetViewerObservers
return JobBuilder
