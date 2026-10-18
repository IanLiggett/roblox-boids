--!strict
--!native

local RunService = game:GetService("RunService")

local BoidsReplicated = script.Parent.Parent

local SharedTypes = require(BoidsReplicated.SharedTypes)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local ResultCommit = require(script.Parent.ResultCommit)
local ViewerLOD = require(script.ViewerLOD)
local DispatchPump = require(script.DispatchPump)
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


local function buildJob(group: Group, currentTick: number, targetCost: number, frameTick: number): (Job, number, JobRecipients)
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
	while targetCost > job.estimatedCost do
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

local function getNextGroupWithWork(now: number): (Group?, number?)
	local bestGroup: Group? = nil
	local bestWakeTime = math.huge
	for _, group in groups do
		if group.cellCount <= 0 then continue end
		local wakeTime = Schedulers.PeekNextWakeTime(group.scheduler)
		if wakeTime and wakeTime < bestWakeTime then
			bestWakeTime = wakeTime
			bestGroup = group
		end
	end
	return if bestWakeTime <= now then bestGroup else nil,
		if bestWakeTime < math.huge then bestWakeTime else nil
end

local frameTick = 0
local nextActorStart = 1
local actorCount = 0
local dispatchPump: DispatchPump.Pump? = nil
local dispatchCounters: {[DispatchPump.Trigger]: SharedTypes.RuntimeCounterName} = {
	heartbeat = "heartbeatDispatches", completion = "completionDispatches", timer = "timerDispatches",
}

local function assignWork(deadline: number, trigger: DispatchPump.Trigger): (DispatchPump.StopReason, number?)
	debug.profilebegin("Boids.WorkAssignment")
	local stopReason: DispatchPump.StopReason = "noActors"
	local nextDelay: number? = nil
	local startIndex = nextActorStart
	for offset = 0, actorCount - 1 do
		if os.clock() >= deadline then stopReason = "budget"; break end
		local index = (startIndex + offset - 1) % actorCount + 1
		local actor = ActorsInitializer.actors[index]
		if not ActorsInitializer.IsActorFree(actor) then continue end
		for _ = 1, 8 do
			local now = workspace:GetServerTimeNow()
			local group, wakeTime = getNextGroupWithWork(now)
			if os.clock() >= deadline then stopReason = "budget"; break end
			if not group then
				stopReason = "noDue"
				nextDelay = if wakeTime then math.max(wakeTime - now, 0) else nil
				break
			end
			local job, boidsScheduled, recipients = buildJob(group, now, actor.targetJobWork, frameTick)
			if job.estimatedCost > 0 and boidsScheduled > 0 then
				nextActorStart = index % actorCount + 1
				RuntimeMetrics.Sample(metrics, "cellOverdueMs", math.max(now - (wakeTime :: number), 0) * 1000)
				RuntimeMetrics.Add(metrics, dispatchCounters[trigger], 1)
				ResultCommit.Run(group, actor, job, frameTick, TARGET_ACTOR_JOB_MS, recipients)
				break
			end
			-- GetNextSchedulee removes invalid heap entries; bounded retries let
			-- the next group proceed without spinning on an empty selection.
		end
		if stopReason == "budget" or stopReason == "noDue" then break end
	end
	if os.clock() >= deadline then stopReason = "budget"; nextDelay = nil end
	debug.profileend()
	return stopReason, nextDelay
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
	
	local elapsed: number?
	lastStatsCollect, elapsed = RuntimeMetrics.PollInterval(lastStatsCollect, schedulerStart, 1)
	if elapsed then collectStats(elapsed) end
	RuntimeMetrics.Sample(metrics, "frameMs", dt * 1000)

	if os.clock() - lastCleanup > cleanupInterval then
		cleanupGroupHeaps()
	end

	frameTick += 1
	local pump = dispatchPump
	if pump then pump.BeginFrame() end
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
	dispatchPump = DispatchPump.New(0.001, {
		Clock = os.clock,
		Defer = function(callback: () -> ()): () task.defer(callback) end,
		Delay = function(seconds: number, callback: () -> ()): thread return task.delay(seconds, callback) end,
		Cancel = function(timer: thread): () task.cancel(timer) end,
		Run = assignWork,
		Observe = function(_: DispatchPump.Trigger, reason: DispatchPump.StopReason, seconds: number): ()
			RuntimeMetrics.Add(metrics, "dispatchPumps", 1)
			RuntimeMetrics.Add(metrics, "dispatchPumpMs", seconds * 1000)
			RuntimeMetrics.Add(metrics, "schedulerMs", seconds * 1000)
			local counter: SharedTypes.RuntimeCounterName = if reason == "budget" then "dispatchBudgetStops"
				elseif reason == "noActors" then "dispatchNoActorStops" else "dispatchNoDueStops"
			RuntimeMetrics.Add(metrics, counter, 1)
		end,
	})
	ActorsInitializer.SetOnActorReusable(function(_: ActorState): ()
		local pump = dispatchPump
		if pump then pump.Request("completion") end
	end)
	ViewerLOD.Start()
	RunService.Heartbeat:Connect(onHeartbeat)
end

JobBuilder.SetViewerObservers = ViewerLOD.SetViewerObservers
JobBuilder.ResetViewerObservers = ViewerLOD.ResetViewerObservers
return JobBuilder
