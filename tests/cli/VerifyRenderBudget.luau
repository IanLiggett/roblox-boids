--!strict
-- Production renderer/index against deterministic engine-write and proxy costs.
-- This checks scheduling/pose invariants, not engine physics or device capacity.
local fs=require("@lune/fs")
local luau=require("@lune/luau")
local roblox=require("@lune/roblox")
local root=if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base=root.."src/BoidsSystem/"
local V,C=roblox.Vector3,roblox.CFrame
local function load(path: string,env: any): any
	local source=fs.readFile(base..path)
    if require("@lune/process").args[1]=="--position-only" and path=="BoidsClient/BoidsRenderer/init.luau" then
        source=source:gsub("previousRenderPosition %+ latestVelocity %* dt %- predictedPosition","previousRenderPosition - predictedPosition")
    end
    return luau.load(source,{debugName=path,environment=env,injectGlobals=true})()
end
local function fixture(mobile: boolean?): any
	local clock,world,writes,proxyCalls=0,10,0,0
	local preparationSeconds=0
	local writtenIds: {number}={}
	local methods: any={}
	local function object(class: string): any
		local properties: any={Name=class,ClassName=class,CFrame=C.identity,Transform=C.identity,Color=roblox.Color3.new(),LocalTransparencyModifier=0}
		local children: {any}={}
		local attributes: {[string]: any}={}
		local result: any
		result=setmetatable({}, {
			__index=function(_self: any,key: any): any
				if methods[key] then return methods[key] end
				if key=="_children" then return children elseif key=="_attributes" then return attributes elseif key=="_properties" then return properties end
				if properties[key]~=nil then return properties[key] end
				for _,child in children do if child.Name==key then return child end end
				return nil
			end,
			__newindex=function(_self: any,key: any,value: any): ()
				if key=="Transform" and class=="Motor6D" then
					clock+=0.00003;writes+=1
					if properties.Part1 then table.insert(writtenIds,properties.Part1:GetAttribute("BoidId")) end
				end
				if key=="Parent" then
					if properties.Parent then local slot=table.find(properties.Parent._children,result);if slot then table.remove(properties.Parent._children,slot) end end
					if value then table.insert(value._children,result) end
				end
				properties[key]=value
			end,
		})
		return result
	end
	function methods:GetChildren(): any return table.clone(self._children) end
	function methods:FindFirstChild(name: string): any for _,child in self._children do if child.Name==name then return child end end;return nil end
	function methods:WaitForChild(name: string): any return assert(self:FindFirstChild(name),name) end
	function methods:SetAttribute(name: string,value: any): () self._attributes[name]=value end
	function methods:GetAttribute(name: string): any return self._attributes[name] end
	function methods:IsA(class: string): boolean return self.ClassName==class or (class=="BasePart" and self.ClassName=="Part") end
	function methods:Clone(): any local copy=object(self.ClassName);for k,v in self._properties do if k~="Parent" then copy[k]=v end end;return copy end
	function methods:Destroy(): () self.Parent=nil;for _,child in self:GetChildren() do child:Destroy() end;self._properties.destroyed=true end
	local workspace: any=object("Workspace")
	workspace.CurrentCamera={CFrame=C.lookAt(V.new(16,16,96),V.new(16,16,16)),FieldOfView=70,ViewportSize=roblox.Vector2.new(1280,720)}
	function workspace:GetServerTimeNow(): number return world end
	local callbacks: {(number) -> ()}={}
	local run: any={RenderStepped={Connect=function(_self: any,fn: (number) -> ()): () table.insert(callbacks,fn) end}}
	local configuration: any={client={visibleRenderBands={{range=math.huge,hertz=60}},offscreenHertz=.2,maxRenderBoidsPerFrame=100000,maxRenderMsPerFrame=4,maxMobileRenderMsPerFrame=3,peripheralLodDistanceScale=.5}}
	local lod: any={GetActive=function(): any return configuration end,GetNetworkConfig=function(): any return {farDistance=512} end,GetSimulationKindForGroup=function(): string return "clientPrediction" end}
	local environment: any={Vector3=V,CFrame=C,Color3=roblox.Color3,workspace=workspace,require=function(v: any): any return v end,os={clock=function(): number return clock end},debug={profilebegin=function(): () end,profileend=function(): () end}}
	local function child(path: string,extra: any?): any local e: any=table.clone(environment);for k,v in extra or {} do e[k]=v end;return load(path,e) end
	local geometry: any=child("BoidsReplicated/CollisionGeometry.luau")
	local collision: any=child("BoidsReplicated/CollisionIndex.luau",{script={Parent={CollisionGeometry=geometry}}})
	local replica: any=child("BoidsReplicated/ReplicaIdentity.luau")
	local measurements: any=child("BoidsClient/BoidsRenderer/Measurements.luau")
	local visibility: any=child("BoidsClient/BoidsRenderer/Visibility.luau")
	local rowsByBuffer: {[buffer]: {any}}={}
	local codec: any={BOID_ROW_BYTES=14,ForEachBoid=function(bytes: buffer): any
		local rows=assert(rowsByBuffer[bytes]);local i=0
		return function(): any i+=1;local row: any=rows[i];if row then return table.unpack(row) end;return nil end
	end}
	local shared: any={SharedTypes={BoidModels={Boid=1},BoidModelNames={[1]="Boid"}},Quantization={CELL_SIZE=64,GetNumericalKey=function(x: number,y: number,z: number): number return x+y*10000+z*100000000 end},NetworkResults={PacketCodec=codec},LODConfig=lod,CollisionIndex=collision,ReplicaIdentity=replica,QueryIndexConfig={IsEnabledForClient=function(): boolean return true end},BoidCollisionConfig={GetRadius=function(): number clock+=0.00002;proxyCalls+=1;return 2 end}}
	local models: any=object("Folder");local template: any=object("Part");template.Name="Boid";template.Parent=models
	local rendererScript: any={Parent={BoidModels=models},Measurements=measurements,Visibility=visibility}
	local services: any={ReplicatedStorage={WaitForChild=function(): any return shared end},RunService=run,UserInputService={TouchEnabled=mobile==true,KeyboardEnabled=mobile~=true}}
	local renderer: any=child("BoidsClient/BoidsRenderer/init.luau",{script=rendererScript,Instance={new=object},game={GetService=function(_self: any,name: string): any return assert(services[name],name) end}})
	renderer.Start(function(): () clock+=preparationSeconds end)
	local f: any={renderer=renderer,replica=replica,measurements=measurements,config=configuration,workspace=workspace}
	function f.setPreparationCost(seconds: number): () preparationSeconds=seconds end
	function f.advanceWorld(seconds: number): () world+=seconds end
	function f.spawn(group: number,ids: {number},token: number): ()
		local packed,models=buffer.create(#ids*2),buffer.create(#ids)
		local lifetimes: {[number]: number}={}
		for row,id in ids do buffer.writeu16(packed,(row-1)*2,id);buffer.writeu8(models,row-1,1);lifetimes[id]=token;replica.Set(id,token*1000+id) end
		renderer.ReceiveNewBoidBatch({groupId=group,boidCount=#ids,boidIds=packed,boidModels=models,lifetimes=lifetimes,renderColor=roblox.Color3.new(1,0,0)})
	end
	function f.publish(ids: {number},position: any,velocity: any?,sourceTime: number?): ()
		local bytes=buffer.create(#ids*14)
		local rows: {any}={}
		for _,id in ids do local p=if type(position)=="function" then position(id) else position;local v=velocity or V.zero;table.insert(rows,{id,p.X,p.Y,p.Z,v.X,v.Y,v.Z}) end
		rowsByBuffer[bytes]=rows;renderer.ConsumeCellSnapshot(V.zero,bytes,#ids,sourceTime or world)
	end
	function f.step(): (number,number,number,{number})
		world+=1/60;clock=0;writes=0;proxyCalls=0;writtenIds={}
		for _,fn in callbacks do fn(1/60) end
		return clock,writes,proxyCalls,writtenIds
	end
	function f.check(id: number): ()
		local state: any=assert(renderer.GetRenderedBoidState(id))
		if not state.isRendered then return end
		local part: any=nil
		local motor: any=nil
		for _,group in workspace.BoidFolder:GetChildren() do if group.ClassName~="Folder" then continue end;for _,p in group:GetChildren() do if p:GetAttribute("BoidId")==id then part=p end end end
		for _,m in workspace.BoidFolder.BoidRoot:GetChildren() do if m.Part1==part then motor=m end end
		assert(part and not part.CanQuery and motor and motor.Transform==state.cframe,"Displayed pose and Motor differ")
		local ignored: {[number]: boolean}={}
		for other=1,256 do if other~=id then ignored[other]=true end end
		local _,hits=renderer.QueryAttack({shape={kind="Sphere",origin=state.cframe.Position,radius=.01},ignored=ignored},{cellsLeft=256,testsLeft=4096,deadline=clock+1})
		assert(#hits==1 and hits[1].boidId==id and hits[1].proxyPosition==state.cframe.Position and hits[1].replicaSerial==replica.Get(id),"Displayed proxy/identity differs")
	end
	return f
end
local passed=0
local function test(name: string,fn: () -> ()): () fn();passed+=1;print("PASS",name) end
test("deadline includes proxy and Motor cost while measurements are disabled",function()
	local f: any=fixture()
	local ids: {number}={};for id=1,256 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16)
	local elapsed,writes,proxies=f.step()
	assert(writes>0 and writes<=96 and writes==proxies and elapsed<=.004+32*.00005+.000001,"Work escaped its combined elapsed allowance")
	assert(not f.measurements.IsEnabled())
	for _=1,12 do f.step() end
	for _,id in ids do assert(f.renderer.GetRenderedBoidState(id).isRendered) end
	f.check(1);f.check(256)
end)
test("mobile budget selection and reported overshoot use the same clock",function()
	local f: any=fixture(true);local ids: {number}={};for id=1,256 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16);f.measurements.SetEnabled(true)
	local elapsed,writes=f.step();local m: any=f.measurements.Read()
	assert(writes>0 and writes<=64 and m.renderBudgetMs==3 and m.timeLimitedFrames==1)
	assert(math.abs(m.rendererMsTotal-elapsed*1000)<.00001)
	assert(math.abs(m.budgetOvershootMsMax-math.max(0,elapsed*1000-3))<.00001)
end)
test("partial passes repair dense swaps and replacement identities",function()
	local f: any=fixture();local ids: {number}={};for id=1,256 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16);f.step()
	local packet=buffer.create(4);buffer.writeu16(packet,0,1);buffer.writeu16(packet,2,1)
	f.renderer.ReceiveDeleteBoidBatch(packet,{[1]=1});f.replica.Remove(1)
	f.spawn(0,{1},2);f.publish({1},V.new(20,16,16),V.xAxis*8)
	for _=1,15 do f.step();f.check(1);f.check(256) end
	f.renderer.ReceiveDeleteGroup(0)
	assert(f.renderer.GetQueryMetrics().entryCount==0 and not f.renderer.HasRenderedGroup(0))
end)
test("elapsed preparation exhaustion still permits bounded pose progress",function()
	local f: any=fixture();f.setPreparationCost(.004)
	local ids: {number}={};for id=1,96 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16)
	for _=1,8 do local _,writes=f.step();assert(writes>0 and writes<=32) end
	for _,id in ids do assert(f.renderer.GetRenderedBoidState(id).isRendered) end
end)
test("aging advances a farther cell despite a perpetually incomplete near cell",function()
	local f: any=fixture();f.config.client.maxRenderBoidsPerFrame=1
	local ids: {number}={};for id=1,96 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,function(id: number): any return if id==96 then V.new(16,16,-112) else V.one*16 end)
	for _=1,120 do f.step() end
	local far: any=assert(f.renderer.GetRenderedBoidState(96))
	assert(far.isRendered and far.renderedAt>11,"Aged cell starved")
	f.check(96)
end)
test("aging reserves elapsed time rather than draining all old cells before near work",function()
	local f: any=fixture();f.config.client.maxRenderBoidsPerFrame=1
	local farIds: {number}={};for id=257,296 do table.insert(farIds,id) end
	f.spawn(0,farIds,1)
	f.publish(farIds,function(id: number): any
		local row=id-257
		return V.new(-48+(row%5)*32,16+(math.floor(row/5)%2)*32,-96-math.floor(row/10)*32)
	end)
	f.step();f.advanceWorld(1)
	local nearIds: {number}={};for id=1,256 do nearIds[id]=id end
	f.spawn(0,nearIds,1);f.publish(nearIds,V.one*16)
	f.config.client.maxRenderBoidsPerFrame=100000
	local _,_,_,order=f.step()
	local agedRows=0
	for _,id in order do if id<=256 then break end;agedRows+=1 end
	assert(agedRows>0 and agedRows<=9,"Aging exceeded its 10% elapsed reserve")
	assert(#order>agedRows,"Aging consumed the near-first opportunity")
end)
test("moving members cannot rewind a dense partial pass",function()
	local f: any=fixture();f.config.client.maxRenderBoidsPerFrame=1
	local ids: {number}={};for id=1,96 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16)
	for frame=1,240 do
		f.step()
		-- A processed prefix member repeatedly crosses out and back. The tail
		-- must advance even when each accepted snapshot changes dense slots.
		for _,id in {1,96} do
			f.publish({id},V.new(48,16,16));f.advanceWorld(.0001)
			f.publish({id},V.one*16);f.advanceWorld(.0001)
		end
	end
	for _,id in ids do
		local state: any = f.renderer.GetRenderedBoidState(id)
		assert(state.isRendered and state.renderedAt>11,`Moving prefix starved {id}`)
	end
end)
test("removing an entire unvisited suffix preserves the completed boundary",function()
	local f: any=fixture();f.config.client.maxRenderBoidsPerFrame=2
	local ids: {number}={};for id=1,16 do ids[id]=id end
	f.spawn(0,ids,1);f.publish(ids,V.one*16);f.step()
	local packet=buffer.create(2+14*2);buffer.writeu16(packet,0,14)
	local lifetimes: {[number]: number}={}
	for id=3,16 do buffer.writeu16(packet,(id-2)*2,id);lifetimes[id]=1 end
	f.renderer.ReceiveDeleteBoidBatch(packet,lifetimes)
	f.publish({1},V.new(48,16,16));f.advanceWorld(.0001)
	f.publish({1},V.one*16)
	for _=1,8 do f.step() end
	f.check(1);f.check(2)
end)
test("an onscreen displayed pose cannot freeze when its latest cell moves offscreen",function()
	local f: any=fixture();f.spawn(0,{1},1);f.publish({1},V.one*16);f.step()
	local before: any=f.renderer.GetRenderedBoidState(1)
	f.publish({1},V.new(16,16,176),V.zAxis*8)
	for _=1,60 do f.step() end
	local after: any=f.renderer.GetRenderedBoidState(1)
	assert(after.renderedAt>before.renderedAt+.5,"Visible cached pose was abandoned with its offscreen snapshot cell")
	f.check(1)
end)
test("constant velocity has no smoothing lag with sparse snapshots",function()
    local f: any=fixture(); local start=V.new(16,16,16);local velocity=V.new(0,0,-30)
    f.spawn(0,{1},1);f.publish({1},start,velocity);f.step();f.publish({1},start,velocity)
    for frame=1,300 do
        f.step()
        local state=f.renderer.GetRenderedBoidState(1)
        local expected=start+velocity*(frame/60)
        assert((state.cframe.Position-expected).Magnitude<.001,`Perfect motion accumulated positional lag at {frame}: {state.cframe.Position} vs {expected}, rendered {state.renderedAt}`)
        assert(state.visualError<.001 and state.predictedPositionAtRender~=nil)
        if frame%60==0 then f.publish({1},expected,velocity) end
    end
    f.check(1)
end)
test("uninterrupted dead reckoning stays aligned at a reduced render cadence",function()
    local f: any=fixture();f.config.client.visibleRenderBands={{range=math.huge,hertz=10}}
    local start=V.new(16,16,16);local velocity=V.new(0,0,-30)
    f.spawn(0,{1},1);f.publish({1},start,velocity);f.step();f.publish({1},start,velocity)
    for _=1,300 do
        f.step();local state=f.renderer.GetRenderedBoidState(1)
        if state.predictedPositionAtRender then
            assert(state.visualError<.001,"Sparse render visits introduced trajectory lag")
        end
    end
    local state=f.renderer.GetRenderedBoidState(1)
    assert(state.snapshotAgeAtRender>4,"Test did not exercise old snapshots")
    f.check(1)
end)
test("corrections and reversals stay facing-first and converge without a snap",function()
    local f: any=fixture();f.spawn(0,{1},1);f.publish({1},V.new(16,16,16),V.new(0,0,-10))
    for _=1,60 do f.step() end
    local before=f.renderer.GetRenderedBoidState(1).cframe.Position
    f.publish({1},before+V.xAxis*5,V.new(0,0,10))
    local previous=before
    for _=1,300 do
        f.step();local state=f.renderer.GetRenderedBoidState(1)
        local delta=state.cframe.Position-previous
        assert(delta.Magnitude<1,"Correction snapped")
        assert(delta:Dot(state.cframe.LookVector)>=-.0001,"Correction moved backward")
        assert(delta:Cross(state.cframe.LookVector).Magnitude<.0001,"Correction slid sideways")
        previous=state.cframe.Position
    end
    assert(f.renderer.GetRenderedBoidState(1).visualError<.5,"Correction failed to converge")
    f.check(1)
end)
test("diagnostic clocks separate snapshot age, display age and prediction residual",function()
    local f: any=fixture();f.spawn(0,{1},1);f.publish({1},V.one*16,V.new(0,0,-10));f.step()
    local before=f.renderer.GetRenderedBoidState(1)
    f.advanceWorld(.3)
    local after=f.renderer.GetRenderedBoidState(1)
    assert(after.renderedAt==before.renderedAt and after.sampledAt>before.sampledAt)
    assert(after.snapshotAt==before.snapshotAt and after.visualError==before.visualError)
    f.publish({1},V.one*16,V.zero,before.snapshotAt+.001)
    assert(f.renderer.GetRenderedBoidState(1).snapshotReceivedAt>before.renderedAt)
    assert(f.renderer.GetRenderedBoidState(1).predictedPositionAtRender==nil,"Future snapshot compared with older display")
end)
print(`SUMMARY {passed} renderer budget cases passed`)
