--!native
--!strict
-- Actor-local packed presentation math. No runtime startup or Instance writes.
local Kernel = {}

local F32_SIZE: number = 4
local F64_SIZE: number = 8

local STATE_LATEST_TIME_OFFSET: number = 0
local STATE_LATEST_PX_OFFSET: number = STATE_LATEST_TIME_OFFSET + F64_SIZE
local STATE_LATEST_PY_OFFSET: number = STATE_LATEST_PX_OFFSET + F32_SIZE
local STATE_LATEST_PZ_OFFSET: number = STATE_LATEST_PY_OFFSET + F32_SIZE
local STATE_LATEST_VX_OFFSET: number = STATE_LATEST_PZ_OFFSET + F32_SIZE
local STATE_LATEST_VY_OFFSET: number = STATE_LATEST_VX_OFFSET + F32_SIZE
local STATE_LATEST_VZ_OFFSET: number = STATE_LATEST_VY_OFFSET + F32_SIZE

local STATE_RENDER_PX_OFFSET: number = STATE_LATEST_VZ_OFFSET + F32_SIZE
local STATE_RENDER_PY_OFFSET: number = STATE_RENDER_PX_OFFSET + F32_SIZE
local STATE_RENDER_PZ_OFFSET: number = STATE_RENDER_PY_OFFSET + F32_SIZE
local STATE_RENDER_VX_OFFSET: number = STATE_RENDER_PZ_OFFSET + F32_SIZE
local STATE_RENDER_VY_OFFSET: number = STATE_RENDER_VX_OFFSET + F32_SIZE
local STATE_RENDER_VZ_OFFSET: number = STATE_RENDER_VY_OFFSET + F32_SIZE

local STATE_NEXT_RENDER_TIME_OFFSET: number = STATE_RENDER_VZ_OFFSET + F32_SIZE
local STATE_RENDER_INTERVAL_OFFSET: number = STATE_NEXT_RENDER_TIME_OFFSET + F64_SIZE
local STATE_LAST_NETWORK_INTERVAL_OFFSET: number = STATE_RENDER_INTERVAL_OFFSET + F32_SIZE
local STATE_FLAGS_OFFSET: number = STATE_LAST_NETWORK_INTERVAL_OFFSET + F32_SIZE
-- Keep the facing vector f32-aligned after the flags byte and its padding.
local STATE_FACING_X_OFFSET: number = STATE_FLAGS_OFFSET + F32_SIZE
local STATE_FACING_Y_OFFSET: number = STATE_FACING_X_OFFSET + F32_SIZE
local STATE_FACING_Z_OFFSET: number = STATE_FACING_Y_OFFSET + F32_SIZE
local RENDER_STATE_ROW_BYTES: number = 96

local STATE_HAS_LATEST: number = 1
local STATE_HAS_RENDER: number = 2
local STATE_HAS_LAST_NETWORK_INTERVAL: number = 8


local function stateOffset(index: number): number
	return (index - 1) * RENDER_STATE_ROW_BYTES
end

-- Smooth authoritative corrections over much of a boid's expected update interval.
-- Extrapolation remains capped below, so a stale snapshot cannot make the render
-- state drift without bound.
local POSITION_CORRECTION_HALF_LIFE: number = 0.75
local NETWORK_INTERVAL_CORRECTION_RATIO: number = 0.75
local MAX_POSITION_CORRECTION_HALF_LIFE: number = 6
-- Facing follows the already-smoothed render trajectory, not the new snapshot velocity.
local ORIENTATION_CORRECTION_HALF_LIFE: number = 0.1 --1
local SNAP_DISTANCE: number = 0.05
local SNAP_DISTANCE_SQUARED: number = SNAP_DISTANCE * SNAP_DISTANCE
local MAX_EXTRAPOLATION: number = 24

local function exponentialDecayAlpha(dt: number, halfLife: number): number
	if halfLife <= 0 then
		return 0
	end

	return 0.5 ^ (dt / halfLife)
end

function Kernel.Init(renderStateBuffer: buffer, index: number, now: number): ()

	local offset: number = stateOffset(index)
	buffer.writef64(renderStateBuffer, offset + STATE_LATEST_TIME_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_PX_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_PY_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_PZ_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_VX_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_VY_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LATEST_VZ_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PX_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PY_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PZ_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VX_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VY_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VZ_OFFSET, 0)
	buffer.writef64(renderStateBuffer, offset + STATE_NEXT_RENDER_TIME_OFFSET, now)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_INTERVAL_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_LAST_NETWORK_INTERVAL_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_FACING_X_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_FACING_Y_OFFSET, 0)
	buffer.writef32(renderStateBuffer, offset + STATE_FACING_Z_OFFSET, 0)
	buffer.writeu8(renderStateBuffer, offset + STATE_FLAGS_OFFSET, 0)
end

local function writeNewState(renderStateBuffer: buffer, offset: number, renderPx: number, renderPy: number, renderPz: number, renderVx: number, renderVy: number, renderVz: number, flags: number): ()
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PX_OFFSET, renderPx)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PY_OFFSET, renderPy)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_PZ_OFFSET, renderPz)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VX_OFFSET, renderVx)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VY_OFFSET, renderVy)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_VZ_OFFSET, renderVz)
	buffer.writeu8(renderStateBuffer, offset + STATE_FLAGS_OFFSET, flags)
end

function Kernel.Step(renderStateBuffer: buffer, index: number, now: number): CFrame?
	local offset: number = stateOffset(index)
	local flags: number = buffer.readu8(renderStateBuffer, offset + STATE_FLAGS_OFFSET)
	if bit32.band(flags, STATE_HAS_LATEST) == 0 then
		return nil
	end

	local lastRenderTime: number = buffer.readf64(renderStateBuffer, offset + STATE_NEXT_RENDER_TIME_OFFSET)
	local dt: number = math.min(math.max(0, now - lastRenderTime), MAX_EXTRAPOLATION)
	buffer.writef64(renderStateBuffer, offset + STATE_NEXT_RENDER_TIME_OFFSET, now)
	buffer.writef32(renderStateBuffer, offset + STATE_RENDER_INTERVAL_OFFSET, dt)

	local latestTime: number = buffer.readf64(renderStateBuffer, offset + STATE_LATEST_TIME_OFFSET)
	local latestPx: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_PX_OFFSET)
	local latestPy: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_PY_OFFSET)
	local latestPz: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_PZ_OFFSET)
	local latestVx: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_VX_OFFSET)
	local latestVy: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_VY_OFFSET)
	local latestVz: number = buffer.readf32(renderStateBuffer, offset + STATE_LATEST_VZ_OFFSET)

	local renderPx: number
	local renderPy: number
	local renderPz: number
	local renderVx: number
	local renderVy: number
	local renderVz: number
	local facingX: number
	local facingY: number
	local facingZ: number
	if bit32.band(flags, STATE_HAS_RENDER) ~= 0 then
		renderPx = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_PX_OFFSET)
		renderPy = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_PY_OFFSET)
		renderPz = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_PZ_OFFSET)
		renderVx = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_VX_OFFSET)
		renderVy = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_VY_OFFSET)
		renderVz = buffer.readf32(renderStateBuffer, offset + STATE_RENDER_VZ_OFFSET)
		facingX = buffer.readf32(renderStateBuffer, offset + STATE_FACING_X_OFFSET)
		facingY = buffer.readf32(renderStateBuffer, offset + STATE_FACING_Y_OFFSET)
		facingZ = buffer.readf32(renderStateBuffer, offset + STATE_FACING_Z_OFFSET)
	else
		renderPx, renderPy, renderPz = latestPx, latestPy, latestPz
		renderVx, renderVy, renderVz = latestVx, latestVy, latestVz
		facingX, facingY, facingZ = renderVx, renderVy, renderVz
	end

	local snapshotAge: number = math.clamp(now - latestTime, 0, MAX_EXTRAPOLATION)
	local predictedPx: number = latestPx + latestVx * snapshotAge
	local predictedPy: number = latestPy + latestVy * snapshotAge
	local predictedPz: number = latestPz + latestVz * snapshotAge
	local previousRenderPx: number = renderPx
	local previousRenderPy: number = renderPy
	local previousRenderPz: number = renderPz

	local visualErrorX: number = previousRenderPx - predictedPx
	local visualErrorY: number = previousRenderPy - predictedPy
	local visualErrorZ: number = previousRenderPz - predictedPz
	local correctionHalfLife: number = if bit32.band(flags, STATE_HAS_LAST_NETWORK_INTERVAL) ~= 0 then math.clamp(buffer.readf32(renderStateBuffer, offset + STATE_LAST_NETWORK_INTERVAL_OFFSET) * NETWORK_INTERVAL_CORRECTION_RATIO, POSITION_CORRECTION_HALF_LIFE, MAX_POSITION_CORRECTION_HALF_LIFE) else POSITION_CORRECTION_HALF_LIFE
	local keepError: number = exponentialDecayAlpha(dt, correctionHalfLife)
	visualErrorX *= keepError
	visualErrorY *= keepError
	visualErrorZ *= keepError
	if visualErrorX * visualErrorX + visualErrorY * visualErrorY + visualErrorZ * visualErrorZ <= SNAP_DISTANCE_SQUARED then
		visualErrorX, visualErrorY, visualErrorZ = 0, 0, 0
	end

	renderPx = predictedPx + visualErrorX
	renderPy = predictedPy + visualErrorY
	renderPz = predictedPz + visualErrorZ
	local desiredMoveX: number = renderPx - previousRenderPx
	local desiredMoveY: number = renderPy - previousRenderPy
	local desiredMoveZ: number = renderPz - previousRenderPz
	local desiredMoveLength: number = math.sqrt(desiredMoveX * desiredMoveX + desiredMoveY * desiredMoveY + desiredMoveZ * desiredMoveZ)
	local targetLookX: number
	local targetLookY: number
	local targetLookZ: number
	if desiredMoveLength > 0.001 then
		local inverseLength: number = 1 / desiredMoveLength
		targetLookX, targetLookY, targetLookZ = desiredMoveX * inverseLength, desiredMoveY * inverseLength, desiredMoveZ * inverseLength
	else
		targetLookX, targetLookY, targetLookZ = facingX, facingY, facingZ
	end

	local facingKeep: number = exponentialDecayAlpha(dt, ORIENTATION_CORRECTION_HALF_LIFE)
	facingX = facingX * facingKeep + targetLookX * (1 - facingKeep)
	facingY = facingY * facingKeep + targetLookY * (1 - facingKeep)
	facingZ = facingZ * facingKeep + targetLookZ * (1 - facingKeep)
	local facingLength: number = math.sqrt(facingX * facingX + facingY * facingY + facingZ * facingZ)
	if facingLength > 0.001 then
		local inverseFacingLength: number = 1 / facingLength
		facingX, facingY, facingZ = facingX * inverseFacingLength, facingY * inverseFacingLength, facingZ * inverseFacingLength
	else
		facingX, facingY, facingZ = 0, 0, 1
	end

	local desiredSpeed: number = if dt > 0 then math.max(0, (desiredMoveX * facingX + desiredMoveY * facingY + desiredMoveZ * facingZ) / dt) else 0
	renderVx, renderVy, renderVz = facingX * desiredSpeed, facingY * desiredSpeed, facingZ * desiredSpeed
	renderPx, renderPy, renderPz = previousRenderPx + renderVx * dt, previousRenderPy + renderVy * dt, previousRenderPz + renderVz * dt

	buffer.writef32(renderStateBuffer, offset + STATE_FACING_X_OFFSET, facingX)
	buffer.writef32(renderStateBuffer, offset + STATE_FACING_Y_OFFSET, facingY)
	buffer.writef32(renderStateBuffer, offset + STATE_FACING_Z_OFFSET, facingZ)
	writeNewState(renderStateBuffer, offset, renderPx, renderPy, renderPz, renderVx, renderVy, renderVz, bit32.bor(flags, STATE_HAS_RENDER))

	local renderPosition: Vector3 = Vector3.new(renderPx, renderPy, renderPz)
	return CFrame.lookAt(renderPosition, Vector3.new(renderPx + facingX, renderPy + facingY, renderPz + facingZ))
end


Kernel.RowBytes = RENDER_STATE_ROW_BYTES

function Kernel.Push(data: buffer, index: number, at: number, position: Vector3, velocity: Vector3, interval: number?): ()
	local offset = stateOffset(index)
	local flags = buffer.readu8(data, offset + STATE_FLAGS_OFFSET)
	buffer.writef64(data, offset + STATE_LATEST_TIME_OFFSET, at)
	buffer.writef32(data, offset + STATE_LATEST_PX_OFFSET, position.X)
	buffer.writef32(data, offset + STATE_LATEST_PY_OFFSET, position.Y)
	buffer.writef32(data, offset + STATE_LATEST_PZ_OFFSET, position.Z)
	buffer.writef32(data, offset + STATE_LATEST_VX_OFFSET, velocity.X)
	buffer.writef32(data, offset + STATE_LATEST_VY_OFFSET, velocity.Y)
	buffer.writef32(data, offset + STATE_LATEST_VZ_OFFSET, velocity.Z)
	flags = bit32.bor(flags, STATE_HAS_LATEST)
	if interval then
		buffer.writef32(data, offset + STATE_LAST_NETWORK_INTERVAL_OFFSET, interval)
		flags = bit32.bor(flags, STATE_HAS_LAST_NETWORK_INTERVAL)
	end
	buffer.writeu8(data, offset + STATE_FLAGS_OFFSET, flags)
end

export type Sample = { velocity: Vector3, renderedAt: number?, snapshotAt: number? }

function Kernel.Read(data: buffer, index: number): Sample
	local offset = stateOffset(index)
	local flags = buffer.readu8(data, offset + STATE_FLAGS_OFFSET)
	return {
		velocity = Vector3.new(buffer.readf32(data, offset + STATE_RENDER_VX_OFFSET), buffer.readf32(data, offset + STATE_RENDER_VY_OFFSET), buffer.readf32(data, offset + STATE_RENDER_VZ_OFFSET)),
		renderedAt = if bit32.band(flags, STATE_HAS_RENDER) ~= 0 then buffer.readf64(data, offset + STATE_NEXT_RENDER_TIME_OFFSET) else nil,
		snapshotAt = if bit32.band(flags, STATE_HAS_LATEST) ~= 0 then buffer.readf64(data, offset + STATE_LATEST_TIME_OFFSET) else nil,
	}
end

return Kernel

