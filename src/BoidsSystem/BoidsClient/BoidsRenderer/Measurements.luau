--!strict
-- Renderer-owned numeric instrumentation; no experiment attributes or output.
local Measurements = {}
export type Snapshot = {
 samples: number, rendererMsTotal: number, rendererMsMax: number,
 frameMsTotal: number, frameMsMax: number, activeCells: number,
 scheduledCells: number, scheduledBoids: number, dirtyTransforms: number,
 renderCap: number, agedCells: number,
}
local enabled = false
local state: Snapshot
function Measurements.Reset(): ()
 state = {samples=0, rendererMsTotal=0, rendererMsMax=0, frameMsTotal=0, frameMsMax=0,
  activeCells=0, scheduledCells=0, scheduledBoids=0, dirtyTransforms=0, renderCap=0, agedCells=0}
end
function Measurements.SetEnabled(value: boolean): () enabled = value end
function Measurements.IsEnabled(): boolean return enabled end
function Measurements.Read(): Snapshot return table.clone(state) end
function Measurements.Record(rendererMs: number, frameDt: number, activeCells: number, scheduledCells: number, scheduledBoids: number, dirtyTransforms: number, renderCap: number, agedCells: number): ()
 if not enabled then return end
 local frameMs = frameDt * 1000
 state.samples += 1
 state.rendererMsTotal += rendererMs
 state.rendererMsMax = math.max(state.rendererMsMax, rendererMs)
 state.frameMsTotal += frameMs
 state.frameMsMax = math.max(state.frameMsMax, frameMs)
 state.activeCells = activeCells
 state.scheduledCells = scheduledCells
 state.scheduledBoids = scheduledBoids
 state.dirtyTransforms = dirtyTransforms
 state.renderCap = renderCap
 state.agedCells = agedCells
end
Measurements.Reset()
return Measurements
