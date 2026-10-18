--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedTypes = require(ReplicatedStorage:WaitForChild("BoidsReplicated").SharedTypes)
local RuntimeTypes = require(ReplicatedStorage.BoidsReplicated.RuntimeTypes)
local Diagnostics = require(ReplicatedStorage.BoidsReplicated.Boids.ObstacleDiagnostics)
local Obstacle = {}

export type State = {
	isEnabled: boolean, isFrozen: boolean,
	showProbes: boolean, showCandidates: boolean, showMovement: boolean,
	decision: SharedTypes.ObstacleObservation?, status: string,
}
local state: State = {
	isEnabled = false, isFrozen = false,
	showProbes = true, showCandidates = true, showMovement = true, status = "Observation inactive",
}
local boids: RuntimeTypes.ObstacleCapture? = nil
local isActive = false
local selectedId: number? = nil
local session: string? = nil
local revision = -1
local captureId: number? = nil
local hasClientState = false

local function configureCapture(): ()
	local wanted = if isActive and state.isEnabled and not state.isFrozen and hasClientState then selectedId else nil
	if wanted == captureId then return end
	if boids then boids.SetObstacleObservation(wanted) end
	captureId = wanted
end

local function clearDecision(): ()
	state.decision = nil
	state.isFrozen = false
end

function Obstacle.Sync(handle: RuntimeTypes.ObstacleCapture?, active: boolean, boidId: number?, sessionId: string?, selectionRevision: number): ()
	if handle == boids and active == isActive and selectedId == boidId and session == sessionId and revision == selectionRevision then return end
	if boids and captureId ~= nil then boids.SetObstacleObservation(nil) end
	captureId = nil
	boids, isActive, selectedId, session, revision = handle, active, boidId, sessionId, selectionRevision
	hasClientState = false
	clearDecision()
	if not active then state.isEnabled = false end
end

function Obstacle.SetEnabled(enabled: boolean): ()
	if state.isEnabled == enabled or not isActive then return end
	state.isEnabled = enabled
	clearDecision()
	configureCapture()
end

function Obstacle.SetLayer(layer: "Probes" | "Candidates" | "Movement", enabled: boolean): ()
	if layer == "Probes" then state.showProbes = enabled
	elseif layer == "Candidates" then state.showCandidates = enabled
	else state.showMovement = enabled end
end

function Obstacle.Freeze(): boolean
	if not isActive or not state.isEnabled or not state.decision or state.isFrozen then return false end
	-- Preserve the decision already displayed, not a newer coordinator result.
	state.isFrozen = true
	configureCapture()
	return true
end

function Obstacle.Resume(): ()
	if not state.isFrozen then return end
	clearDecision()
	configureCapture()
end

-- Called by the feature inspection controller with its selected-only availability read.
function Obstacle.Refresh(isAvailable: boolean): ()
	hasClientState = isAvailable
	if not isAvailable then clearDecision() end
	configureCapture()
	if captureId ~= nil and boids then
		state.decision = boids.GetObstacleObservation()
	end
end

function Obstacle.GetState(): State
	local copy: State = table.clone(state)
	copy.decision = if state.decision then Diagnostics.Copy(state.decision) else nil
	copy.status = if not isActive then "Observation inactive"
		elseif not state.isEnabled then "Obstacle decisions OFF"
		elseif selectedId == nil then "Select a boid"
		elseif not hasClientState then "Client simulation unavailable / waiting"
		elseif state.isFrozen then "Frozen diagnostic; simulation continues"
		elseif not state.decision then "Waiting for natural simulation update (LOD unchanged)"
		else "Live"
	return copy
end

function Obstacle.Stop(): ()
	if boids and captureId ~= nil then boids.SetObstacleObservation(nil) end
	boids, captureId, selectedId, session = nil, nil, nil, nil
	isActive, hasClientState = false, false
	revision = -1
	state.isEnabled = false
	clearDecision()
end

return Obstacle
