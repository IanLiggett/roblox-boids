--!strict

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local ScenarioModules = BoidsReplicated:WaitForChild("Scenarios") :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated.Scenarios)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local ScenarioTypes = require(ScenarioModules.Types)
local ObservationTypes = require(ScenarioModules:WaitForChild("ObservationTypes") :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated.Scenarios.ObservationTypes))
local Config = require(script.Parent.ObservationConfig)
local Age = require(ScenarioModules.ObservationAge)
local HostHooks = require(ScenarioModules.HostHooks)
local Observation = {}

type BoidsApi = RuntimeTypes.ServerObservation
type ScenarioContext = ScenarioTypes.ScenarioContext
type FixedObserver = ObservationTypes.FixedObserver
type SessionState = ObservationTypes.SessionState
type Session = {
	id: string,
	streamingFolder: Folder?,
	cameraFocus: BasePart?,
	fixedFoci: {[number]: BasePart},
	lastCameraReport: number,
	resumeInput: HostHooks.Cleanup?,
	cameraEnabled: boolean,
	fixedObservers: {FixedObserver},
	selectionRevision: number,
	selectedBoidId: number?,
	ageTracker: Age.Tracker?,
}
type RateState = { tokens: number, updatedAt: number }

local requestRemote: RemoteEvent = ScenarioModules:WaitForChild("ObservationRequest") :: RemoteEvent
local stateRemote: RemoteEvent = ScenarioModules:WaitForChild("ObservationState") :: RemoteEvent
local sampleRemote: UnreliableRemoteEvent = ScenarioModules:WaitForChild("ObservationSample") :: UnreliableRemoteEvent
local cameraRemote: UnreliableRemoteEvent = BoidsReplicated.Remotes.CameraUpdate
local activeContext: ScenarioContext? = nil
local activeBoids: BoidsApi? = nil
local sessions: {[Player]: Session} = {}
local revisions: {[Player]: number} = {}
local rates: {[Player]: RateState} = {}
local connections: {RBXScriptConnection} = {}
local nextObserverId = 0
local generation = 0
local isStarted = false
local hostHooks: HostHooks.Server? = nil
local MAX_FIXED_OBSERVERS = 4
local REQUESTS_PER_SECOND = 10
local REQUEST_BURST = 20

local function isInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

local function isFinitePosition(value: unknown): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X and value.Y == value.Y and value.Z == value.Z
		and math.abs(value.X) < math.huge and math.abs(value.Y) < math.huge and math.abs(value.Z) < math.huge
end

local function isAuthorized(player: Player): boolean
	return RunService:IsStudio()
		or (game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId)
		or Config.allowedUserIds[player.UserId] == true
end

local function isAvailable(player: Player): boolean
	local context: ScenarioContext? = activeContext
	return isStarted and context ~= nil and not string.find(context.name, "^Benchmark") and isAuthorized(player)
end

local function createFocus(player: Player, session: Session, name: string, position: Vector3): BasePart
	local focus: Part = Instance.new("Part")
	focus.Name = name
	focus.Size = Vector3.one
	focus.Anchored = true
	focus.Transparency = 1
	focus.CanCollide = false
	focus.CanTouch = false
	focus.CanQuery = false
	focus.CastShadow = false
	focus.Position = position
	focus.Parent = session.streamingFolder
	player:AddReplicationFocus(focus)
	return focus
end

local function updateFixedFoci(player: Player, session: Session): ()
	if not session.streamingFolder then
		return
	end
	local retained: {[number]: boolean} = {}
	for _, observer in session.fixedObservers do
		retained[observer.id] = true
		if not session.fixedFoci[observer.id] then
			session.fixedFoci[observer.id] = createFocus(player, session, "Fixed_" .. observer.id, observer.position)
		end
	end
	for id, focus in session.fixedFoci do
		if not retained[id] then
			player:RemoveReplicationFocus(focus)
			focus:Destroy()
			session.fixedFoci[id] = nil
		end
	end
end

local function applyObservers(player: Player, session: Session): ()
	local boids: BoidsApi = activeBoids :: BoidsApi
	local positions: {Vector3} = table.create(#session.fixedObservers, Vector3.zero)
	for index, observer in session.fixedObservers do
		positions[index] = observer.position
	end
	boids.SetViewerObservers(player.UserId, session.cameraEnabled, positions)
	updateFixedFoci(player, session)
end

local function closeSession(player: Player): ()
	local session = sessions[player]
	if session then
		if session.resumeInput then session.resumeInput() end
		if session.cameraFocus then
			player:RemoveReplicationFocus(session.cameraFocus)
		end
		for _, focus in session.fixedFoci do
			player:RemoveReplicationFocus(focus)
		end
		table.clear(session.fixedFoci)
		if session.streamingFolder then
			session.streamingFolder:Destroy()
		end
	end
	if session and activeBoids then
		activeBoids.ResetViewerObservers(player.UserId)
	end
	sessions[player] = nil
end

local function sendState(player: Player, message: string?): ()
	local session: Session? = sessions[player]
	local fixedObservers: {FixedObserver} = {}
	if session then
		for index, observer in session.fixedObservers do
			fixedObservers[index] = { id = observer.id, position = observer.position }
		end
	end
	local revision = (revisions[player] or 0) + 1
	revisions[player] = revision
	local state: SessionState = {
		revision = revision,
		isAllowed = isAvailable(player),
		isActive = session ~= nil,
		sessionId = if session then session.id else nil,
		cameraEnabled = if session then session.cameraEnabled else true,
		fixedObservers = fixedObservers,
		selectionRevision = if session then session.selectionRevision else 0,
		selectedBoidId = if session then session.selectedBoidId else nil,
		message = message,
	}
	stateRemote:FireClient(player, state)
end

local function takeRequestToken(player: Player): boolean
	local now = os.clock()
	local rate: RateState = rates[player] or { tokens = REQUEST_BURST, updatedAt = now }
	rates[player] = rate
	rate.tokens = math.min(REQUEST_BURST, rate.tokens + (now - rate.updatedAt) * REQUESTS_PER_SECOND)
	rate.updatedAt = now
	if rate.tokens < 1 then
		return false
	end
	rate.tokens -= 1
	return true
end

local function setCameraEnabled(player: Player, session: Session, request: ObservationTypes.SetCameraEnabledCommand): ()
	session.cameraEnabled = request.cameraEnabled
	applyObservers(player, session)
	sendState(player)
end

local function createFixed(player: Player, session: Session, request: ObservationTypes.CreateFixedCommand): ()
	if #session.fixedObservers >= MAX_FIXED_OBSERVERS then
		sendState(player, "Maximum of four fixed observers reached")
		return
	end
	nextObserverId += 1
	table.insert(session.fixedObservers, { id = nextObserverId, position = request.position })
	applyObservers(player, session)
	sendState(player)
end

local function deleteFixed(player: Player, session: Session, request: ObservationTypes.DeleteFixedCommand): ()
	for index, observer in session.fixedObservers do
		if observer.id == request.observerId then
			table.remove(session.fixedObservers, index)
			applyObservers(player, session)
			sendState(player)
			return
		end
	end
	sendState(player, "Observer does not belong to this session")
end

local function selectBoid(player: Player, session: Session, request: ObservationTypes.SelectBoidCommand): ()
	session.selectionRevision = request.selectionRevision
	session.selectedBoidId = request.boidId
	session.ageTracker = nil
	sendState(player)
end

-- Admission/session ownership is already established; validate raw fields before typed dispatch.
local function dispatchCommand(player: Player, session: Session, request: {[string]: unknown}): ()
	if request.action == "SetCameraEnabled" then
		if type(request.cameraEnabled) ~= "boolean" then
			sendState(player, "Invalid camera setting")
			return
		end
		setCameraEnabled(player, session, {
			action = "SetCameraEnabled", sessionId = session.id, cameraEnabled = request.cameraEnabled,
		})
	elseif request.action == "CreateFixed" then
		if not isFinitePosition(request.position) then
			sendState(player, "Invalid observer position")
			return
		end
		createFixed(player, session, { action = "CreateFixed", sessionId = session.id, position = request.position :: Vector3 })
	elseif request.action == "DeleteFixed" then
		if not isInteger(request.observerId, 1, 2^53 - 1) then
			sendState(player, "Invalid observer ID")
			return
		end
		deleteFixed(player, session, { action = "DeleteFixed", sessionId = session.id, observerId = request.observerId :: number })
	elseif request.action == "SelectBoid" then
		if not isInteger(request.selectionRevision, 1, 2^31 - 1)
			or (request.selectionRevision :: number) <= session.selectionRevision
			or (request.boidId ~= nil and not isInteger(request.boidId, 0, 65535)) then
			sendState(player, "Invalid or stale selection")
			return
		end
		selectBoid(player, session, {
			action = "SelectBoid", sessionId = session.id,
			selectionRevision = request.selectionRevision :: number, boidId = request.boidId :: number?,
		})
	else
		sendState(player, "Unknown observation action")
	end
end

local function handleRequest(player: Player, rawRequest: unknown): ()
	if type(rawRequest) ~= "table" then return end
	local request = rawRequest :: {[string]: unknown}
	if type(request.action) ~= "string" then return end
	local session: Session? = sessions[player]
	-- Closing one's own session remains possible after a burst or access revocation.
	if request.action == "Close" and session and request.sessionId == session.id then
		closeSession(player)
		sendState(player)
		return
	end
	if not takeRequestToken(player) then
		return
	end
	if not isAvailable(player) then
		closeSession(player)
		sendState(player, "Observation unavailable")
		return
	end
	if request.action == "Sync" then
		sendState(player)
		return
	end
	if request.action == "Open" then
		if not session then
			local created: Session = {
				id = HttpService:GenerateGUID(false), cameraEnabled = true, fixedObservers = {},
				selectionRevision = 0, fixedFoci = {}, lastCameraReport = -math.huge,
				resumeInput = if hostHooks then hostHooks.SuspendInput(player) else nil,
			}
			session = created
			if workspace.StreamingEnabled then
				local folder: Folder = Instance.new("Folder")
				folder.Name = "BoidsObservationStreaming_" .. player.UserId
				folder.Parent = workspace
				session.streamingFolder = folder
				-- The first camera report supplies the view, independently of LOD enablement.
				local character: Model? = player.Character
				local root: Instance? = character and character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					session.cameraFocus = createFocus(player, session, "Camera", root.Position)
				end
			end
			sessions[player] = session
			applyObservers(player, session)
		end
		sendState(player)
		return
	end
	if not session or request.sessionId ~= session.id then
		sendState(player, "Session is not active")
		return
	end
	dispatchCommand(player, session, request)
end

function Observation.Stop(): ()
	isStarted = false
	generation += 1
	for player in sessions do
		closeSession(player)
		sendState(player)
	end
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	table.clear(rates)
end

-- The initializer supplies its running coordinator; observation never starts one.
function Observation.RegisterScenario(boids: BoidsApi, context: ScenarioContext, hooks: HostHooks.Server?): ()
	Observation.Stop()
	hostHooks = hooks
	activeBoids = boids
	activeContext = context
	isStarted = true
	local currentGeneration = generation
	table.insert(connections, requestRemote.OnServerEvent:Connect(handleRequest))
	table.insert(connections, cameraRemote.OnServerEvent:Connect(function(player: Player, cameraCFrame: unknown): ()
		local session = sessions[player]
		if not session or not session.streamingFolder or not isAvailable(player)
			or typeof(cameraCFrame) ~= "CFrame" or not isFinitePosition(cameraCFrame.Position) then
			return
		end
		local now = os.clock()
		if now - session.lastCameraReport < 1 / 30 then
			return
		end
		session.lastCameraReport = now
		if session.cameraFocus then
			session.cameraFocus.Position = cameraCFrame.Position
		else
			session.cameraFocus = createFocus(player, session, "Camera", cameraCFrame.Position)
		end
	end))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player: Player): ()
		closeSession(player)
		rates[player] = nil
		revisions[player] = nil
	end))
	local elapsed = 0
	table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime: number): ()
		if not isStarted or generation ~= currentGeneration then
			return
		end
		elapsed += deltaTime
		if elapsed < 0.25 then
			return
		end
		elapsed %= 0.25
		for player, session in sessions do
			if not isAvailable(player) then
				closeSession(player)
				sendState(player, "Observation unavailable")
				continue
			end
			local boidId: number? = session.selectedBoidId
			if boidId then
				local state = boids.GetBoidObservation(boidId)
				session.ageTracker = if state then Age.Observe(session.ageTracker, state) else nil
				-- Diagnostic channel only; these samples never enter reconciliation.
				local sample: ObservationTypes.ServerSample = {
					sessionId = session.id,
					selectionRevision = session.selectionRevision,
					boidId = boidId,
					sampledAt = workspace:GetServerTimeNow(),
					isAvailable = state ~= nil,
					position = if state then state.position else nil,
					velocity = if state then state.velocity else nil,
					state = state,
					simulationAge = if session.ageTracker then session.ageTracker.seconds else nil,
					isAgeLowerBound = if session.ageTracker then session.ageTracker.isLowerBound else nil,
				}
				sampleRemote:FireClient(player, sample)
			end
		end
	end))
end

function Observation.GetContext(): ScenarioContext?
	return activeContext
end

function Observation.GetBoids(): BoidsApi?
	return activeBoids
end

return Observation
