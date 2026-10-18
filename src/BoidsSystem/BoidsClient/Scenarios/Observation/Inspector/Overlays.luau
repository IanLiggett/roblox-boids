--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SharedTypes = require(ReplicatedStorage:WaitForChild("BoidsReplicated").SharedTypes)
local Renderer = require(script.Parent.Parent.Parent.Parent.BoidsRenderer)
local Overlays = {}
export type ObstacleLayers = { showProbes: boolean, showCandidates: boolean, showMovement: boolean }
type Item = SphereHandleAdornment | LineHandleAdornment
type ItemClass = "SphereHandleAdornment" | "LineHandleAdornment"
local folder: Folder? = nil
local anchor: Part? = nil
local pools: {[ItemClass]: {Item}} = {}
local used: {[ItemClass]: number} = {}
local labels: {BillboardGui} = {}
local labelUsed = 0
local total = 0
local missing = 0
local truncated = false
local LIMIT = 512
type ObstacleCache = {
	boidId: number, generation: number, jobOrder: number, layerKey: number,
	used: {[ItemClass]: number}, labelCount: number, total: number, isTruncated: boolean,
}
local obstacleCache: ObstacleCache? = nil

local function item(className: ItemClass, color: Color3, transparency: number): Item?
	if total >= LIMIT then
		truncated = true
		return nil
	end
	total += 1
	local pool: {Item}? = pools[className]
	if not pool then
		pool = {}
		pools[className] = pool
	end
	local index = (used[className] or 0) + 1
	used[className] = index
	local cached: Item? = (pool :: {Item})[index]
	local value: Item = cached or (if className == "SphereHandleAdornment" then Instance.new("SphereHandleAdornment") else Instance.new("LineHandleAdornment"))
	if not cached then
		value.Adornee = anchor :: Part
		value.AlwaysOnTop = true
		value.ZIndex = 1
		value.Parent = folder
		;(pool :: {Item})[index] = value
	end
	if not value.Visible then value.Visible = true end
	if value.Color3 ~= color then value.Color3 = color end
	if value.Transparency ~= transparency then value.Transparency = transparency end
	return value
end

local function sphere(position: Vector3, radius: number, color: Color3, transparency: number): ()
	local value: SphereHandleAdornment? = item("SphereHandleAdornment", color, transparency) :: SphereHandleAdornment?
	if value then
		local cframe: CFrame = CFrame.new(position)
		local size = math.max(radius, 0.1)
		if value.CFrame ~= cframe then value.CFrame = cframe end
		if value.Radius ~= size then value.Radius = size end
	end
end

local function line(a: Vector3, b: Vector3, color: Color3, thickness: number): ()
	if (b - a).Magnitude < 0.001 then return end
	local value: LineHandleAdornment? = item("LineHandleAdornment", color, 0) :: LineHandleAdornment?
	if value then
		local cframe: CFrame = CFrame.lookAt(a, b)
		local length = (b - a).Magnitude
		if value.CFrame ~= cframe then value.CFrame = cframe end
		if value.Length ~= length then value.Length = length end
		if value.Thickness ~= thickness then value.Thickness = thickness end
	end
end

local CYAN: Color3 = Color3.fromRGB(80, 220, 255)
local RED: Color3 = Color3.fromRGB(255, 90, 90)
local GREEN: Color3 = Color3.fromRGB(90, 255, 130)
local GRAY: Color3 = Color3.fromRGB(155, 165, 180)
local MAGENTA: Color3 = Color3.fromRGB(255, 100, 230)
local AMBER: Color3 = Color3.fromRGB(255, 190, 65)

local function worldLabel(position: Vector3, text: string, color: Color3): ()
	if total >= LIMIT then
		truncated = true
		return
	end
	total += 1
	labelUsed += 1
	local gui: BillboardGui? = labels[labelUsed]
	if not gui then
		gui = Instance.new("BillboardGui")
		gui.Name = "DecisionLabel"
		gui.Adornee = anchor :: Part
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(220, 32)
		gui.Parent = folder
		local textLabel: TextLabel = Instance.new("TextLabel")
		textLabel.Name = "Text"
		textLabel.Size = UDim2.fromScale(1, 1)
		textLabel.BackgroundTransparency = 1
		textLabel.Font = Enum.Font.Code
		textLabel.TextSize = 12
		textLabel.TextStrokeTransparency = 0.2
		textLabel.Parent = gui
		labels[labelUsed] = gui
	end
	;(gui :: BillboardGui).Enabled = true
	;(gui :: BillboardGui).StudsOffsetWorldSpace = position
	local textLabel: TextLabel = (gui :: BillboardGui & {Text: TextLabel}).Text
	textLabel.Text, textLabel.TextColor3 = text, color
end

local function arrow(origin: Vector3, vector: Vector3, color: Color3, name: string): ()
	if vector.Magnitude <= 0.001 then return end
	local tip: Vector3 = origin + vector
	local direction: Vector3 = vector.Unit
	local side: Vector3 = direction:Cross(Vector3.yAxis)
	if side.Magnitude < 0.01 then side = direction:Cross(Vector3.xAxis) end
	side = side.Unit * math.min(2, vector.Magnitude * 0.15)
	local head: Vector3 = direction * math.min(4, vector.Magnitude * 0.3)
	line(origin, tip, color, 3)
	line(tip, tip - head + side, color, 3)
	line(tip, tip - head - side, color, 3)
	worldLabel(tip, name, color)
end

local function drawObstacle(value: SharedTypes.ObstacleObservation, layers: ObstacleLayers): ()
	local origin: Vector3 = value.position
	sphere(origin, 0.8, CYAN, 0.2)
	for _, probe in value.probes do
		local isCandidate = probe.candidateIndex ~= nil
		if (isCandidate and not layers.showCandidates) or (not isCandidate and not layers.showProbes) then continue end
		local candidate: SharedTypes.ObstacleCandidate? = if probe.candidateIndex then value.candidates[probe.candidateIndex] else nil
		local color: Color3 = if candidate then (if candidate.isSelected then GREEN elseif candidate.isEligible then CYAN else GRAY) else CYAN
		line(probe.origin, probe.origin + probe.vector, color, if candidate and candidate.isSelected then 5 else 2)
		local name = if candidate then "#" .. candidate.index .. (if candidate.isSelected then " SELECTED" elseif candidate.isEligible then " eligible" else " rejected") else probe.role
		worldLabel(probe.origin + probe.vector.Unit * math.min(probe.vector.Magnitude, 18) + Vector3.yAxis * 2,
			name .. (if probe.didHit then " | hit" else " | clear"), color)
		if probe.hitPosition and probe.hitNormal then
			sphere(probe.hitPosition, 0.8, RED, 0.1)
			line(probe.hitPosition, probe.hitPosition + probe.hitNormal * 6, RED, 3)
		end
		local threshold = if probe.role == "Heading" then value.requiredClearance elseif probe.role == "Target" then value.lookAhead else nil
		if threshold and threshold <= probe.vector.Magnitude and probe.vector.Magnitude > 0.001 then
			local marker: Vector3 = probe.origin + probe.vector.Unit * threshold
			sphere(marker, 0.7, AMBER, 0.1)
			worldLabel(marker, if probe.role == "Heading" then "travel + margin" else "release horizon", AMBER)
		end
	end
	if layers.showMovement then
		arrow(origin, value.targetDirection * 18, CYAN, "preferred target")
		arrow(origin, value.committedBefore * 14, GRAY, "detour before")
		arrow(origin, value.committedAfter * 24, MAGENTA, "detour after")
		arrow(origin, value.displacement, GREEN, string.format("result %.2f studs", value.displacement.Magnitude))
		local soft: Vector3 = value.softAcceleration
		if soft.Magnitude > 0.001 then
			arrow(origin, soft.Unit * math.min(soft.Magnitude, 25), AMBER, string.format("soft accel %.2f (scaled)", soft.Magnitude))
		end
	end
	if string.find(value.reason, "Fallback", 1, true) then worldLabel(origin + Vector3.yAxis * 5, value.reason, AMBER) end
end

function Overlays.Start(): ()
	if folder then return end
	local createdFolder: Folder = Instance.new("Folder")
	createdFolder.Name = "BoidsObservationOverlays"
	createdFolder.Parent = workspace
	folder = createdFolder
	local createdAnchor: Part = Instance.new("Part")
	createdAnchor.Name = "AdornmentAnchor"
	createdAnchor.Anchored = true
	createdAnchor.CanCollide = false
	createdAnchor.CanTouch = false
	createdAnchor.CanQuery = false
	createdAnchor.Transparency = 1
	createdAnchor.Size = Vector3.one
	createdAnchor.CFrame = CFrame.identity
	createdAnchor.Parent = createdFolder
	anchor = createdAnchor
end

function Overlays.Update(rendered: Renderer.RenderedBoidState?, groupColor: Color3?, groupState: SharedTypes.GroupObservation?, showSelection: boolean, showGroup: boolean, obstacle: SharedTypes.ObstacleObservation?, obstacleLayers: ObstacleLayers?): string
	if not folder then return "Overlays inactive" end
	table.clear(used)
	total, missing, truncated, labelUsed = 0, 0, false, 0
	if obstacle and obstacleLayers then
		local layerKey = (if obstacleLayers.showProbes then 1 else 0)
			+ (if obstacleLayers.showCandidates then 2 else 0) + (if obstacleLayers.showMovement then 4 else 0)
		local cached: ObstacleCache? = obstacleCache
		if cached and cached.boidId == obstacle.boidId and cached.generation == obstacle.generation
			and cached.jobOrder == obstacle.jobOrder and cached.layerKey == layerKey then
			-- Captured geometry occupies the leading pool slots; moving selection/group visuals follow it.
			for className, count in cached.used do used[className] = count end
			total, labelUsed, truncated = cached.total, cached.labelCount, cached.isTruncated
		else
			drawObstacle(obstacle, obstacleLayers)
			obstacleCache = {
				boidId = obstacle.boidId, generation = obstacle.generation, jobOrder = obstacle.jobOrder,
				layerKey = layerKey, used = table.clone(used), labelCount = labelUsed,
				total = total, isTruncated = truncated,
			}
		end
	else
		obstacleCache = nil
	end
	if showSelection and rendered and rendered.isRendered then
		local position: Vector3 = rendered.cframe.Position
		sphere(position, 3, Color3.new(1, 1, 0), 0.35)
		local velocity: Vector3 = rendered.velocity
		if velocity.Magnitude > 0.001 then
			local tip: Vector3 = position + velocity.Unit * math.clamp(velocity.Magnitude, 4, 80)
			local right: Vector3 = velocity.Unit:Cross(Vector3.yAxis)
			if right.Magnitude < 0.01 then right = velocity.Unit:Cross(Vector3.xAxis) end
			right = right.Unit
			line(position, tip, Color3.new(1, 1, 0), 3)
			line(tip, tip - velocity.Unit * 4 + right * 2, Color3.new(1, 1, 0), 3)
			line(tip, tip - velocity.Unit * 4 - right * 2, Color3.new(1, 1, 0), 3)
		end
	end
	if showGroup and groupColor and groupState then
		local color: Color3 = groupColor
		local previous: Vector3? = nil
		local first: Vector3? = nil
		missing = groupState.unavailableCount
		for _, node in groupState.path do
			local position: Vector3? = node.position
			if position then
				sphere(position, groupState.pathArrivalRadius, color, 0.93)
				if previous then line(previous, position, color, 2) end
				if not first then first = position end
				previous = position
			else
				previous = nil
			end
		end
		if groupState.loops and groupState.unavailableCount == 0 and previous and first then line(previous, first, color, 2) end
		if groupState.target then sphere(groupState.target, 4, color, 0.25) end
		for _, well in groupState.gravityWells do
			sphere(well.position, well.influenceRadius, if well.strength >= 0 then Color3.new(0.4, 0.4, 1) else Color3.new(1, 0.3, 0.3), 0.94)
		end
	end
	for className, pool in pools do
		for i = (used[className] or 0) + 1, #pool do
			if pool[i].Visible then pool[i].Visible = false end
		end
	end
	for index = labelUsed + 1, #labels do
		if labels[index].Enabled then labels[index].Enabled = false end
	end
	return string.format("Runtime overlays: %d items%s%s", total,
		if missing > 0 then string.format(" | %d unavailable references", missing) else "",
		if truncated then " | 512-item limit" else "")
end

function Overlays.Stop(): ()
	if folder then
		folder:Destroy()
		folder = nil
	end
	anchor = nil
	obstacleCache = nil
	table.clear(pools)
	table.clear(labels)
	table.clear(used)
end

return Overlays
