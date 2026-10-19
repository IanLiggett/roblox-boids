--!strict
local fs=require("@lune/fs")
local luau=require("@lune/luau")
local roblox=(require("@lune/roblox") :: unknown) :: {Vector3: typeof(Vector3), CFrame: typeof(CFrame)}
local root=if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base=root.."src/BoidsSystem/BoidsClient/BoidsRenderer/"
local Vector3,CFrame=roblox.Vector3,roblox.CFrame
local modules={}
local function load(name: string)
 return luau.load(fs.readFile(base..name..".luau"),{injectGlobals=true,environment={
  Vector3=Vector3,CFrame=CFrame,script={Parent=modules},
  require=function(value) return value end,
  workspace={GetServerTimeNow=function() return 100 end},
 }})()
end
modules.Types=load("Types")
modules.Kernel=load("Kernel")
local Shard=load("Shard")
local Scheduler=load("Scheduler")
local count=0
local function test(name: string,run: ()->()): ()
 run()
 count+=1
 print("PASS",name)
end
local function motor()
 local attributes={}
 return {
  Parent=({} :: {}?),Transform=CFrame.identity,
  GetAttribute=function(_self,key) return attributes[key] end,
  SetAttribute=function(_self,key,value) attributes[key]=value end,
 }
end
local config={visibleRenderBands={{range=64,hertz=60},{range=10000,hertz=1}},offscreenHertz=0.2,maxRenderBoidsPerFrame=7,peripheralLodDistanceScale=0.5}
test("global cap, mirrored fragments, no duplicate grants, and aging progress",function()
 local scheduler=Scheduler.New(4)
 local states={}
 for owner=1,4 do states[owner]=Shard.New() end
 local changes={{},{},{},{}}
 local inputs={{},{},{},{}}
 local motors={}
 for id=1,50 do
  local owner=id%4+1
  local key=if id<=30 then 1 else 2
  local change={id=id,lifetime=id,groupId=1,motor=motor(),createdAt=0,cellKey=key,cellOrigin=if key==1 then Vector3.new(-32,-32,-32) else Vector3.new(1000,0,0)}
  motors[id]=change.motor
  Scheduler.Apply(scheduler,change,owner,0)
  table.insert(changes[owner],change)
  table.insert(inputs[owner],id)
 end
 for owner=1,4 do
  local data=buffer.create(#inputs[owner]*modules.Types.SampleBytes)
  for index,id in inputs[owner] do modules.Types.WriteSample(data,(index-1)*modules.Types.SampleBytes,id,id,0,nil,Vector3.new(id,0,0),Vector3.new(10,0,0)) end
  Shard.Apply(states[owner],changes[owner],data)
 end
 for frame=1,100 do
  local now=frame/10
  local plan=Scheduler.Plan(scheduler,CFrame.lookAt(Vector3.zero,Vector3.zAxis),70,config,now)
  assert(plan.attempted<=7,"global cap exceeded")
  local seen={}
  local granted=0
  for owner,grants in plan.grants do
   for _,grant in grants do
    local fragment=scheduler.cells[grant.key].fragments[owner]
    for slot=grant.first,grant.first+grant.count-1 do
     local id=fragment.ids[slot]
     assert(not seen[id],"same boid granted twice")
     seen[id]=true
     granted+=1
     assert(states[owner].rows[states[owner].cells[grant.key][slot]].id==id,"fragment mirrors diverged")
    end
   end
   Shard.Calculate(states[owner],grants,now)
   Shard.Commit(states[owner])
  end
  assert(granted==plan.attempted)
  Scheduler.Settle(plan,now)
 end
 for id,value in motors do assert(value:GetAttribute("HasRendered")==true,"starved boid "..id) end
end)
test("slot compaction, cell moves, and lifetime replacement preserve mirrors",function()
 local scheduler=Scheduler.New(1)
 local state=Shard.New()
 local changes={}
 for id=1,4 do
  local change={id=id,lifetime=id,groupId=1,motor=motor(),createdAt=0,cellKey=1,cellOrigin=Vector3.zero}
  Scheduler.Apply(scheduler,change,1,0)
  table.insert(changes,change)
 end
 Shard.Apply(state,changes,buffer.create(0))
 local edits={
  {id=2,lifetime=2,groupId=1,createdAt=0},
  {id=4,lifetime=4,groupId=1,motor=state.rows[state.byId[4]].motor,createdAt=0,cellKey=2,cellOrigin=Vector3.one*64},
  {id=2,lifetime=100,groupId=2,motor=motor(),createdAt=1,cellKey=2,cellOrigin=Vector3.one*64},
 }
 for _,change in edits do Scheduler.Apply(scheduler,change,1,1) end
 Shard.Apply(state,edits,buffer.create(0))
 assert(state.rows[state.byId[2]].lifetime==100)
 assert(#state.rows==4)
 for key,cell in scheduler.cells do
  for slot,id in cell.fragments[1].ids do assert(state.rows[state.cells[key][slot]].id==id) end
 end
 local stale=buffer.create(modules.Types.SampleBytes)
 modules.Types.WriteSample(stale,0,2,2,100,nil,Vector3.one,Vector3.one)
 Shard.Apply(state,{},stale)
 assert(Shard.Sample(state,2,100).snapshotAt==nil,"retired sample reached replacement")
end)
test("deleted Motors cannot receive a completed calculation",function()
 local state=Shard.New()
 local value=motor()
 local change={id=1,lifetime=1,groupId=1,motor=value,createdAt=0,cellKey=1,cellOrigin=Vector3.zero}
 local data=buffer.create(modules.Types.SampleBytes)
 modules.Types.WriteSample(data,0,1,1,0,nil,Vector3.new(20,0,0),Vector3.new(10,0,0))
 Shard.Apply(state,{change},data)
 Shard.Calculate(state,{{key=1,first=1,count=1}},1)
 value.Parent=nil
 assert(Shard.Commit(state)==0)
 assert(value.Transform==CFrame.identity)
 assert(Shard.Sample(state,1,1)==nil)
end)
test("coalesced sample retains accepted source interval and coherent observation",function()
 local state=Shard.New()
 local change={id=1,lifetime=4,groupId=1,motor=motor(),createdAt=0,cellKey=1,cellOrigin=Vector3.zero}
 local data=buffer.create(modules.Types.SampleBytes)
 modules.Types.WriteSample(data,0,1,4,10,0.25,Vector3.new(20,0,0),Vector3.new(10,0,0))
 Shard.Apply(state,{change},data)
 assert(buffer.readf32(state.data,68)==0.25,"interval was recomputed from delivery")
 Shard.Calculate(state,{{key=1,first=1,count=1}},10.5)
 Shard.Commit(state)
 local sample=Shard.Sample(state,1,4)
 assert(sample.renderedAt==10.5 and sample.snapshotAt==10)
 assert(sample.cframe==change.motor.Transform and sample.isRendered)
 assert(sample.sampledAt==100)
 assert(Shard.Sample(state,1,3)==nil)
 local age=Shard.GroupAge(state,1)
 assert(age.count==1 and age.oldestRenderedAt==10.5)
end)
test("successful settlement preserves render-time cadence and responds to camera LOD",function()
 local scheduler=Scheduler.New(1)
 Scheduler.Apply(scheduler,{id=1,lifetime=1,groupId=1,motor=motor(),createdAt=0,cellKey=1,cellOrigin=Vector3.new(-32,-32,32)},1,0)
 local view=CFrame.lookAt(Vector3.zero,Vector3.zAxis)
 local plan=Scheduler.Plan(scheduler,view,70,config,1)
 local cell=scheduler.cells[1]
 assert(plan.attempted==1 and cell.nextDue==0,"dispatch advanced completion deadline")
 -- Even if acknowledgement arrives later, the caller supplies the common render timestamp.
 Scheduler.Settle(plan,1)
 assert(math.abs(cell.nextDue-(1+1/60))<1e-9,"ack latency stretched cadence")
 local nextPlan=Scheduler.Plan(scheduler,view,70,config,1.02)
 assert(nextPlan.attempted==1,"next render interval was skipped")
 Scheduler.Settle(nextPlan,1.02)
 local away=CFrame.lookAt(Vector3.zero,-Vector3.zAxis)
 local offscreen=Scheduler.Plan(scheduler,away,70,config,1.04)
 assert(offscreen.attempted==1)
 Scheduler.Settle(offscreen,1.04)
 assert(cell.nextDue==6.04,"offscreen cadence was not retained")
 assert(Scheduler.Plan(scheduler,view,70,config,1.05).attempted==1,"camera return failed to make a nearer band due")
end)
print("PASS renderer shard/scheduler cases",count)

