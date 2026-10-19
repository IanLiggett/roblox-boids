--!strict
-- Invoke from a normal client LocalScript after scenario startup, outside timing captures.
local Players = game:GetService("Players")
local client = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient")
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsClient)
local Observation = require(client.Scenarios.Observation)
local Renderer = require(client.BoidsRenderer)

local function await(check: () -> boolean, message: string): ()
	local deadline = os.clock() + 5
	while not check() and os.clock() < deadline do
		task.wait()
	end
	assert(check(), message)
end

return function(): {boidId: number, groupId: number, boidStatus: string, groupStatus: string}
	assert(not Observation.GetSessionState().isActive, "Close observation before verification")
	local ok, result = pcall(function()
		Observation.Open()
		await(function(): boolean return Observation.GetSessionState().isActive end, "Observer did not open")
		local pose = assert(Renderer.GetRenderedBoidPose(0), "Missing test boid")
		assert(pose.isRendered, "Test boid has not rendered")
		assert(Observation.TrySelectBoid(pose.boidId))
		assert(Observation.SetCameraMode("Boid"))
		await(function(): boolean
			local sample = Observation.GetInspectionState().rendered
			return sample ~= nil and sample.boidId == pose.boidId and sample.renderedAt ~= nil
		end, "Inspector did not receive selected shard sample")
		task.wait(0.6)
		local boidState = Observation.GetCameraState()
		assert(boidState.mode == "Boid" and boidState.isActive, "Boid follow lost selection")
		assert(boidState.status:find("Rendered boid", 1, true), "Boid follow did not acquire a rendered camera target")
		assert(Renderer.GetRenderedGroupBounds(pose.groupId), "Missing submitted group bounds")
		assert(Observation.SelectGroup(pose.groupId))
		assert(Observation.SetCameraMode("Group"))
		task.wait(1.1)
		local groupState = Observation.GetCameraState()
		assert(groupState.mode == "Group" and groupState.selectedGroupId == pose.groupId, "Group follow lost selection")
		assert(groupState.status:find("Rendered group", 1, true), "Group follow did not acquire rendered bounds")
		Observation.SelectBoid(nil)
		await(function(): boolean return Observation.GetInspectionState().rendered == nil end, "Obsolete selected sample survived deselection")
		assert(Observation.SetCameraMode("Free"))
		return {boidId = pose.boidId, groupId = pose.groupId, boidStatus = boidState.status, groupStatus = groupState.status}
	end)
	Observation.Close()
	await(function(): boolean return not Observation.GetSessionState().isActive end, "Observer did not close")
	assert(ok, tostring(result))
	return result :: {boidId: number, groupId: number, boidStatus: string, groupStatus: string}
end
