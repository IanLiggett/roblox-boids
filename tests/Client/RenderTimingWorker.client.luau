--!strict
local actor = script.Parent :: Actor
local motor = (actor:WaitForChild("Motor") :: ObjectValue).Value :: Motor6D
local reply = actor:WaitForChild("Reply") :: BindableEvent
actor:BindToMessageParallel("Frame", function(epoch: number): ()
	debug.profilebegin("RenderTimingProbe.Calculate")
	local pose = CFrame.new(epoch, 0, 0)
	debug.profileend()
	task.synchronize()
	debug.profilebegin("RenderTimingProbe.Assign")
	motor.Transform = pose
	debug.profileend()
	reply:Fire(epoch)
end)
reply:Fire(0)
