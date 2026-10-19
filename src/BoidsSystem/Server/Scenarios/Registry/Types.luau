--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
export type Viewer = {id: number, position: Vector3}
export type LODPresetName = "low" | "medium" | "high"
export type Scenario = {
 name: string, lodPreset: LODPresetName,
 serverGroups: {ScenarioTypes.GroupDefinition} | ((Player) -> {ScenarioTypes.GroupDefinition}),
 clientGroups: {ScenarioTypes.GroupDefinition}, viewers: {Viewer},
 warmupSeconds: number, sampleSeconds: number,
 queryIndexMode: "none" | "client" | "server" | "both",
}
return {}
