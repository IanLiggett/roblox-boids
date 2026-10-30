--!strict
-- Run from a normal LocalScript after startup, with observation closed and the
-- host camera suspended by the caller. This uses the existing renderer only.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local PacketCodec = require(BoidsReplicated.NetworkResults.PacketCodec)
local LODConfig = require(BoidsReplicated.LODConfig)
local Quantization = require(BoidsReplicated.Quantization)

return function(): {hiddenMotion: number, hiddenWrites: number, mixedOwnership: boolean, reusedId: boolean}
	assert(RunService:IsClient(), "Run in the normal client runtime")
	local client = Players.LocalPlayer.PlayerScripts:WaitForChild("BoidsClient") :: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
	local renderer = require(client.BoidsRenderer)
	local camera = workspace.CurrentCamera :: Camera
	local originalView, originalFov = camera.CFrame, camera.FieldOfView
	local originalGetActive = LODConfig.GetActive
	local remoteGroup, localGroup = 30000, 60000
	local ids = {65000, 65001, 65002}
	for _, id in ids do assert(not renderer.GetRenderedBoidState(id), "Verification ID already in use") end
	assert(not renderer.HasRenderedGroup(remoteGroup) and not renderer.HasRenderedGroup(localGroup), "Verification groups already in use")
	local sourceTime = workspace:GetServerTimeNow()
	local lifetime = math.floor(sourceTime * 1000)
	local origin: Vector3 = Vector3.new(3008, 0, 0)
	local point: Vector3 = origin + Vector3.one * 16
	local networkCenter: Vector3 = origin + Vector3.one * (Quantization.CELL_SIZE * 0.5)
	local desired: CFrame = CFrame.lookAt(networkCenter + Vector3.zAxis * 80, point)
	RunService:BindToRenderStep("RenderVisibilityVerification", Enum.RenderPriority.Camera.Value + 10, function(): ()
		camera.FieldOfView = 70
		camera.CFrame = desired
	end)

	local function spawn(groupId: number, id: number, token: number): ()
		local boidIds = buffer.create(2)
		buffer.writeu16(boidIds, 0, id)
		local models = buffer.create(1)
		buffer.writeu8(models, 0, 1)
		renderer.ReceiveNewBoidBatch({groupId = groupId, boidCount = 1, boidIds = boidIds, boidModels = models, lifetimes = {[id] = token}, renderColor = Color3.new(1, 0, 0)})
	end
	local function publish(id: number, position: Vector3, velocity: Vector3?): ()
		local x, y, z = Quantization.ConvertCoordsToGrid(position.X, position.Y, position.Z)
		local cell = PacketCodec.NewCellSnapshot(1, Vector3.new(x, y, z))
		PacketCodec.AppendBoid(cell, id, position - cell.origin, velocity or Vector3.zero)
		sourceTime = math.max(sourceTime + 0.001, workspace:GetServerTimeNow())
		renderer.ConsumeCellSnapshot(cell.origin, cell.networkBoids, 1, sourceTime)
	end
	local function part(groupId: number, id: number): BasePart
		local root = workspace:WaitForChild("BoidFolder") :: Folder
		local folder = root:FindFirstChild("Boids-" .. groupId) :: Folder
		for _, child in folder:GetChildren() do
			if child:GetAttribute("BoidId") == id then return child :: BasePart end
		end
		error("Missing verification part")
	end
	local function waitFor(check: () -> boolean): ()
		local deadline = os.clock() + 5
		repeat
			if check() then return end
			task.wait()
		until os.clock() >= deadline
		assert(check(), "Visibility verification timed out")
	end
	local result: {hiddenMotion: number, hiddenWrites: number, mixedOwnership: boolean, reusedId: boolean}? = nil
	local ok, failure = pcall(function(): ()
		spawn(remoteGroup, ids[1], lifetime)
		spawn(remoteGroup, ids[2], lifetime)
		spawn(localGroup, ids[3], lifetime)
		for _, id in ids do publish(id, point) end
		waitFor(function(): boolean return part(remoteGroup, ids[1]).LocalTransparencyModifier == 0 and part(localGroup, ids[3]).LocalTransparencyModifier == 0 end)
		desired = CFrame.lookAt(networkCenter + Vector3.zAxis * (originalGetActive().network.farDistance * 0.9), point)
		task.wait(0.2)
		assert(part(remoteGroup, ids[1]).LocalTransparencyModifier == 0, "In-range replica changed opacity")
		assert(part(localGroup, ids[3]).LocalTransparencyModifier == 0, "Local-only boid inherited network visibility")

		renderer.SetMeasurementsEnabled(true)
		waitFor(function(): boolean
			local m = renderer.GetMeasurements()
			return m.samples > 0 and m.activeCells >= 2 and m.hiddenCells >= m.activeCells - 2
		end)
		renderer.SetMeasurementsEnabled(false)
		local limited = table.clone(originalGetActive())
		limited.client = table.clone(limited.client)
		limited.client.maxRenderBoidsPerFrame = 1
		LODConfig.GetActive = function(): LODConfig.Config return limited end
		desired = CFrame.lookAt(networkCenter + Vector3.zAxis * (limited.network.farDistance + 100), point)
		task.wait()
		local deletion = buffer.create(4)
		buffer.writeu16(deletion, 0, 1)
		buffer.writeu16(deletion, 2, ids[1])
		renderer.ReceiveDeleteBoidBatch(deletion, {[ids[1]] = lifetime})
		waitFor(function(): boolean return part(remoteGroup, ids[2]).LocalTransparencyModifier == 1 end)
		assert(part(localGroup, ids[3]).LocalTransparencyModifier == 0)
		LODConfig.GetActive = originalGetActive
		local hiddenAt = (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt
		publish(ids[2], point)
		task.wait(0.3)
		assert((renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt == hiddenAt, "Hidden intake advanced a pose")
		assert(renderer.PickRenderedBoid(camera.CFrame.Position, point - camera.CFrame.Position, remoteGroup) == nil)
		for _, hit in renderer.GetBoidsInRadius(point, 20) do assert(hit.boidId ~= ids[2], "Hidden row remained indexed") end

		desired = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + Vector3.zAxis)
		-- Start counting on the first renderer frame after the camera driver turns.
		RunService.RenderStepped:Wait()
		renderer.ResetMeasurements()
		renderer.SetMeasurementsEnabled(true)
		task.wait(0.3)
		local measured = renderer.GetMeasurements()
		renderer.SetMeasurementsEnabled(false)
		assert(measured.scheduledBoids == 0 and measured.motionUpdatesTotal == 0 and measured.transparencyWritesTotal == 0, "Camera culling traversed boids")
		assert(part(localGroup, ids[3]).LocalTransparencyModifier == 0, "Camera rotation changed opacity")

		spawn(remoteGroup, ids[1], lifetime + 1)
		publish(ids[1], point + Vector3.xAxis * 64)
		publish(ids[2], point + Vector3.xAxis * 64)
		desired = CFrame.lookAt(networkCenter + Vector3.zAxis * 180, point)
		waitFor(function(): boolean return part(remoteGroup, ids[1]).LocalTransparencyModifier == 0 and part(remoteGroup, ids[2]).LocalTransparencyModifier == 0 end)
		assert(renderer.GetRenderedBoidState(ids[1]), "ID reuse failed")
		publish(ids[1], point + Vector3.xAxis * 96)
		local untilTime = os.clock() + 0.3
		repeat
			task.wait()
			assert(part(remoteGroup, ids[1]).LocalTransparencyModifier == 0, "Visible cell migration hid a replica")
		until os.clock() >= untilTime
		-- Frequent simulation snapshots must not wake an entire destination cell
		-- when an already-visible row crosses into it between scheduled passes.
		local slow = table.clone(originalGetActive())
		slow.client = table.clone(slow.client)
		slow.client.visibleRenderBands = {{range = math.huge, hertz = 0.1}}
		local previousAnchor = (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt
		LODConfig.GetActive = function(): LODConfig.Config return slow end
		waitFor(function(): boolean return (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt ~= previousAnchor end)
		local anchorAt = (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt
		publish(ids[1], point + Vector3.xAxis * 64)
		task.wait(0.2)
		assert((renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt == anchorAt, "Migration bypassed the destination cell's render cadence")
		LODConfig.GetActive = originalGetActive
		-- Repeated rotation must preserve visible replicas' opacity.
		for _ = 1, 3 do
			local inView = desired
			desired = CFrame.lookAt(inView.Position, inView.Position + Vector3.zAxis)
			RunService.RenderStepped:Wait()
			renderer.ResetMeasurements()
			renderer.SetMeasurementsEnabled(true)
			task.wait(0.1)
			local rotation = renderer.GetMeasurements()
			renderer.SetMeasurementsEnabled(false)
			assert(rotation.scheduledBoids == 0 and rotation.motionUpdatesTotal == 0 and rotation.transparencyWritesTotal == 0, "Rotation caused membership churn")
			assert(part(remoteGroup, ids[1]).LocalTransparencyModifier == 0, "Rotation hid a replica")
			desired = inView
			task.wait(0.1)
			assert(part(remoteGroup, ids[1]).LocalTransparencyModifier == 0, "View reentry hid a replica")
		end
		-- Nonzero velocity and a long quiet interval expose wall-clock catch-up:
		-- zero-velocity snapshots alone cannot detect hidden extrapolation.
		for _, reason in {"distance", "camera"} do
			local visibleView = desired
			local seed = (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).cframe.Position
			publish(ids[2], seed, Vector3.xAxis * 128)
			task.wait(0.1)
			if reason == "distance" then
				desired = CFrame.lookAt(networkCenter + Vector3.zAxis * (originalGetActive().network.farDistance + 100), point)
				waitFor(function(): boolean return part(remoteGroup, ids[2]).LocalTransparencyModifier == 1 end)
			else
				desired = CFrame.lookAt(visibleView.Position, visibleView.Position + Vector3.zAxis)
				RunService.RenderStepped:Wait()
			end
			local frozen = renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState
			task.wait(2)
			local hidden = renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState
			assert(hidden.cframe == frozen.cframe and hidden.renderedAt == frozen.renderedAt, "Hidden moving pose advanced")
			desired = visibleView
			waitFor(function(): boolean return (renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState).renderedAt ~= frozen.renderedAt end)
			local resumed = renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState
			assert((resumed.cframe.Position - frozen.cframe.Position).Magnitude < 6, "First resume integrated hidden time")
			task.wait(0.35)
			local active = renderer.GetRenderedBoidState(ids[2]) :: renderer.RenderedBoidState
			assert((active.cframe.Position - frozen.cframe.Position).Magnitude < 64, "Prediction extrapolated across hidden time")
		end
		result = {hiddenMotion = measured.motionUpdatesTotal, hiddenWrites = measured.transparencyWritesTotal, mixedOwnership = true, reusedId = true}
	end)
	LODConfig.GetActive = originalGetActive
	renderer.SetMeasurementsEnabled(false)
	renderer.ReceiveDeleteGroup(remoteGroup)
	renderer.ReceiveDeleteGroup(localGroup)
	RunService:UnbindFromRenderStep("RenderVisibilityVerification")
	camera.CFrame, camera.FieldOfView = originalView, originalFov
	assert(ok, tostring(failure))
	return result :: {hiddenMotion: number, hiddenWrites: number, mixedOwnership: boolean, reusedId: boolean}
end
