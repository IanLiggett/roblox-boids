--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local SharedTypes = require(BoidsReplicated.SharedTypes)
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
local ObservationTypes = require(BoidsReplicated.Scenarios.ObservationTypes)
local Age = require(BoidsReplicated.Scenarios.ObservationAge)
local Renderer = require(script.Parent.Parent.Parent.BoidsRenderer)
local Obstacle = require(script.Parent.Obstacle)
local Inspection = {}

export type ClientSample = { state: SharedTypes.BoidObservation, simulationAge: number, isAgeLowerBound: boolean }
export type GroupRow = {
	groupId: number, name: string, ownership: "server" | "client", color: Color3,
	renderedCount: number?, clientCount: number?,
}
type Sample = {
	selectedBoidId: number?, refreshedAt: number,
	rendered: Renderer.RenderedBoidState?, client: ClientSample?, server: ObservationTypes.ServerSample?,
	selectedGroupId: number?, groupColor: Color3?, group: SharedTypes.GroupObservation?,
}
export type Snapshot = Sample & { obstacle: Obstacle.State }
export type Source = {
	GetSelectedBoid: () -> number?, GetSelectedGroup: () -> number?,
	GetServerSample: () -> ObservationTypes.ServerSample?,
	GetBindings: () -> {ScenarioTypes.GroupBinding},
	GetBinding: (number) -> ScenarioTypes.GroupBinding?,
	GetGroupCount: (number) -> number?,
	GetBoidObservation: (number) -> SharedTypes.BoidObservation?,
	GetGroupObservation: (number) -> SharedTypes.GroupObservation?,
	ClearGroup: (number) -> (),
	InspectionChanged: () -> (), GroupsChanged: () -> (),
}

local source: Source? = nil
local connection: RBXScriptConnection? = nil
local isActive = false
local generation = 0
local sessionId: string? = nil
local selectionRevision = -1
local currentId: number? = nil
local tracker: Age.Tracker? = nil
local nextRead, nextGroups = 0, 0
local groupOverlayEnabled = false
local seenGroups: {[number]: boolean} = {}
local groups: {GroupRow} = {}
local snapshot: Sample = { refreshedAt = 0 }

local function clearSnapshot(): ()
	tracker, currentId = nil, nil
	snapshot = { refreshedAt = 0 }
end

local function refreshGroups(owner: Source): ()
	local rows: {GroupRow} = {}
	local selected = owner.GetSelectedGroup()
	for _, binding in owner.GetBindings() do
		local id = binding.groupId
		local rendered: Renderer.RenderedGroupInfo? = Renderer.GetRenderedGroupInfo(id)
		if rendered then seenGroups[id] = true end
		if not rendered and seenGroups[id] and selected == id then owner.ClearGroup(id) end
		table.insert(rows, {
			groupId = id, name = binding.definition.name, ownership = binding.ownership, color = binding.definition.color,
			renderedCount = if rendered then rendered.count else nil,
			clientCount = if rendered then owner.GetGroupCount(id) else nil,
		})
	end
	groups = rows
	owner.GroupsChanged()
end

local function refresh(owner: Source, now: number): ()
	local id = owner.GetSelectedBoid()
	if id ~= currentId then
		tracker = nil
		currentId = id
	end
	local client: SharedTypes.BoidObservation? = if id then owner.GetBoidObservation(id) else nil
	tracker = if client then Age.Observe(tracker, client) else nil
	-- Availability/capture is feature work, independent of any GUI visibility or listeners.
	Obstacle.Refresh(client ~= nil)
	local selectedGroup = owner.GetSelectedGroup()
	local color: Color3? = nil
	if groupOverlayEnabled and selectedGroup ~= nil then
		local binding: ScenarioTypes.GroupBinding? = owner.GetBinding(selectedGroup)
		color = if binding then binding.definition.color else nil
	end
	snapshot = {
		selectedBoidId = id, refreshedAt = now,
		rendered = if id then Renderer.GetRenderedBoidState(id) else nil,
		client = if client and tracker then { state = client, simulationAge = tracker.seconds, isAgeLowerBound = tracker.isLowerBound } else nil,
		server = owner.GetServerSample(),
		selectedGroupId = selectedGroup, groupColor = color,
		group = if groupOverlayEnabled and selectedGroup then owner.GetGroupObservation(selectedGroup) else nil,
	}
	owner.InspectionChanged()
end

function Inspection.Start(owner: Source): ()
	if connection then return end
	source = owner
	generation += 1
	local currentGeneration = generation
	connection = RunService.Heartbeat:Connect(function(): ()
		if not isActive or generation ~= currentGeneration or source ~= owner then return end
		local now = workspace:GetServerTimeNow()
		if now < nextRead then return end
		nextRead = now + 0.25
		if now >= nextGroups then
			nextGroups = now + 0.5
			refreshGroups(owner)
		end
		refresh(owner, now)
	end)
end

function Inspection.Sync(active: boolean, nextSessionId: string?, revision: number): ()
	local newSession = nextSessionId ~= sessionId or active ~= isActive
	if not newSession and revision == selectionRevision then return end
	isActive, sessionId, selectionRevision = active, nextSessionId, revision
	clearSnapshot()
	nextRead = 0
	if newSession then
		table.clear(seenGroups)
		table.clear(groups)
		nextGroups = 0
		if source then source.GroupsChanged() end
	end
	if source then source.InspectionChanged() end
end

function Inspection.SetGroupOverlayEnabled(enabled: boolean): ()
	groupOverlayEnabled = enabled
end

function Inspection.GetState(): Snapshot
	local copy: Snapshot = {
		selectedBoidId = snapshot.selectedBoidId, refreshedAt = snapshot.refreshedAt,
		rendered = if snapshot.rendered then table.clone(snapshot.rendered) else nil,
		selectedGroupId = snapshot.selectedGroupId, groupColor = snapshot.groupColor,
		obstacle = Obstacle.GetState(),
	}
	if snapshot.client then
		local client: ClientSample = table.clone(snapshot.client)
		client.state = table.clone(snapshot.client.state)
		copy.client = client
	end
	if snapshot.server then
		local server: ObservationTypes.ServerSample = table.clone(snapshot.server)
		server.state = if snapshot.server.state then table.clone(snapshot.server.state) else nil
		copy.server = server
	end
	if snapshot.group then
		local group: SharedTypes.GroupObservation = table.clone(snapshot.group)
		group.path, group.gravityWells = {}, {}
		for index, node in snapshot.group.path do group.path[index] = table.clone(node) end
		for index, well in snapshot.group.gravityWells do group.gravityWells[index] = table.clone(well) end
		copy.group = group
	end
	return copy
end

function Inspection.GetGroups(): {GroupRow}
	local copy: {GroupRow} = {}
	for index, row in groups do copy[index] = table.clone(row) end
	return copy
end

function Inspection.Stop(): ()
	generation += 1
	if connection then
		connection:Disconnect()
		connection = nil
	end
	source = nil
	isActive, sessionId, selectionRevision = false, nil, -1
	nextRead, nextGroups = 0, 0
	table.clear(seenGroups)
	table.clear(groups)
	clearSnapshot()
end

return Inspection
