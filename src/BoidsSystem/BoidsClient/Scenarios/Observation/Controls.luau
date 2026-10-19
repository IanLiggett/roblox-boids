--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local ObservationTypes = require(BoidsReplicated.Scenarios.ObservationTypes)
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
local Camera = require(script.Parent.Camera)
local Types = require(script.Parent.Types)
local Controls = {}

type ControlsApi = {
	GetSessionState: () -> ObservationTypes.SessionState,
	GetStreamingStatus: () -> Types.StreamingStatus,
	GetCameraState: () -> Camera.State,
	SetCameraMode: (Camera.Mode) -> boolean,
	SetCameraSpeed: (number) -> (),
	ZoomCamera: (number) -> (),
	SelectBoid: (number?) -> (),
	TrySelectBoid: (number) -> (boolean, string?),
	SelectGroup: (number?) -> boolean,
	GetGroupBindings: () -> {ScenarioTypes.GroupBinding},
	GetGroupBinding: (number) -> ScenarioTypes.GroupBinding?,
	Subscribe: (Types.ChangeDomain, () -> ()) -> (() -> ()),
	Open: () -> (),
	Close: () -> (),
	SetCameraEnabled: (cameraEnabled: boolean) -> (),
	CreateFixedObserver: (position: Vector3?) -> (),
	DeleteFixedObserver: (observerId: number) -> (),
}

local BACKGROUND: Color3 = Color3.fromRGB(24, 29, 37)
local FOREGROUND: Color3 = Color3.fromRGB(235, 240, 247)
local BUTTON: Color3 = Color3.fromRGB(52, 67, 86)

local function label(parent: Instance, text: string, y: number, height: number): TextLabel
	local item: TextLabel = Instance.new("TextLabel")
	item.BackgroundTransparency = 1
	item.Position = UDim2.fromOffset(12, y)
	item.Size = UDim2.new(1, -24, 0, height)
	item.Font = Enum.Font.Code
	item.TextSize = 13
	item.TextColor3 = FOREGROUND
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextYAlignment = Enum.TextYAlignment.Center
	item.TextWrapped = true
	item.Text = text
	item.Parent = parent
	return item
end

local function button(parent: Instance, name: string, text: string, y: number, callback: () -> ()): TextButton
	local item: TextButton = Instance.new("TextButton")
	item.Name = name
	item.Position = UDim2.fromOffset(12, y)
	item.Size = UDim2.new(1, -24, 0, 32)
	item.BackgroundColor3 = BUTTON
	item.BorderSizePixel = 0
	item.Font = Enum.Font.Code
	item.TextSize = 14
	item.TextColor3 = FOREGROUND
	item.Text = text
	-- Session controls remain reachable while the package owns the viewing camera.
	item.Modal = true
	item.Activated:Connect(function(_input: InputObject, _clickCount: number): ()
		callback()
	end)
	item.Parent = parent
	return item
end

local function streamingText(status: Types.StreamingStatus): string
	if status.state == "Inactive" then return "Streaming: inactive" end
	if status.state == "Disabled" then return "Streaming: disabled in this place" end
	if status.state == "Loading" then
		return string.format("Streaming: loading %d / %d regions%s", status.loading, status.total,
			if status.incomplete > 0 then string.format(" | %d incomplete", status.incomplete) else "")
	end
	if status.state == "Incomplete" then
		return string.format("Streaming: %d requests failed/timed out; geometry may be incomplete", status.incomplete)
	end
	return string.format("Streaming: %d regions requested (best effort)", status.total)
end

function Controls.Start(observation: ControlsApi, sessionHost: ScrollingFrame, cameraHost: ScrollingFrame): () -> ()
	local panel: Frame = Instance.new("Frame")
	panel.Name = "SessionContent"
	panel.Size = UDim2.new(1, 0, 0, 530)
	panel.BackgroundTransparency = 1
	panel.Parent = sessionHost
	local cameraPanel: Frame = Instance.new("Frame")
	cameraPanel.Name = "CameraControls"
	cameraPanel.Size = UDim2.new(1, 0, 0, 530)
	cameraPanel.BackgroundTransparency = 1
	cameraPanel.Parent = cameraHost
	label(cameraPanel, "OBSERVER / CAMERA", 8, 24)
	local modeLabel: TextLabel = label(cameraPanel, "", 34, 24)
	label(cameraPanel, "WASD: fly | Q/E: down/up | Shift: 4x\nRMB: look/orbit | wheel: orbit zoom\n[ / ]: halve/double flight speed", 62, 58)
	local speedLabel: TextLabel = label(cameraPanel, "", 122, 24)
	local slower: TextButton = button(cameraPanel, "Slower", "Speed / 2", 152, function(): ()
		observation.SetCameraSpeed(observation.GetCameraState().speed * 0.5)
	end)
	slower.Size = UDim2.new(0.5, -18, 0, 32)
	local faster: TextButton = button(cameraPanel, "Faster", "Speed x 2", 152, function(): ()
		observation.SetCameraSpeed(observation.GetCameraState().speed * 2)
	end)
	faster.Position = UDim2.new(0.5, 6, 0, 152)
	faster.Size = UDim2.new(0.5, -18, 0, 32)
	local free: TextButton = button(cameraPanel, "Free", "Free flight", 190, function(): () observation.SetCameraMode("Free") end)
	free.Size = UDim2.new(0.5, -18, 0, 32)
	local overview: TextButton = button(cameraPanel, "Overview", "Scenario overview", 190, function(): () observation.SetCameraMode("Overview") end)
	overview.Position = UDim2.new(0.5, 6, 0, 190)
	overview.Size = UDim2.new(0.5, -18, 0, 32)

	local boidField: TextBox = Instance.new("TextBox")
	boidField.Name = "BoidId"
	boidField.Position = UDim2.fromOffset(12, 234)
	boidField.Size = UDim2.new(0.5, -18, 0, 32)
	boidField.BackgroundColor3 = BUTTON
	boidField.BorderSizePixel = 0
	boidField.Font = Enum.Font.Code
	boidField.TextSize = 14
	boidField.TextColor3 = FOREGROUND
	boidField.PlaceholderText = "Boid ID (0-65535)"
	boidField.Text = ""
	boidField.ClearTextOnFocus = false
	boidField.Parent = cameraPanel
	local localMessage: TextLabel = label(cameraPanel, "", 270, 24)
	local followBoid: TextButton = button(cameraPanel, "FollowBoid", "Follow boid", 234, function(): ()
		local id = tonumber(boidField.Text)
		if not id or id ~= id or id % 1 ~= 0 or id < 0 or id > 65535 then
			localMessage.Text = "Enter an integer boid ID: 0-65535"
			return
		end
		localMessage.Text = ""
		local accepted, message = observation.TrySelectBoid(id)
		localMessage.Text = message or ""
		if accepted then observation.SetCameraMode("Boid") end
	end)
	followBoid.Position = UDim2.new(0.5, 6, 0, 234)
	followBoid.Size = UDim2.new(0.5, -18, 0, 32)
	local groupLabel: TextLabel = label(cameraPanel, "", 300, 40)
	local function cycleGroup(offset: number): ()
		local bindings: {ScenarioTypes.GroupBinding} = observation.GetGroupBindings()
		if #bindings == 0 then return end
		local selected = observation.GetCameraState().selectedGroupId
		local index = if offset > 0 then 0 else 1
		for i, binding in bindings do
			if binding.groupId == selected then
				index = i
				break
			end
		end
		local nextIndex = (index - 1 + offset) % #bindings + 1
		observation.SelectGroup(bindings[nextIndex].groupId)
	end
	local previous: TextButton = button(cameraPanel, "PreviousGroup", "<", 344, function(): () cycleGroup(-1) end)
	previous.Size = UDim2.fromOffset(42, 32)
	local nextGroup: TextButton = button(cameraPanel, "NextGroup", ">", 344, function(): () cycleGroup(1) end)
	nextGroup.Position = UDim2.fromOffset(60, 344)
	nextGroup.Size = UDim2.fromOffset(42, 32)
	local followGroup: TextButton = button(cameraPanel, "FollowGroup", "Follow selected group", 344, function(): ()
		observation.SetCameraMode("Group")
	end)
	followGroup.Position = UDim2.fromOffset(108, 344)
	followGroup.Size = UDim2.new(1, -120, 0, 32)
	local zoomIn: TextButton = button(cameraPanel, "ZoomIn", "Zoom in", 384, function(): () observation.ZoomCamera(1) end)
	zoomIn.Size = UDim2.new(0.5, -18, 0, 32)
	local zoomOut: TextButton = button(cameraPanel, "ZoomOut", "Zoom out", 384, function(): () observation.ZoomCamera(-1) end)
	zoomOut.Position = UDim2.new(0.5, 6, 0, 384)
	zoomOut.Size = UDim2.new(0.5, -18, 0, 32)
	local targetStatus: TextLabel = label(cameraPanel, "", 424, 62)
	label(cameraPanel, "Camera follows rendered motion.\nF6: exit / restore gameplay", 488, 34)
	local previousBoidId: number? = nil
	local function renderCamera(): ()
		if not cameraHost.Visible then return end
		local state: Camera.State = observation.GetCameraState()
		modeLabel.Text = "Mode: " .. state.mode
		speedLabel.Text = string.format("Flight: %g studs/s | zoom: %.2fx", state.speed, state.zoomScale)
		targetStatus.Text = state.status
		if state.selectedBoidId ~= previousBoidId then
			if not boidField:IsFocused() then
				boidField.Text = if state.selectedBoidId then tostring(state.selectedBoidId) else ""
				previousBoidId = state.selectedBoidId
			end
		end
		local binding: ScenarioTypes.GroupBinding? = if state.selectedGroupId
			then observation.GetGroupBinding(state.selectedGroupId) else nil
		groupLabel.Text = if binding then string.format("Group #%d | %s (%s)", binding.groupId, binding.definition.name, binding.ownership)
			else "Group: none selected"
	end

	-- Stable widgets: notifications change values/visibility, never rebuild the page.
	label(panel, "BOIDS / LOD OBSERVERS", 8, 24)
	label(panel, "Session active | F6: exit\nGameplay input suspended.", 34, 40)
	local cameraObserver: TextButton = button(panel, "Camera", "", 80, function(): ()
		observation.SetCameraEnabled(not observation.GetSessionState().cameraEnabled)
	end)
	local create: TextButton = button(panel, "CreateFixed", "Create fixed observer here", 118, function(): ()
		observation.CreateFixedObserver(nil)
	end)
	local fixedCount: TextLabel = label(panel, "", 156, 24)
	type FixedRow = { label: TextLabel, remove: TextButton, observerId: number? }
	local fixedRows: {FixedRow} = {}
	for index = 1, 4 do
		local y = 186 + (index - 1) * 42
		local item: TextLabel = label(panel, "", y, 34)
		item.Name = "Fixed_" .. index
		item.Size = UDim2.new(1, -98, 0, 34)
		local slot = index
		local remove: TextButton = button(panel, "DeleteSlot_" .. index, "Delete", y, function(): ()
			local id = fixedRows[slot].observerId
			if id then observation.DeleteFixedObserver(id) end
		end)
		remove.Position = UDim2.new(1, -82, 0, y)
		remove.Size = UDim2.fromOffset(70, 32)
		fixedRows[index] = { label = item, remove = remove }
	end
	local explanation: TextLabel = label(panel, "", 358, 62)
	local streaming: TextLabel = label(panel, "", 420, 44)
	streaming.Name = "StreamingStatus"
	local message: TextLabel = label(panel, "", 464, 24)
	button(panel, "Exit", "Exit / restore camera observer", 492, observation.Close)

	local function renderSession(): ()
		if not sessionHost.Visible then return end
		local state: ObservationTypes.SessionState = observation.GetSessionState()
		panel.Visible = state.isActive
		cameraObserver.Text = "Camera observer: " .. (if state.cameraEnabled then "ON" else "OFF")
		local canCreate = #state.fixedObservers < 4
		create.Interactable = canCreate
		create.AutoButtonColor = canCreate
		create.BackgroundColor3 = if canCreate then BUTTON else BACKGROUND
		fixedCount.Text = string.format("Fixed observers: %d / 4 (all active)", #state.fixedObservers)
		for index, row in fixedRows do
			local observer: ObservationTypes.FixedObserver? = state.fixedObservers[index]
			row.observerId = if observer then observer.id else nil
			row.label.Visible, row.remove.Visible = observer ~= nil, observer ~= nil
			if observer then
				local position: Vector3 = observer.position
				row.label.Text = string.format("#%d  (%.1f, %.1f, %.1f)", observer.id, position.X, position.Y, position.Z)
			end
		end
		local text = if not state.cameraEnabled and #state.fixedObservers == 0
			then "No observers: background simulation; no new regular corrections."
			else "Enabled observers control simulation and correction LOD, not rendering."
		explanation.Text = text .. "\nOther players can still affect shared server scheduling."
		message.Text = state.message or ""
	end
	local function renderStreaming(): ()
		if not sessionHost.Visible then return end
		streaming.Text = streamingText(observation.GetStreamingStatus())
	end
	local visibilityConnections: {RBXScriptConnection} = {
		cameraHost:GetPropertyChangedSignal("Visible"):Connect(renderCamera),
		sessionHost:GetPropertyChangedSignal("Visible"):Connect(function(): ()
			renderSession()
			renderStreaming()
		end),
	}
	local unsubscribes: {() -> ()} = {
		observation.Subscribe("Session", renderSession),
		observation.Subscribe("Streaming", renderStreaming),
		observation.Subscribe("Camera", renderCamera),
	}
	renderSession()
	renderStreaming()
	renderCamera()
	return function(): ()
		for _, unsubscribe in unsubscribes do unsubscribe() end
		for _, connection in visibilityConnections do connection:Disconnect() end
		panel:Destroy()
		cameraPanel:Destroy()
	end
end

return Controls
