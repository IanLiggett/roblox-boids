--!strict
--!native

--[[ Quantization
Description:
	Shared helpers for converting positions, velocities, simulation ticks, and
	world coordinates into compact deterministic representations used by server,
	worker, storage, and network code.

Public API:
	MAX_U8_INT, MAX_U16_INT, CELL_SIZE, CELL_MARGIN, POSITION_MIN, POSITION_RANGE
	NORM_VELOCITY_MIN, NORM_VELOCITY_RANGE, VELOCITY_MIN, VELOCITY_RANGE
	quantizePositionAxis(axis: number, maxInt: number): number
	dequantizePositionAxis(encoded: number, maxInt: number): number
	quantizeVelocityAxis(axis: number, minVelocity: number, velocityRange: number, maxInt: number): number
	dequantizeVelocityAxis(encoded: number, minVelocity: number, velocityRange: number, maxInt: number): number
	write/read quantized U8 and U16 positions and velocities
	readVector(buf: buffer, index: number): (number, number, number)
	writeVector(buf: buffer, x: number, y: number, z: number, index: number): ()
	currentSimTick(): number
	writeLastTick(buf: buffer, index: number, tick: number): ()
	readLastTick(buf: buffer, index: number): number
	tickDeltaSeconds(currentTick: number, lastTick: number): number
	getNumericalKey(x: number, y: number, z: number): number
	convertCoordsToGrid(x: number, y: number, z: number): (number, number, number)
]]

local Quantization = {}

local U8_SIZE:number = 1
local U16_SIZE:number = 2
local U32_SIZE:number = 4

local MAX_U8_INT = 2^(8*U8_SIZE) - 1
Quantization.MAX_U8_INT = MAX_U8_INT
local MAX_U16_INT = 2^(8*U16_SIZE) - 1
Quantization.MAX_U16_INT = MAX_U16_INT

local CELL_SIZE:number = 64
Quantization.CELL_SIZE = CELL_SIZE

-- Session-fixed: storage and every snapshot decoder must use the same range.
-- Owner-confirmed default after comparing 0/2/4/8 in fresh sessions.
local CELL_MARGIN = 4
Quantization.CELL_MARGIN = CELL_MARGIN
local POSITION_MIN = -CELL_MARGIN
local POSITION_RANGE = CELL_SIZE + 2 * CELL_MARGIN
Quantization.POSITION_MIN = POSITION_MIN
Quantization.POSITION_RANGE = POSITION_RANGE

local NORM_VELOCITY_MAX:number = 1
local NORM_VELOCITY_MIN:number = -1
local NORM_VELOCITY_RANGE:number = NORM_VELOCITY_MAX - NORM_VELOCITY_MIN

Quantization.NORM_VELOCITY_MIN = NORM_VELOCITY_MIN
Quantization.NORM_VELOCITY_RANGE = NORM_VELOCITY_RANGE

local VELOCITY_MAX:number = 127
local VELOCITY_MIN:number = -127
local VELOCITY_RANGE:number = VELOCITY_MAX - VELOCITY_MIN

Quantization.VELOCITY_MIN = VELOCITY_MIN
Quantization.VELOCITY_RANGE = VELOCITY_RANGE

local TIME_SIZE:number = U16_SIZE


local function quantizePositionAxis(axis:number, maxInt:number):number
	return
		math.clamp(
			math.round(
				((axis - POSITION_MIN) / POSITION_RANGE)
					* maxInt
			), 0, maxInt
		)
end
Quantization.quantizePositionAxis = quantizePositionAxis

local function dequantizePositionAxis(encoded:number, maxInt:number):number
	return 
		(encoded / maxInt)
		* POSITION_RANGE + POSITION_MIN
end
Quantization.dequantizePositionAxis = dequantizePositionAxis

local function quantizeVelocityAxis(axis:number, minVelocity:number, velocityRange:number, maxInt:number):number
	return
		math.clamp(
			math.round(
				((axis - minVelocity) / velocityRange)
				* maxInt
			), 0, maxInt
		)
end
Quantization.quantizeVelocityAxis = quantizeVelocityAxis

local function dequantizeVelocityAxis(encoded:number, minVelocity:number, velocityRange:number, maxInt:number):number
	return
		minVelocity
		+ (encoded / maxInt)
		* velocityRange
end
Quantization.dequantizeVelocityAxis = dequantizeVelocityAxis


-- Writes and quantizes to U8 a position local to its cell to the buffer
function Quantization.WriteQuantizedPositionU8(buf:buffer, index:number, x:number, y:number, z:number): ()
	local offset:number = index * 3 * U8_SIZE
	
	buffer.writeu8(buf, offset, quantizePositionAxis(x, MAX_U8_INT))
	buffer.writeu8(buf, offset + U8_SIZE, quantizePositionAxis(y, MAX_U8_INT))
	buffer.writeu8(buf, offset + U16_SIZE, quantizePositionAxis(z, MAX_U8_INT))
end
-- Writes and quantizes to U8 a normalized velocity to the buffer
function Quantization.WriteQuantizedVelocityU8(buf:buffer, index:number, x:number, y:number, z:number, velocityMin:number, velocityRange:number): ()
	local offset:number = index * 3 * U8_SIZE
	
	buffer.writeu8(buf, offset, quantizeVelocityAxis(x, velocityMin, velocityRange, MAX_U8_INT))
	buffer.writeu8(buf, offset + U8_SIZE, quantizeVelocityAxis(y, velocityMin, velocityRange, MAX_U8_INT))
	buffer.writeu8(buf, offset + U16_SIZE, quantizeVelocityAxis(z, velocityMin, velocityRange, MAX_U8_INT))
end

-- Reads and dequantizes from U8 a local position from the buffer at the given index
function Quantization.ReadQuantizedPositionU8(buf:buffer, index:number):(number, number, number)
	local offset:number = index * 3 * U8_SIZE
	
	return
		dequantizePositionAxis(buffer.readu8(buf, offset), MAX_U8_INT),
		dequantizePositionAxis(buffer.readu8(buf, offset + U8_SIZE), MAX_U8_INT),
		dequantizePositionAxis(buffer.readu8(buf, offset + U16_SIZE), MAX_U8_INT)
end
-- Reads and dequantizes from U8 a normalized velociy from the buffer at the given index
function Quantization.ReadQuantizedVelocityU8(buf:buffer, index:number, velocityMin:number, velocityRange:number):(number, number, number)
	local offset:number = index * 3 * U8_SIZE
	
	return
			dequantizeVelocityAxis(buffer.readu8(buf, offset), velocityMin, velocityRange, MAX_U8_INT),
		dequantizeVelocityAxis(buffer.readu8(buf, offset + U8_SIZE), velocityMin, velocityRange, MAX_U8_INT),
		dequantizeVelocityAxis(buffer.readu8(buf, offset + U16_SIZE), velocityMin, velocityRange, MAX_U8_INT)
end

-- Writes and quantizes to U16 a position local to its cell to the buffer
function Quantization.WriteQuantizedPositionU16(buf:buffer, index:number, x:number, y:number, z:number): ()
	local offset:number = index * 3 * U16_SIZE

	buffer.writeu16(buf, offset, quantizePositionAxis(x, MAX_U16_INT))
	buffer.writeu16(buf, offset + U16_SIZE, quantizePositionAxis(y, MAX_U16_INT))
	buffer.writeu16(buf, offset + U32_SIZE, quantizePositionAxis(z, MAX_U16_INT))
end
-- Writes and quantizes to U16 a normalized velocity to the buffer
function Quantization.WriteQuantizedVelocityU16(buf:buffer, index:number, x:number, y:number, z:number, velocityMin:number, velocityRange:number): ()
	local offset:number = index * 3 * U16_SIZE

	buffer.writeu16(buf, offset, quantizeVelocityAxis(x, velocityMin, velocityRange, MAX_U16_INT))
	buffer.writeu16(buf, offset + U16_SIZE, quantizeVelocityAxis(y, velocityMin, velocityRange, MAX_U16_INT))
	buffer.writeu16(buf, offset + U32_SIZE, quantizeVelocityAxis(z, velocityMin, velocityRange, MAX_U16_INT))
end

-- Reads and dequantizes from U16 a local position from the buffer at the given index
function Quantization.ReadQuantizedPositionU16(buf:buffer, index:number):(number, number, number)
	local offset:number = index * 3 * U16_SIZE

	return
		dequantizePositionAxis(buffer.readu16(buf, offset), MAX_U16_INT),
		dequantizePositionAxis(buffer.readu16(buf, offset + U16_SIZE), MAX_U16_INT),
		dequantizePositionAxis(buffer.readu16(buf, offset + U32_SIZE), MAX_U16_INT)
end
-- Reads and dequantizes from U16 a normalized velociy from the buffer at the given index
function Quantization.ReadQuantizedVelocityU16(buf:buffer, index:number, velocityMin:number, velocityRange:number):(number, number, number)
	local offset:number = index * 3 * U16_SIZE

	return
		dequantizeVelocityAxis(buffer.readu16(buf, offset), velocityMin, velocityRange, MAX_U16_INT),
		dequantizeVelocityAxis(buffer.readu16(buf, offset + U16_SIZE), velocityMin, velocityRange, MAX_U16_INT),
		dequantizeVelocityAxis(buffer.readu16(buf, offset + U32_SIZE), velocityMin, velocityRange, MAX_U16_INT)
end



function Quantization.ReadVector(buf:buffer, index:number): (number, number, number)
	return
		buffer.readf64(buf, index * 8),
		buffer.readf64(buf, index * 8 + 8),
		buffer.readf64(buf, index * 8 + 8 * 2)
end

function Quantization.WriteVector(buf:buffer, x:number, y:number, z:number, index:number): ()
	buffer.writef64(buf, index * 8, x)
	buffer.writef64(buf, index * 8 + 8, y)
	buffer.writef64(buf, index * 8 + 8 * 2, z)
end



local TICK_RATE:number = 60
local U16_MOD:number = 65536
-- Low-preset background prediction runs every 12 seconds; allow scheduling headroom.
local MAX_DT:number = 32

function Quantization.CurrentSimTick():number
	return math.floor(workspace:GetServerTimeNow() * TICK_RATE) % U16_MOD
end

function Quantization.WriteLastTick(buf:buffer, index:number, tick:number): ()
	buffer.writeu16(buf, index * 2, tick % U16_MOD)
end

local function tickDeltaTicks(currentTick:number, lastTick:number):number
	return (currentTick - lastTick) % U16_MOD
end

local MAX_REASONABLE_TICKS = TICK_RATE * MAX_DT
function Quantization.TickDeltaSeconds(currentTick: number, lastTick: number): number
	local deltaTicks = tickDeltaTicks(currentTick, lastTick)
	if deltaTicks > MAX_REASONABLE_TICKS then
		warn(
			`Invalid simulation tick delta: current={currentTick}, last={lastTick}, delta={deltaTicks}`
		)
		return 0
	end

	return deltaTicks / TICK_RATE
end

function Quantization.ReadLastTick(buf:buffer, index:number):number
	return buffer.readu16(buf, index * U16_SIZE)
end


local function mapToPositive(n:number):number
	return n >= 0 and 2 * n or -2 * n - 1
end

function Quantization.GetNumericalKey(x:number, y:number, z:number):number
	x, y, z = mapToPositive(x), mapToPositive(y), mapToPositive(z)

	local xyPair:number = 0.5 * (x + y) * (x + y + 1) + y
	return 0.5 * (xyPair + z) * (xyPair + z + 1) + z
end

function Quantization.ConvertCoordsToGrid(x:number, y:number, z:number):(number, number, number)
	return
		(x // CELL_SIZE) * CELL_SIZE,
		(y // CELL_SIZE) * CELL_SIZE,
		(z // CELL_SIZE) * CELL_SIZE
end

return Quantization
