--!strict
--[[
BenchmarkHarness
================
Test-only orchestration for repeatable WorkerCore performance comparisons.
It configures fresh Studio sessions through replicated attributes and keeps all
scenario/Actor work outside the reusable simulation package.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BenchmarkConfig = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)

local RuntimeConfig = require(BenchmarkConfig.RuntimeConfig)
local Quantization = require(BenchmarkConfig.Quantization)
local BenchmarkHarness = {}
local runtimeConfigurations: {[string]: RuntimeConfig.Resolved} = {}

export type RunOptions = {
	runId: string,
	variant: string,
	warmupSeconds: number,
	sampleSeconds: number,
	metadata: {[string]: string | number | boolean},
	cameraCFrame: CFrame,
}

export type PairEntry = {
	pair: number,
	variant: "baseline" | "candidate",
}

type Profile = {warmupSeconds: number, sampleSeconds: number, pairCount: number}
local profiles: {[string]: Profile} = {
	screening = { warmupSeconds = 15, sampleSeconds = 45, pairCount = 3 },
	confirmation = { warmupSeconds = 30, sampleSeconds = 90, pairCount = 5 },
}

local function readStringAttribute(name: string, fallback: string): string
	local value = BenchmarkConfig:GetAttribute(name)
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function readNumberAttribute(name: string, fallback: number): number
	local value = BenchmarkConfig:GetAttribute(name)
	return if type(value) == "number" and value >= 0 then value else fallback
end

-- Resolve once per scenario/session; runtime and report metadata use this same value.
function BenchmarkHarness.GetRuntimeConfiguration(scenarioName: string): RuntimeConfig.Resolved
	local cached = runtimeConfigurations[scenarioName]
	if cached then return cached end
	local options: {actorCount: number?, targetActorJobMs: number?} = {}
	if string.find(scenarioName, "^Benchmark") then
		local actorCount = BenchmarkConfig:GetAttribute("BoidBenchmarkActorCount")
		local targetMs = BenchmarkConfig:GetAttribute("BoidBenchmarkTargetActorJobMs")
		if type(actorCount) == "number" and actorCount % 1 == 0 and actorCount >= 1 and actorCount <= 32 then
			options.actorCount = actorCount
		end
		if type(targetMs) == "number" and targetMs > 0 and targetMs < math.huge then
			options.targetActorJobMs = targetMs
		end
	end
	local resolved = RuntimeConfig.Resolve(options)
	runtimeConfigurations[scenarioName] = resolved
	return resolved
end

function BenchmarkHarness.GetStartupConfiguration(): RuntimeConfig.Resolved
	local name = BenchmarkConfig:GetAttribute("ActiveBoidsScenario")
	return BenchmarkHarness.GetRuntimeConfiguration(if type(name) == "string" then name else "")
end

function BenchmarkHarness.GetRunOptions(scenarioName: string): RunOptions?
	if not string.find(scenarioName, "^Benchmark") then
		return nil
	end

	local profileName = readStringAttribute("BoidBenchmarkProfile", "screening")
	local profile = profiles[profileName :: "screening" | "confirmation"]
	assert(profile, `Unknown BoidBenchmarkProfile {profileName}`)

	local variant = readStringAttribute("BoidBenchmarkVariant", "baseline")
	assert(variant == "baseline" or variant == "candidate", `Unknown BoidBenchmarkVariant {variant}`)

	local warmupSeconds = readNumberAttribute("BoidBenchmarkWarmupSeconds", profile.warmupSeconds)
	local sampleSeconds = readNumberAttribute("BoidBenchmarkSampleSeconds", profile.sampleSeconds)
	local runId = readStringAttribute("BoidBenchmarkRunId", `{scenarioName}:{profileName}:{variant}`)
	local sourceRevision = readStringAttribute("BoidBenchmarkSourceRevision", "unrecorded")
	local runtimeConfig = BenchmarkHarness.GetRuntimeConfiguration(scenarioName)

	return {
		runId = runId,
		variant = variant,
		warmupSeconds = warmupSeconds,
		sampleSeconds = sampleSeconds,
		metadata = {
			benchmarkRunId = runId,
			benchmarkVariant = variant,
			benchmarkProfile = profileName,
			benchmarkScenario = scenarioName,
			benchmarkTargetSchedule = "static-path-v1",
			benchmarkCamera = "0,200,700 -> 0,0,0",
			benchmarkQueryIndexMode = "both",
			benchmarkSourceRevision = sourceRevision,
			benchmarkActorCount = runtimeConfig.actorCount,
			benchmarkCellMargin = Quantization.CELL_MARGIN,
			benchmarkTargetActorJobMs = runtimeConfig.targetActorJobMs,
		},
		cameraCFrame = CFrame.lookAt(Vector3.new(0, 200, 700), Vector3.zero),
	}
end

function BenchmarkHarness.CreateAlternatingPlan(pairCount: number): {PairEntry}
	assert(pairCount > 0 and pairCount % 1 == 0, "pairCount must be a positive integer")
	local entries: {PairEntry} = table.create(pairCount * 2) :: {PairEntry}
	for pair = 1, pairCount do
		local first = if pair % 2 == 1 then "baseline" else "candidate"
		entries[#entries + 1] = { pair = pair, variant = first }
		entries[#entries + 1] = { pair = pair, variant = if first == "baseline" then "candidate" else "baseline" }
	end
	return entries
end

function BenchmarkHarness.GetProfile(name: string): (number, number, number)
	local profile = assert(profiles[name :: "screening" | "confirmation"], `Unknown benchmark profile {name}`)
	return profile.warmupSeconds, profile.sampleSeconds, profile.pairCount
end

return BenchmarkHarness
