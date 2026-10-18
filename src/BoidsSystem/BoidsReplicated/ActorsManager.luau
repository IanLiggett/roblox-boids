--!strict
--[[ ActorsManager
Description:
	Creates and owns a fixed pool of Roblox Actors for parallel script execution.
	Clones requested scripts/modules into Actors in round-robin order.

Public API:
	Start(actorCount: number): (): creates the configured fixed pool once
	MultiThreadModule(moduleToClone: Script | ModuleScript | LocalScript, moduleCount: number): {Instance}
	getActorCount(): number
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ActorsManager = {}


local actors: {Actor} = {}
local isStarted = false

local isClient = RunService:IsClient()
local DEFAULT_ACTOR_COUNT: number = 2
local ACTOR_COUNT = 0
local ACTOR_POOL_COUNT = 0
local actorIndex = 1

function ActorsManager.Start(actorCount: number): ()
	if isStarted then return end
	isStarted = true
	ACTOR_COUNT = actorCount
	ACTOR_POOL_COUNT = math.max(DEFAULT_ACTOR_COUNT, actorCount)
	local actorsFolder = Instance.new("Folder")
	actorsFolder.Name = "BoidsActors"
	if isClient then
		actorsFolder.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerScripts")
	else
		actorsFolder.Parent = ServerScriptService
	end
	for index = 1, ACTOR_POOL_COUNT do
		local newActor = Instance.new("Actor")
		newActor.Name = "BoidsActor_" .. index
		newActor.Parent = actorsFolder
		actors[index] = newActor
	end
end

function ActorsManager.MultiThreadModule(moduleToClone: BaseScript, moduleCount: number): {BaseScript}
	assert(isStarted, "Actor pool must be started before cloning workers")
	local modulesList: {BaseScript} = {}
	if moduleCount > ACTOR_POOL_COUNT then
		error("Unable to initialize " .. moduleToClone.Name .. ": requested " .. moduleCount .. " workers but this pool has " .. ACTOR_POOL_COUNT .. " Actors")
	end

	for _ = 1, moduleCount do
		local newModule = moduleToClone:Clone() :: BaseScript
		newModule.Parent = actors[actorIndex]
		table.insert(modulesList, newModule)

		actorIndex = actorIndex % ACTOR_POOL_COUNT + 1
	end

	return modulesList
end

function ActorsManager.GetActorCount(): number
	return ACTOR_COUNT
end

return ActorsManager
