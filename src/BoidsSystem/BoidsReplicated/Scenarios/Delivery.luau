--!strict
-- Scenario metadata owns its ledger/replay and late-handler queue. The generic
-- control plane supplies extension hooks; this module reuses its reliable remote.
local RunService = game:GetService("RunService")
local ScenarioTypes = require(script.Parent.Types)
local Replication = require(script.Parent.Parent.SimulationReplication)
local stateRemote: RemoteEvent = script.Parent.Parent.Remotes.SimulationState
local Delivery = {}

type Scenario = {name: string, groups: {ScenarioTypes.GroupDefinition}, benchmark: ScenarioTypes.Benchmark?, context: ScenarioTypes.ScenarioContext}
export type Handler = (string, {ScenarioTypes.GroupDefinition}, ScenarioTypes.Benchmark?, ScenarioTypes.ScenarioContext) -> ()
local serverScenarios: {[string]: Scenario} = {}
local serverStarted, clientStarted = false, false
local handler: Handler? = nil
local queued: {Scenario} = {}
local seen: {[string]: boolean} = {}

local function dispatch(record: Scenario): ()
	local current = handler
	if current then current(record.name, record.groups, record.benchmark, record.context)
	else table.insert(queued, record) end
end

function Delivery.StartServer(): ()
	if not RunService:IsServer() or serverStarted then return end
	serverStarted = true
	Replication.SetServerReplayExtension(function(player: Player): ()
		for _, record in serverScenarios do
			stateRemote:FireClient(player, "Scenario", record.name, record.groups, record.benchmark, record.context)
		end
	end)
end

function Delivery.Publish(name: string, groups: {ScenarioTypes.GroupDefinition}, benchmark: ScenarioTypes.Benchmark?, context: ScenarioTypes.ScenarioContext): ()
	assert(serverStarted, "Scenario delivery must start before publishing")
	local record: Scenario = {name=name, groups=groups, benchmark=benchmark, context=context}
	serverScenarios[name] = record
	stateRemote:FireAllClients("Scenario", name, groups, benchmark, context)
end

function Delivery.StartClient(): ()
	if not RunService:IsClient() or clientStarted then return end
	clientStarted = true
	Replication.SetClientStateExtension(function(kind: string, a: unknown, b: unknown, c: unknown, d: unknown): ()
		if kind ~= "Scenario" or type(a) ~= "string" or type(b) ~= "table" or type(d) ~= "table" then return end
		local rawContext: {name: unknown, serverGroups: unknown} = d :: {name: unknown, serverGroups: unknown}
		if seen[a] or type(rawContext.name) ~= "string" or type(rawContext.serverGroups) ~= "table" then return end
		if c ~= nil and type(c) ~= "table" then return end
		seen[a] = true
		dispatch({name=a, groups=b :: {ScenarioTypes.GroupDefinition}, benchmark=c :: ScenarioTypes.Benchmark?, context=d :: ScenarioTypes.ScenarioContext})
	end)
end

function Delivery.SetClientHandler(value: Handler): ()
	assert(not handler, "Scenario handler already registered")
	handler = value
	local pending = queued
	queued = {}
	for _, record in pending do dispatch(record) end
end
return Delivery
