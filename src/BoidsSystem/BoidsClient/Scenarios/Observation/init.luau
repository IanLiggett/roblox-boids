--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local HostHooks = require(BoidsReplicated.Scenarios.HostHooks)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
local ObservationTypes = require(BoidsReplicated.Scenarios.ObservationTypes)
local SimulationReplication = require(BoidsReplicated.SimulationReplication)
local SharedTypes = require(BoidsReplicated.SharedTypes)
local Handoff = require(script.Handoff)
local Camera = require(script.Camera)
local Renderer = require(script.Parent.Parent.BoidsRenderer)
local Obstacle = require(script.Obstacle)
local Dock = require(script.Dock)
local Types = require(script.Types)
local Inspection = require(script.Inspection)
local Observation = {}

type BoidsApi = RuntimeTypes.ClientObservation
type Group = SharedTypes.Group
type GroupBinding = ScenarioTypes.GroupBinding
type ScenarioContext = ScenarioTypes.ScenarioContext

local activeContext: ScenarioContext? = nil
local activeBoids: BoidsApi? = nil
local groupBindings: {GroupBinding} = {}
local bindingsById: {[number]: GroupBinding} = {}
local localGroupsById: {[number]: Group} = {}


type SessionState = ObservationTypes.SessionState
type ServerSample = ObservationTypes.ServerSample

local localPlayer: Player = Players.LocalPlayer :: Player
local scenarioModules: Folder = BoidsReplicated.Scenarios
local requestRemote: RemoteEvent = scenarioModules:WaitForChild("ObservationRequest") :: RemoteEvent
local stateRemote: RemoteEvent = scenarioModules:WaitForChild("ObservationState") :: RemoteEvent
local sampleRemote: UnreliableRemoteEvent = scenarioModules:WaitForChild("ObservationSample") :: UnreliableRemoteEvent
local sessionState: SessionState = {
	revision = 0, isAllowed = false, isActive = false,
	cameraEnabled = true, fixedObservers = {}, selectionRevision = 0,
}
local serverSample: ServerSample? = nil
local selectedBoidId: number? = nil
local pickFilter: number? = nil
local selectionRevision = 0
local isClosing = false
local isStarted = false
local hostHooks: HostHooks.Client? = nil
local generation = 0
local connections: {RBXScriptConnection} = {}
local listeners: {[Types.ChangeDomain]: {[() -> ()]: boolean}} = {
	Session = {}, Selection = {}, Camera = {}, Streaming = {}, Inspection = {}, Groups = {}, Capture = {},
}
local dock: Dock.Controller? = nil
local stopControls: (() -> ())? = nil
local stopInspector: (() -> ())? = nil
local stopDeletion: (() -> ())? = nil

local function notify(domain: Types.ChangeDomain): ()
	for listener in listeners[domain] do listener() end
end

local function syncInspection(): ()
	local active = sessionState.isActive and sessionState.isAllowed and not isClosing
	Obstacle.Sync(activeBoids, active, selectedBoidId, sessionState.sessionId, selectionRevision)
	Inspection.Sync(active, sessionState.sessionId, selectionRevision)
end

local function getGroupCount(groupId: number): number?
	local binding: GroupBinding? = bindingsById[groupId]
	if not binding then return nil end
	local group: Group? = if binding.ownership == "client" then localGroupsById[groupId] else SimulationReplication.GetClientGroup(groupId)
	return if group then group.boidCount else nil
end

local function startInspection(): ()
	Inspection.Start({
		GetSelectedBoid = function(): number? return selectedBoidId end,
		GetSelectedGroup = function(): number? return Camera.GetState().selectedGroupId end,
		-- Private sampling can retain the immutable received sample; public reads copy it.
		GetServerSample = function(): ServerSample? return serverSample end,
		GetBindings = Observation.GetGroupBindings,
		GetBinding = Observation.GetGroupBinding,
		GetGroupCount = getGroupCount,
		GetBoidObservation = function(id: number): SharedTypes.BoidObservation?
			return if activeBoids then activeBoids.GetBoidObservation(id) else nil
		end,
		GetGroupObservation = function(id: number): SharedTypes.GroupObservation?
			return if activeBoids then activeBoids.GetGroupObservation(id) else nil
		end,
		ClearGroup = function(id: number): ()
			Observation.SelectGroup(nil)
			if pickFilter == id then Observation.SetPickFilter(nil) end
		end,
		InspectionChanged = function(): () notify("Inspection") end,
		GroupsChanged = function(): () notify("Groups") end,
	})
	syncInspection()
end

local function applyAcceptedObservers(): ()
	local boids: BoidsApi? = activeBoids
	if not boids then
		return
	end
	if not sessionState.isActive then
		boids.ResetViewerObservers(localPlayer.UserId)
		return
	end
	local positions: {Vector3} = table.create(#sessionState.fixedObservers, Vector3.zero)
	for index, observer in sessionState.fixedObservers do
		positions[index] = observer.position
	end
	boids.SetViewerObservers(localPlayer.UserId, sessionState.cameraEnabled, positions)
end

local function acceptState(state: SessionState): ()
	if state.revision <= sessionState.revision then
		return
	end
	local previous: SessionState = sessionState
	local isNewSession = state.sessionId ~= previous.sessionId
	local lifecycleChanged = isNewSession or state.isActive ~= previous.isActive or state.isAllowed ~= previous.isAllowed
	local fixedChanged = #state.fixedObservers ~= #previous.fixedObservers
	if not fixedChanged then
		for index, observer in state.fixedObservers do
			local old: ObservationTypes.FixedObserver = previous.fixedObservers[index]
			if observer.id ~= old.id or observer.position ~= old.position then
				fixedChanged = true
				break
			end
		end
	end
	local sessionChanged = lifecycleChanged or fixedChanged or state.cameraEnabled ~= previous.cameraEnabled or state.message ~= previous.message
	sessionState = state
	if isNewSession or not state.isActive then
		selectionRevision = state.selectionRevision
		selectedBoidId = state.selectedBoidId
		serverSample = nil
		pickFilter = nil
		isClosing = false
	end
	applyAcceptedObservers()
	if state.isActive then
		Handoff.Start(function(): () notify("Streaming") end, hostHooks)
		Camera.Start({
			GetBindings = Observation.GetGroupBindings,
			GetSelectedBoid = function(): number? return selectedBoidId end,
			ClearSelection = function(): () Observation.SelectBoid(nil) end,
			Changed = function(): () notify("Camera") end,
		})
		if isNewSession or fixedChanged then Handoff.SyncFixedObservers(state.fixedObservers) end
	else
		Camera.Stop()
		Handoff.Stop()
	end
	if lifecycleChanged then
		syncInspection()
		notify("Camera")
		notify("Streaming")
	end
	if sessionChanged then notify("Session") end
	if isNewSession or not state.isActive then notify("Selection") end
end

local function acceptSample(sample: ServerSample): ()
	-- The diagnostic stream has no simulation or renderer write path.
	if isClosing or not sessionState.isActive or sample.sessionId ~= sessionState.sessionId
		or sample.selectionRevision ~= selectionRevision or sample.boidId ~= selectedBoidId
		or sessionState.selectionRevision ~= selectionRevision
		or (serverSample ~= nil and sample.sampledAt <= serverSample.sampledAt) then
		return
	end
	serverSample = sample
end

local function sendCommand(command: ObservationTypes.Command): ()
	requestRemote:FireServer(command)
end

local function sessionToken(): string?
	return if isStarted and sessionState.isActive and not isClosing then sessionState.sessionId else nil
end

local function start(): ()
	if isStarted then
		applyAcceptedObservers()
		sendCommand({ action = "Sync" })
		return
	end
	isStarted = true
	generation += 1
	local currentGeneration = generation
	table.insert(connections, stateRemote.OnClientEvent:Connect(function(state: SessionState): ()
		if isStarted and generation == currentGeneration then
			acceptState(state)
		end
	end))
	table.insert(connections, sampleRemote.OnClientEvent:Connect(function(sample: ServerSample): ()
		if isStarted and generation == currentGeneration then
			acceptSample(sample)
		end
	end))
	startInspection()
	local presentation: Dock.Controller = Dock.Start(Observation)
	dock = presentation
	local Controls = require(script.Controls)
	stopControls = Controls.Start(Observation, presentation.pages.Session, presentation.pages.Camera)
	local Inspector = require(script.Inspector)
	stopInspector = Inspector.Start(Observation, presentation.pages.Inspector)
	sendCommand({ action = "Sync" })
end

function Observation.RegisterScenario(
	boids: BoidsApi,
	context: ScenarioContext,
	definitions: {ScenarioTypes.GroupDefinition},
	spawnedGroups: {ScenarioTypes.SpawnedGroup},
	hooks: HostHooks.Client?
): ()
	assert(not isStarted or hostHooks == hooks, "Observer host hooks are fixed at startup")
	hostHooks = hooks
	assert(#definitions == #spawnedGroups, "Scenario definitions and spawned groups must match")
	if stopDeletion then stopDeletion() end
	stopDeletion = boids.SubscribeDeleted(function(ids: {number}): ()
		if not sessionState.isActive or isClosing then return end
		for _, id in ids do
			if id == selectedBoidId then
				Observation.SelectBoid(nil)
				break
			end
		end
	end)
	activeBoids = boids
	activeContext = context
	table.clear(groupBindings)
	table.clear(bindingsById)
	table.clear(localGroupsById)

	for _, binding in context.serverGroups do
		table.insert(groupBindings, binding)
		bindingsById[binding.groupId] = binding
	end
	for index, spawned in spawnedGroups do
		local group: Group = spawned.group
		local binding: GroupBinding = {
			groupId = group.id,
			ownership = "client",
			definition = definitions[index],
		}
		table.insert(groupBindings, binding)
		bindingsById[group.id] = binding
		localGroupsById[group.id] = group
	end
	if isStarted then
		Inspection.Stop()
		startInspection()
	end
	start()
end

function Observation.GetContext(): ScenarioContext?
	return activeContext
end

function Observation.GetGroupBindings(): {GroupBinding}
	return table.clone(groupBindings)
end

function Observation.GetGroupBinding(groupId: number): GroupBinding?
	return bindingsById[groupId]
end

function Observation.GetSessionState(): SessionState
	local state: SessionState = table.clone(sessionState)
	state.fixedObservers = {}
	for index, observer in sessionState.fixedObservers do
		state.fixedObservers[index] = table.clone(observer)
	end
	return state
end

function Observation.GetStreamingStatus(): Types.StreamingStatus
	return Handoff.GetStreamingStatus()
end

-- The package camera modes can move the held view through this handoff.
function Observation.SetCameraCFrame(cframe: CFrame): ()
	Handoff.SetCameraCFrame(cframe)
end

function Observation.GetCameraState(): Camera.State
	return Camera.GetState()
end

function Observation.SetCameraMode(mode: Camera.Mode): boolean
	return Camera.SetMode(mode)
end

function Observation.SetCameraSpeed(speed: number): ()
	Camera.SetSpeed(speed)
end

function Observation.ZoomCamera(steps: number): ()
	Camera.Zoom(steps)
end

function Observation.SelectGroup(groupId: number?): boolean
	if not sessionState.isActive or (groupId ~= nil and bindingsById[groupId] == nil) then
		return false
	end
	Camera.SelectGroup(groupId)
	if groupId == nil and Camera.GetState().mode == "Group" then Camera.SetMode("Free") end
	return true
end

function Observation.GetSelectedBoidId(): number?
	return selectedBoidId
end

function Observation.SetObstacleEnabled(enabled: boolean): ()
	Obstacle.SetEnabled(enabled)
	notify("Capture")
end

function Observation.SetObstacleLayer(layer: "Probes" | "Candidates" | "Movement", enabled: boolean): ()
	Obstacle.SetLayer(layer, enabled)
	notify("Capture")
end

function Observation.FreezeObstacle(): boolean
	local accepted = Obstacle.Freeze()
	if accepted then notify("Capture") end
	return accepted
end

function Observation.ResumeObstacle(): ()
	Obstacle.Resume()
	notify("Capture")
end

function Observation.GetInspectionState(): Inspection.Snapshot
	return Inspection.GetState()
end

function Observation.GetInspectionGroups(): {Inspection.GroupRow}
	return Inspection.GetGroups()
end

function Observation.SetGroupOverlayEnabled(enabled: boolean): ()
	Inspection.SetGroupOverlayEnabled(enabled)
end

function Observation.GetObstacleState(): Obstacle.State
	return Obstacle.GetState()
end

function Observation.GetServerSample(): ServerSample?
	if not serverSample then return nil end
	local sample: ServerSample = table.clone(serverSample)
	sample.state = if serverSample.state then table.clone(serverSample.state) else nil
	return sample
end

function Observation.GetPickFilter(): number?
	return pickFilter
end

function Observation.SetPickFilter(groupId: number?): ()
	pickFilter = groupId
	notify("Selection")
end

function Observation.TrySelectBoid(boidId: number): (boolean, string?)
	if not sessionState.isActive or isClosing then return false, "Observation inactive" end
	if boidId ~= boidId or boidId % 1 ~= 0 or boidId < 0 or boidId > 65535 then return false, "Use an integer ID: 0-65535" end
	local rendered = Renderer.GetRenderedBoidState(boidId)
	if pickFilter ~= nil and (not rendered or rendered.groupId ~= pickFilter) then return false, "ID is outside the selected group filter" end
	Observation.SelectBoid(boidId)
	if rendered then Observation.SelectGroup(rendered.groupId) end
	return true, nil
end

function Observation.PickBoid(origin: Vector3, direction: Vector3, angularTolerance: number?): number?
	if not sessionState.isActive or isClosing then return nil end
	local hit = Renderer.PickRenderedBoid(origin, direction, pickFilter, angularTolerance)
	if hit then Observation.TrySelectBoid(hit.boidId) end
	return if hit then hit.boidId else nil
end

function Observation.Subscribe(domain: Types.ChangeDomain, listener: () -> ()): () -> ()
	listeners[domain][listener] = true
	return function(): ()
		listeners[domain][listener] = nil
	end
end

function Observation.Open(): ()
	if isStarted and not isClosing then
		sendCommand({ action = "Open" })
	end
end

function Observation.Close(): ()
	local token = sessionToken()
	if not token then return end
	sendCommand({ action = "Close", sessionId = token })
	isClosing = true
	serverSample = nil
	syncInspection()
	notify("Session")
end

function Observation.SetCameraEnabled(cameraEnabled: boolean): ()
	local token = sessionToken()
	if token then sendCommand({ action = "SetCameraEnabled", sessionId = token, cameraEnabled = cameraEnabled }) end
end

function Observation.CreateFixedObserver(position: Vector3?): ()
	local token = sessionToken()
	local camera: Camera? = workspace.CurrentCamera
	local observerPosition = position or (if camera then camera.CFrame.Position else nil)
	if token and observerPosition then
		sendCommand({ action = "CreateFixed", sessionId = token, position = observerPosition })
	end
end

function Observation.DeleteFixedObserver(observerId: number): ()
	local token = sessionToken()
	if token then sendCommand({ action = "DeleteFixed", sessionId = token, observerId = observerId }) end
end

-- Camera selection shares the diagnostic identity; client-only IDs clear server selection.
function Observation.SelectBoid(boidId: number?): ()
	local token = sessionToken()
	if not token then return end
	assert(boidId == nil or (boidId >= 0 and boidId <= 65535 and boidId % 1 == 0), "Invalid boid selection")
	selectionRevision += 1
	selectedBoidId = boidId
	serverSample = nil
	sendCommand({
		action = "SelectBoid", sessionId = token,
		selectionRevision = selectionRevision,
		boidId = if boidId ~= nil and activeBoids and activeBoids.IsServerBoid(boidId) then boidId else nil,
	})
	syncInspection()
	notify("Selection")
	notify("Camera")
end

function Observation.Stop(): ()
	Observation.Close()
	Inspection.Stop()
	Obstacle.Stop()
	Camera.Stop()
	Handoff.Stop()
	isStarted = false
	generation += 1
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	if stopDeletion then
		stopDeletion()
		stopDeletion = nil
	end
	if stopInspector then
		stopInspector()
		stopInspector = nil
	end
	if stopControls then
		stopControls()
		stopControls = nil
	end
	if dock then
		dock.Destroy()
		dock = nil
	end
	if activeBoids then
		activeBoids.ResetViewerObservers(localPlayer.UserId)
	end
	sessionState.isActive = false
	sessionState.isAllowed = false
	sessionState.sessionId = nil
	table.clear(sessionState.fixedObservers)
	serverSample = nil
	notify("Session")
	for _, domainListeners in listeners do table.clear(domainListeners) end
end

return Observation

