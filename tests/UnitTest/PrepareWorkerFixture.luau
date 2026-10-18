--!strict
-- Call from a privileged Studio Edit tool before Play, then use the normal test runner.
local RunService = game:GetService("RunService")
local prelude = [==[local package = game.ReplicatedStorage.BoidsReplicated
local SharedTypes = require(package.SharedTypes)
local Quantization = table.clone(require(package.Quantization))
Quantization.CurrentSimTick = function(): number return 100 end
local BoidStorage = require(package.BoidStorage)
local StatsCodec = require(package.Boids.StatsCodec)
local SnapshotCodec = require(package.SnapshotCodec)
local fakeClock = 0
local os = {clock=function(): number fakeClock += 0.000001;return fakeClock end}
local raycastProvider: ((Vector3, Vector3) -> any)? = nil
local workspace = {
 GetServerTimeNow=function(): number return 100/60 end,
 Raycast=function(_: any, origin: Vector3, direction: Vector3, _params: any): any
  if raycastProvider then return raycastProvider(origin, direction) end
  return nil
 end,
}
local WorkerCore = {}
function WorkerCore.SetTestRaycastProvider(provider: ((Vector3, Vector3) -> any)?): ()
 raycastProvider = provider
end]==]
return function(): string
 assert(not RunService:IsRunning(), "Prepare the generated fixture in Edit mode")
 local worker = game.ServerScriptService.BoidsSystem.BoidsReplicated.Boids.WorkerCore
 local source = worker.Source
 local first = assert(source:find("local ReplicatedStorage", 1, true), "Worker import boundary changed")
 local marker = "local WorkerCore = {}"
 local last = assert(source:find(marker, first, true), "Worker import boundary changed") + #marker
 local generated = source:sub(1, first - 1) .. prelude .. source:sub(last)
 local folder = script.Parent.Fixtures
 local fixture = folder:FindFirstChild("WorkerCoreStep01") :: ModuleScript?
 if not fixture then
  fixture=Instance.new("ModuleScript");fixture.Name="WorkerCoreStep01";fixture.Parent=folder
 else
  assert(fixture:GetAttribute("GeneratedStep01Fixture") == true, "Do not overwrite a hand-edited fixture")
 end
 fixture.Source=generated
 fixture:SetAttribute("GeneratedStep01Fixture",true)
 fixture:SetAttribute("SourcePath",worker:GetFullName())
 fixture:SetAttribute("GeneratedAtUtc",os.date("!%Y-%m-%dT%H:%M:%SZ"))
 return fixture:GetFullName()
end
