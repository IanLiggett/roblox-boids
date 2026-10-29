--!strict
-- Coordinator result commit/settlement. Actor execution itself remains owned by JobExecution.
local RunService = game:GetService("RunService")
local BoidsReplicated = script.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local NetworkResults = require(BoidsReplicated.NetworkResults)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local ObstacleDiagnostics = require(script.Parent.ObstacleDiagnostics)
local ActorsInitializer = require(script.Parent.ActorsInitializer)
local Schedulers = require(script.Parent.Scheduler)
local Cells = require(script.Parent.Cells)
local ViewerLOD = require(script.Parent.JobBuilder.ViewerLOD)
local Benchmarkers = require(BoidsReplicated.Dependencies.Benchmarker.Value :: typeof(game.ReplicatedStorage.ExternalLibraries.Benchmarker))
local ResultCommit = {}
local metrics = RuntimeMetrics.State
local detailedMetrics = metrics.mode == "detailed"
type Group = SharedTypes.Group
type Cell = SharedTypes.Cell
type Schedulee<T> = SharedTypes.Schedulee<T>
type Scheduler<T> = SharedTypes.Scheduler<T>
type Job = SharedTypes.Job
type WorkerJobCell = SharedTypes.WorkerJobCell
type WorkerJobResult = SharedTypes.WorkerJobResult
type ActorState = ActorsInitializer.ActorState
type JobOutcome = ActorsInitializer.JobOutcome
type JobRecipients = {[number]: {number}}
local groups: SharedTypes.GroupRegistry

export type CompletedBoidBatch = {
	groupId: number,
	boidIds: {number},
	positions: {Vector3},
	velocities: {Vector3},
	completionTime: number,
}
type PostMergeObserver = (batch: CompletedBoidBatch) -> ()

local postMergeObservers: {[number]: PostMergeObserver} = {}
local nextPostMergeObserverId = 0

function ResultCommit.SubscribePostMerge(observer: PostMergeObserver): () -> ()
	nextPostMergeObserverId += 1
	local observerId = nextPostMergeObserverId
	postMergeObservers[observerId] = observer
	return function(): ()
		postMergeObservers[observerId] = nil
	end
end

local function emitPostMergeBatch(groupId: number, boidIds: {number}, positions: {Vector3}, velocities: {Vector3}, completionTime: number): ()
	if next(postMergeObservers) == nil or next(boidIds) == nil then --#boidIds == 0 then
		return
	end
	local batch: CompletedBoidBatch = {
		groupId = groupId,
		boidIds = boidIds,
		positions = positions,
		velocities = velocities,
		completionTime = completionTime,
	}
	for _, observer in postMergeObservers do
		local ok, err = pcall(observer, batch)
		if not ok then
			warn("Boids post-merge observer failed: " .. tostring(err))
		end
	end
end

-- This process-local opt-in never changes cell scheduling or correction payloads.
local observedBoidId: number? = nil
local observedGroupId: number? = nil
local obstacleGeneration = 0
local lastObstacleJob = -1
local obstacleObservation: SharedTypes.ObstacleObservation? = nil

function ResultCommit.SetObstacleObservation(boidId: number?, groupId: number?): ()
	obstacleGeneration += 1
	observedBoidId, observedGroupId = boidId, groupId
	lastObstacleJob = -1
	obstacleObservation = nil
end

function ResultCommit.GetObstacleObservation(): SharedTypes.ObstacleObservation?
	return if obstacleObservation then ObstacleDiagnostics.Copy(obstacleObservation) else nil
end

local function acceptObstacleObservation(job: Job, result: WorkerJobResult, returnedCells: {[number]: boolean}): ()
	local value = result.obstacleObservation
	local request = job.obstacleRequest
	if not value or not request or observedBoidId == nil
		or value.generation ~= obstacleGeneration or request.generation ~= obstacleGeneration
		or value.boidId ~= observedBoidId or value.groupId ~= observedGroupId
		or value.jobOrder ~= job.id or value.jobOrder <= lastObstacleJob
		or not returnedCells[value.cellId] then return end
	local group = groups[value.groupId]
	local entry = BoidStorage.BoidRegistry[value.boidId]
	if not group or not entry or not group.activeCells[entry.cellId] then return end
	obstacleObservation = value
	lastObstacleJob = value.jobOrder
end

local function reAddCellToQueue(group: Group, scheduler: Scheduler<Cell>, schedulee: Schedulee<Cell>, now: number): ()
	local newMultiplier: number = ViewerLOD.GetCellSimMultiplier(group, schedulee.entity)
	
	Schedulers.SetIntervalMultiplierSoft(schedulee, newMultiplier)
	Schedulers.MarkScheduleeCompleted(scheduler, schedulee, now)
end


local function handleJobResults(group: Group, job: Job, jobResults: WorkerJobResult, returnedCells: {[number]:boolean}, recipients: JobRecipients): ()

	if groups[group.id] ~= group then
		RuntimeMetrics.Add(metrics, "discardedJobs", 1)
		warn("running job returned for nonexistant group")
		return
	end
	
	local completionTime:number = jobResults.completionTime
	local activeCells: {[number]: Cell} = group.activeCells

	Benchmarkers.push(group.jobMsStats, (jobResults.measurement :: SharedTypes.WorkerMeasurement).executionMs)
	if detailedMetrics then Benchmarkers.push(group.neighborItersPerJob, jobResults.neighborIterations) end
	local mergeStart = os.clock()
	local observerPreparationMs = 0
	-- Only decode completed rows when a subscriber will receive the post-merge batch.
	local hasPostMergeObservers = next(postMergeObservers) ~= nil

	local updatedCells, updatedBoids = 0, 0
	local completedBoidIds: {number}? = nil
	local completedPositions: {Vector3}? = nil
	local completedVelocities: {Vector3}? = nil
	if hasPostMergeObservers then
		completedBoidIds = {}
		completedPositions = {}
		completedVelocities = {}
	end
	
	local cell: Cell
	for _, jobCell: WorkerJobCell in jobResults.jobCells do
		cell = activeCells[jobCell.id]
		if not cell then
			warn(`Returned cell {jobCell.id} no longer exists`)
			continue
		end
		
		updatedCells += 1

		BoidStorage.OverwriteWithJobResults(cell.pages, jobCell.pages, jobCell.pageCount)
		cell.boidCount = cell.boidCount - jobCell.scheduledBoidCount + jobCell.boidCount
		updatedBoids += jobCell.processedBoidCount
		returnedCells[jobCell.id] = true
		if hasPostMergeObservers then
			local preparationStart = os.clock()
			for _, page in jobCell.pages.pages do
				for baseSlot, liveMask in BoidStorage.LiveWords(page) do
					while liveMask ~= 0 do
						local bitIndex = bit32.countrz(liveMask)
						local slot = baseSlot + bitIndex
						liveMask = bit32.band(liveMask, liveMask - 1)
						;(completedBoidIds :: {number})[#(completedBoidIds :: {number}) + 1] = BoidStorage.ReadBoidId(page.data, slot)
						;(completedPositions :: {Vector3})[#(completedPositions :: {Vector3}) + 1] = cell.origin + Vector3.new(BoidStorage.ReadPosition(page.data, slot))
						;(completedVelocities :: {Vector3})[#(completedVelocities :: {Vector3}) + 1] = Vector3.new(BoidStorage.ReadVelocity(page.data, slot)) * BoidStorage.ReadSpeed(page.data, slot)
					end
				end
			end
			observerPreparationMs += (os.clock() - preparationStart) * 1000
		end

		if cell.boidCount <= 0 then
			Cells.Remove(group, cell)

			continue
		end



	end
	
	group.cellsThisSecond += updatedCells
	group.boidsThisSecond += updatedBoids
	
	local simulationTick: number = jobResults.simulationTick :: number
	local id: number, position: Vector3, velocity: Vector3, pathNode: number, pathVersion: number, obstacleDirectionCode: number
	for returnedCellId, movedBoids: {number | Vector3} in jobResults.movedBoids do
		-- Actor transport stringifies sparse keys; storage and schedulers use numeric cell IDs.
		local dstCellId: number = tonumber(returnedCellId) :: number
		for i = 1, #movedBoids, 6 do
			id = movedBoids[i] :: number
			position = movedBoids[i + 1] :: Vector3
			velocity = movedBoids[i + 2] :: Vector3
			pathNode = movedBoids[i + 3] :: number
			pathVersion = movedBoids[i + 4] :: number
			obstacleDirectionCode = movedBoids[i + 5] :: number

			Cells.AddBoid(group, dstCellId, position, velocity, id, simulationTick, pathNode, pathVersion, obstacleDirectionCode)
			if hasPostMergeObservers then
				local preparationStart = if detailedMetrics then os.clock() else 0
				;(completedBoidIds :: {number})[#(completedBoidIds :: {number}) + 1] = id
				;(completedPositions :: {Vector3})[#(completedPositions :: {Vector3}) + 1] = position
				;(completedVelocities :: {Vector3})[#(completedVelocities :: {Vector3}) + 1] = velocity
				if detailedMetrics then observerPreparationMs += (os.clock() - preparationStart) * 1000 end
			end
		end
	end

	RuntimeMetrics.Add(metrics, "observerPreparationMs", observerPreparationMs)
	RuntimeMetrics.Add(metrics, "mergeMs", (os.clock() - mergeStart) * 1000 - observerPreparationMs)
	-- Failed/incomplete merges cannot publish uncommitted snapshot rows.
	local isComplete = true
	for _, scheduledCell in job.jobCells do
		if not returnedCells[scheduledCell.id] then isComplete = false; break end
	end
	local snapshotDeliveryStart = os.clock()
	if isComplete then
		if jobResults.snapshotGroups then
			if RunService:IsServer() then
				local jobRecipients: JobRecipients = recipients
				if jobRecipients then
					local userIds: {number}
					for sourceCellId, simulationSnapshot in jobResults.snapshotGroups do
						-- Actor result transport stringifies sparse numeric keys.
						userIds = jobRecipients[tonumber(sourceCellId) :: number]
						if userIds then
							NetworkResults.EnqueueSimulationSnapshotForPlayers(userIds, simulationSnapshot, jobResults.completionTime)
						end
					end
				end
			else
				for _, simulationSnapshot in jobResults.snapshotGroups do
					NetworkResults.PublishSimulationSnapshot(simulationSnapshot, jobResults.completionTime)
				end
			end
		end
	end
	RuntimeMetrics.Add(metrics, "snapshotDeliveryMs", (os.clock() - snapshotDeliveryStart) * 1000)
	if hasPostMergeObservers then
		local callbackStart = os.clock()
		debug.profilebegin("Boids.ObserverCallbacks")
		emitPostMergeBatch(group.id, completedBoidIds :: {number}, completedPositions :: {Vector3}, completedVelocities :: {Vector3}, completionTime)
		debug.profileend()
		RuntimeMetrics.Add(metrics, "observerCallbacksMs", (os.clock() - callbackStart) * 1000)
	end
end

function ResultCommit.Run(group: Group, actor: ActorState, job: Job, frameTick: number, targetActorJobMs: number, recipients: JobRecipients): ()
	local scheduler = group.scheduler
	-- Capture identities, not just numeric IDs: retired jobs must never release
	-- a replacement group's cells or buffers after an ID is reused.
	local originalSchedulees: {[number]: Schedulee<Cell>} = {}
	local originalCells: {[number]: Cell} = {}
	for _, jobCell in job.jobCells do
		originalSchedulees[jobCell.id] = scheduler.schedulees[jobCell.id]
		originalCells[jobCell.id] = group.activeCells[jobCell.id]
	end
	local mergedCells: {[number]: boolean} = {}
	if observedBoidId ~= nil and group.id == observedGroupId then
		local entry = BoidStorage.BoidRegistry[observedBoidId]
		if entry then
			for _, cell in job.jobCells do
				if cell.id == entry.cellId then
					job.obstacleRequest = { boidId = observedBoidId, generation = obstacleGeneration, jobOrder = job.id }
					break
				end
			end
		end
	end
	ActorsInitializer.RunJob(actor, group, job, frameTick, targetActorJobMs, {
		IsCurrent = function(): boolean
			return groups[group.id] == group
		end,
		Commit = function(result: WorkerJobResult, inboundMs: number): boolean
			local seenCells: {[number]: boolean} = {}
			for _, returnedCell in result.jobCells do
				assert(not seenCells[returnedCell.id] and originalCells[returnedCell.id]
					and group.activeCells[returnedCell.id] == originalCells[returnedCell.id]
					and scheduler.schedulees[returnedCell.id] == originalSchedulees[returnedCell.id],
					"Worker returned a duplicate, unscheduled or replaced cell")
				seenCells[returnedCell.id] = true
			end
			Benchmarkers.push(group.jobSendStats, inboundMs)
			Benchmarkers.push(group.jobReceiveStats, (workspace:GetServerTimeNow() - result.completionTime) * 1000)
			handleJobResults(group, job, result, mergedCells, recipients)
			acceptObstacleObservation(job, result, mergedCells)
			for _, cell in job.jobCells do
				if not mergedCells[cell.id] then return false end
			end
			return true
		end,
		Retire = function(outcome: JobOutcome, completionTime: number?): ()
			table.clear(recipients)
			for _, jobCell in job.jobCells do
				local pages = jobCell.pages
				BoidStorage.RestorePendingPages(pages)
				local schedulee = originalSchedulees[jobCell.id]
				if groups[group.id] ~= group then
					if schedulee and scheduler.schedulees[jobCell.id] == schedulee then
						schedulee.alreadyScheduled = false
						schedulee.heapVersion += 1
						scheduler.schedulees[jobCell.id] = nil
					end
					continue
				end
				if group.activeCells[jobCell.id] ~= originalCells[jobCell.id]
					or scheduler.schedulees[jobCell.id] ~= schedulee or not schedulee then
					continue
				end
				if (outcome == "completed" or outcome == "incomplete") and mergedCells[jobCell.id] and completionTime then
					reAddCellToQueue(group, scheduler, schedulee, completionTime)
				else
					Schedulers.ReleaseSchedulee(scheduler, schedulee)
				end
			end
		end,
	})
end


function ResultCommit.Start(registry: SharedTypes.GroupRegistry): ()
 assert(groups == nil or groups == registry, "Cannot replace coordinator registry")
 groups = registry
end
return ResultCommit
