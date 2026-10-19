--!strict
-- Isolated renderer lifecycle exercise. Run from a normal client LocalScript.
local Players=game:GetService("Players")
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local client=Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
local shared=ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local Renderer=require(client.BoidsRenderer)
local Snapshot=require(shared.SnapshotCodec)
local SharedTypes=require(shared.SharedTypes)
return function(): {replacement: boolean,staleReplyRejected: boolean,groupRemoved: boolean}
 local id,groupId=65535,60000
 assert(Renderer.GetRenderedBoidPose(id)==nil and not Renderer.HasRenderedGroup(groupId),"Test IDs are occupied")
 local ids=buffer.create(2)
 buffer.writeu16(ids,0,id)
 local models=buffer.create(1)
 buffer.writeu8(models,0,SharedTypes.BoidModels.Boid)
 local view=(workspace.CurrentCamera :: Camera).CFrame
 local target=view.Position+view.LookVector*20
 local origin=Vector3.new((target.X//128)*128,(target.Y//128)*128,(target.Z//128)*128)
 local row=Snapshot.NewCellSnapshot(1,origin)
 Snapshot.AppendBoid(row,id,target-origin,view.LookVector*10)
 local packet=buffer.create(4)
 buffer.writeu16(packet,0,1)
 buffer.writeu16(packet,2,id)
 local function spawn(lifetime: number): ()
  Renderer.ReceiveNewBoidBatch({groupId=groupId,boidCount=1,boidIds=ids,boidModels=models,renderColor=Color3.new(1,1,1),lifetimes={[id]=lifetime}})
  Renderer.ConsumeCellSnapshot(origin,row.networkBoids,1,workspace:GetServerTimeNow())
 end
 local function awaitRendered(): ()
  local deadline=os.clock()+5
  while os.clock()<deadline do
   local pose=Renderer.GetRenderedBoidPose(id)
   if pose and pose.isRendered then return end
   task.wait()
  end
  error("Test boid was not rendered")
 end
 local ok,result=pcall(function()
  spawn(1000)
  awaitRendered()
  local oldReply=false
  local rejected=false
  Renderer.RequestRenderedBoidSample(id,function(sample: Renderer.RenderedBoidSample?): ()
   oldReply=true
   rejected=sample==nil
  end)
  Renderer.ReceiveDeleteBoidBatch(packet,{[id]=1000})
  assert(Renderer.GetRenderedBoidPose(id)==nil)
  spawn(1001)
  Renderer.ReceiveDeleteBoidBatch(packet,{[id]=1000})
  assert(Renderer.GetRenderedBoidPose(id)~=nil,"Old deletion removed replacement")
  awaitRendered()
  local deadline=os.clock()+5
  while not oldReply and os.clock()<deadline do task.wait() end
  assert(oldReply and rejected,"Old request crossed renderer lifetime")
  Renderer.ReceiveDeleteGroup(groupId)
  assert(Renderer.GetRenderedBoidPose(id)==nil and Renderer.GetRenderedGroupInfo(groupId)==nil)
  spawn(1000) -- tombstoned batch must not recreate an empty group
  assert(Renderer.GetRenderedBoidPose(id)==nil and not Renderer.HasRenderedGroup(groupId))
  return {replacement=true,staleReplyRejected=true,groupRemoved=true}
 end)
 Renderer.ReceiveDeleteGroup(groupId)
 assert(ok,tostring(result))
 return result :: {replacement: boolean,staleReplyRejected: boolean,groupRemoved: boolean}
end

