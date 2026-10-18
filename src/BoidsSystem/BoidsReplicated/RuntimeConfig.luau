--!strict
-- Trusted process configuration; no scenario names, test attributes or runtime work.
local RunService = game:GetService("RunService")

local RuntimeConfig = {}
export type Options = {actorCount: number?, targetActorJobMs: number?}
export type Resolved = {actorCount: number, targetActorJobMs: number}
RuntimeConfig.Defaults = table.freeze({actorCount = if RunService:IsClient() then 16 else 2, targetActorJobMs = 4})

function RuntimeConfig.Resolve(options: Options?): Resolved
	local actorCount = if options and options.actorCount ~= nil then options.actorCount else RuntimeConfig.Defaults.actorCount
	local targetActorJobMs = if options and options.targetActorJobMs ~= nil then options.targetActorJobMs else RuntimeConfig.Defaults.targetActorJobMs
	assert(actorCount % 1 == 0 and actorCount >= 1 and actorCount <= 32, "actorCount must be an integer in [1, 32]")
	assert(targetActorJobMs > 0 and targetActorJobMs < math.huge, "targetActorJobMs must be finite and positive")
	return table.freeze({actorCount = actorCount, targetActorJobMs = targetActorJobMs})
end
return RuntimeConfig
