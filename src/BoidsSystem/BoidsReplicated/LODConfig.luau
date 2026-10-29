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
	nearDistance: number,
	farDistance: number,
	nearPositionError: number,
	farPositionError: number,
	nearVelocityError: number,
	farVelocityError: number,
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

-- Higher presets spend more traffic on tighter position and velocity error bounds.
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
			maxRenderBoidsPerFrame = 100000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 0.2,
			maxIntervalMultiplier = 1,
			backgroundIntervalMultiplier = 4,
		},
		-- Tune predictive work against correction bandwidth independently.
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 512,
			minIntervalMultiplier = 0.2,
			maxIntervalMultiplier = 1,
			backgroundIntervalMultiplier = 4,
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
			nearDistance = 0,
			farDistance = 512,
			nearPositionError = 8,
			farPositionError = 32,
			nearVelocityError = 4,
			farVelocityError = 16,
		},
	},
	medium = {
		client = {
			visibleRenderBands = {
				{range = 64, hertz = 30}, {range = 128, hertz = 25},
				{range = 192, hertz = 15}, {range = 256, hertz = 10},
				{range = 384, hertz = 7.5}, {range = 512, hertz = 5},
				{range = 640, hertz = 2.5}, {range = 768, hertz = 1.5},
				{range = 896, hertz = 1}, {range = 1024, hertz = 1},
				{range = 1280, hertz = 0.5}, {range = 1536, hertz = 0.5},
			},

			offscreenHertz = 0.5,
		peripheralLodDistanceScale = 0.30,
			maxRenderBoidsPerFrame = 100000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 0.15,
			maxIntervalMultiplier = 0.7,
			backgroundIntervalMultiplier = 3,
		},
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 0.15,
			maxIntervalMultiplier = 0.7,
			backgroundIntervalMultiplier = 3,
		},
		clientLocalSimulation = {
			nearDistance = 0,
			farDistance = 768,
			minIntervalMultiplier = 0.15,
			maxIntervalMultiplier = 0.7,
			backgroundIntervalMultiplier = 3,
		},
		network = {
			nearDistance = 0,
			farDistance = 512,
			nearPositionError = 2,
			farPositionError = 8,
			nearVelocityError = 1,
			farVelocityError = 4,
		},
	},
	high = {
		client = {
			visibleRenderBands = {
				{range = 64, hertz = 30}, {range = 128, hertz = 25},
				{range = 192, hertz = 20}, {range = 256, hertz = 15},
				{range = 384, hertz = 10}, {range = 512, hertz = 7.5},
				{range = 640, hertz = 5}, {range = 768, hertz = 2.5},
				{range = 896, hertz = 2}, {range = 1024, hertz = 1.5},
				{range = 1280, hertz = 1}, {range = 1536, hertz = 0.5},
			},

			offscreenHertz = 0.5,
			peripheralLodDistanceScale = 0.15,
			maxRenderBoidsPerFrame = 100000,
		},
		serverSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 0.1,
			maxIntervalMultiplier = 0.5,
			backgroundIntervalMultiplier = 2,
		},
		clientPredictionSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 0.1,
			maxIntervalMultiplier = 0.5,
			backgroundIntervalMultiplier = 2,
		},
		clientLocalSimulation = {
			nearDistance = 0,
			farDistance = 1024,
			minIntervalMultiplier = 0.1,
			maxIntervalMultiplier = 0.5,
			backgroundIntervalMultiplier = 2,
		},
		network = {
			nearDistance = 0,
			farDistance = 512,
			nearPositionError = 1,
			farPositionError = 4,
			nearVelocityError = 1,
			farVelocityError = 2,
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
