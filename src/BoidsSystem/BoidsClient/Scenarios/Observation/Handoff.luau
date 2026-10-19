--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local HostHooks = require(BoidsReplicated.Scenarios.HostHooks)
local ObservationTypes = require(BoidsReplicated.Scenarios.ObservationTypes)
local player: Player = Players.LocalPlayer
local CameraReporter = require(script.Parent.Parent.Parent.ClientSimulation.CameraReporter)
local Types = require(script.Parent.Types)
local Handoff = {}

type SavedCamera = { camera: Camera, cameraType: Enum.CameraType, cframe: CFrame, focus: CFrame }
type Region = { position: Vector3, revision: number, status: "loading" | "failed" | "timeout" | "requested", isRunning: boolean }

local isActive = false
local generation = 0
local view: CFrame = CFrame.identity
local focus: CFrame = CFrame.identity
local savedCamera: SavedCamera? = nil
local resumeInput: (() -> ())? = nil
local connections: {RBXScriptConnection} = {}
local regions: {[string]: Region} = {}
local onChanged: (() -> ())? = nil
local cameraDriver: ((number, CFrame) -> (CFrame, Vector3?))? = nil
local lastDriverView: CFrame? = nil
local lastFocusPosition: Vector3? = nil
local savedMouseBehavior = Enum.MouseBehavior.Default
local wasMouseIconEnabled = true
local REGION_DISTANCE = 128
local STREAM_TIMEOUT = 5

local function notify(): ()
	if onChanged then
		onChanged()
	end
end

local function restoreCamera(): ()
	if savedCamera then
		savedCamera.camera.CameraType = savedCamera.cameraType
		savedCamera.camera.CFrame = savedCamera.cframe
		savedCamera.camera.Focus = savedCamera.focus
		savedCamera = nil
	end
end

local function applyCamera(): ()
	local camera: Camera? = workspace.CurrentCamera
	if not camera then
		return
	end
	if not savedCamera or savedCamera.camera ~= camera then
		restoreCamera()
		savedCamera = { camera = camera, cameraType = camera.CameraType, cframe = camera.CFrame, focus = camera.Focus }
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then camera.CameraType = Enum.CameraType.Scriptable end
	if camera.CFrame ~= view then camera.CFrame = view end
	if camera.Focus ~= focus then camera.Focus = focus end
end

local function requestRegion(key: string, position: Vector3): ()
	if not workspace.StreamingEnabled then
		return
	end
	local existing: Region? = regions[key]
	if existing and (existing.position - position).Magnitude < REGION_DISTANCE then
		return
	end
	local region: Region = existing or { position = position, revision = 0, status = "loading", isRunning = false }
	regions[key] = region
	region.position = position
	region.revision += 1
	region.status = "loading"
	notify()
	if region.isRunning then
		return
	end
	region.isRunning = true
	local currentGeneration = generation
	local record: Region = region
	task.spawn(function(): ()
		while isActive and generation == currentGeneration and regions[key] == record do
			local revision = record.revision
			local requestedPosition: Vector3 = record.position
			local startedAt = os.clock()
			local ok = pcall(function(): ()
				player:RequestStreamAroundAsync(requestedPosition, STREAM_TIMEOUT)
			end)
			if not isActive or generation ~= currentGeneration or regions[key] ~= record then
				return
			end
			if record.revision ~= revision then
				continue
			end
			-- Completion is best effort, not proof that every distant Instance is resident.
			record.status = if not ok then "failed" elseif os.clock() - startedAt >= STREAM_TIMEOUT then "timeout" else "requested"
			record.isRunning = false
			notify()
			return
		end
	end)
end

function Handoff.GetStreamingStatus(): Types.StreamingStatus
	local loading, incomplete, total = 0, 0, 0
	for _, region in regions do
		total += 1
		if region.status == "loading" then
			loading += 1
		elseif region.status ~= "requested" then
			incomplete += 1
		end
	end
	return {
		state = if not isActive then "Inactive" elseif not workspace.StreamingEnabled then "Disabled"
			elseif loading > 0 then "Loading" elseif incomplete > 0 then "Incomplete" else "Requested",
		total = total, loading = loading, incomplete = incomplete,
		needsAttention = isActive and incomplete > 0,
	}
end

function Handoff.SetCameraDriver(driver: ((number, CFrame) -> (CFrame, Vector3?))?): ()
	cameraDriver = driver
	lastDriverView = nil
	lastFocusPosition = nil
end

function Handoff.SetCameraCFrame(cframe: CFrame): ()
	assert(isActive, "Observation camera requires an active handoff")
	view = cframe
	focus = cframe * CFrame.new(0, 0, -32)
	lastDriverView = nil
	lastFocusPosition = nil
	applyCamera()
	CameraReporter.ReportNow(view)
	requestRegion("Camera", view.Position)
end

function Handoff.SyncFixedObservers(observers: {ObservationTypes.FixedObserver}): ()
	if not isActive then
		return
	end
	local retained: {[string]: boolean} = { Camera = true }
	for _, observer in observers do
		local key = "Fixed_" .. observer.id
		retained[key] = true
		requestRegion(key, observer.position)
	end
	for key in regions do
		if not retained[key] then
			regions[key] = nil
		end
	end
	notify()
end

function Handoff.Start(changed: () -> (), hostHooks: HostHooks.Client?): ()
	if isActive then
		return
	end
	isActive = true
	generation += 1
	onChanged = changed
	local camera: Camera? = workspace.CurrentCamera
	view = if camera then camera.CFrame else CFrame.identity
	focus = if camera then camera.Focus else view * CFrame.new(0, 0, -32)
	savedMouseBehavior = UserInputService.MouseBehavior
	wasMouseIconEnabled = UserInputService.MouseIconEnabled
	resumeInput = if hostHooks then hostHooks.Suspend() else nil
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	applyCamera()
	table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function(): ()
		if isActive then
			applyCamera()
			CameraReporter.ReportNow(view)
		end
	end))
	RunService:BindToRenderStep("BoidsObservationCamera", Enum.RenderPriority.Camera.Value + 1, function(deltaTime: number): ()
		if not isActive then
			return
		end
		if cameraDriver then
			local previousPosition: Vector3 = view.Position
			local nextView: CFrame, focusPosition: Vector3? = cameraDriver(deltaTime, view)
			if nextView ~= lastDriverView or focusPosition ~= lastFocusPosition then
				focus = if focusPosition then CFrame.new(focusPosition) else nextView * CFrame.new(0, 0, -32)
				lastDriverView = nextView
				lastFocusPosition = focusPosition
			end
			view = nextView
			if (view.Position - previousPosition).Magnitude >= REGION_DISTANCE then
				CameraReporter.ReportNow(view)
			end
		end
		applyCamera()
		requestRegion("Camera", view.Position)
	end)
	CameraReporter.ReportNow(view)
	requestRegion("Camera", view.Position)
end

function Handoff.Stop(): ()
	if not isActive then
		return
	end
	isActive = false
	generation += 1
	cameraDriver = nil
	lastDriverView = nil
	lastFocusPosition = nil
	RunService:UnbindFromRenderStep("BoidsObservationCamera")
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(regions)
	restoreCamera()
	if resumeInput then
		resumeInput()
		resumeInput = nil
	end
	UserInputService.MouseBehavior = savedMouseBehavior
	UserInputService.MouseIconEnabled = wasMouseIconEnabled
	onChanged = nil
end

return Handoff
