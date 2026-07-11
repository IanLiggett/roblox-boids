--!native
--!strict

--[[ BoidsUpdater
Description:
	Client-side boid renderer. Receives spawn batches and unreliable simulation
	snapshots, instantiates boid models, smooths/extrapolates render state, and
	moves visible boids with Motor6D transforms.

Runtime API:
	NewBoidBatch.OnClientEvent(networkBoidsBatch: NetworkBoidsBatch): creates render models
	BoidJobUpdate.OnClientEvent(boidPacket: BoidPacket, completionTime: number): records snapshots
	DeleteGroup.OnClientEvent(groupId: number): removes rendered group state
	CameraUpdate:FireServer(Camera.CFrame): periodically reports camera position
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
local Camera: Camera = workspace.CurrentCamera :: Camera

-- cursed typechecking client peeking into server
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(game:GetService("ServerScriptService").BoidsSystem.BoidsReplicated)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local NetworkResults = require(BoidsReplicated.NetworkResults)

local Dependencies = BoidsReplicated.Dependencies
local Benchmarkers = require(Dependencies.Benchmarker.Value)

type Benchmarker = Benchmarkers.Benchmarker

type BoidPacket = SharedTypes.BoidPacket
type BoidModel = SharedTypes.BoidModel
type BoidModelName = SharedTypes.BoidModelName
type NetworkBoidsBatch = SharedTypes.NetworkBoidsBatch

local readQuantizedPositionU8 = Quantization.readQuantizedPositionU8
local readQuantizedVelocityU8 = Quantization.readQuantizedVelocityU8

local cameraUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.CameraUpdate
local boidJobUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.BoidJobUpdate
local newBoidBatch: RemoteEvent = BoidsReplicated.Remotes.NewBoidBatch
local deleteGroup: RemoteEvent = BoidsReplicated.Remotes.DeleteGroup

type BoidBody = {
	LinearVelocity:LinearVelocity
} & BasePart

local BoidFolder = Instance.new("Folder")
BoidFolder.Name = "BoidFolder"
BoidFolder.Parent = workspace

local BoidModelsStorage = script.Parent.BoidModels

local boidsByGroup = {}
local groupFolders:{[number]: Folder} = {}

local renderParts: {BasePart} = {}
local renderMotors: {Motor6D} = {}
local renderCFrames: {CFrame} = {}

local renderIndexByBoid: {[number]: number} = {}
local boidIdByRenderIndex: {number} = {}

type Snapshot = {
	time: number,
	position: Vector3,
	velocity: Vector3,
}

type BoidRenderState = {
	a: Snapshot?,
	b: Snapshot?,
	latest: Snapshot?,

	renderPosition: Vector3?,
	renderVelocity: Vector3?,
	
	nextRenderTime: number,
	renderInterval: number,
	
	outOfView: boolean
}

local statesByBoid: {[number]: BoidRenderState} = {}

local U8_SIZE: number = 1
local U16_SIZE: number = 2
local U32_SIZE: number = 4

local POSITION_CORRECTION_GAIN: number = 3
local VELOCITY_CORRECTION_GAIN: number = 2
local MAX_CORRECTION_SPEED: number = 20
local MAX_EXTRAPOLATION: number = 20

local BASE_RENDER_INTERVAL: number = 1/60
local LOD_START: number = 30
local LOD_SCALE: number = 0.06

local CAMERA_UPDATE_INTERVAL: number = 1
local lastCameraUpdate: number = workspace:GetServerTimeNow()

local function safeDirection(v: Vector3):Vector3
	if v.Magnitude > 0.1 then
		return v
	end
	return Vector3.zAxis
end

local function safeLookDirection(v: Vector3): Vector3
	if v.Magnitude > 0.001 then
		return v
	end
	return Vector3.zAxis
end

local function boidJitter(id: number, interval: number): number
	return ((id * 1103515245) % 10000) / 10000 * interval
end

RunService.RenderStepped:Connect(function()
	local now: number = workspace:GetServerTimeNow()
	local dt: number
	
	if now > lastCameraUpdate + CAMERA_UPDATE_INTERVAL then
		lastCameraUpdate = now
		cameraUpdate:FireServer(Camera.CFrame)
	end
	
	local FOVRadDot: number = math.cos(math.rad(Camera.FieldOfView))
	local cameraLookDir: Vector3 = Camera.CFrame.LookVector
	local cameraPosition: Vector3 = Camera.CFrame.Position
	local toBoid: Vector3
		
	local renderPosition: Vector3?, renderVelocity: Vector3?, snapshotAge: number, predictedServerPosition: Vector3, positionError: Vector3, correctionVelocity: Vector3
	local state: BoidRenderState?, boidId: number, latest: Snapshot?
	for index: number, part: BasePart in renderParts do
		boidId = boidIdByRenderIndex[index]
		state = statesByBoid[boidId]		
		if not state then
			continue
		end
		
		latest = state.latest
		if not latest or now < state.nextRenderTime then
			continue
		end
		
		renderPosition = state.renderPosition
		renderVelocity = state.renderVelocity
		if not renderPosition or not renderVelocity then
			renderPosition = latest.position
			renderVelocity = latest.velocity
		end

		snapshotAge = math.clamp(now - latest.time, 0, MAX_EXTRAPOLATION)
		predictedServerPosition = latest.position + latest.velocity * snapshotAge
		
		toBoid = predictedServerPosition - cameraPosition
		if toBoid.Unit:Dot(cameraLookDir) < FOVRadDot then
			state.outOfView = true
			state.renderPosition = predictedServerPosition
			state.renderVelocity = latest.velocity
			state.nextRenderTime = now + BASE_RENDER_INTERVAL

			continue
		end
		
		state.renderInterval = math.max(BASE_RENDER_INTERVAL * (toBoid.Magnitude - LOD_START) * LOD_SCALE, BASE_RENDER_INTERVAL)
		repeat
			state.nextRenderTime += state.renderInterval
		until state.nextRenderTime > now
		
		if state.outOfView then
			state.outOfView = false
			
			-- if implement sparse position updates, use lastupdate for position to calculate predictedserverposition, not just last update, since it may have only included velocity
			
			renderVelocity = latest.velocity
			--renderCFrames[index] = CFrame.lookAt(predictedServerPosition, predictedServerPosition + renderVelocity :: Vector3)
			renderMotors[index].Transform = CFrame.lookAt(predictedServerPosition, predictedServerPosition + safeLookDirection(renderVelocity))
			
			state.renderPosition = predictedServerPosition
			state.renderVelocity = renderVelocity
			
			continue
		end

		positionError = predictedServerPosition - (renderPosition :: Vector3)
		correctionVelocity = positionError * POSITION_CORRECTION_GAIN

		if correctionVelocity.Magnitude > MAX_CORRECTION_SPEED then
			correctionVelocity = correctionVelocity.Unit * MAX_CORRECTION_SPEED
		end

		dt = math.min(state.renderInterval + math.max(now - state.nextRenderTime, 0), MAX_EXTRAPOLATION)
		renderVelocity = (renderVelocity :: Vector3):Lerp(
			latest.velocity + correctionVelocity,
			math.clamp(VELOCITY_CORRECTION_GAIN * dt, 0, 1)
		)
		renderPosition += renderVelocity * dt

		state.renderPosition = renderPosition
		state.renderVelocity = renderVelocity

		renderVelocity = safeLookDirection(renderVelocity)
		
		renderMotors[index].Transform = CFrame.lookAt((renderPosition :: Vector3), (renderPosition :: Vector3) + renderVelocity)
		--renderCFrames[index] = CFrame.lookAt((renderPosition :: Vector3), (renderPosition :: Vector3) + renderVelocity)
	end

	--workspace:BulkMoveTo(
	--	renderParts :: {Instance},
	--	renderCFrames,
	--	Enum.BulkMoveMode.FireCFrameChanged
	--)
end)

local snapshotIntervalStats: Benchmarker = Benchmarkers.newBenchmarker(10000)
local packetIntervalStats: Benchmarker = Benchmarkers.newBenchmarker(2000)
local boidsPerPacketStats: Benchmarker = Benchmarkers.newBenchmarker(2000)
local bytesPerPacketStats: Benchmarker = Benchmarkers.newBenchmarker(2000)

local bytesPerSecondStats: Benchmarker = Benchmarkers.newBenchmarker(120)
local boidRowsPerSecondStats: Benchmarker = Benchmarkers.newBenchmarker(120)

local SNAPSHOT_SAMPLE_MOD = 8

local function shouldSampleBoid(boidId: number): boolean
	return boidId % SNAPSHOT_SAMPLE_MOD == 0
end

local function pushSnapshot(boidId: number, serverTime: number, position: Vector3, velocity: Vector3)
	local state = statesByBoid[boidId]
	if not state then
		return
	end

	local latest = state.latest
	if latest and serverTime <= latest.time then
		return
	end

	state.a = latest
	state.b = {
		time = serverTime,
		position = position,
		velocity = velocity,
	}
	state.latest = state.b
	
	--renderCFrames[boidId] = CFrame.lookAt(position, position + velocity)
end

local lastSnapshotTimeByBoid:{[number]: number} = {}

local function auditBoidUpdateFrequency()
	local now: number = workspace:GetServerTimeNow()
	
	local total: number = 0
	local staleCount: number = 0
	
	local avg: number = 0
	local min: number = 0
	local max: number = 0
	
	local dt: number
	for _, snapshotTime: number in lastSnapshotTimeByBoid do
		dt = now - snapshotTime
		if dt > MAX_EXTRAPOLATION then
			staleCount += 1
		end
		if dt > max then
			max = dt
		end
		if dt < min then
			min = dt
		end
		avg += dt
		total += 1
	end
	avg /= total
	
	local msg: string = `CLIENT BOIDS: {total} | STALE: {staleCount} | AVG: {avg} | MIN: {min} | MAX: {max}`
	if staleCount > 0 then
		warn(msg)
	else
		print(msg)
	end
end

local lastPacketReceiveTime: number
local bytesThisSecond: number, boidRowsThisSecond: number = 0, 0
boidJobUpdate.OnClientEvent:Connect(function(boidPacket: BoidPacket, completionTime: number)
	local receiveTime: number = workspace:GetServerTimeNow()
	
	if lastPacketReceiveTime then
		Benchmarkers.push(packetIntervalStats, (receiveTime - lastPacketReceiveTime) * 1000)
	end
	lastPacketReceiveTime = receiveTime
	
	local packetBoidCount: number = 0
	
	local packetBytes: number = buffer.len(boidPacket)
	bytesThisSecond += packetBytes
	Benchmarkers.push(bytesPerPacketStats, packetBytes)
	
	local origin: Vector3, boidCount:number
	local boidId: number, lastTime:number
	for offset: number, ox: number, oy: number, oz: number, boidCount: number in NetworkResults.forEachCellHeader(boidPacket) :: any do
		packetBoidCount += boidCount
		
		origin = Vector3.new(ox, oy, oz)
		for boidId: number, px: number, py: number, pz: number, vx: number, vy: number, vz: number in NetworkResults.forEachBoid(boidPacket, offset, boidCount) :: any do
			lastTime = lastSnapshotTimeByBoid[boidId]
			if lastTime and completionTime <= lastTime then
				continue
			end
			lastSnapshotTimeByBoid[boidId] = completionTime

			if shouldSampleBoid(boidId) then
				Benchmarkers.push(snapshotIntervalStats, completionTime - lastTime)
			end

			pushSnapshot(
				boidId,
				completionTime,
				origin + Vector3.new(px, py, pz),
				Vector3.new(vx, vy, vz)
			)
		end
	end
	
	boidRowsThisSecond += packetBoidCount
	Benchmarkers.push(boidsPerPacketStats, packetBoidCount)
end)

local nextRenderPartIndex = 1

local function registerBoid(boidId: number, boid: Model | BasePart, now: number, motor: Motor6D)
	local part: BasePart

	if boid:IsA("Model") then
		part = boid.PrimaryPart :: BasePart
	else
		part = boid
	end
	--part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	
	local index:number = nextRenderPartIndex
	renderParts[index] = part
	renderMotors[index] = motor
	renderCFrames[index] = part.CFrame
	
	lastSnapshotTimeByBoid[boidId] = now
	renderIndexByBoid[boidId] = index
	boidIdByRenderIndex[index] = boidId
	
	statesByBoid[boidId] = {
		a = nil,
		b = nil,
		latest = nil,

		renderPosition = nil,
		renderVelocity = nil,
		
		nextRenderTime = now + boidJitter(boidId, BASE_RENDER_INTERVAL),
		renderInterval = BASE_RENDER_INTERVAL,
		
		outOfView = false
	}
	--print(`Boid registered at time {statesByBoid[boidId].lastRenderTime}`)
	
	nextRenderPartIndex += 1
end

local function unregisterBoid(boidId: number)
	local index = renderIndexByBoid[boidId]
	if not index then
		return
	end
	
	local lastIndex = #renderParts
	local lastPart = renderParts[lastIndex]
	local lastBoidId = boidIdByRenderIndex[lastIndex]

	renderParts[index] = lastPart
	renderMotors[index] = renderMotors[lastIndex]
	renderCFrames[index] = renderCFrames[lastIndex]
	boidIdByRenderIndex[index] = lastBoidId

	if lastBoidId then
		renderIndexByBoid[lastBoidId] = index
	end

	renderParts[lastIndex] = nil
	renderMotors[lastIndex] = nil
	renderCFrames[lastIndex] = nil
	boidIdByRenderIndex[lastIndex] = nil

	renderIndexByBoid[boidId] = nil
	statesByBoid[boidId] = nil
	
	nextRenderPartIndex -= 1
end

local groupColors = {}

local totalBoidsRegistered = 0

local shenanigansPart: Part = Instance.new("Part")
shenanigansPart.Anchored = true
shenanigansPart.Transparency = 1
shenanigansPart.CanCollide = false
shenanigansPart.CanQuery = false
shenanigansPart.CanTouch = false
shenanigansPart.Position = Vector3.zero
shenanigansPart.Parent = workspace

-- reconsider system structure to allow client access to this type
-- client doesn't necessarily need behavior from BoidBatches, so moving it to replicated storage probably isn't best
-- could put the type in utility, but is it worth having the type if you don't want any behavior attached?
-- not sure
-- could include behavior purely for reading buffer so that assumption of boid id size here isn't required
newBoidBatch.OnClientEvent:Connect(function(networkBoidsBatch:NetworkBoidsBatch)
	local boidCount:number = networkBoidsBatch.boidCount
	local groupId:number = networkBoidsBatch.groupId
	local boidModels: buffer = networkBoidsBatch.boidModels
	local boidIds:buffer = networkBoidsBatch.boidIds
	
	if not groupColors[groupId] then
		groupColors[groupId] = Color3.new(math.random(), math.random(), math.random())
	end
	
	--print(`Got batch for group {groupId} with {boidCount} boids`)
	
	local groupTracker:{[number]:Model | BasePart} = boidsByGroup[groupId]
	local groupFolder = groupFolders[groupId]
	if not groupTracker then
		groupTracker = {}
		boidsByGroup[groupId] = groupTracker
		
		groupFolder = Instance.new("Folder")
		groupFolder.Name = "Boids-" .. tostring(groupId)
		groupFolder.Parent = BoidFolder
		
		groupFolders[groupId] = groupFolder
	end
	
	local now: number = workspace:GetServerTimeNow()
	
	local newBoidModel:(Model | BasePart)
	local boidId:number, boid:Model | BasePart
	for i = 0, boidCount - 1 do
		boidId = buffer.readu16(boidIds, i * 2)
		
		newBoidModel = BoidModelsStorage:FindFirstChild(SharedTypes.BoidModelNames[buffer.readu8(boidModels, i)]) :: any
		
		newBoidModel = newBoidModel:Clone()
		newBoidModel.Color = groupColors[groupId]
		newBoidModel.Parent = groupFolder
		
		local motor: Motor6D = Instance.new("Motor6D")
		motor.MaxVelocity = 100000
		motor.Part0 = shenanigansPart
		motor.Part1 = newBoidModel
		motor.Name = "shenanigans"
		motor.Parent = shenanigansPart
		
		registerBoid(boidId, newBoidModel, now, motor)
	end
	
	totalBoidsRegistered += boidCount
	
	print(`Client has registered {totalBoidsRegistered} boids`)
end)

deleteGroup.OnClientEvent:Connect(function(groupId)
	--print(`Deleting {groupId}`)
	
	local groupFolder:Folder? = groupFolders[groupId]
	if groupFolder then
		for boidId, _ in boidsByGroup[groupId] or {} do
			unregisterBoid(boidId)
		end
		
		groupFolders[groupId] = nil
		groupFolder:Destroy()
	end
	
	boidsByGroup[groupId] = nil
end)

local statsAccum: number = 0
RunService.Heartbeat:Connect(function(dt)
	statsAccum += dt

	if statsAccum < 1 then
		return
	end

	Benchmarkers.push(bytesPerSecondStats, bytesThisSecond)
	Benchmarkers.push(boidRowsPerSecondStats, boidRowsThisSecond)

	bytesThisSecond = 0
	boidRowsThisSecond = 0
	statsAccum = 0
end)


local function hzFromMs(ms: number): number
	if ms <= 0 then
		return 0
	end

	return 1000 / ms
end

local function printStats()
	print(`BOID UPDATE INTERVALS: s`)
	Benchmarkers.printStats(snapshotIntervalStats)
	
	print(`PACKET INTERVALS: ms`)
	Benchmarkers.printStats(packetIntervalStats)
	
	print(`BOIDS PER PACKET:`)
	Benchmarkers.printStats(boidsPerPacketStats)
	
	print(`BYTES PER PACKET:`)
	Benchmarkers.printStats(bytesPerPacketStats)
	
	print(`BYTES PER SECOND:`)
	Benchmarkers.printStats(bytesPerSecondStats)
	
	print(`BOIDS UPDATED PER SECOND:`)
	Benchmarkers.printStats(boidRowsPerSecondStats)
	
	--local avgSnapshotMs = Benchmarkers.getAvg(snapshotIntervalStats)
	--local medSnapshotMs = Benchmarkers.getMed(snapshotIntervalStats)
	
	--print(
	--	("\nBOID SNAPSHOT INTERVAL\n" ..
	--		"avg: %.1f ms / %.2f Hz\n" ..
	--		"med: %.1f ms / %.2f Hz\n" ..
	--		"min: %.1f ms\n" ..
	--		"max: %.1f ms\n" ..
	--		"sd: %.1f ms")
	--		:format(
	--			avgSnapshotMs,
	--			hzFromMs(avgSnapshotMs),
	--			medSnapshotMs,
	--			hzFromMs(medSnapshotMs),
	--			Benchmarkers.getMin(snapshotIntervalStats) or 0,
	--			Benchmarkers.getMax(snapshotIntervalStats) or 0,
	--			Benchmarkers.getSD(snapshotIntervalStats)
	--		)
	--)

	--print(
	--	("\nPACKETS\n" ..
	--		"packet interval avg: %.1f ms / %.2f Hz\n" ..
	--		"boids per packet avg: %.1f\n" ..
	--		"bytes per packet avg: %.1f\n" ..
	--		"bytes/sec avg: %.1f\n" ..
	--		"boid rows/sec avg: %.1f")
	--		:format(
	--			Benchmarkers.getAvg(packetIntervalStats),
	--			hzFromMs(Benchmarkers.getAvg(packetIntervalStats)),
	--			Benchmarkers.getAvg(boidsPerPacketStats),
	--			Benchmarkers.getAvg(bytesPerPacketStats),
	--			Benchmarkers.getAvg(bytesPerSecondStats),
	--			Benchmarkers.getAvg(boidRowsPerSecondStats)
	--		)
	--)
end

task.spawn(function()
	while task.wait(5) do
		--printStats()
	end
end)
