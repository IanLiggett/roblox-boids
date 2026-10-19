--!strict
-- Exercise the production Worker in an isolated Actor, outside the live render pool.
local Players=game:GetService("Players")
local client=Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
return function(): {terminalFailure: boolean,reorderedRejected: boolean}
 local actor=Instance.new("Actor")
 actor.Name="RendererWorkerVerification"
 local reply=Instance.new("BindableEvent")
 reply.Name="Reply"
 reply.Parent=actor
 local ready=false
 local errors: {string}={}
 local connection=reply.Event:Connect(function(kind: string,_epoch: number,result: {error: string?}?): ()
  if kind=="Ready" then ready=true
  elseif kind=="Done" and result and result.error then errors[#errors+1]=result.error end
 end)
 local runner=client.BoidsRenderer.Worker:Clone()
 local reference=Instance.new("ObjectValue")
 reference.Name="Modules"
 reference.Value=client.BoidsRenderer
 reference.Parent=runner
 runner.Parent=actor
 actor.Parent=Players.LocalPlayer.PlayerScripts
 runner.Enabled=true
 local function waitFor(predicate: ()->boolean): ()
  local deadline=os.clock()+5
  while not predicate() and os.clock()<deadline do task.wait() end
  assert(predicate(),"Worker terminal acknowledgement timed out")
 end
 local ok,failure=pcall(function(): ()
  waitFor(function(): boolean return ready end)
  actor:SendMessage("Frame",{epoch=1,now=1,changes={},samples=buffer.create(0),grants={{key=123,first=1,count=1}},measure=false})
  waitFor(function(): boolean return #errors==1 end)
  assert(actor:GetAttribute("CommittedEpoch")==nil,"Failed work published a commit marker")
  actor:SendMessage("Frame",{epoch=1,now=1,changes={},samples=buffer.create(0),grants={},measure=false})
  waitFor(function(): boolean return #errors==2 end)
  assert(string.find(errors[2],"reordered",1,true),"Old epoch was not rejected")
 end)
 connection:Disconnect()
 actor:Destroy()
 assert(ok,tostring(failure))
 return {terminalFailure=true,reorderedRejected=true}
end

