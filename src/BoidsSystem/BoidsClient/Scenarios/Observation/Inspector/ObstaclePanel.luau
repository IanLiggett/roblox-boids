--!strict

local Obstacle = require(script.Parent.Parent.Obstacle)
local SharedTypes = require(game:GetService("ReplicatedStorage").BoidsReplicated.SharedTypes)
local Panel = {}

type Api = {
	GetObstacleState: () -> Obstacle.State,
	SetObstacleEnabled: (boolean) -> (),
	SetObstacleLayer: ("Probes" | "Candidates" | "Movement", boolean) -> (),
	FreezeObstacle: () -> boolean, ResumeObstacle: () -> (),
}
export type Controller = { Refresh: (Obstacle.State, number) -> (), Destroy: () -> () }

local REASONS: {[string]: string} = {
	ForwardClear = "Forward ray clear; normal steering",
	DetourStarted = "Escape selected; detour owns movement",
	DetourChanged = "Imminent hit; replacement escape selected",
	DetourDistantHit = "Heading hit is distant; keep detour",
	DetourHeadingClear = "Heading clear; target still blocked",
	RetainedHeadingFallback = "No eligible replacement; retain heading",
	SoftFallback = "No safe escape; soft avoidance",
	ReleasedTargetClear = "Target ray clear; release detour",
	ReleasedBeyondHorizon = "Target hit beyond local horizon; release",
	ReleasedNoTargetRay = "No target ray (zero length); release",
	NotEvaluatedZeroDelta = "No obstacle checks: zero delta",
	NotEvaluatedZeroSpeed = "No obstacle checks: zero speed",
	NotEvaluatedMissingStats = "No update: boid stats unavailable",
}
local function vector(value: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
end

local function describe(value: SharedTypes.ObstacleObservation, state: Obstacle.State, now: number): string
	local age = math.max(0, now - value.capturedAt)
	local rows: {string} = {
		string.format("Client simulation decision #%d / group #%d", value.boidId, value.groupId),
		string.format("%s | decision age %.2fs%s", if state.isFrozen then "FROZEN" else "LIVE", age, if age > 1 then " (stale)" else ""),
		string.format("Tick %d | job %d | generation %d", value.simulationTick, value.jobOrder, value.generation),
		REASONS[value.reason] or value.reason,
		"P " .. vector(value.position),
		string.format("Speed %.2f | delta %.3fs | %d actual rays", value.speed, value.dt, #value.probes),
		string.format("Horizon %.2f | travel + margin %.2f", value.lookAhead, value.requiredClearance),
		string.format("Continuation dot > %.3f", value.continuationThreshold),
		"Probe endpoints remain at captured positions.",
	}
	for _, role in {"Forward", "Target", "Heading"} do
		local found: SharedTypes.ObstacleProbe? = nil
		for _, probe in value.probes do if probe.role == role then found = probe break end end
		table.insert(rows, if found then string.format("%s: %s | tested %.2f%s", role,
			if found.didHit then "HIT" else "clear", found.vector.Magnitude,
			if found.hitDistance then string.format(" | hit %.2f", found.hitDistance) else "")
			else role .. ": not evaluated")
	end
	if #value.candidates == 0 then
		table.insert(rows, "Escape candidates: not evaluated")
	elseif not state.showCandidates then
		table.insert(rows, "Escape candidate details hidden")
	else
		for _, candidate in value.candidates do
			local reason = if candidate.isSelected then "SELECTED" elseif candidate.isEligible then "eligible; lower rank/tie"
				elseif not candidate.isClear and not candidate.canContinue then "reject clearance + continuation"
				elseif not candidate.isClear then "reject clearance" else "reject continuation"
			table.insert(rows, string.format("#%d %s", candidate.index, reason))
			table.insert(rows, string.format("  clearance %.2f / required %.2f", candidate.clearance, candidate.requiredClearance))
			table.insert(rows, string.format("  dot %s | score %s",
				if candidate.alignment then string.format("%.3f", candidate.alignment) else "n/a",
				if candidate.score then string.format("%.2f", candidate.score) else "not evaluated"))
		end
	end
	if state.showMovement then
		table.insert(rows, "Target dir " .. vector(value.targetDirection))
		table.insert(rows, "Detour before " .. vector(value.committedBefore))
		table.insert(rows, "Detour after  " .. vector(value.committedAfter))
		table.insert(rows, "Result dir " .. vector(value.resultDirection))
		table.insert(rows, "Displacement " .. vector(value.displacement))
		table.insert(rows, "Soft accel " .. vector(value.softAcceleration))
	end
	table.insert(rows, "Client geometry only; server decisions not captured.")
	return table.concat(rows, "\n")
end

function Panel.Create(parent: GuiObject, api: Api): Controller
	local outer = Instance.new("Frame")
	outer.Name = "ObstacleDecisions"
	outer.Position = UDim2.fromOffset(10, 562)
	outer.Size = UDim2.new(1, -20, 0, 66)
	outer.BackgroundTransparency = 1
	outer.Parent = parent
	local expanded = false
	local function button(name: string, text: string, target: Instance, position: UDim2, size: UDim2, callback: () -> ()): TextButton
		local value = Instance.new("TextButton")
		value.Name, value.Text = name, text
		value.Position, value.Size = position, size
		value.BackgroundColor3 = Color3.fromRGB(52, 67, 86)
		value.BorderSizePixel = 0
		value.TextColor3 = Color3.fromRGB(235, 240, 247)
		value.Font, value.TextSize = Enum.Font.Code, 12
		value.Parent = target
		value.Activated:Connect(callback)
		return value
	end
	local body = Instance.new("Frame")
	body.Name = "Details"
	body.Position = UDim2.fromOffset(0, 66)
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.BackgroundTransparency = 1
	body.Visible = false
	body.Parent = outer
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = body
	local function resize(): ()
		outer.Size = UDim2.new(1, -20, 0, 72 + (if expanded then body.AbsoluteSize.Y else 0))
	end
	local enable = button("ObstacleToggle", "Obstacle decisions: OFF", outer, UDim2.new(), UDim2.new(0.5, -3, 0, 28), function(): ()
		local state = api.GetObstacleState()
		api.SetObstacleEnabled(not state.isEnabled)
		expanded = not state.isEnabled
		body.Visible = expanded
		resize()
	end)
	local collapse = button("Collapse", "Details: show", outer, UDim2.new(0.5, 3, 0, 0), UDim2.new(0.5, -3, 0, 28), function(): ()
		expanded = not expanded
		body.Visible = expanded
		resize()
	end)
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Position = UDim2.fromOffset(0, 32)
	status.Size = UDim2.new(1, 0, 0, 30)
	status.BackgroundTransparency = 1
	status.Font, status.TextSize = Enum.Font.Code, 12
	status.TextColor3 = Color3.fromRGB(235, 240, 247)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextWrapped = true
	status.Parent = outer
	local layers = Instance.new("Frame")
	layers.Name = "Layers"
	layers.Size = UDim2.new(1, 0, 0, 28)
	layers.BackgroundTransparency = 1
	layers.LayoutOrder = 1
	layers.Parent = body
	local probes = button("Probes", "Probes: ON", layers, UDim2.new(), UDim2.new(1/3, -4, 1, 0), function(): ()
		api.SetObstacleLayer("Probes", not api.GetObstacleState().showProbes)
	end)
	local candidates = button("Candidates", "Candidates: ON", layers, UDim2.new(1/3, 2, 0, 0), UDim2.new(1/3, -4, 1, 0), function(): ()
		api.SetObstacleLayer("Candidates", not api.GetObstacleState().showCandidates)
	end)
	local movement = button("Movement", "Movement: ON", layers, UDim2.new(2/3, 4, 0, 0), UDim2.new(1/3, -4, 1, 0), function(): ()
		api.SetObstacleLayer("Movement", not api.GetObstacleState().showMovement)
	end)
	local freeze = button("Freeze", "Freeze latest", body, UDim2.new(), UDim2.new(1, 0, 0, 28), function(): ()
		if api.GetObstacleState().isFrozen then api.ResumeObstacle() else api.FreezeObstacle() end
	end)
	freeze.LayoutOrder = 2
	local readout = Instance.new("TextLabel")
	readout.Name = "Decision"
	readout.Size = UDim2.new(1, 0, 0, 0)
	readout.AutomaticSize = Enum.AutomaticSize.Y
	readout.LayoutOrder = 3
	readout.BackgroundTransparency = 1
	readout.Font, readout.TextSize = Enum.Font.Code, 12
	readout.TextColor3 = Color3.fromRGB(235, 240, 247)
	readout.TextXAlignment = Enum.TextXAlignment.Left
	readout.TextYAlignment = Enum.TextYAlignment.Top
	readout.TextWrapped = true
	readout.Parent = body
	local sizeChanged = body:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
	return {
		Refresh = function(state: Obstacle.State, now: number): ()
			enable.Text = "Obstacle decisions: " .. (if state.isEnabled then "ON" else "OFF")
			collapse.Text = "Details: " .. (if expanded then "hide" else "show")
			status.Text = state.status
			probes.Text = "Probes: " .. (if state.showProbes then "ON" else "OFF")
			candidates.Text = "Candidates: " .. (if state.showCandidates then "ON" else "OFF")
			movement.Text = "Movement: " .. (if state.showMovement then "ON" else "OFF")
			freeze.Text = if state.isFrozen then "Resume live capture" else "Freeze latest"
			freeze.Active = state.isEnabled and state.decision ~= nil
			freeze.AutoButtonColor = freeze.Active
			freeze.TextTransparency = if freeze.Active then 0 else 0.5
			readout.Text = if state.decision then describe(state.decision, state, now) else state.status .. "\nNo probes assumed clear.\nCapture does not change LOD scheduling."
			resize()
		end,
		Destroy = function(): ()
			sizeChanged:Disconnect()
			outer:Destroy()
		end,
	}
end

return Panel
