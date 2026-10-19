--!strict
-- Run from a normal client LocalScript after startup, with client indexing enabled.
local Players=game:GetService("Players")
local client=Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
local Renderer=require(client.BoidsRenderer)
export type Result={boidId: number,groupId: number,markerQueries: number,sampledAt: number,renderedAt: number,groupCount: number}
return function(): Result
 local id: number?=nil
 for _,part in workspace:WaitForChild("BoidFolder"):GetDescendants() do
  if not part:IsA("BasePart") then continue end
  local value=part:GetAttribute("BoidId")
  if type(value)=="number" then
   local pose=Renderer.GetRenderedBoidPose(value)
   if pose and pose.isRendered then
    id=value
    break
   end
  end
 end
 local selected=assert(id,"No rendered boid")
 local pose=assert(Renderer.GetRenderedBoidPose(selected))
 local function checkIndex(): ()
  local current=assert(Renderer.GetRenderedBoidPose(selected))
  local found=false
  for _,hit in Renderer.GetBoidsInRadius(current.cframe.Position,0.01) do
   if hit.boidId==selected then
    found=true
    break
   end
  end
  if not found then
   local indexed: Vector3?=nil
   for _,hit in Renderer.GetBoidsInRadius(current.cframe.Position,512) do
    if hit.boidId==selected then
     indexed=hit.Position
     break
    end
   end
   error("Query index does not contain submitted pose: id="..selected.." pose="..tostring(current.cframe.Position).." indexed="..tostring(indexed))
  end
 end
 checkIndex()
 assert(Renderer.RaycastBoids(pose.cframe.Position-Vector3.zAxis*5,Vector3.zAxis*10),"Ray missed rendered boid")
 local sample: Renderer.RenderedBoidSample?=nil
 local age: Renderer.RenderedGroupAge?=nil
 local sampleDone,ageDone=false,false
 local cancelSample=Renderer.RequestRenderedBoidSample(selected,function(value: Renderer.RenderedBoidSample?): ()
  sample=value
  sampleDone=true
 end)
 local cancelAge=Renderer.RequestRenderedGroupAge(pose.groupId,function(value: Renderer.RenderedGroupAge?): ()
  age=value
  ageDone=true
 end)
 local cancelledCalled=false
 local cancel=Renderer.RequestRenderedBoidSample(selected,function(): () cancelledCalled=true end)
 cancel()
 local markerQueries=0
 local markerFailure: unknown=nil
 local actors=(Players.LocalPlayer.PlayerScripts :: Instance):WaitForChild("BoidsRenderActors"):GetChildren()
 local actor=(Players.LocalPlayer.PlayerScripts :: Instance):WaitForChild("BoidsRenderActors"):FindFirstChild("Render_"..(selected%#actors+1)) :: Actor
 local connection=actor:GetAttributeChangedSignal("CommittedEpoch"):Connect(function(): ()
  local ok,err=pcall(checkIndex)
  if not ok then markerFailure=err end
  markerQueries+=1
 end)
 local deadline=os.clock()+5
 while (not sampleDone or not ageDone or markerQueries<3) and os.clock()<deadline do task.wait() end
 connection:Disconnect()
 cancelSample()
 cancelAge()
 assert(sampleDone and ageDone and markerQueries>=3,"Observation timed out")
 assert(markerFailure==nil,tostring(markerFailure))
 local sampled=assert(sample,"Missing detailed sample")
 local groupAge=assert(age,"Missing group reduction")
 assert(sampled.boidId==selected and sampled.isRendered and sampled.renderedAt and sampled.snapshotAt,"Inconsistent sample")
 assert(groupAge.count>0 and groupAge.oldestRenderedAt,"Missing group update age")
 assert(not cancelledCalled,"Cancelled observation delivered")
 return {boidId=selected,groupId=pose.groupId,markerQueries=markerQueries,sampledAt=sampled.sampledAt,renderedAt=sampled.renderedAt :: number,groupCount=groupAge.count}
end

