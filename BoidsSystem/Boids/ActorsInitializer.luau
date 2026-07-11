--[[ ActorsInitializer
Description:
	Initializes boid worker scripts across the Actor pool and tracks per-Actor
	scheduling/performance state used by the server simulation scheduler.

Public API:
	actors: {ActorState}
	initializeBoidActors(): ()
]]

local module = {}

local ActorsManager = require(game:GetService("ServerScriptService"):QueryDescendants(">> .actors-manager-module")[1])

export type ActorState = {
	ready:boolean,
	targetJobWork:number,
	instance:Script,
	avgMsPerWorkUnit:number,
	lastJobMs:number
}

local actors:{ActorState} = {}
module.actors = actors

function module.initializeBoidActors()
	local actorInstances = ActorsManager.MultiThreadModule(script.Parent.Parallelized.JobHandler, ActorsManager.getActorCount())--)
	for _, actorInstance:Script in actorInstances do
		table.insert(actors, {
			ready = true,
			targetJobWork = 10,
			instance = actorInstance,
			avgMsPerWorkUnit = 0.05,
			lastJobMs = 50
		})
	end
end

return module
