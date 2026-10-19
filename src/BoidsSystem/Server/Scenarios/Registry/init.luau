--!strict
-- Lookup, trusted runtime configuration and one-session scenario orchestration.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local ScenarioRuntime = require(BoidsReplicated.Scenarios.Runtime)
local Delivery = require(BoidsReplicated.Scenarios.Delivery)
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local SharedTypes = require(BoidsReplicated.SharedTypes)
local QueryIndexConfig = require(BoidsReplicated.QueryIndexConfig)
local Types = require(script.Types)
local Catalog = require(script.Catalog)
local Registry = {}
type GroupBinding = ScenarioTypes.GroupBinding
type ScenarioContext = ScenarioTypes.ScenarioContext
type Group = SharedTypes.Group
type BoidsApi = RuntimeTypes.GroupWriter & {SetLODPreset: ("low" | "medium" | "high") -> boolean}
export type Viewer = Types.Viewer
export type LODPresetName = Types.LODPresetName
export type Scenario = Types.Scenario
Registry.GetScenario = Catalog.GetScenario
local hasStarted = false

-- Resolve trusted scenario configuration before the process starts runtime hooks.
function Registry.ConfigureRuntime(scenarioName: string, boids: BoidsApi): ()
	local scenario = assert(Registry.GetScenario(scenarioName), `Unknown boid scenario {scenarioName}`)
	assert(boids.SetLODPreset(scenario.lodPreset), `Scenario {scenarioName} has an invalid LOD preset`)
	if not QueryIndexConfig.IsLocked() then
		assert(QueryIndexConfig.SetMode(scenario.queryIndexMode), `Scenario {scenarioName} has an invalid query-index mode`)
	end
end

function Registry.StartServerScenario(scenarioName: string, boids: BoidsApi, player: Player?, spawnServerGroups: boolean): ({Group}, {number}, Scenario, ScenarioContext)
	local scenario = assert(Registry.GetScenario(scenarioName), `Unknown boid scenario {scenarioName}`)
	assert(not hasStarted, "Only one scenario may start per Play session")
	hasStarted = true
	Registry.ConfigureRuntime(scenarioName, boids)
	-- World fixtures are session resources, not group or combat lifetimes.
	game:BindToClose(Catalog.CleanupFixtures)

	local groups: {Group} = {}
	local boidIds: {number} = {}
	local context: ScenarioContext = { name = scenario.name, serverGroups = {} }
	if spawnServerGroups then
		local groupSource = scenario.serverGroups
		local serverGroups: {ScenarioTypes.GroupDefinition}
		if type(groupSource) == "function" then
			assert(player, `Scenario {scenarioName} requires a player target`)
			serverGroups = groupSource(player)
		else
			serverGroups = groupSource
		end

		for index, spawned in ScenarioRuntime.SpawnGroups(boids, serverGroups) do
			local binding: GroupBinding = {
				groupId = spawned.group.id,
				ownership = "server",
				definition = serverGroups[index],
			}
			table.insert(context.serverGroups, binding)
			table.insert(groups, spawned.group)
			for _, boidId in spawned.boidIds do
				table.insert(boidIds, boidId)
			end
		end
	end



	-- This is separate from the server lifecycle stream: it instructs every
	-- client to create an intentionally client-owned group alongside replicas.
	Delivery.Publish(scenario.name, scenario.clientGroups, {
		warmupSeconds = scenario.warmupSeconds,
		sampleSeconds = scenario.sampleSeconds,
	}, context)

	return groups, boidIds, scenario, context
end

return Registry
