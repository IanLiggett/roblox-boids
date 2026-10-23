--!strict
-- Trusted process configuration; no scenario names, test attributes or runtime work.
local RunService = game:GetService("RunService")

local RuntimeConfig = {}
export type Options = {read actorCount: number?, read targetActorJobMs: number?, read simulationEnabled: boolean?}
export type Resolved = {read actorCount: number, read targetActorJobMs: number, read simulationEnabled: boolean}
RuntimeConfig.Defaults = table.freeze({actorCount = 16, targetActorJobMs = 4, simulationEnabled = true})

function RuntimeConfig.Resolve(options: Options?): Resolved
	local actorCount = if options and options.actorCount ~= nil then options.actorCount else RuntimeConfig.Defaults.actorCount
	local targetActorJobMs = if options and options.targetActorJobMs ~= nil then options.targetActorJobMs else RuntimeConfig.Defaults.targetActorJobMs
	local simulationEnabled = if options and options.simulationEnabled ~= nil then options.simulationEnabled else RuntimeConfig.Defaults.simulationEnabled
	assert(type(simulationEnabled) == "boolean", "simulationEnabled must be a boolean")
	assert(simulationEnabled or RunService:IsClient(), "simulationEnabled=false is client-only")
	assert(actorCount % 1 == 0 and actorCount >= 1 and actorCount <= 32, "actorCount must be an integer in [1, 32]")
	assert(targetActorJobMs > 0 and targetActorJobMs < math.huge, "targetActorJobMs must be finite and positive")
	return table.freeze({actorCount = actorCount, targetActorJobMs = targetActorJobMs, simulationEnabled = simulationEnabled})
end
return RuntimeConfig
