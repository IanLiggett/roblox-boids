--!strict
-- Uses the existing renderer from a normal LocalScript with host camera control suspended.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local shared = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local LODConfig = require(shared.LODConfig)
local PacketCodec = require(shared.NetworkResults.PacketCodec)
local ReplicaIdentity = require(shared.ReplicaIdentity)

return function(): {frames: number, maxRows: number, checkedQueries: number, agingProgress: boolean, reusedId: boolean}
	assert(RunService:IsClient(), "Run in the normal client runtime")
	local client = Players.LocalPlayer.PlayerScripts:WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
	local renderer = require(client.BoidsRenderer)
	local measurements = require(client.BoidsRenderer.Measurements)
	local camera = workspace.CurrentCamera :: Camera
	local originalView, originalGetActive, originalEnabled = camera.CFrame, LODConfig.GetActive, measurements.IsEnabled()
	local groupId, firstId, count = 30001, 64000, 96
	assert(not renderer.HasRenderedGroup(groupId), "Verification group already exists")
	for id=firstId,firstId+count-1 do assert(not renderer.GetRenderedBoidState(id) and not ReplicaIdentity.Get(id), "Verification ID already in use") end
	local origin = Vector3.new(4032,0,0)
	local point = origin+Vector3.one*16
	local view = CFrame.lookAt(point+Vector3.zAxis*80,point)
	local config = table.clone(originalGetActive())
	config.client = table.clone(config.client)
	config.client.visibleRenderBands = {{range=math.huge,hertz=60}}
	config.client.maxRenderMsPerFrame,config.client.maxMobileRenderMsPerFrame = 0.0001,0.0001
	local sourceTime = workspace:GetServerTimeNow()
	local lifetime = math.floor(sourceTime*1000)
	local frames,maxRows,checkedQueries = 0,0,0
	local parts: {[number]: BasePart} = {}
	local motors: {[number]: Motor6D} = {}
	local root = workspace:WaitForChild("BoidFolder") :: Folder
	local function position(row: number): Vector3
		return origin+Vector3.new(8+(row%4)*4,8+(math.floor(row/4)%4)*4,8+math.floor(row/16)*4)
	end
	local function publish(id: number,where: Vector3,velocity: Vector3?): ()
		local cellOrigin = Vector3.new(math.floor(where.X/64)*64,math.floor(where.Y/64)*64,math.floor(where.Z/64)*64)
		local cell = PacketCodec.NewCellSnapshot(1,cellOrigin)
		PacketCodec.AppendBoid(cell,id,where-cellOrigin,velocity or Vector3.zero)
		sourceTime = math.max(sourceTime+0.001,workspace:GetServerTimeNow())
		renderer.ConsumeCellSnapshot(cell.origin,cell.networkBoids,1,sourceTime)
	end
	local function findPartsAndMotors(): ()
		local folder = root:FindFirstChild("Boids-"..groupId) :: Folder
		for _,child in folder:GetChildren() do
			local part = child :: BasePart
			parts[part:GetAttribute("BoidId") :: number] = part
		end
		local anchor = root:FindFirstChild("BoidRoot") :: BasePart
		for _,child in anchor:GetChildren() do
			local motor = child :: Motor6D
			local part = motor.Part1
			local id = if part then part:GetAttribute("BoidId") :: number? else nil
			if id and id>=firstId and id<firstId+count then motors[id] = motor end
		end
	end
	local function stateFor(id: number): renderer.RenderedBoidState
		return assert(renderer.GetRenderedBoidState(id), "Verification row disappeared")
	end
	local function waitForRender(): ()
		local initial = renderer.GetMeasurements().samples
		local deadline = os.clock()+5
		repeat RunService.Heartbeat:Wait()
		until renderer.GetMeasurements().samples>initial or os.clock()>=deadline
		assert(renderer.GetMeasurements().samples>initial, "No render frames; keep the running game viewport visible")
	end
	local function checkAgreement(): ()
		for row=0,count-1 do
			local id = firstId+row
			local state = renderer.GetRenderedBoidState(id)
			if not state or not state.isRendered then continue end
			-- Engine joint storage may renormalize rotation by a few f32 ulps.
			local displayed = motors[id].Transform
			assert(not parts[id].CanQuery and (displayed.Position-state.cframe.Position).Magnitude<0.001
				and (displayed.LookVector-state.cframe.LookVector).Magnitude<0.00001
				and (displayed.UpVector-state.cframe.UpVector).Magnitude<0.00001, "Pose was deferred independently of its Motor")
			-- Spread queries over the fixtures while checking all Motor writes.
			if row%8~=frames%8 then continue end
			local result,hits = renderer.QueryAttack({shape={kind="Sphere",origin=state.cframe.Position,radius=0.01},maxHits=64},{cellsLeft=256,testsLeft=1024,deadline=os.clock()+0.05})
			assert(not result.isTruncated, "Verification query unexpectedly truncated")
			local found = false
			for _,hit in hits do
				if hit.boidId~=id then continue end
				assert(hit.replicaSerial==ReplicaIdentity.Get(id) and (assert(hit.proxyPosition)-state.cframe.Position).Magnitude<0.001, "Query proxy differs from the displayed pose")
				found=true
			end
			assert(found, "Displayed verification pose was missing from its collision index")
			checkedQueries+=1
		end
	end
	RunService:BindToRenderStep("RenderBudgetVerification",Enum.RenderPriority.Camera.Value+10,function(): () camera.CFrame=view end)
	local ok,failure = pcall(function(): ()
		LODConfig.GetActive = function(): LODConfig.Config return config end
		local ids,models = buffer.create(count*2),buffer.create(count)
		local lifetimes: {[number]: number} = {}
		for row=0,count-1 do
			local id = firstId+row
			buffer.writeu16(ids,row*2,id);buffer.writeu8(models,row,1)
			lifetimes[id]=lifetime;ReplicaIdentity.Set(id,2000000000+row)
		end
		renderer.ReceiveNewBoidBatch({groupId=groupId,boidCount=count,boidIds=ids,boidModels=models,lifetimes=lifetimes,renderColor=Color3.new(1,0,0)})
		for row=0,count-1 do publish(firstId+row,position(row)) end
		findPartsAndMotors()
		renderer.ResetMeasurements();renderer.SetMeasurementsEnabled(true)
		local deadline = os.clock()+5
		local allRendered = false
		repeat
			waitForRender();frames+=1
			local m = renderer.GetMeasurements()
			maxRows=math.max(maxRows,m.scheduledBoids)
			assert(m.scheduledBoids<=32, "Elapsed deadline allowed more than one initial chunk")
			checkAgreement()
			if frames==1 then
				local packet = buffer.create(4);buffer.writeu16(packet,0,1);buffer.writeu16(packet,2,firstId)
				renderer.ReceiveDeleteBoidBatch(packet,{[firstId]=lifetime})
				ReplicaIdentity.Remove(firstId,sourceTime)
				ReplicaIdentity.Set(firstId,2100000000)
				local replacementIds,replacementModels = buffer.create(2),buffer.create(1)
				buffer.writeu16(replacementIds,0,firstId);buffer.writeu8(replacementModels,0,1)
				renderer.ReceiveNewBoidBatch({groupId=groupId,boidCount=1,boidIds=replacementIds,boidModels=replacementModels,lifetimes={[firstId]=lifetime+1},renderColor=Color3.new(1,0,0)})
				publish(firstId,position(0));findPartsAndMotors()
			end
			allRendered = true
			for row=0,count-1 do if not stateFor(firstId+row).isRendered then allRendered=false;break end end
		until allRendered or os.clock()>=deadline
		assert(allRendered and frames>=3, "Dense partial pass failed to resume")
		-- One perpetually incomplete near cell must not starve a farther due cell.
		config.client.maxRenderBoidsPerFrame = 1
		config.client.maxRenderMsPerFrame,config.client.maxMobileRenderMsPerFrame = 4,4
		local farId = firstId+count-1
		publish(farId,point-Vector3.zAxis*128,Vector3.xAxis*8)
		local before = stateFor(farId).renderedAt :: number
		deadline = os.clock()+2
		repeat waitForRender();frames+=1;checkAgreement()
		until (stateFor(farId).renderedAt :: number)>before+0.5 or os.clock()>=deadline
		assert((stateFor(farId).renderedAt :: number)>before+0.5, "Aged cell made no progress under near-cell pressure")
		publish(farId,point,Vector3.xAxis*8)
		for _=1,4 do waitForRender();frames+=1;checkAgreement() end
		-- Cached onscreen presentation remains relevant when snapshot membership
		-- crosses behind the camera; it must not freeze in the old visible pose.
		local beforeOffscreen = stateFor(farId).renderedAt :: number
		publish(farId,point+Vector3.zAxis*192,Vector3.zAxis*8)
		deadline = os.clock()+3
		repeat waitForRender();frames+=1;checkAgreement()
		until (stateFor(farId).renderedAt :: number)>beforeOffscreen or os.clock()>=deadline
		assert((stateFor(farId).renderedAt :: number)>beforeOffscreen, "Onscreen pose froze after snapshot migration behind camera")
	end)
	LODConfig.GetActive = originalGetActive
	renderer.SetMeasurementsEnabled(originalEnabled)
	renderer.ReceiveDeleteGroup(groupId)
	for row=0,count-1 do ReplicaIdentity.Remove(firstId+row) end
	RunService:UnbindFromRenderStep("RenderBudgetVerification")
	camera.CFrame = originalView
	assert(ok,tostring(failure))
	return {frames=frames,maxRows=maxRows,checkedQueries=checkedQueries,agingProgress=true,reusedId=true}
end
