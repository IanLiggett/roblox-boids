--!strict
-- Test-only capture, invoked by a normal LocalScript in a fresh standalone session.
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local HttpService=game:GetService("HttpService")
local client=Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
local Renderer=require(client.BoidsRenderer)
local Measurements=require(client.BoidsRenderer.Measurements)
export type Options={warmupSeconds: number,sampleSeconds: number,runId: string,scenario: string,variant: string}
return function(options: Options)
 local frames: {number}={}
 local isSampling=false
 local heartbeatSamples,heartbeatsWithoutRender,maxHeartbeatsWithoutRender=0,0,0
 local renderSeconds,firstRenderAt,lastRenderAt,maxRenderGap=0,0,0,0
 local cameraPosition=if options.scenario=="RandomTargetStress" then Vector3.new(0,150,350) else Vector3.new(0,200,700)
 local view=CFrame.lookAt(cameraPosition,Vector3.zero)
 local binding="RendererAcceptanceCamera"
 RunService:BindToRenderStep(binding,500,function(dt: number): ()
  if isSampling then
   frames[#frames+1]=dt*1000
   local now=os.clock()
   if firstRenderAt==0 then firstRenderAt=now end
   if lastRenderAt>0 then maxRenderGap=math.max(maxRenderGap,now-lastRenderAt) end
   lastRenderAt=now
   renderSeconds+=dt
   heartbeatsWithoutRender=0
  end
  local camera=workspace.CurrentCamera
  if camera then
   camera.CameraType=Enum.CameraType.Scriptable
   camera.CFrame=view
  end
 end)
 Renderer.SetMeasurementsEnabled(true)
 local initialWait=math.min(5,options.warmupSeconds)
 task.wait(initialWait)
 -- Exercise the lazy index before timing; mode alone does not create it.
 Renderer.GetBoidsInRadius(Vector3.zero,0)
 task.wait(options.warmupSeconds-initialWait)
 Renderer.ResetMeasurements()
 local rendererCallbacks=0
 local frameApi=(Measurements :: unknown) :: {Frame: ((number)->())?}
 local originalFrame=frameApi.Frame
 if originalFrame then
  frameApi.Frame=function(dt: number): ()
   rendererCallbacks+=1
   originalFrame(dt)
  end
 end
 isSampling=true
 local correctViews=0
 local ages: {number}={}
 local nextAge=0
 local ageSequence=0
 local attempted,processed=0,0
 type Record=(number,number,number,number,number,number,number,number)->()
 local legacy=(Measurements :: unknown) :: {Record: Record?}
 local originalRecord=legacy.Record
 if originalRecord then
  legacy.Record=function(a: number,b: number,c: number,d: number,e: number,f: number,g: number,h: number): ()
   attempted+=e
   processed+=f
   originalRecord(a,b,c,d,e,f,g,h)
  end
 end
 local legacyRenderer=(Renderer :: unknown) :: {GetRenderedBoidState: ((number)->{renderedAt: number?}?)?}
 local started=os.clock()
 local timer=RunService.Heartbeat:Connect(function(_dt: number): ()
  heartbeatSamples+=1
  heartbeatsWithoutRender+=1
  maxHeartbeatsWithoutRender=math.max(maxHeartbeatsWithoutRender,heartbeatsWithoutRender)
  if os.clock()>=nextAge then
   nextAge=os.clock()+0.25
   local sampledId=math.floor((ageSequence%32)*20000/32)
   ageSequence+=1
   if legacyRenderer.GetRenderedBoidState then
    local sample=legacyRenderer.GetRenderedBoidState(sampledId)
    if sample and sample.renderedAt then ages[#ages+1]=workspace:GetServerTimeNow()-sample.renderedAt end
   else
    Renderer.RequestRenderedBoidSample(sampledId,function(sample: Renderer.RenderedBoidSample?): ()
     if sample and sample.renderedAt then ages[#ages+1]=sample.sampledAt-sample.renderedAt end
    end)
   end
  end
  local camera=workspace.CurrentCamera
  if camera and (camera.CFrame.Position-view.Position).Magnitude<0.01 then correctViews+=1 end
 end)
 task.wait(options.sampleSeconds)
 timer:Disconnect()
 isSampling=false
 if originalFrame then frameApi.Frame=originalFrame end
 local elapsed=os.clock()-started
 if originalRecord then legacy.Record=originalRecord end
 local measurements=Renderer.GetMeasurements()
 local renderPool=Players.LocalPlayer.PlayerScripts:FindFirstChild("BoidsRenderActors")
 local renderRoot=workspace:FindFirstChild("BoidFolder")
 local renderFailure=if renderRoot then renderRoot:GetAttribute("RenderFailure") else "Missing render root"
 table.sort(ages)
 table.sort(frames)
 local function quantile(p: number): number return frames[math.max(1,math.ceil(#frames*p))] or 0 end
 local report={
  runId=options.runId,scenario=options.scenario,variant=options.variant,elapsed=elapsed,
  frameSamples=#frames,p50=quantile(.5),p95=quantile(.95),p99=quantile(.99),
  frameTimingSource="PreRender",heartbeatSamples=heartbeatSamples,
  rendererCallbacks=if originalFrame then rendererCallbacks else nil,
  maxHeartbeatsWithoutRender=maxHeartbeatsWithoutRender,
  renderSeconds=renderSeconds,firstRenderDelay=firstRenderAt-started,
  lastRenderDelay=os.clock()-lastRenderAt,maxRenderGap=maxRenderGap,
  renderFailure=renderFailure,
  -- Heartbeat can outnumber rendered frames under load; that is measured frame loss, not missing coverage.
  isValidForPerformance=renderSeconds>=elapsed*.95 and renderSeconds<=elapsed*1.05
   and firstRenderAt-started<1 and os.clock()-lastRenderAt<1 and maxRenderGap<5 and renderFailure==nil,
  correctViews=correctViews,renderer=measurements,
  processedBoids=if originalRecord then processed else measurements.processedBoids,
  attemptedBoids=if originalRecord then attempted else nil,
  sampledPoseAgeCount=#ages,
  sampledPoseAgeP50=ages[math.max(1,math.ceil(#ages*.5))],
  sampledPoseAgeP95=ages[math.max(1,math.ceil(#ages*.95))],
  sampledPoseAgeP99=ages[math.max(1,math.ceil(#ages*.99))],
  queryMetrics=Renderer.GetQueryMetrics(),
  renderActors=if renderPool then #renderPool:GetChildren() else 0,
  camera=tostring((workspace.CurrentCamera :: Camera).CFrame),
  viewport=tostring((workspace.CurrentCamera :: Camera).ViewportSize),
  queryMode=game.ReplicatedStorage:WaitForChild("BoidsReplicated"):GetAttribute("BoidQueryIndexMode"),
 }
 RunService:UnbindFromRenderStep(binding)
 Renderer.SetMeasurementsEnabled(false)
 local output=Instance.new("StringValue")
 output.Name="RendererAcceptanceReport"
 output.Value=HttpService:JSONEncode(report)
 output.Parent=workspace
 print("RENDER_ACCEPTANCE "..output.Value)
 return report
end

