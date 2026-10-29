--!strict
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local RendererBenchmark = {}
type Snapshot = {
 samples: number, rendererMsTotal: number, rendererMsMax: number,
 frameMsTotal: number, frameMsMax: number, activeCells: number,
 scheduledCells: number, scheduledBoids: number, dirtyTransforms: number,
 renderCap: number, agedCells: number,
 motionUpdates: number, motionUpdatesTotal: number, transparencyWrites: number, transparencyWritesTotal: number,
 hiddenCells: number, transitionCells: number, visibilityCap: number, transparencyWritesMax: number,
}
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
  workspace:SetAttribute("RendererBenchmarkImplementation", "Motor6D")
  workspace:SetAttribute("RendererBenchmarkSamples", s.samples)
  workspace:SetAttribute("RendererBenchmarkRendererMsAverage", s.rendererMsTotal / s.samples)
  workspace:SetAttribute("RendererBenchmarkRendererMsMax", s.rendererMsMax)
  workspace:SetAttribute("RendererBenchmarkFrameMsAverage", s.frameMsTotal / s.samples)
  workspace:SetAttribute("RendererBenchmarkFrameMsMax", s.frameMsMax)
  workspace:SetAttribute("RendererBenchmarkCpuFrameBudgetPercent", if s.frameMsTotal > 0 then s.rendererMsTotal / s.frameMsTotal * 100 else 0)
  workspace:SetAttribute("RendererBenchmarkActiveCells", s.activeCells)
  workspace:SetAttribute("RendererBenchmarkScheduledCells", s.scheduledCells)
  workspace:SetAttribute("RendererBenchmarkScheduledBoids", s.scheduledBoids)
  workspace:SetAttribute("RendererBenchmarkDirtyTransforms", s.dirtyTransforms)
  workspace:SetAttribute("RendererBenchmarkRenderCap", s.renderCap)
  workspace:SetAttribute("RendererBenchmarkAgedCells", s.agedCells)
  workspace:SetAttribute("RendererBenchmarkMotionUpdates", s.motionUpdates)
  workspace:SetAttribute("RendererBenchmarkMotionUpdatesTotal", s.motionUpdatesTotal)
  workspace:SetAttribute("RendererBenchmarkTransparencyWrites", s.transparencyWrites)
  workspace:SetAttribute("RendererBenchmarkTransparencyWritesTotal", s.transparencyWritesTotal)
  workspace:SetAttribute("RendererBenchmarkHiddenCells", s.hiddenCells)
  workspace:SetAttribute("RendererBenchmarkTransitionCells", s.transitionCells)
  workspace:SetAttribute("RendererBenchmarkVisibilityCap", s.visibilityCap)
  workspace:SetAttribute("RendererBenchmarkTransparencyWritesMax", s.transparencyWritesMax)
 end)
end
return RendererBenchmark
