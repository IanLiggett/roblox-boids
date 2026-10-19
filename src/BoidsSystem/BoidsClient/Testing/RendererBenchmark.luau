--!strict
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local Measurements = require(script.Parent.Parent.BoidsRenderer.Measurements)
local RendererBenchmark = {}
type Snapshot = Measurements.Snapshot
type Reader = {
 SetMeasurementsEnabled: (boolean) -> (), ResetMeasurements: () -> (),
 GetMeasurements: () -> Snapshot,
}
local connection: RBXScriptConnection? = nil
local running: Reader? = nil
local generation = 0

function RendererBenchmark.Stop(): ()
 generation += 1
 if connection then connection:Disconnect() connection = nil end
 if running then running.SetMeasurementsEnabled(false) end
 running = nil
end
-- Continuous opt-in session collector, independent of one-shot scenario telemetry.
-- The existing attribute interface/export names remain testing-owned.
function RendererBenchmark.Start(renderer: Reader): ()
 if running or Config:GetAttribute("RendererBenchmarkEnabled") ~= true then return end
 running = renderer
 generation += 1
 local ownedGeneration = generation
 local revision = Config:GetAttribute("RendererBenchmarkResetRevision")
 local lastExport = 0
 renderer.ResetMeasurements()
 renderer.SetMeasurementsEnabled(true)
 connection = RunService.Heartbeat:Connect(function()
  if running ~= renderer or generation ~= ownedGeneration then return end
  local currentRevision = Config:GetAttribute("RendererBenchmarkResetRevision")
  if currentRevision ~= revision then
   revision = currentRevision
   lastExport = 0
   renderer.ResetMeasurements()
   return
  end
  local s = renderer.GetMeasurements()
  if s.samples - lastExport < 60 then return end
  lastExport = s.samples
  workspace:SetAttribute("RendererBenchmarkImplementation", "Motor6DParallel")
  workspace:SetAttribute("RendererBenchmarkSamples", s.samples)
  workspace:SetAttribute("RendererBenchmarkRendererMsAverage", s.rendererMsTotal / s.samples)
  workspace:SetAttribute("RendererBenchmarkRendererMsMax", s.rendererMsMax)
  workspace:SetAttribute("RendererBenchmarkFrameMsAverage", s.frameMsTotal / s.samples)
  workspace:SetAttribute("RendererBenchmarkFrameMsMax", s.frameMsMax)
  workspace:SetAttribute("RendererBenchmarkWallFramePercent", if s.frameMsTotal > 0 then s.rendererMsTotal / s.frameMsTotal * 100 else 0)
  workspace:SetAttribute("RendererBenchmarkActiveCells", s.activeCells)
  workspace:SetAttribute("RendererBenchmarkScheduledCells", s.scheduledCells)
  workspace:SetAttribute("RendererBenchmarkScheduledBoids", s.scheduledBoids)
  workspace:SetAttribute("RendererBenchmarkDirtyTransforms", s.dirtyTransforms)
  workspace:SetAttribute("RendererBenchmarkRenderCap", s.renderCap)
  workspace:SetAttribute("RendererBenchmarkAgedCells", s.agedCells)
  workspace:SetAttribute("RendererBenchmarkEpochs", s.epochs)
  workspace:SetAttribute("RendererBenchmarkCoordinatorMs", s.coordinatorMs)
  workspace:SetAttribute("RendererBenchmarkKernelMs", s.kernelMs)
  workspace:SetAttribute("RendererBenchmarkInputMs", s.inputMs)
  workspace:SetAttribute("RendererBenchmarkSynchronizeMs", s.synchronizeMs)
  workspace:SetAttribute("RendererBenchmarkAssignmentMs", s.assignmentMs)
  workspace:SetAttribute("RendererBenchmarkInputBytes", s.inputBytes)
  workspace:SetAttribute("RendererBenchmarkMessages", s.messages)
  workspace:SetAttribute("RendererBenchmarkProcessedBoids", s.processedBoids)
 end)
end
return RendererBenchmark
