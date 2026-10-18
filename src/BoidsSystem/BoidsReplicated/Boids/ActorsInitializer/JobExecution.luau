--!strict
-- Owns execution for the fixed Boids Actor pool. A logical timeout is not proof
-- of worker completion: quarantine keeps scratch exclusive until a terminal reply.
local BoidsReplicated = script.Parent.Parent.Parent
local SharedTypes = require(BoidsReplicated.SharedTypes)
local RuntimeMetrics = require(BoidsReplicated.RuntimeMetrics)
local Benchmarkers = require(BoidsReplicated.Dependencies.Benchmarker.Value)
local JobExecution = {}

type Job = SharedTypes.Job
type Result = SharedTypes.WorkerJobResult
export type Outcome = "completed" | "incomplete" | "merge_failed" | "timed_out" | "cancelled" | "worker_failed" | "dispatch_failed"
export type Callbacks = {
	IsCurrent: () -> boolean,
	Commit: (Result, number) -> boolean,
	Retire: (Outcome, number?) -> (),
}
export type Execution = {
	actor: ActorState,
	group: SharedTypes.Group?,
	job: Job?,
	jobId: number,
	phase: "running" | "completing" | "quarantined" | "complete",
	callbacks: Callbacks?,
	event: BindableEvent,
	timer: thread?,
	dispatchClock: number,
	isRetired: boolean,
	isAccounted: boolean,
	cancelRequested: boolean,
}
export type ActorState = {
	ready: boolean,
	targetJobWork: number,
	instance: BaseScript,
	avgMsPerWorkUnit: number,
	lastJobCompletion: number,
	lastJobMs: number,
	timeIdleStats: Benchmarkers.Benchmarker,
	execution: Execution?,
}
local metrics = RuntimeMetrics.State

function JobExecution.NewActor(instance: BaseScript, now: number): ActorState
	return {
		ready = true, targetJobWork = 10, instance = instance,
		avgMsPerWorkUnit = 0.05, lastJobCompletion = now, lastJobMs = 50,
		timeIdleStats = Benchmarkers.newBenchmarker(100), execution = nil,
	}
end

local function stopTimer(execution: Execution): ()
	local timer = execution.timer
	execution.timer = nil
	if timer then task.cancel(timer) end
end

local function retire(execution: Execution, outcome: Outcome, completionTime: number?): ()
	if execution.isRetired then return end
	execution.isRetired = true
	if not execution.isAccounted then
		execution.isAccounted = true
		if outcome == "timed_out" then
			RuntimeMetrics.TimedOut(metrics)
		else
			RuntimeMetrics.Add(metrics, "outstandingJobs", -1)
		end
	end
	if outcome == "cancelled" or outcome == "worker_failed" or outcome == "dispatch_failed" then
		RuntimeMetrics.Add(metrics, "discardedJobs", 1)
	end
	local callbacks = execution.callbacks
	-- An unresponsive worker must not retain the whole coordinator group/job.
	execution.callbacks, execution.job, execution.group = nil, nil, nil
	if callbacks then
		local ok, err = pcall(callbacks.Retire, outcome, completionTime)
		if not ok then warn("Boids job retirement failed: " .. tostring(err)) end
	end
end

local function makeReusable(execution: Execution): ()
	stopTimer(execution)
	execution.event:Destroy()
	execution.phase = "complete"
	local actor = execution.actor
	if actor.execution == execution then
		actor.execution = nil
		actor.lastJobCompletion = workspace:GetServerTimeNow()
		actor.ready = true
	end
end

local function quarantine(execution: Execution, outcome: Outcome): ()
	if execution.phase ~= "running" then return end
	stopTimer(execution)
	execution.phase = "quarantined"
	retire(execution, outcome, nil)
	-- Retain only the terminal-reply listener. Never reuse on a timeout alone.
end

function JobExecution.Expire(execution: Execution): ()
	if execution.phase ~= "running" then return end
	quarantine(execution, "timed_out")
	warn("Boids job " .. execution.jobId .. " timed out; Actor quarantined until its terminal reply")
end

function JobExecution.Cancel(execution: Execution): ()
	if execution.phase == "completing" then
		-- A serial commit already entered may be in an observer callback. Wait for
		-- it to return; its retirement callback still checks owner identities.
		execution.cancelRequested = true
		return
	end
	quarantine(execution, "cancelled")
end

local function receive(execution: Execution, result: Result?, inboundSeconds: number?, failure: string?, targetJobMs: number): ()
	if execution.actor.execution ~= execution then return end
	if execution.phase == "quarantined" then
		-- A late result proves scratch is no longer in use, but cannot commit,
		-- sample adaptive feedback or settle reservations a second time.
		makeReusable(execution)
		return
	end
	if execution.phase ~= "running" then return end
	stopTimer(execution)
	execution.phase = "completing"
	local callbacks = assert(execution.callbacks)
	local job = assert(execution.job)
	if failure or not result then
		retire(execution, "worker_failed", nil)
		warn("Boids worker failed for job " .. execution.jobId .. ": " .. tostring(failure))
		makeReusable(execution)
		return
	end
	local currentOk, isCurrent = pcall(callbacks.IsCurrent)
	if not currentOk then
		RuntimeMetrics.Add(metrics, "mergeFailures", 1)
		retire(execution, "merge_failed", nil)
		warn("Boids owner validation failed: " .. tostring(isCurrent))
		makeReusable(execution)
		return
	end
	if not isCurrent then
		retire(execution, "cancelled", nil)
		makeReusable(execution)
		return
	end
	local resultStart = os.clock()
	local outboundMs = (workspace:GetServerTimeNow() - result.completionTime) * 1000
	execution.isAccounted = true
	RuntimeMetrics.Completed(metrics, result.measurement,
		(resultStart - execution.dispatchClock) * 1000, (inboundSeconds or 0) * 1000, outboundMs)
	-- Commit/observers may yield. Profile annotations cannot span a frame yield;
	-- the inclusive elapsed resultHandlingMs measurement remains valid.
	local ok, isComplete = pcall(callbacks.Commit, result, (inboundSeconds or 0) * 1000)
	if ok and isComplete and not execution.cancelRequested then
		local actor = execution.actor
		local measuredMs = (result.completionTime - job.startTime) * 1000
		local cost = measuredMs / job.estimatedCost
		if cost ~= cost or cost <= 0 or cost == math.huge then
			cost = if actor.avgMsPerWorkUnit > 0 then actor.avgMsPerWorkUnit else 0.05
		end
		actor.avgMsPerWorkUnit = actor.avgMsPerWorkUnit * 0.8 + cost * 0.2
		actor.targetJobWork = math.max(8, targetJobMs / actor.avgMsPerWorkUnit)
		actor.lastJobMs = measuredMs
	end
	if not ok then
		RuntimeMetrics.Add(metrics, "mergeFailures", 1)
		warn("Boids commit failed for job " .. execution.jobId .. ": " .. tostring(isComplete))
	elseif not isComplete then
		RuntimeMetrics.Add(metrics, "mergeFailures", 1)
		warn("Boids job " .. execution.jobId .. " omitted scheduled cells")
	end
	local outcome: Outcome = if execution.cancelRequested then "cancelled" elseif not ok then "merge_failed" elseif isComplete then "completed" else "incomplete"
	retire(execution, outcome, result.completionTime)
	RuntimeMetrics.Add(metrics, "resultHandlingMs", (os.clock() - resultStart) * 1000)
	makeReusable(execution)
end

function JobExecution.Start(actor: ActorState, group: SharedTypes.Group, job: Job, frameTick: number, targetJobMs: number, callbacks: Callbacks): Execution
	assert(actor.ready and actor.execution == nil, "Actor already has unfinished work")
	local now = workspace:GetServerTimeNow()
	actor.ready = false
	Benchmarkers.push(actor.timeIdleStats, now - actor.lastJobCompletion)
	local execution: Execution = {
		actor = actor, group = group, job = job, jobId = job.id,
		phase = "running", callbacks = callbacks, event = Instance.new("BindableEvent"),
		timer = nil, dispatchClock = os.clock(), isRetired = false,
		isAccounted = false, cancelRequested = false,
	}
	actor.execution = execution
	local scheduledBoids = 0
	for _, cell in job.jobCells do scheduledBoids += cell.scheduledBoidCount end
	RuntimeMetrics.Dispatched(metrics, scheduledBoids)
	-- Subscribe before dispatch: even an immediate terminal reply must be observed.
	execution.event.Event:Connect(function(result: Result?, inboundSeconds: number?, failure: string?)
		receive(execution, result, inboundSeconds, failure, targetJobMs)
	end)
	execution.timer = task.delay(5, function()
		execution.timer = nil
		JobExecution.Expire(execution)
	end)
	local dispatchStart = os.clock()
	local ok, err = pcall(function()
		(actor.instance.Parent :: Actor):SendMessage("NewJob", job, execution.event, frameTick, now)
	end)
	RuntimeMetrics.Add(metrics, "dispatchMs", (os.clock() - dispatchStart) * 1000)
	if not ok then
		-- A throwing dispatch supplies no completion proof. Retire logical work,
		-- and require a terminal reply before making this Actor reusable.
		quarantine(execution, "dispatch_failed")
		warn("Boids dispatch failed for job " .. job.id .. ": " .. tostring(err))
	end
	return execution
end

return JobExecution
