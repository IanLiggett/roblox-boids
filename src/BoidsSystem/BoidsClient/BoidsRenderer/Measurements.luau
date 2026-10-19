--!strict
-- Renderer-owned opt-in accounting. Parallel sums and elapsed time are separate.
local Measurements={}
export type Snapshot={
 samples: number,epochs: number,rendererMsTotal: number,rendererMsMax: number,
 frameMsTotal: number,frameMsMax: number,activeCells: number,scheduledCells: number,
 scheduledBoids: number,dirtyTransforms: number,renderCap: number,agedCells: number,
 coordinatorMs: number,kernelMs: number,inputMs: number,synchronizeMs: number,assignmentMs: number,
 inputBytes: number,messages: number,processedBoids: number,
}
local enabled=false
local revision=0
local state: Snapshot
function Measurements.Reset(): ()
 revision+=1
 state={samples=0,epochs=0,rendererMsTotal=0,rendererMsMax=0,frameMsTotal=0,frameMsMax=0,
  activeCells=0,scheduledCells=0,scheduledBoids=0,dirtyTransforms=0,renderCap=0,agedCells=0,
  coordinatorMs=0,kernelMs=0,inputMs=0,synchronizeMs=0,assignmentMs=0,inputBytes=0,messages=0,processedBoids=0}
end
function Measurements.Revision(): number return revision end
function Measurements.SetEnabled(value: boolean): () enabled=value end
function Measurements.IsEnabled(): boolean return enabled end
function Measurements.Read(): Snapshot return table.clone(state) end
function Measurements.Frame(dt: number): ()
 if not enabled then return end
 state.samples+=1
 state.frameMsTotal+=dt*1000
 state.frameMsMax=math.max(state.frameMsMax,dt*1000)
end
function Measurements.RecordEpoch(wallMs: number,coordinatorMs: number,kernelMs: number,inputMs: number,synchronizeMs: number,assignmentMs: number,
 inputBytes: number,messages: number,activeCells: number,scheduledCells: number,scheduledBoids: number,dirty: number,cap: number,aged: number): ()
 if not enabled then return end
 state.epochs+=1
 state.rendererMsTotal+=wallMs
 state.rendererMsMax=math.max(state.rendererMsMax,wallMs)
 state.coordinatorMs+=coordinatorMs
 state.kernelMs+=kernelMs
 state.inputMs+=inputMs
 state.synchronizeMs+=synchronizeMs
 state.assignmentMs+=assignmentMs
 state.inputBytes+=inputBytes
 state.messages+=messages
 state.processedBoids+=dirty
 state.activeCells=activeCells
 state.scheduledCells=scheduledCells
 state.scheduledBoids=scheduledBoids
 state.dirtyTransforms=dirty
 state.renderCap=cap
 state.agedCells=aged
end
Measurements.Reset()
return Measurements
