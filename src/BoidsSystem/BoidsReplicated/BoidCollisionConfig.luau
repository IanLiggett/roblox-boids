--!strict
-- Immutable gameplay collision bounds shared by the server and client query paths.
local SharedTypes = require(script.Parent.SharedTypes)
local BoidCollisionConfig = {}

local radiiByModel: {[number]: number} = {
	[SharedTypes.BoidModels.Boid] = 2,
	[SharedTypes.BoidModels.BoidSphere] = 2,
	[SharedTypes.BoidModels.Predator] = 3,
}

table.freeze(radiiByModel)

function BoidCollisionConfig.GetRadius(model: number): number
	return radiiByModel[model] or radiiByModel[SharedTypes.BoidModels.Boid]
end

return table.freeze(BoidCollisionConfig)