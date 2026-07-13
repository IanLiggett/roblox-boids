--!strict
--!native

local module = {}

local PlayersService = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(script.Parent.Parent.BoidsReplicated)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local ActorsInitializer = require(script.Parent.ActorsInitializer)
local Schedulers = require(script.Parent.Scheduler)
local Boids = require(script.Parent)

local Dependencies = BoidsReplicated.Dependencies
local BinaryHeaps = require(Dependencies.BinaryHeaps.Value)
local Benchmarkers = require(Dependencies.Benchmarker.Value)

ActorsInitializer.initializeBoidActors()
type ActorState = ActorsInitializer.ActorState

type Cell = Boids.Cell
type Group = Boids.Group

type Scheduler<T> = Schedulers.Scheduler<T>
type Schedulee<T> = Schedulers.Schedulee<T>

type Job = SharedTypes.Job
type JobCell = SharedTypes.JobCell

type CellLODState = {
	networkMultiplierByPlayer: {[Player]: number},
	nextSendAtByPlayer: {[Player]: number},

	multiplierCounts: {[number]: number},
	effectiveSimMultiplier: number,
}


local BASE_NETWORK_INTERVAL: number = 1

local groupsScheduler: Scheduler<Group> = Boids.groupsScheduler

local boidJobUpdate:UnreliableRemoteEvent = BoidsReplicated.Remotes.BoidJobUpdate

-- remember to update this to match actual job handler with new bucketing strategy
local function computeCellCost(cell: Cell): number
	return math.max(cell.boidCount, 1) ^ 2
end

local function isPlayerDueForCell(cellLOD: CellLODState, player: Player, now: number): boolean
	const multiplier: number? = cellLOD.networkMultiplierByPlayer[player]
	if not multiplier then
		return false
	end

	const nextSendAt: number? = cellLOD.nextSendAtByPlayer[player]
	return not nextSendAt or now >= nextSendAt
end

local function markPlayerSentForCell(cellLOD: CellLODState, player: Player, now: number)
	const multiplier: number? = cellLOD.networkMultiplierByPlayer[player]
	if not multiplier then
		return
	end

	const interval: number = BASE_NETWORK_INTERVAL * multiplier
	local nextSendAt: number = cellLOD.nextSendAtByPlayer[player] or now

	repeat
		nextSendAt += interval
	until nextSendAt > now

	cellLOD.nextSendAtByPlayer[player] = nextSendAt
end

local function getDuePlayersForCell(cell, now: number): {Player}
	
end

local function updatePlayerPosition()
	
end


local function markCellPending(cell: Cell)
	BoidStorage.markPagesPending(cell.pages)
end


local TARGET_ACTOR_JOB_MS = 10

local nextJobId = 0

local lastScheduledByCell: {[number]: number} = {}
local lastReturnedByCell: {[number]: number} = {}
local scheduledCountByCell: {[number]: number} = {}
local returnedCountByCell: {[number]: number} = {}


local function buildJob(group: Group, currentTick: number, targetCost: number, boidsRemaining: number): (Job, number)
	local scheduler = group.scheduler

	local now: number = workspace:GetServerTimeNow()
	local job: Job = {
		id = nextJobId,
		groupId = group.id,

		jobCells = {},
		movedBoids = {},

		cellCount = 0,

		startTime = now,
		completionTime = -1,
		estimatedCost = 0,

		averageSight = group.averageSight,

		neighborIterations = 0
	}

	nextJobId += 1

	local boidsScheduled:number = 0

	local nextSchedulee:Schedulee<Cell>?, nextCell:Cell, cost:number, cellBoidCount:number
	while targetCost > job.estimatedCost and boidsRemaining - boidsScheduled > 0 do
		nextSchedulee = Schedulers.getNextSchedulee(scheduler, currentTick)
		if not nextSchedulee then
			break
		end

		nextCell = nextSchedulee.entity
		cost = computeCellCost(nextCell)
		if cost + job.estimatedCost > targetCost and job.cellCount > 0 then
			Schedulers.enqueueSchedulee(scheduler, nextSchedulee)
			break
		end

		cellBoidCount = nextCell.boidCount

		job.estimatedCost += cost
		boidsScheduled += cellBoidCount

		job.jobCells[nextCell.id] = {
			id = nextCell.id,
			origin = nextCell.origin,

			networkTick = nextCell.networkTick,
			networkInterval = nextCell.networkInterval,

			emitSnapshot = #getDuePlayersForCell(nextCell, now) > 0,

			pages = nextCell.pages,
			pageCount = nextCell.pages.pageCount,
			boidCount = cellBoidCount,
		}

		Schedulers.scheduleSchedulee(nextSchedulee)
		markCellPending(nextCell)

		job.cellCount += 1
	end

	return job, boidsScheduled
end

local MIN_JOB_WORK = 8
local MAX_JOB_WORK = 200
const DEFAULT_MS_PER_WORK_UNIT = 0.05

local testParts:{[number]:BasePart} = {}
local neighborIterationsStats = Benchmarkers.newBenchmarker(1000)

local function handleJobResults(groupSchedulee:Schedulee<Group>, actor:ActorState, job:Job, jobResults:Job, returnedCells:{[number]:boolean})
	if not groupsScheduler.schedulees[groupSchedulee.entity.id] then
		warn("running job returned for nonexistant group")
		return
	end

	local completionTime:number = jobResults.completionTime
	local measuredMs:number = (completionTime - job.startTime) * 1000
	local measuredMsPerWorkUnit:number = measuredMs / job.estimatedCost

	if measuredMsPerWorkUnit ~= measuredMsPerWorkUnit or measuredMsPerWorkUnit <= 0 then
		measuredMsPerWorkUnit = actor.avgMsPerWorkUnit
		if measuredMsPerWorkUnit <= 0 then
			measuredMsPerWorkUnit = DEFAULT_MS_PER_WORK_UNIT
		end
	end

	actor.avgMsPerWorkUnit = actor.avgMsPerWorkUnit * 0.8 + measuredMsPerWorkUnit * 0.2
	actor.targetJobWork = math.clamp(
		TARGET_ACTOR_JOB_MS / actor.avgMsPerWorkUnit,
		MIN_JOB_WORK,
		MAX_JOB_WORK
	)

	local group:Group = groupSchedulee.entity

	Benchmarkers.push(group.benchmarker, measuredMs)
	Benchmarkers.push(neighborIterationsStats, jobResults.neighborIterations)

	if jobResults.snapshotPackets then
		for _, packet in jobResults.snapshotPackets do
			boidJobUpdate:FireAllClients(packet, jobResults.completionTime)
		end
	end

	local function updateDebugBoid(boidId: number, worldPosition: Vector3, velocity: Vector3)
		local boid = testParts[boidId]

		if not boid then
			local rng: Random = Random.new(group.id)

			boid = Instance.new("Part")
			boid.Anchored = true
			boid.CanCollide = false
			boid.CanQuery = false
			boid.CanTouch = false
			boid.Size = Vector3.new(1, 1, 3)
			boid.Parent = workspace
			boid.Color = Color3.new((rng:NextNumber() + 0.5) / 2, (rng:NextNumber() + 0.5) / 2, (rng:NextNumber() + 0.5) / 2)
			testParts[boidId] = boid
		end

		local dir = velocity.Magnitude > 0.001 and velocity.Unit or Vector3.zAxis
		boid.CFrame = CFrame.lookAt(worldPosition, worldPosition + dir)
	end

	local cell:Cell
	for _, jobCell:JobCell in jobResults.jobCells do
		returnedCells[jobCell.id] = true
		cell = group.activeCells[jobCell.id]
		if not cell then
			warn(`Returned cell {jobCell.id} no longer exists`)
			continue
		end

		local originalJobCell:JobCell? = job.jobCells[jobCell.id]
		if originalJobCell then
			cell.boidCount = cell.boidCount - originalJobCell.boidCount + jobCell.boidCount
		else
			cell.boidCount = jobCell.boidCount
		end

		BoidStorage.overwriteWithJobResults(cell.pages, jobCell.pages, jobCell.pageCount)

		if cell.boidCount <= 0 then
			if cell.visualizer then
				cell.visualizer:Destroy()
			end
			group.activeCells[cell.id] = nil
			group.cellCount -= 1
			group.scheduler.schedulees[cell.id] = nil
			BoidStorage.deletePagedBuffer(cell.pages.id)

			continue
		end

		cell.networkTick += 1

		-- for debugging
		--for _, page in jobCell.pages.pages do
		--	local data: buffer = page.data

		--	local bitIndex:number, boidIndex:number
		--	for baseSlot:number, liveMask:number in BoidStorage.liveWords(page) :: ()->(number, number) do
		--		while liveMask ~= 0 do
		--			bitIndex = bit32.countrz(liveMask)
		--			boidIndex = baseSlot + bitIndex
		--			liveMask = bit32.band(liveMask, liveMask - 1)

		--			local boidId = BoidStorage.readBoidId(data, boidIndex)
		--			updateDebugBoid(
		--				boidId, 
		--				Vector3.new(BoidStorage.readPosition(data, boidIndex)) + cell.origin, 
		--				Vector3.new(BoidStorage.readVelocity(data, boidIndex))
		--			)
		--		end
		--	end
		--end
	end

	local id:number, position:Vector3, velocity:Vector3
	for dstCellId: number, movedBoids: {number | Vector3} in jobResults.movedBoids do
		for i = 1, #movedBoids, 3 do
			id = movedBoids[i] :: number
			position = movedBoids[i + 1] :: Vector3
			velocity = movedBoids[i + 2] :: Vector3

			Boids.addBoidToCell(group, dstCellId, position, velocity, id, completionTime)
			--updateDebugBoid(id, position, velocity)
		end
	end
end

-- if tables of data are passed instead of compressing to buffers, no extra processing would be required. Maybe faster, test
local function runJob(groupSchedulee:Schedulee<Group>, actor:ActorState, job:Job)
	local group:Group = groupSchedulee.entity
	local scheduler:Scheduler<Cell> = group.scheduler
	local actorInstance:Actor = actor.instance.Parent :: Actor

	local bindableEvent:BindableEvent = Instance.new("BindableEvent")

	actor.ready = false

	local returned:boolean = false
	local function releaseOriginalCells()
		for cellId: number, _ in job.jobCells do
			local schedulee = scheduler.schedulees[cellId]
			if schedulee then
				Schedulers.releaseSchedulee(scheduler, schedulee)
			end
		end
	end

	actorInstance:SendMessage("NewJob", job, bindableEvent)
	bindableEvent.Event:Once(function(jobResults: Job)
		if returned then
			return
		end
		returned = true

		actor.ready = true
		bindableEvent:Destroy()

		local returnedCells:{[number]:boolean} = {}
		local completionTime:number = jobResults.completionTime

		local ok, err = pcall(function()
			handleJobResults(groupSchedulee, actor, job, jobResults, returnedCells)
		end)

		if not ok then
			warn(`handleJobResults error for job {job.id}: {err}`)
		end

		local schedulee:Schedulee<Cell>?
		local interval:number
		for cellId:number, _ in job.jobCells do
			schedulee = scheduler.schedulees[cellId]
			if not schedulee then
				continue
			end

			if returnedCells[cellId] then
				Schedulers.markScheduleeCompleted(scheduler, schedulee, completionTime)
			else
				warn(`Job {job.id} returned but omitted scheduled cell {cellId}`)

				Schedulers.releaseSchedulee(scheduler, schedulee)
			end
		end
	end)

	task.delay(5, function()
		if returned then
			return
		end

		returned = true
		actor.ready = true
		bindableEvent:Destroy()

		warn(`Job {job.id} never returned; releasing {job.cellCount} cells`)
		releaseOriginalCells()
	end)
end

local function getNextGroupWithWork(now: number): Schedulee<Group>?
	local bestGroupSchedulee: Schedulee<Group>? = nil
	local bestWakeTime = math.huge

	local group:Group, wakeTime:number?
	for _, groupSchedulee: Schedulee<Group> in groupsScheduler.schedulees do
		group = groupSchedulee.entity
		if group.cellCount <= 0 then
			continue
		end

		wakeTime = Schedulers.peekNextWakeTime(group.scheduler)
		if not wakeTime then
			continue
		end

		if wakeTime <= now and wakeTime < bestWakeTime then
			bestWakeTime = wakeTime
			bestGroupSchedulee = groupSchedulee
		end
	end

	return bestGroupSchedulee
end

local function assignWorkForFrame(currentTick: number)
	--local frameBudgetRemaining = MAX_FRAME_COST
	local frameBudgetRemaining = 1000000
	local boidBudgetRemaining = Boids.MAX_BOIDS_PER_FRAME

	local groupSchedulee:Schedulee<Group>?
	for _, actor: ActorState in ActorsInitializer.actors do
		if frameBudgetRemaining <= 0 or boidBudgetRemaining <= 0 then
			break
		end

		if not actor.ready then
			continue
		end

		local actorBudget = math.min(actor.targetJobWork, frameBudgetRemaining)

		local attempts:number = 0
		local maxGroupAttempts:number = 8

		while attempts < maxGroupAttempts do
			attempts += 1

			groupSchedulee = getNextGroupWithWork(currentTick)
			if not groupSchedulee then
				break
			end

			local job, boidsScheduled = buildJob(
				groupSchedulee.entity,
				currentTick,
				actorBudget,
				boidBudgetRemaining
			)

			if job.estimatedCost > 0 and boidsScheduled > 0 then
				boidBudgetRemaining -= boidsScheduled
				frameBudgetRemaining -= job.estimatedCost
				runJob(groupSchedulee, actor, job)

				Schedulers.markScheduleeCompleted(groupsScheduler, groupSchedulee, workspace:GetServerTimeNow())
				break
			end

			warn(`Group {groupSchedulee.entity.id} selected but built no job`)

			Schedulers.releaseSchedulee(groupsScheduler, groupSchedulee)
		end
	end
end

local lastCleanup:number = os.clock()
local cleanupInterval = 30
-- uses heuristic to determine when to clean up invalid group scheduler's heap nodes due to lazy invalidation
local function cleanupGroupHeaps()
	lastCleanup = os.clock()

	local group:Group
	for _, groupSchedulee:Schedulee<Group> in groupsScheduler.schedulees do
		group = groupSchedulee.entity
		if BinaryHeaps.size(group.scheduler.heap) > group.cellCount * 4 + 64 then
			Schedulers.rebuildSchedulerHeap(group.scheduler)
		end
	end
end

game:GetService("RunService").Heartbeat:Connect(function(dt)
	local currentTick:number = workspace:GetServerTimeNow()

	if os.clock() - lastCleanup > cleanupInterval then
		cleanupGroupHeaps()
	end

	assignWorkForFrame(currentTick)
end)

local function printStats()
	print(`NEIGHBOR ITERATIONS PER JOB:`)
	Benchmarkers.printStats(neighborIterationsStats)
end

task.spawn(function()
	while task.wait(5) do
		printStats()
	end
end)

--local debugAccum = 0

--game:GetService("RunService").Heartbeat:Connect(function(dt)
--	debugAccum += dt
--	if debugAccum < 1 then
--		return
--	end
--	debugAccum = 0

--	local maxCellBoids = 0
--	local scheduledCells = 0
--	local validCells = 0
--	local totalCells = 0
--	local readyActors = 0
--	local staleCells = 0

--	for _, actor in ActorsInitializer.actors do
--		if actor.ready then
--			readyActors += 1
--		end
--	end

--	local now:number = workspace:GetServerTimeNow()

--	local oldestCellAge:number = 0
--	local oldestCellId:number = 0
--	for _, groupSchedulee in groupsScheduler.schedulees do
--		for _, cellSchedulee in groupSchedulee.entity.scheduler.schedulees do
--			local cell = cellSchedulee.entity
--			totalCells += 1
--			maxCellBoids = math.max(maxCellBoids, cell.boidCount)

--			if cellSchedulee.alreadyScheduled then
--				scheduledCells += 1
--			end

--			if cellValidator(cellSchedulee) then
--				validCells += 1
--			end

--			local age = now - cellSchedulee.lastUpdated
--			if age > oldestCellAge then
--				oldestCellAge = age
--				oldestCellId = cell.id
--			end

--			if age > 2 then
--				staleCells += 1
--			end
--		end
--	end

--	warn(`cells total={totalCells}, valid={validCells}, scheduled={scheduledCells}, readyActors={readyActors}, oldestAge={oldestCellAge}, staleCells={staleCells}`)
--	for i, actor in ActorsInitializer.actors do
--		print(`actor {i}: ready={actor.ready}, avgMs={actor.avgMsPerWorkUnit}, targetWork={actor.targetJobWork}`)
--	end
--end)



local players: {[Player]: boolean} = {}

PlayersService.PlayerAdded:Connect(function(player)
	players[player] = true
end)

PlayersService.PlayerRemoving:Connect(function(player)
	players[player] = nil
end)

game:GetService("RunService").PostSimulation:Connect(function()
	
end)

return module
