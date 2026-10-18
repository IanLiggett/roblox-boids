--!strict

--[[ LODConfig
Description:
	Owns the client-render, server-simulation, and network LOD presets for the
	boid system. Server preset changes replicate to clients through the
	BoidsReplicated preset attribute.

Public API:
	getActive(): Config
	getSimulationConfig(kind: SimulationKind): SimulationConfig
	getSimulationKindForGroup(groupId: number): SimulationKind
	getPresetName(): PresetName
	setPreset(preset: PresetName): boolean
	getPreset(preset: PresetName): Config
]]

local RunService = game:GetService("RunService")
local LODConfig = {}


export type PresetName = "low" | "medium" | "high"

export type RenderBand = {
	range: number,
	hertz: number
}

export type RenderBands = {RenderBand}

-- Renderer scheduling is cell-based; bands select exact cell due intervals.
export type ClientConfig = {
	visibleRenderBands: RenderBands,
	offscreenHertz: number,
	maxRenderBoidsPerFrame: number,
	peripheralLodDistanceScale: number,
}

export type SimulationConfig = {
	nearDistance: number,
	farDistance: number,
	minIntervalMultiplier: number,
	maxIntervalMultiplier: number,
	backgroundIntervalMultiplier: number,
}

-- Server-owned boids, replicated client prediction, and client-local boids
-- deliberately have independent scheduling budgets and distance LOD settings.
export type SimulationKind = "server" | "clientPrediction" | "clientLocal"

export type NetworkConfig = {
	baseInterval: number,
	nearDistance: number,
	farDistance: number,
	minIntervalMultiplier: number,
	maxIntervalMultiplier: number,
}

export type Config = {
	client: ClientConfig,
	serverSimulation: SimulationConfig,
	clientPredictionSimulation: SimulationConfig,
	clientLocalSimulation: SimulationConfig,
	network: NetworkConfig,
}

local PRESET_ATTRIBUTE = "BoidsLODPreset"
LODConfig.PRESET_ATTRIBUTE = PRESET_ATTRIBUTE

-- Lower presets deliberately send substantially less frequent authoritative
-- correction data. Higher presets trade more network traffic for lower client
-- simulation divergence while retaining the same distance-based LOD shape.
local presets: {[PresetName]: Config} = {
	low = {
		client = {
			visibleRenderBands = {
				{range = 64, hertz = 30}, {range = 128, hertz = 15},
				{range = 192, hertz = 7.5}, {range = 256, hertz = 5},
				{range = 384, hertz = 3}, {range = 512, hertz = 1.5},
				{range = 640, hertz = 1}, {range = 768, hertz = 0.75},
				{range = 896, hertz = 0.5}, {range = 1024, hertz = 0.5},
				{range = 1280, hertz = 0.2}, {range = 1536, hertz = 0.2},
			},

			offscreenHertz = 0.2,
		peripheralLodDistanceScale = 0.50,
			maxRenderBoidsPerFrame = 1000000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 4,
			backgroundIntervalMultiplier = 4,
		},
		-- Tune predictive work against correction bandwidth independently.
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 4,
			backgroundIntervalMultiplier = 12,
		},
		-- Local-only scenarios never compete with prediction tuning.
		clientLocalSimulation = {
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 4,
			backgroundIntervalMultiplier = 4,
		},
		network = {
			baseInterval = 2,
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 6,
			maxIntervalMultiplier = 12,
		},
	},
	medium = {
		client = {
			visibleRenderBands = {
				{range = 64, hertz = 60}, {range = 128, hertz = 60},
				{range = 192, hertz = 45}, {range = 256, hertz = 30},
				{range = 384, hertz = 22.5}, {range = 512, hertz = 15},
				{range = 640, hertz = 13.125}, {range = 768, hertz = 11.25},
				{range = 896, hertz = 9.375}, {range = 1024, hertz = 7.5},
				{range = 1280, hertz = 7.5}, {range = 1536, hertz = 7.5},
			},

			offscreenHertz = 2,
		peripheralLodDistanceScale = 0.30,
			maxRenderBoidsPerFrame = 1000000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 3,
			backgroundIntervalMultiplier = 3,
		},
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 3,
			backgroundIntervalMultiplier = 3,
		},
		clientLocalSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 3,
			backgroundIntervalMultiplier = 3,
		},
		network = {
			baseInterval = 2,
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 3,
			maxIntervalMultiplier = 6,
		},
	},
	high = {
		client = {
			visibleRenderBands = {
				{range = 64, hertz = 60}, {range = 128, hertz = 60},
				{range = 192, hertz = 45}, {range = 256, hertz = 30},
				{range = 384, hertz = 22.5}, {range = 512, hertz = 15},
				{range = 640, hertz = 13.125}, {range = 768, hertz = 11.25},
				{range = 896, hertz = 9.375}, {range = 1024, hertz = 7.5},
				{range = 1280, hertz = 7.5}, {range = 1536, hertz = 7.5},
			},

			offscreenHertz = 4,
		peripheralLodDistanceScale = 0.15,
			maxRenderBoidsPerFrame = 1000000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 2,
			backgroundIntervalMultiplier = 2,
		},
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 2,
			backgroundIntervalMultiplier = 2,
		},
		clientLocalSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 1,
			maxIntervalMultiplier = 2,
			backgroundIntervalMultiplier = 2,
		},
		network = {
			baseInterval = 2,
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 2,
			maxIntervalMultiplier = 3,
		},
	},
}

for _, config: Config in presets do
	for _, band: RenderBand in config.client.visibleRenderBands do
		table.freeze(band)
	end
	table.freeze(config.client.visibleRenderBands)
	table.freeze(config.client)
	table.freeze(config.serverSimulation)
	table.freeze(config.clientPredictionSimulation)
	table.freeze(config.clientLocalSimulation)
	table.freeze(config.network)
	table.freeze(config)
end
table.freeze(presets)
LODConfig.Presets = presets

local activePreset: PresetName = "low"

local function resolvePresetName(value: unknown): PresetName?
	if type(value) ~= "string" then
		return nil
	end

	local preset = value :: PresetName
	if presets[preset] then
		return preset
	end

	return nil
end

local replicatedRoot = script.Parent
local replicatedPreset = resolvePresetName(replicatedRoot:GetAttribute(PRESET_ATTRIBUTE))
if replicatedPreset then
	activePreset = replicatedPreset
elseif RunService:IsServer() then
	replicatedRoot:SetAttribute(PRESET_ATTRIBUTE, activePreset)
end

replicatedRoot:GetAttributeChangedSignal(PRESET_ATTRIBUTE):Connect(function()
	local preset = resolvePresetName(replicatedRoot:GetAttribute(PRESET_ATTRIBUTE))
	if preset then
		activePreset = preset
	end
end)

function LODConfig.GetActive(): Config
	return presets[activePreset]
end

function LODConfig.GetSimulationConfig(kind: SimulationKind): SimulationConfig
	local config = presets[activePreset]
	if kind == "server" then
		return config.serverSimulation
	elseif kind == "clientPrediction" then
		return config.clientPredictionSimulation
	end
	return config.clientLocalSimulation
end

function LODConfig.GetSimulationKindForGroup(groupId: number): SimulationKind
	if not RunService:IsClient() then
		return "server"
	end

	-- Server-replica IDs occupy the lower u15 partition. Client-generated
	-- groups occupy the upper partition and are intentionally local-only.
	if groupId < 2^15 then
		return "clientPrediction"
	end
	return "clientLocal"
end

function LODConfig.GetPresetName(): PresetName
	return activePreset
end

function LODConfig.GetPreset(preset: PresetName): Config
	return presets[preset]
end

function LODConfig.SetPreset(preset: PresetName): boolean
	if not presets[preset] then
		return false
	end

	activePreset = preset
	if RunService:IsServer() then
		replicatedRoot:SetAttribute(PRESET_ATTRIBUTE, preset)
	end

	return true
end

return LODConfig
