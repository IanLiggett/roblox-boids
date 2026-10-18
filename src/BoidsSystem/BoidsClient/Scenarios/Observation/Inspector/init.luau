--!strict

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local SharedTypes = require(ReplicatedStorage:WaitForChild("BoidsReplicated").SharedTypes)
local ObservationTypes = require(ReplicatedStorage.BoidsReplicated.Scenarios.ObservationTypes)
local Types = require(script.Parent.Types)
local Inspection = require(script.Parent.Inspection)
local Camera = require(script.Parent.Camera)
local Overlays = require(script.Overlays)
local ObstaclePanel = require(script.ObstaclePanel)
local Obstacle = require(script.Parent.Obstacle)
local Inspector = {}
type Api = {
	GetObstacleState: () -> Obstacle.State,
	SetObstacleEnabled: (boolean) -> (),
	SetObstacleLayer: ("Probes" | "Candidates" | "Movement", boolean) -> (),
	FreezeObstacle: () -> boolean, ResumeObstacle: () -> (),
	GetSessionState: () -> ObservationTypes.SessionState,
	Subscribe: (Types.ChangeDomain, () -> ()) -> (() -> ()),
	GetInspectionState: () -> Inspection.Snapshot, GetInspectionGroups: () -> {Inspection.GroupRow},
	GetCameraState: () -> Camera.State, SelectGroup: (number?) -> boolean,
	GetPickFilter: () -> number?, SetPickFilter: (number?) -> (),
	SetGroupOverlayEnabled: (boolean) -> (),
	TrySelectBoid: (number) -> (boolean, string?),
	PickBoid: (Vector3, Vector3, number?) -> number?,
}
local FOREGROUND: Color3 = Color3.fromRGB(235, 240, 247)
local BUTTON: Color3 = Color3.fromRGB(52, 67, 86)

local function vector(value: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", value.X, value.Y, value.Z)
end

local function ageText(seconds: number, lowerBound: boolean?): string
	return string.format("%s%.2fs%s", if lowerBound then ">=" else "", seconds, if seconds > 1 then " (stale)" else "")
end

local function simulationText(title: string, state: SharedTypes.BoidObservation?, seconds: number?, lowerBound: boolean?, delay: number?): string
	if not state then return title .. "\nUnavailable / waiting for data" end
	return string.format("%s\nP %s\nV %s | speed %.1f\nGroup #%d | cell %s\nNode %s | tick %d\nSimulation age %s%s",
		title, vector(state.position), vector(state.velocity), state.velocity.Magnitude, state.groupId,
		tostring(state.cellId), if state.pathNodeIndex then tostring(state.pathNodeIndex) else "n/a",
		state.lastSimulationTick, ageText(seconds or 0, lowerBound),
		if delay then string.format(" | sample %.2fs old", delay) else "")
end

function Inspector.Start(observation: Api, panel: ScrollingFrame): () -> ()
	local player: Player = Players.LocalPlayer
	local gui: ScreenGui = panel:FindFirstAncestorOfClass("ScreenGui") :: ScreenGui
	local function label(name: string, y: number, height: number): TextLabel
		local text: TextLabel = Instance.new("TextLabel")
		text.Name = name
		text.Position = UDim2.fromOffset(10, y)
		text.Size = UDim2.new(1, -20, 0, height)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.Code
		text.TextSize = 12
		text.TextColor3 = FOREGROUND
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextYAlignment = Enum.TextYAlignment.Top
		text.TextWrapped = true
		text.Parent = panel
		return text
	end
	local function button(name: string, text: string, x: number, y: number, width: number, callback: () -> ()): TextButton
		local b: TextButton = Instance.new("TextButton")
		b.Name = name
		b.Text = text
		b.Size = UDim2.new(width / 400, -20 * width / 400, 0, 28)
		b.Position = UDim2.new((x - 10) / 400, 10 - 20 * (x - 10) / 400, 0, y)
		b.BackgroundColor3 = BUTTON
		b.BorderSizePixel = 0
		b.Font = Enum.Font.Code
		b.TextSize = 12
		b.TextColor3 = FOREGROUND
		b.Parent = panel
		b.Activated:Connect(function(_input: InputObject, _clickCount: number): ()
			callback()
		end)
		return b
	end
	label("Heading", 8, 20).Text = "LIVE INSPECTOR / click through geometry"
	local groups: ScrollingFrame = Instance.new("ScrollingFrame")
	groups.Name = "Groups"
	groups.Position = UDim2.fromOffset(10, 30)
	groups.Size = UDim2.new(1, -20, 0, 92)
	groups.BackgroundTransparency = 1
	groups.BorderSizePixel = 0
	groups.ScrollBarThickness = 5
	groups.CanvasSize = UDim2.new()
	groups.AutomaticCanvasSize = Enum.AutomaticSize.Y
	groups.Parent = panel
	local layout: UIListLayout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.Parent = groups
	local rows: {[number]: TextButton} = {}
	local message: TextLabel = label("Status", 518, 40)
	local messageUntil = 0
	local filter: TextButton = button("Filter", "", 10, 128, 400, function(): ()
		local groupId = observation.GetCameraState().selectedGroupId
		if observation.GetPickFilter() ~= nil then observation.SetPickFilter(nil)
		elseif groupId ~= nil then observation.SetPickFilter(groupId)
		else message.Text = "Choose a group first" end
	end)
	local field: TextBox = Instance.new("TextBox")
	field.Name = "BoidId"
	field.Position = UDim2.fromOffset(10, 162)
	field.Size = UDim2.new(0.65, -13, 0, 28)
	field.BackgroundColor3 = BUTTON
	field.BorderSizePixel = 0
	field.Font = Enum.Font.Code
	field.TextSize = 12
	field.TextColor3 = FOREGROUND
	field.PlaceholderText = "Boid ID 0-65535"
	field.Text = ""
	field.ClearTextOnFocus = false
	field.Parent = panel
	button("Select", "Select ID", 276, 162, 134, function(): ()
		local id = tonumber(field.Text)
		if id then
			local accepted, reason = observation.TrySelectBoid(id)
			message.Text = reason or (if accepted then "Selected #" .. id else "Selection rejected")
		else message.Text = "Enter an integer ID: 0-65535" end
		messageUntil = workspace:GetServerTimeNow() + 3
	end)
	local showSelection, showGroup = true, false
	local markerButton: TextButton
	markerButton = button("SelectionOverlay", "Marker/velocity: ON", 10, 196, 197, function(): ()
		showSelection = not showSelection
		markerButton.Text = "Marker/velocity: " .. (if showSelection then "ON" else "OFF")
	end)
	local groupButton: TextButton
	groupButton = button("GroupOverlay", "Group overlays: OFF", 213, 196, 197, function(): ()
		showGroup = not showGroup
		observation.SetGroupOverlayEnabled(showGroup)
		groupButton.Text = "Group overlays: " .. (if showGroup then "ON" else "OFF")
	end)
	local renderedText: TextLabel = label("Rendered", 230, 76)
	local clientText: TextLabel = label("ClientSimulation", 308, 98)
	local serverText: TextLabel = label("ServerSimulation", 410, 106)
	local obstaclePanel: ObstaclePanel.Controller = ObstaclePanel.Create(panel, observation)
	local displayedId: number? = nil
	local isRunning = true
	local isActive = false
	local selectionContext: InputContext? = nil

	local function refreshGroups(): ()
		if not panel.Visible then return end
		local retained: {[number]: boolean} = {}
		local selectedGroup = observation.GetCameraState().selectedGroupId
		for index, group in observation.GetInspectionGroups() do
			local id = group.groupId
			retained[id] = true
			local row: TextButton = rows[id] or Instance.new("TextButton")
			if not rows[id] then
				row.Name = "Group_" .. id
				row.Size = UDim2.new(1, -6, 0, 42)
				row.BorderSizePixel = 0
				row.Font = Enum.Font.Code
				row.TextSize = 12
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.TextColor3 = group.color
				row.Parent = groups
				row.Activated:Connect(function(): () observation.SelectGroup(id) end)
				rows[id] = row
			end
			row.TextColor3 = group.color
			row.LayoutOrder = index
			row.Text = string.format(" #%d %s [%s]\n %s rendered | %s client sim", id, group.name, group.ownership,
				if group.renderedCount then tostring(group.renderedCount) else "unavailable",
				if group.clientCount then tostring(group.clientCount) else "unavailable")
			row.BackgroundColor3 = if selectedGroup == id then Color3.fromRGB(65, 85, 110) else BUTTON
		end
		for id, row in rows do
			if not retained[id] then
				row:Destroy()
				rows[id] = nil
			end
		end
	end

	local function refresh(): ()
		local snapshot: Inspection.Snapshot = observation.GetInspectionState()
		local now = snapshot.refreshedAt
		local id = snapshot.selectedBoidId
		local rendered: typeof(snapshot.rendered) = snapshot.rendered
		local sample: ObservationTypes.ServerSample? = snapshot.server
		local client: SharedTypes.BoidObservation? = if snapshot.client then snapshot.client.state else nil
		local obstacle: Obstacle.State = snapshot.obstacle
		-- World overlays stay active independently of dock visibility.
		local overlayMessage = Overlays.Update(rendered, snapshot.groupColor, snapshot.group, showSelection, showGroup, obstacle.decision, obstacle)
		if not panel.Visible then return end
		obstaclePanel.Refresh(obstacle, now)
		local header = if id then " #" .. id else " | no selection"
		if rendered and rendered.isRendered then
			renderedText.Text = string.format("Rendered motion%s\nP %s\nV %s | speed %.1f\nGroup #%d | visual age %s\nSnapshot age %s",
				header, vector(rendered.cframe.Position), vector(rendered.velocity), rendered.velocity.Magnitude,
				rendered.groupId, ageText(math.max(0, now - (rendered.renderedAt :: number))),
				if rendered.snapshotAt then ageText(math.max(0, now - rendered.snapshotAt)) else "unavailable")
		else renderedText.Text = "Rendered motion" .. header .. "\nUnavailable / awaiting first rendered pose" end
		clientText.Text = simulationText("Client simulation" .. header, client, if snapshot.client then snapshot.client.simulationAge else nil, if snapshot.client then snapshot.client.isAgeLowerBound else nil, nil)
		if id and id >= 32768 then
			serverText.Text = "Sampled server simulation" .. header .. "\nUnavailable: client-only boid"
		elseif sample and sample.isAvailable and sample.state then
			local delay = math.max(0, now - sample.sampledAt)
			serverText.Text = simulationText("Sampled server simulation" .. header, sample.state, (sample.simulationAge or 0) + delay, sample.isAgeLowerBound, delay)
		else serverText.Text = "Sampled server simulation" .. header .. "\nUnavailable / waiting for matching server sample" end
		if id ~= displayedId and not field:IsFocused() then
			field.Text = if id then tostring(id) else ""
			displayedId = id
		end
		if now >= messageUntil then message.Text = overlayMessage end
		local pickFilter = observation.GetPickFilter()
		filter.Text = if pickFilter ~= nil then "Click/ID filter: group #" .. pickFilter .. " | clear"
			else "Click/ID filter: all groups | use selected group"
	end

	local function sync(): ()
		local state: ObservationTypes.SessionState = observation.GetSessionState()
		local active = state.isActive and state.isAllowed
		if active == isActive then return end
		isActive = active
		if active then
			Overlays.Start()
			local context: InputContext = Instance.new("InputContext")
			context.Name = "BoidsObservationSelectionInput"
			context.Priority = 6000
			context.Sink = true
			local action: InputAction = Instance.new("InputAction")
			action.Name = "Pick"
			action.Type = Enum.InputActionType.Bool
			local binding: InputBinding = Instance.new("InputBinding")
			binding.KeyCode = Enum.KeyCode.MouseLeftButton
			binding.Parent = action
			action.Parent = context
			action.Pressed:Connect(function(): ()
				if not isRunning or not isActive or GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then return end
				local mouse: Vector2 = UserInputService:GetMouseLocation()
				local inset: Vector2 = GuiService:GetGuiInset()
				if mouse.Y < inset.Y then return end
				-- GUI hit testing uses inset-local coordinates; projection below keeps raw viewport coordinates.
				local guiPosition: Vector2 = mouse - inset
				for _, object in player.PlayerGui:GetGuiObjectsAtPosition(guiPosition.X, guiPosition.Y) do
					if object:IsDescendantOf(gui) then return end
				end
				local camera: Camera? = workspace.CurrentCamera
				if not camera then return end
				-- GetMouseLocation includes the top-bar inset; use viewport coordinates.
				local ray: Ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
				local tolerance = 12 * math.tan(math.rad(camera.FieldOfView * 0.5)) / math.max(camera.ViewportSize.Y, 1)
				observation.PickBoid(ray.Origin, ray.Direction * 100000, tolerance)
			end)
			context.Parent = player
			selectionContext = context
		else
			if selectionContext then
				selectionContext:Destroy()
				selectionContext = nil
			end
			Overlays.Stop()
		end
	end
	local unsubscribes: {() -> ()} = {
		observation.Subscribe("Session", sync),
		observation.Subscribe("Inspection", refresh),
		observation.Subscribe("Groups", refreshGroups),
		observation.Subscribe("Capture", refresh),
	}
	local visibilityConnection: RBXScriptConnection = panel:GetPropertyChangedSignal("Visible"):Connect(function(): ()
		if not isRunning then return end
		refreshGroups()
		refresh()
	end)
	sync()
	return function(): ()
		isRunning = false
		visibilityConnection:Disconnect()
		for _, unsubscribe in unsubscribes do unsubscribe() end
		if selectionContext then selectionContext:Destroy() end
		Overlays.Stop()
		obstaclePanel.Destroy()
		panel:ClearAllChildren()
	end
end

return Inspector
