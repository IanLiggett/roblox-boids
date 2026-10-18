--!strict
-- Initializes the fixed pool. JobExecution owns each Actor's execution lifetime.
local RunService = game:GetService("RunService")
local BoidsReplicated = script.Parent.Parent
local ActorsManager = require(BoidsReplicated.ActorsManager)
local JobExecution = require(script.JobExecution)
local SharedTypes = require(BoidsReplicated.SharedTypes)
local ActorsInitializer = {}

export type ActorState = JobExecution.ActorState
export type JobCallbacks = JobExecution.Callbacks
export type JobOutcome = JobExecution.Outcome
local actors: {ActorState} = {}
ActorsInitializer.actors = actors

function ActorsInitializer.InitializeBoidActors(actorCount: number): ()
	assert(#actors == 0, "Boid Actors already initialized")
	ActorsManager.Start(actorCount)
	local workerTemplate = if RunService:IsClient()
		then script.Parent.Parallelized.ClientJobHandler
		else script.Parent.Parallelized.JobHandler
	for _, instance in ActorsManager.MultiThreadModule(workerTemplate, ActorsManager.GetActorCount()) do
		table.insert(actors, JobExecution.NewActor(instance, workspace:GetServerTimeNow()))
	end
end

function ActorsInitializer.IsActorFree(actor: ActorState): boolean
	return actor.ready and actor.execution == nil
end

function ActorsInitializer.RunJob(actor: ActorState, group: SharedTypes.Group, job: SharedTypes.Job, frameTick: number, targetJobMs: number, callbacks: JobCallbacks): ()
	JobExecution.Start(actor, group, job, frameTick, targetJobMs, callbacks)
end

function ActorsInitializer.CancelGroup(group: SharedTypes.Group): ()
	for _, actor in actors do
		local execution = actor.execution
		if execution and execution.group == group then JobExecution.Cancel(execution) end
	end
end

return ActorsInitializer
