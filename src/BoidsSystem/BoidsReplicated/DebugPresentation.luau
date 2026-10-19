--!strict
-- Package-owned debug presentation. Simulation supplies values and lifetime
-- notifications; no visual Instance is stored in a simulation cell or Actor job.
local RunService = game:GetService("RunService")
local Quantization = require(script.Parent.Quantization)

local DebugPresentation = {}
local DEBUG_CELL_OUTLINES = false

type GroupVisuals = {target: Part?, path: Model?, cells: {[number]: Model}}
local visuals: {[number]: GroupVisuals} = {}
local GridVisualizersFolder: Folder? = nil

local function getVisuals(lifetime: number): GroupVisuals
	local existing: GroupVisuals? = visuals[lifetime]
	if existing then return existing end
	local state: GroupVisuals = {cells = {}}
	visuals[lifetime] = state
	return state
end

local function destroy(instance: Instance?): ()
	if instance then instance:Destroy() end
end

local function createCellOutline(origin: Vector3): Model
	local cellSize = Quantization.CELL_SIZE
	local thickness = 0.5

	local model = Instance.new("Model")
	model.Name = `CellOutline_{origin.X}_{origin.Y}_{origin.Z}`

	local corners = {
		origin + Vector3.new(0, 0, 0),
		origin + Vector3.new(cellSize, 0, 0),
		origin + Vector3.new(cellSize, cellSize, 0),
		origin + Vector3.new(0, cellSize, 0),
		origin + Vector3.new(0, 0, cellSize),
		origin + Vector3.new(cellSize, 0, cellSize),
		origin + Vector3.new(cellSize, cellSize, cellSize),
		origin + Vector3.new(0, cellSize, cellSize),
	}

	local edges = {
		{1, 2}, {2, 3}, {3, 4}, {4, 1}, -- bottom face
		{5, 6}, {6, 7}, {7, 8}, {8, 5}, -- top face
		{1, 5}, {2, 6}, {3, 7}, {4, 8}, -- vertical edges
	}

	for _, edge in edges do
		local p1 = corners[edge[1]]
		local p2 = corners[edge[2]]
		local midpoint = (p1 + p2) / 2
		local length = (p2 - p1).Magnitude

		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 0.5
		part.Color = Color3.new(0, 1, 0)
		part.Material = Enum.Material.Neon
		part.Size = Vector3.new(thickness, thickness, length)
		part.CFrame = CFrame.lookAt(midpoint, p2)
		part.Parent = model
	end

	if not GridVisualizersFolder then
		local folder: Folder = Instance.new("Folder")
		folder.Name = "GridVisualizers"
		folder.Parent = workspace
		GridVisualizersFolder = folder
	end
	model.Parent = GridVisualizersFolder
	return model
end


function DebugPresentation.SetTarget(lifetime: number, position: Vector3?): ()
	local state = visuals[lifetime]
	if state then destroy(state.target); state.target = nil end
	if not position then return end
	state = getVisuals(lifetime)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.Transparency = 0.4
	part.Color = Color3.new(0, 0.333333, 1)
	part.Size = Vector3.new(50, 50, 50)
	part.Position = position
	part.Parent = workspace
	state.target = part
end

function DebugPresentation.SetPath(lifetime: number, groupId: number, positions: {Vector3}?): ()
	local state = visuals[lifetime]
	if state then destroy(state.path); state.path = nil end
	if not positions then return end
	state = getVisuals(lifetime)
	local model = Instance.new("Model")
	model.Name = `Path_{groupId}`
	for index, position in positions do
		local marker = Instance.new("Part")
		marker.Name = `Node_{index}`
		marker.Shape = Enum.PartType.Ball
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Material = Enum.Material.Neon
		marker.Transparency = 0.25
		marker.Color = Color3.new(1, 0.75, 0)
		marker.Size = Vector3.new(8, 8, 8)
		marker.Position = position
		marker.Parent = model
	end
	model.Parent = workspace
	state.path = model
end

function DebugPresentation.CellCreated(lifetime: number, cellId: number, origin: Vector3): ()
	if not DEBUG_CELL_OUTLINES or not RunService:IsServer() then return end
	local state = getVisuals(lifetime)
	destroy(state.cells[cellId])
	state.cells[cellId] = createCellOutline(origin)
end

function DebugPresentation.CellRemoved(lifetime: number, cellId: number): ()
	local state = visuals[lifetime]
	if not state then return end
	destroy(state.cells[cellId])
	state.cells[cellId] = nil
end

function DebugPresentation.GroupRemoved(lifetime: number): ()
	local state = visuals[lifetime]
	if not state then return end
	destroy(state.target)
	destroy(state.path)
	for _, model in state.cells do model:Destroy() end
	visuals[lifetime] = nil
end

return DebugPresentation
