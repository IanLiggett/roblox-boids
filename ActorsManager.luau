local module = {}
local actors = {}

local Utilities = require(game:GetService("ServerScriptService").Utilities)

local ACTOR_COUNT:number = 8
local actorIndex:number = 1

local actorsFolder = Instance.new("Folder")
actorsFolder.Name = "Actors"
actorsFolder.Parent = script

-- initialize actors
for index = 1, ACTOR_COUNT do
	local newActor = Instance.new("Actor")
	newActor.Parent = actorsFolder

	actors[index] = newActor
end

function module.MultiThreadModule(moduleToClone:Script | ModuleScript | LocalScript, moduleCount)
	local modulesList = {}
	if moduleCount > ACTOR_COUNT then
		error("Unable to initialize parallelized module ", moduleToClone.Name, " because it requested ", moduleCount, " modules but there are only ", ACTOR_COUNT, " actors")
	end
	
	for index:number = 1, moduleCount do
		local newModule = moduleToClone:Clone()
		newModule.Parent = actors[actorIndex]
		
		table.insert(modulesList, newModule)
		
		actorIndex = Utilities.IncrementInRange(actorIndex, ACTOR_COUNT)
	end
	
	return modulesList
end

function module.getActorCount()
	return ACTOR_COUNT
end

return module
