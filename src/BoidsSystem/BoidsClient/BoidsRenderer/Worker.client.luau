--!strict
-- Disabled template, enabled only on clones in the renderer's fixed pool.
local actor=script.Parent
if not actor:IsA("Actor") then return end
local modules=script:WaitForChild("Modules") :: ObjectValue
local source=modules.Value :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient.BoidsRenderer)
local Types=require(source.Types)
local Shard=require(source.Shard)
local reply=actor:WaitForChild("Reply") :: BindableEvent
local state=Shard.New()
local busy=false
local lastEpoch=0
type Request={id: number,lifetime: number,token: number,isGroup: boolean}
local requests: {Request}={}
local function observe(request: Request): ()
	if request.isGroup then reply:Fire("Group",request.token,Shard.GroupAge(state,request.id))
	else reply:Fire("Sample",request.token,Shard.Sample(state,request.id,request.lifetime)) end
end
actor:BindToMessage("Observe",function(id: number,lifetime: number,token: number,isGroup: boolean): ()
	local request: Request={id=id,lifetime=lifetime,token=token,isGroup=isGroup}
	if busy then requests[#requests+1]=request else observe(request) end
end)
actor:BindToMessageParallel("Frame",function(job: Types.Frame): ()
	if busy or job.epoch<=lastEpoch then
		task.synchronize()
		reply:Fire("Done",job.epoch,{epoch=job.epoch,dirty=0,kernelMs=0,synchronizeMs=0,assignmentMs=0,inputMs=0,error="Overlapping or reordered render frame"})
		return
	end
	busy=true
	lastEpoch=job.epoch
	local inputMs,kernelMs,synchronizeMs,assignmentMs=0,0,0,0
	local dirty=0
	local ok,err=xpcall(function(): boolean
		local started=if job.measure then os.clock() else 0
		debug.profilebegin("BoidsRender.Input")
		Shard.Apply(state,job.changes,job.samples)
		debug.profileend()
		if job.measure then inputMs=(os.clock()-started)*1000
		started=os.clock() end
		debug.profilebegin("BoidsRender.Calculate")
		Shard.Calculate(state,job.grants,job.now)
		debug.profileend()
		if job.measure then kernelMs=(os.clock()-started)*1000
		started=os.clock() end
		task.synchronize()
		if job.measure then synchronizeMs=(os.clock()-started)*1000
		started=os.clock() end
		debug.profilebegin("BoidsRender.Assign")
		dirty=Shard.Commit(state)
		actor:SetAttribute("CommittedEpoch",job.epoch)
		debug.profileend()
		if job.measure then assignmentMs=(os.clock()-started)*1000 end
		return true
	end,function(message: unknown): string return debug.traceback(tostring(message)) end)
	task.synchronize()
	busy=false
	local result: Types.Result={epoch=job.epoch,dirty=dirty,inputMs=inputMs,kernelMs=kernelMs,synchronizeMs=synchronizeMs,assignmentMs=assignmentMs,error=if ok then nil else tostring(err)}
	reply:Fire("Done",job.epoch,result)
	for _,request in requests do observe(request) end
	table.clear(requests)
end)
reply:Fire("Ready",0)

