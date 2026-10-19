--!strict
-- Tagged dispatch/synchronize/Motor probe; run outside performance samples.
-- Inject RenderTimingWorker as a disabled LocalScript child named Worker before invoking.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

type Trace = {epoch: number, dispatchFrame: number, ackFrame: number?, ackPhase: string?, appliedFrame: number?}
return function(): {Trace}
	local actor = Instance.new("Actor")
	actor.Name = "RenderTimingProbe"
	local reply = Instance.new("BindableEvent")
	reply.Name = "Reply"
	reply.Parent = actor
	local root = Instance.new("Part")
	root.Anchored, root.CanCollide, root.Transparency = true, false, 1
	root.CFrame = CFrame.identity
	root.Parent = workspace
	local part = Instance.new("Part")
	part.CanCollide, part.Transparency = false, 1
	part.Parent = workspace
	local motor = Instance.new("Motor6D")
	motor.Name, motor.Part0, motor.Part1 = "Motor", root, part
	motor.Parent = root
	local motorReference = Instance.new("ObjectValue")
	motorReference.Name, motorReference.Value = "Motor", motor
	motorReference.Parent = actor
	local worker = script:WaitForChild("Worker"):Clone() :: LocalScript
	worker.Parent = actor
	local ready, busy = false, false
	local frame, epoch = 0, 0
	local phase = "Startup"
	local traces: {Trace} = {}
	local connections: {RBXScriptConnection} = {}
	connections[#connections + 1] = reply.Event:Connect(function(completed: number): ()
		if completed == 0 then
			ready = true
			return
		end
		local trace = traces[completed]
		trace.ackFrame, trace.ackPhase = frame, phase
		busy = false
	end)
	RunService:BindToRenderStep("RenderTimingProbe", -1000, function(): ()
		frame += 1
		phase = "PreRender"
	end)
	connections[#connections + 1] = RunService.PreAnimation:Connect(function(): () phase = "PreAnimation" end)
	connections[#connections + 1] = RunService.PreSimulation:Connect(function(): () phase = "PreSimulation" end)
	connections[#connections + 1] = RunService.PostSimulation:Connect(function(): ()
		phase = "PostSimulation"
		local applied = math.round(part.Position.X)
		local trace = traces[applied]
		if trace and not trace.appliedFrame then trace.appliedFrame = frame end
	end)
	connections[#connections + 1] = RunService.Heartbeat:Connect(function(): () phase = "Heartbeat" end)
	connections[#connections + 1] = RunService.RenderStepped:Connect(function(): ()
		if not ready or busy or epoch >= 20 then return end
		epoch += 1
		traces[epoch] = {epoch = epoch, dispatchFrame = frame}
		busy = true
		actor:SendMessage("Frame", epoch)
	end)
	actor.Parent = Players.LocalPlayer.PlayerScripts
	worker.Enabled = true
	local deadline = os.clock() + 10
	while (epoch < 20 or not traces[20].appliedFrame) and os.clock() < deadline do task.wait() end
	RunService:UnbindFromRenderStep("RenderTimingProbe")
	for _, connection in connections do connection:Disconnect() end
	actor:Destroy()
	part:Destroy()
	root:Destroy()
	assert(epoch == 20 and traces[20].appliedFrame, "Timing probe did not complete")
	return traces
end
