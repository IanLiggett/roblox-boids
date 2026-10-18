--!strict
-- Catalog-owned world resources and recurring target work, not simulation state.
local Fixtures = {}
local owned: {[Folder]: boolean} = {}
local generation = 0
local POLAR_SPHERE_CENTER = Vector3.new(150, 0, 0)
local POLAR_SPHERE_RADIUS = 100
local POLAR_SPHERE_OPENING_RADIUS = 40

local function createPolarSphereObstacleCourse(): ()
	local existingCourse = workspace:FindFirstChild("BoidPolarSphereCourse")
	if existingCourse then
		existingCourse:Destroy()
	end

	local course = Instance.new("Folder")
	course.Name = "BoidPolarSphereCourse"
	course.Parent = workspace
	owned[course] = true
	course.Destroying:Once(function() owned[course] = nil end)

	-- Overlapping tangent panels approximate a hollow, raycastable shell while
	-- leaving the two polar caps open.
	local latitudeSegments = 20
	local longitudeSegments = 40
	local latitudeStep = math.pi / latitudeSegments
	local longitudeStep = math.pi * 2 / longitudeSegments
	local panelOverlap = 2
	local panelThickness = 8
	local openingAngle = math.asin(POLAR_SPHERE_OPENING_RADIUS / POLAR_SPHERE_RADIUS)
	local color = Color3.fromRGB(90, 105, 130)

	for latitudeIndex = 1, latitudeSegments do
		local latitudeStart = (latitudeIndex - 1) * latitudeStep
		local latitudeEnd = latitudeIndex * latitudeStep
		if latitudeEnd <= openingAngle or latitudeStart >= math.pi - openingAngle then
			continue
		end

		local latitude = (latitudeStart + latitudeEnd) * 0.5
		local latitudeWidth = 2 * POLAR_SPHERE_RADIUS * math.sin(latitudeStep * 0.5) + panelOverlap
		for longitudeIndex = 0, longitudeSegments - 1 do
			local longitude = (longitudeIndex + 0.5) * longitudeStep
			local sinLatitude = math.sin(latitude)
			local radial = Vector3.new(
				sinLatitude * math.cos(longitude),
				math.cos(latitude),
				sinLatitude * math.sin(longitude)
			)
			local tangentLongitude = Vector3.new(-math.sin(longitude), 0, math.cos(longitude))
			local tangentLatitude = Vector3.new(
				math.cos(latitude) * math.cos(longitude),
				-sinLatitude,
				math.cos(latitude) * math.sin(longitude)
			)
			local longitudeWidth = 2 * POLAR_SPHERE_RADIUS * sinLatitude * math.sin(longitudeStep * 0.5) + panelOverlap
			local halfDiagonal = 0.5 * math.sqrt(longitudeWidth * longitudeWidth + latitudeWidth * latitudeWidth)
			local radialInset = POLAR_SPHERE_RADIUS - math.sqrt(
				POLAR_SPHERE_RADIUS * POLAR_SPHERE_RADIUS - halfDiagonal * halfDiagonal
			)
			local panel = Instance.new("Part")
			panel.Name = string.format("Panel_%02d_%02d", latitudeIndex, longitudeIndex + 1)
			panel.Anchored = true
			panel.CanCollide = true
			panel.CanQuery = true
			panel.CanTouch = false
			panel.Material = Enum.Material.Concrete
			panel.Color = color
			panel.Transparency = 0.7
			panel.Size = Vector3.new(longitudeWidth, latitudeWidth, panelThickness)
			panel.CFrame = CFrame.fromMatrix(
				POLAR_SPHERE_CENTER + radial * (POLAR_SPHERE_RADIUS - radialInset),
				tangentLongitude,
				tangentLatitude,
				radial
			)
			panel.Parent = course
		end
	end
end

local function createObstacleAvoidanceCourse(): ()
	local existingCourse = workspace:FindFirstChild("BoidObstacleAvoidanceCourse")
	if existingCourse then
		existingCourse:Destroy()
	end

	local course = Instance.new("Folder")
	course.Name = "BoidObstacleAvoidanceCourse"
	course.Parent = workspace
	owned[course] = true
	course.Destroying:Once(function() owned[course] = nil end)

	local function addObstacle(name: string, position: Vector3, size: Vector3): ()
		local obstacle = Instance.new("Part")
		obstacle.Name = name
		obstacle.Anchored = true
		obstacle.CanCollide = true
		obstacle.CanQuery = true
		obstacle.CanTouch = false
		obstacle.Material = Enum.Material.Concrete
		obstacle.Color = Color3.fromRGB(90, 95, 110)
		obstacle.Position = position
		obstacle.Size = size
		obstacle.Parent = course
	end

	addObstacle("BroadWall", Vector3.new(0, 100, 0), Vector3.new(12, 100, 180))
	addObstacle("CornerWall", Vector3.new(240, 0, 0), Vector3.new(12, 100, 180))
	addObstacle("CornerReturn", Vector3.new(300, 0, 84), Vector3.new(120, 100, 12))
	addObstacle("GapLower", Vector3.new(500, 0, -55), Vector3.new(12, 100, 90))
	addObstacle("GapUpper", Vector3.new(500, 0, 55), Vector3.new(12, 100, 90))
end


local RANDOM_TARGET_GROUP_COUNT = 10
local RANDOM_TARGET_BOIDS_PER_GROUP = 2000
local RANDOM_TARGET_BOX_HALF_EXTENT = 250
local RANDOM_TARGET_INTERVAL = 15

local randomTargetStressRng = Random.new(20001)

local function nextRandomTargetPosition(rng: Random): Vector3
	return Vector3.new(
		rng:NextNumber(-RANDOM_TARGET_BOX_HALF_EXTENT, RANDOM_TARGET_BOX_HALF_EXTENT),
		rng:NextNumber(-RANDOM_TARGET_BOX_HALF_EXTENT, RANDOM_TARGET_BOX_HALF_EXTENT),
		rng:NextNumber(-RANDOM_TARGET_BOX_HALF_EXTENT, RANDOM_TARGET_BOX_HALF_EXTENT)
	)
end


function Fixtures.CreateRandomTargets(): {BasePart}
 local ownedGeneration = generation
		local existingFolder = workspace:FindFirstChild("RandomTargetStressTargets")
		if existingFolder then
			existingFolder:Destroy()
		end

		local targetFolder = Instance.new("Folder")
		targetFolder.Name = "RandomTargetStressTargets"
		targetFolder.Parent = workspace
		owned[targetFolder] = true
        targetFolder.Destroying:Once(function() owned[targetFolder] = nil end)
        local targets: {BasePart} = {}
		for index = 1, RANDOM_TARGET_GROUP_COUNT do
			local target = Instance.new("Part")
			target.Name = "Target_" .. index
			target.Shape = Enum.PartType.Ball
			target.Anchored = true
			target.CanCollide = false
			target.CanTouch = false
			target.CanQuery = false
			target.Material = Enum.Material.Neon
			target.Transparency = 0.2
			target.Size = Vector3.new(10, 10, 10)
			target.Color = Color3.fromHSV((index - 1) / RANDOM_TARGET_GROUP_COUNT, 0.8, 1)
			target.Position = nextRandomTargetPosition(randomTargetStressRng)
			target.Parent = targetFolder

            targets[index] = target
        end
		task.spawn(function()
			while generation == ownedGeneration and owned[targetFolder] and targetFolder.Parent == workspace do
				task.wait(RANDOM_TARGET_INTERVAL)
				if generation ~= ownedGeneration or not owned[targetFolder] or targetFolder.Parent ~= workspace then
					break
				end

				for _, target: BasePart in targetFolder:GetChildren() do
					target.Position = nextRandomTargetPosition(randomTargetStressRng)
				end
			end
		end)

 return targets
end
function Fixtures.Stop(): ()
 generation += 1
 for folder in owned do
  owned[folder] = nil
  folder:Destroy()
 end
end
Fixtures.CreatePolarSphere = createPolarSphereObstacleCourse
Fixtures.CreateObstacleCourse = createObstacleAvoidanceCourse
return Fixtures
