--!strict

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ScenarioTypes = require(ReplicatedStorage:WaitForChild("BoidsReplicated").Scenarios.Types)
local Renderer = require(script.Parent.Parent.Parent.BoidsRenderer)
local Handoff = require(script.Parent.Handoff)
local Camera = {}

export type Mode = "Free" | "Boid" | "Group" | "Overview"
export type State = {
	mode: Mode, speed: number, selectedBoidId: number?, selectedGroupId: number?,
	status: string, isActive: boolean, zoomScale: number,
}
type CameraApi = {
	GetBindings: () -> {ScenarioTypes.GroupBinding},
	GetSelectedBoid: () -> number?,
	ClearSelection: () -> (),
	Changed: () -> (),
}
type Bounds = { center: Vector3, radius: number, message: string }
type Actions = { [string]: InputAction }

local api: CameraApi? = nil
local mode: Mode = "Free"
local speed = 64
local selectedGroupId: number? = nil
local status = "Free flight"
local zoomScale = 1
local yaw, pitch = 0, 0
local orbitNeedsReset = false
local isActive = false
local hasWindowFocus = true
local inputContext: InputContext? = nil
local actions: Actions = {}
local connections: {RBXScriptConnection} = {}
local trackedBoidId: number? = nil
local hasSeenBoid = false
local hasSeenGroup = false
local groupBounds: Renderer.RenderedGroupBounds? = nil
local overviewBounds: Bounds? = nil
local smoothedCenter: Vector3? = nil
local smoothedRadius = 1
local nextBoundsRefresh = 0
local nextUiRefresh = 0
local BOUNDS_INTERVAL = 0.5
local MIN_SPEED, MAX_SPEED = 4, 4096
local MAX_PITCH = math.rad(85)

local function changed(): ()
	if api then
		api.Changed()
	end
end

local function setAngles(view: CFrame): ()
	local look: Vector3 = view.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	pitch = math.clamp(math.atan2(look.Y, math.sqrt(look.X * look.X + look.Z * look.Z)), -MAX_PITCH, MAX_PITCH)
end

local function rotation(): CFrame
	return CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
end

local function fittedDistance(radius: number): number
	local camera: Camera? = workspace.CurrentCamera
	local halfFov = math.rad(if camera then camera.FieldOfView * 0.5 else 35)
	local viewport: Vector2 = if camera then camera.ViewportSize else Vector2.new(1, 1)
	local aspect = viewport.X / math.max(viewport.Y, 1)
	local halfHorizontal = math.atan(math.tan(halfFov) * aspect)
	return math.max(3, radius * 1.15 / math.sin(math.max(0.01, math.min(halfFov, halfHorizontal))))
end

type PositionSource = Vector3 | BasePart | {Position: Vector3 | BasePart}
local function resolvePosition(value: PositionSource): Vector3?
	if typeof(value) == "Vector3" then
		return value
	end
	if typeof(value) == "Instance" then
		if value:IsA("BasePart") and value:IsDescendantOf(workspace) then
			return value.Position
		end
		return nil
	end
	if type(value) == "table" then
		return resolvePosition(value.Position)
	end
	return nil
end

local function scenarioBounds(): Bounds?
	local owner: CameraApi? = api
	if not owner then
		return nil
	end
	local minimum: Vector3 = Vector3.new(math.huge, math.huge, math.huge)
	local maximum: Vector3 = -minimum
	local count, missing = 0, 0
	local function include(position: Vector3, extent: number): ()
		local offset: Vector3 = Vector3.one * extent
		minimum = minimum:Min(position - offset)
		maximum = maximum:Max(position + offset)
		count += 1
	end
	for _, binding in owner.GetBindings() do
		local definition: ScenarioTypes.GroupDefinition = binding.definition
		include(definition.center, definition.spread)
		for _, node in definition.path or {} do
			local position: Vector3? = resolvePosition(node.Position)
			if position then
				include(position + node.offset, definition.pathArrivalRadius or 0)
			else
				missing += 1
			end
		end
		if definition.target then
			local position: Vector3? = resolvePosition(definition.target)
			if position then
				include(position, 0)
			else
				missing += 1
			end
		end
	end
	if count == 0 then
		return nil
	end
	return {
		center = (minimum + maximum) * 0.5,
		radius = math.max(1, (maximum - minimum).Magnitude * 0.5),
		message = if missing > 0 then string.format("Overview | %d streamed targets/path nodes unavailable", missing)
			else "Overview | paths, targets and initial group bounds",
	}
end

local function releaseLook(): ()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function freeAfterDeletion(message: string): ()
	mode = "Free"
	orbitNeedsReset = false
	smoothedCenter = nil
	status = message
	-- The next free-flight step retains the exact held view, including its position.
	releaseLook()
	changed()
end

local function refreshBounds(now: number): ()
	if now < nextBoundsRefresh then
		return
	end
	nextBoundsRefresh = now + BOUNDS_INTERVAL
	if mode == "Group" and selectedGroupId then
		local exists = Renderer.HasRenderedGroup(selectedGroupId)
		if not exists and hasSeenGroup then
			selectedGroupId = nil
			groupBounds = nil
			hasSeenGroup = false
			freeAfterDeletion("Selected group deleted | free flight")
			return
		end
		groupBounds = Renderer.GetRenderedGroupBounds(selectedGroupId)
		if groupBounds then
			hasSeenGroup = true
		end
	elseif mode == "Overview" then
		overviewBounds = scenarioBounds()
	end
end

local function step(deltaTime: number, view: CFrame): (CFrame, Vector3?)
	local owner: CameraApi? = api
	if not isActive or not owner then
		return view, nil
	end
	local dt = math.clamp(deltaTime, 0, 0.1)
	local now = workspace:GetServerTimeNow()
	local boidId = owner.GetSelectedBoid()
	if trackedBoidId ~= boidId then
		trackedBoidId = boidId
		hasSeenBoid = false
	end
	-- This is a single O(1) read, never a population traversal.
	local boid: Renderer.RenderedBoidState? = if boidId then Renderer.GetRenderedBoidState(boidId) else nil
	if boid then
		hasSeenBoid = true
	elseif boidId and hasSeenBoid then
		owner.ClearSelection()
		trackedBoidId = nil
		hasSeenBoid = false
		freeAfterDeletion("Selected boid deleted | free flight")
	end
	refreshBounds(now)
	local canUseInput = hasWindowFocus and not GuiService.MenuIsOpen and UserInputService:GetFocusedTextBox() == nil
	local isLooking = canUseInput and actions.LookHeld:GetState() == true
	if isLooking then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		UserInputService.MouseIconEnabled = false
	else
		releaseLook()
	end
	if orbitNeedsReset then
		setAngles(view)
		zoomScale = 1
		smoothedCenter = nil
		orbitNeedsReset = false
	end
	if isLooking then
		local look: Vector2 = actions.Look:GetState()
		yaw -= look.X * dt * 0.003
		pitch = math.clamp(pitch - look.Y * dt * 0.003, -MAX_PITCH, MAX_PITCH)
	end

	local nextView: CFrame = view
	local focusPosition: Vector3? = nil
	if mode == "Free" then
		if isLooking then
			nextView = CFrame.new(view.Position) * rotation()
		else
			setAngles(view)
		end
		if canUseInput then
			local move: Vector2 = actions.Move:GetState()
			local elevation = (if actions.Rise:GetState() then 1 else 0) - (if actions.Fall:GetState() then 1 else 0)
			local direction: Vector3 = nextView.LookVector * move.Y + nextView.RightVector * move.X + Vector3.yAxis * elevation
			if direction.Magnitude > 0 then
				local acceleration = if actions.Fast:GetState() then 4 else 1
				nextView += direction.Unit * speed * acceleration * dt
			end
		end
	elseif mode == "Boid" then
		if boid and boid.isRendered then
			focusPosition = boid.cframe.Position
			nextView = CFrame.new(focusPosition) * rotation() * CFrame.new(0, 0, 24 * zoomScale)
			local age = now - (boid.renderedAt :: number)
			status = if age > 1 then string.format("Rendered boid #%d | pose stale: %.1fs", boid.boidId, age)
				else string.format("Rendered boid #%d | group #%d", boid.boidId, boid.groupId)
		else
			status = "Selected boid unavailable | waiting for rendered pose"
		end
	else
		local bounds: Bounds? = nil
		if mode == "Group" and groupBounds then
			local group: Renderer.RenderedGroupBounds = groupBounds
			local radius = math.max((group.minimum - group.centroid).Magnitude, (group.maximum - group.centroid).Magnitude)
			local age = now - group.oldestRenderedAt
			bounds = {
				center = group.centroid, radius = radius,
				message = string.format("Rendered group #%d | %d boids%s", group.groupId, group.count,
					if age > 1 then string.format(" | oldest pose: %.1fs (stale)", age) else ""),
			}
		elseif mode == "Overview" then
			bounds = overviewBounds
		end
		if bounds then
			local alpha = 1 - math.exp(-6 * dt)
			smoothedCenter = if smoothedCenter then smoothedCenter:Lerp(bounds.center, alpha) else bounds.center
			smoothedRadius += (bounds.radius - smoothedRadius) * alpha
			local center: Vector3 = smoothedCenter :: Vector3
			-- Keep newly expanded bounds framed while center/radius smoothing catches up.
			local radius = math.max(bounds.radius, smoothedRadius) + (bounds.center - center).Magnitude
			local distance = fittedDistance(radius) * zoomScale
			focusPosition = center
			nextView = CFrame.new(center) * rotation() * CFrame.new(0, 0, distance)
			status = bounds.message
		else
			status = if mode == "Group" then "Selected group unavailable | waiting for rendered bounds"
				else "Scenario overview unavailable"
		end
	end
	if now >= nextUiRefresh then
		nextUiRefresh = now + BOUNDS_INTERVAL
		changed()
	end
	return nextView, focusPosition
end

local function createAction(context: InputContext, name: string, actionType: Enum.InputActionType, key: Enum.KeyCode?): InputAction
	local action: InputAction = Instance.new("InputAction")
	action.Name = name
	action.Type = actionType
	if key then
		local binding: InputBinding = Instance.new("InputBinding")
		binding.KeyCode = key
		binding.Parent = action
	end
	action.Parent = context
	actions[name] = action
	return action
end

function Camera.GetState(): State
	return {
		mode = mode, speed = speed, selectedBoidId = if api then api.GetSelectedBoid() else nil,
		selectedGroupId = selectedGroupId, status = status, isActive = isActive, zoomScale = zoomScale,
	}
end

function Camera.SetSpeed(value: number): ()
	assert(value == value and math.abs(value) < math.huge, "Camera speed must be finite")
	speed = math.clamp(value, MIN_SPEED, MAX_SPEED)
	changed()
end

function Camera.Zoom(steps: number): ()
	if not isActive or mode == "Free" then
		return
	end
	zoomScale = math.clamp(zoomScale * math.exp(-steps * 0.15), 0.1, 20)
	changed()
end

function Camera.SelectGroup(groupId: number?): ()
	selectedGroupId = groupId
	groupBounds = nil
	hasSeenGroup = false
	nextBoundsRefresh = 0
	orbitNeedsReset = mode == "Group"
	changed()
end

function Camera.SetMode(nextMode: Mode): boolean
	assert(nextMode == "Free" or nextMode == "Boid" or nextMode == "Group" or nextMode == "Overview", "Unknown observation camera mode")
	if not isActive or not api then
		return false
	end
	if nextMode == "Boid" and not (api :: CameraApi).GetSelectedBoid() then
		status = "Enter a boid ID before following"
		changed()
		return false
	end
	if nextMode == "Group" and selectedGroupId == nil then
		status = "Choose a group before following"
		changed()
		return false
	end
	mode = nextMode :: Mode
	status = if nextMode == "Free" then "Free flight" else "Waiting for rendered camera target"
	orbitNeedsReset = nextMode ~= "Free"
	smoothedCenter = nil
	smoothedRadius = 1
	nextBoundsRefresh = 0
	changed()
	return true
end

function Camera.Start(owner: CameraApi): ()
	if isActive then
		return
	end
	api = owner
	isActive = true
	hasWindowFocus = true
	mode = "Free"
	status = "Free flight"
	zoomScale = 1
	orbitNeedsReset = false
	local initialCamera: Camera? = workspace.CurrentCamera
	if initialCamera then setAngles(initialCamera.CFrame) end
	trackedBoidId = nil
	hasSeenBoid = false
	hasSeenGroup = false
	groupBounds = nil
	overviewBounds = nil
	nextBoundsRefresh = 0
	nextUiRefresh = 0
	local bindings: {ScenarioTypes.GroupBinding} = owner.GetBindings()
	selectedGroupId = if bindings[1] then bindings[1].groupId else nil
	local context: InputContext = Instance.new("InputContext")
	context.Name = "BoidsObservationCameraInput"
	context.Priority = 5000
	context.Sink = true
	createAction(context, "Move", Enum.InputActionType.Direction2D, nil)
	local move: InputBinding = Instance.new("InputBinding")
	move.Left, move.Right, move.Up, move.Down = Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.W, Enum.KeyCode.S
	move.Parent = actions.Move
	createAction(context, "Rise", Enum.InputActionType.Bool, Enum.KeyCode.E)
	createAction(context, "Fall", Enum.InputActionType.Bool, Enum.KeyCode.Q)
	createAction(context, "Fast", Enum.InputActionType.Bool, Enum.KeyCode.LeftShift)
	createAction(context, "LookHeld", Enum.InputActionType.Bool, Enum.KeyCode.MouseRightButton)
	createAction(context, "Look", Enum.InputActionType.Direction2D, Enum.KeyCode.MouseDelta)
	local slower: InputAction = createAction(context, "Slower", Enum.InputActionType.Bool, Enum.KeyCode.LeftBracket)
	local faster: InputAction = createAction(context, "Faster", Enum.InputActionType.Bool, Enum.KeyCode.RightBracket)
	context.Parent = Players.LocalPlayer
	inputContext = context
	table.insert(connections, slower.Pressed:Connect(function(): ()
		if UserInputService:GetFocusedTextBox() == nil then Camera.SetSpeed(speed * 0.5) end
	end))
	table.insert(connections, faster.Pressed:Connect(function(): ()
		if UserInputService:GetFocusedTextBox() == nil then Camera.SetSpeed(speed * 2) end
	end))
	table.insert(connections, UserInputService.InputChanged:Connect(function(input: InputObject, wasProcessed: boolean): ()
		if not wasProcessed and hasWindowFocus and not GuiService.MenuIsOpen and UserInputService:GetFocusedTextBox() == nil
			and input.UserInputType == Enum.UserInputType.MouseWheel then
			Camera.Zoom(input.Position.Z)
		end
	end))
	table.insert(connections, UserInputService.WindowFocusReleased:Connect(function(): ()
		hasWindowFocus = false
		context.Enabled = false
		releaseLook()
	end))
	table.insert(connections, UserInputService.WindowFocused:Connect(function(): ()
		hasWindowFocus = true
		context.Enabled = true
	end))
	Handoff.SetCameraDriver(step)
end

function Camera.Stop(): ()
	if not isActive then
		return
	end
	isActive = false
	Handoff.SetCameraDriver(nil)
	for _, connection in connections do connection:Disconnect() end
	table.clear(connections)
	if inputContext then
		inputContext:Destroy()
		inputContext = nil
	end
	table.clear(actions)
	api = nil
	groupBounds = nil
	overviewBounds = nil
	smoothedCenter = nil
	selectedGroupId = nil
	trackedBoidId = nil
	releaseLook()
end

return Camera
