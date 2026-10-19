--!strict
-- Call from a privileged Studio Edit tool before Play, then use the normal test runner.
local prelude = [==[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local package = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
 :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local SharedTypes = require(package.SharedTypes)
export type RaycastHit = {Distance: number, Normal: Vector3?, Position: Vector3?, Instance: BasePart?}
export type RaycastProvider = (Vector3, Vector3) -> RaycastHit?
export type Pages = {id: number?, pages: {SharedTypes.Page}, pageCount: number, openPages: {[number]: boolean}, pendingPages: {[number]: boolean}}
export type Cell = {
 id: number, origin: Vector3, networkTick: number, networkInterval: number, emitSnapshot: boolean,
 pages: Pages, pageCount: number, scheduledBoidCount: number, processedBoidCount: number, boidCount: number,
}
export type Input = {
 id: number?, groupId: number, usesPath: boolean, jobCells: {Cell}, averageSight: number, detailedMetrics: boolean,
 movedBoids: {[number]: {number | Vector3}}, cellCount: number?, startTime: number?, completionTime: number?, estimatedCost: number?,
}
export type Result = {
 jobCells: {Cell}, measurement: SharedTypes.WorkerMeasurement, snapshotGroups: SharedTypes.SnapshotGroupsBySourceCell,
 movedBoids: {[number]: {number | Vector3}}, completionTime: number,
}
export type Reply = {Fire: (Reply, Result?, number?, string?) -> ()}
export type MessageReconciliationTarget = {boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number, lifetime: number}
export type Handlers = {
 NewJob: (Input, Reply, number, number) -> (),
 NewBoidsStatsBatch: ({boidCount: number, data: buffer, lifetimes: {number}}) -> (),
 NewGroupTarget: (number, SharedTypes.Target, number) -> (),
 NewGroupPath: (number, {SharedTypes.PathNode}, number, boolean, boolean, number, number) -> (),
 SetBoidReconciliationTargets: ({MessageReconciliationTarget}) -> (),
}
export type ActorDouble = {
 BindToMessageParallel: (ActorDouble, string, unknown) -> (),
 BindToMessage: (ActorDouble, string, unknown) -> (),
}
export type Core = {Start: (ActorDouble) -> (), SetTestRaycastProvider: (RaycastProvider?) -> ()}
local Quantization = table.clone(require(package.Quantization))
Quantization.CurrentSimTick = function(): number return 100 end
local BoidStorage = require(package.BoidStorage)
local StatsCodec = require(package.Boids.StatsCodec)
local SnapshotCodec = require(package.SnapshotCodec)
local ObstacleDiagnostics = require(package.Boids.ObstacleDiagnostics)
local fakeClock = 0
local os = {clock=function(): number fakeClock += 0.000001;return fakeClock end}
local raycastProvider: RaycastProvider? = nil
local workspace = {
 GetServerTimeNow=function(): number return 100/60 end,
 Raycast=function(_: unknown, origin: Vector3, direction: Vector3, _params: RaycastParams?): RaycastResult?
  local readRaycast: RaycastProvider? = raycastProvider
  if readRaycast then return readRaycast(origin, direction) :: RaycastResult? end
  return nil
 end,
}
local WorkerCore = {}
function WorkerCore.SetTestRaycastProvider(provider: RaycastProvider?): ()
 raycastProvider = provider
end]==]
return function(sourceOverride: string?): string
 if not sourceOverride then
  assert(not game:GetService("RunService"):IsRunning(), "Prepare the generated fixture in Edit mode")
 end
 local source = sourceOverride or game.ServerScriptService.BoidsSystem.BoidsReplicated.Boids.WorkerCore.Source
 local first = assert(source:find("local ReplicatedStorage", 1, true), "Worker import boundary changed")
 local marker = "local WorkerCore = {}"
 local last = assert(source:find(marker, first, true), "Worker import boundary changed") + #marker
 local generated = source:sub(1, first - 1) .. prelude .. source:sub(last)
 -- The fixture supplies message registration, not a live engine Actor.
 local replacements: number
 generated, replacements = generated:gsub("function WorkerCore%.Start%(actor: Actor%)", "function WorkerCore.Start(actor: ActorDouble)")
 assert(replacements == 1, "Worker Start boundary changed")
 if sourceOverride then return generated end
 local worker = game.ServerScriptService.BoidsSystem.BoidsReplicated.Boids.WorkerCore
 local folder = script.Parent.Fixtures
 local existing: ModuleScript? = folder:FindFirstChild("WorkerCoreStep01") :: ModuleScript?
 local fixture: ModuleScript
 if not existing then
  fixture=Instance.new("ModuleScript");fixture.Name="WorkerCoreStep01";fixture.Parent=folder
 else
  fixture = existing
  assert(fixture:GetAttribute("GeneratedStep01Fixture") == true, "Do not overwrite a hand-edited fixture")
 end
 fixture.Source=generated
 fixture:SetAttribute("GeneratedStep01Fixture",true)
 fixture:SetAttribute("SourcePath",worker:GetFullName())
 fixture:SetAttribute("GeneratedAtUtc",os.date("!%Y-%m-%dT%H:%M:%SZ"))
 return fixture:GetFullName()
end
