--!strict
--!native

--[[ BoidStorage
Description:
	Packed paged storage for boid simulation state. Stores boids in fixed-size
	buffer rows inside 64-slot pages, tracks deleted slots with bitsets, and
	manages pending pages while worker jobs mutate cell data.

Public API:
	PageRegistry: {[number]: Page}
	BoidRegistry: {[number]: BoidEntry}
	BOID_ROW_BYTES, PAGE_CAPACITY, BOID_ID_SIZE, and row offset constants
	boidOffset(slot: number): number
	read/write helpers for id, position, velocity, speed, lastTick, pathNode, pathVersion, and packed obstacle directions
	newPage(pagedBuffer: PagedBuffer): Page
	newPagedBuffer(): PagedBuffer
	deletePagedBuffer(pagedBufferId: number): ()
	appendPage(pagedBuffer: PagedBuffer, page: Page): ()
	getOpenPage(pagedBuffer: PagedBuffer): Page
	insertBoid(pagedBuffer: PagedBuffer, px: number, py: number, pz: number, vx: number, vy: number, vz: number, currentTick: number, boidId: number, cellId: number): ()
	deleteBoidAtSlot(page: Page, slot: number, pagedBuffer: PagedBuffer?): boolean
	deleteBoid(boidId: number): ()
	removePage(pagedBuffer: PagedBuffer, page: Page): ()
	liveWords(page: Page): () -> (number?, number?)
	countLive(pages: {Page}): number
	restorePendingPages(pagedBuffer: PagedBuffer): ()
	markPagesPending(pagedBuffer: PagedBuffer): ()
	overwriteWithJobResults(dest: PagedBuffer, src: PagedBuffer, lockedPageCount: number): ()
]]

local Quantization = require(script.Parent.Quantization)
local SharedTypes = require(script.Parent.SharedTypes)
local BoidStorage = {}


type Page = SharedTypes.Page
type WorkerPage = SharedTypes.WorkerPage
type PagedBuffer = SharedTypes.PagedBuffer

local writeQuantizedPositionU8 = Quantization.WriteQuantizedPositionU8
local writeQuantizedVelocityU8 = Quantization.WriteQuantizedVelocityU8
local writeQuantizedPositionU16 = Quantization.WriteQuantizedPositionU16
local writeQuantizedVelocityU16 = Quantization.WriteQuantizedVelocityU16

local readQuantizedPositionU8 = Quantization.ReadQuantizedPositionU8
local readQuantizedVelocityU8 = Quantization.ReadQuantizedVelocityU8
local readQuantizedPositionU16 = Quantization.ReadQuantizedPositionU16
local readQuantizedVelocityU16 = Quantization.ReadQuantizedVelocityU16

local writeLastTick = Quantization.WriteLastTick
local readLastTick = Quantization.ReadLastTick

local NORM_VELOCITY_MIN:number = Quantization.NORM_VELOCITY_MIN
local NORM_VELOCITY_RANGE:number = Quantization.NORM_VELOCITY_RANGE

local PageRegistry:{[number]:Page} = {}
BoidStorage.PageRegistry = PageRegistry

local PagedBufferRegistry:{[number]:PagedBuffer} = {}

type BoidEntry = {
	pageId:number,
	slot:number,
	cellId:number
}
local BoidRegistry:{[number]:BoidEntry} = {}
BoidStorage.BoidRegistry = BoidRegistry

local PAGE_COMPACTION_THRESHOLD:number = 0.25
BoidStorage.PAGE_COMPACTION_THRESHOLD = PAGE_COMPACTION_THRESHOLD

local BOID_POSITION_AXIS_SIZE:number = 1
BoidStorage.BOID_POSITION_AXIS_SIZE = BOID_POSITION_AXIS_SIZE

local BOID_VELOCITY_AXIS_SIZE:number = 1
BoidStorage.BOID_VELOCITY_AXIS_SIZE = BOID_VELOCITY_AXIS_SIZE

local BOID_ID_SIZE:number = 2
BoidStorage.BOID_ID_SIZE = BOID_ID_SIZE

local MAX_U8:number = 2^8 - 1
local MAX_U32 = 0xFFFFFFFF

local U8_SIZE:number = 1
local U16_SIZE:number = 2
local U32_SIZE:number = 4

-- Packed boid row layout:
--
-- offset  size  field
-- 0       u16   boidId
-- 2       u8    posX
-- 3       u8    posY
-- 4       u8    posZ
-- 5       u8    velX
-- 6       u8    velY
-- 7       u8    velZ
-- 8       u8    speed
-- 9       u16   lastTick
-- 11      u8    pathNode      -- 0 = unset/sentinel
-- 12      u8    pathVersion
-- 13-15   u8x3 obstacleDirection -- zero sentinel, normalized quantized heading

const BOID_ID_OFFSET: number = 0

const POS_X_OFFSET: number = BOID_ID_OFFSET + BOID_ID_SIZE
const POS_Y_OFFSET: number = POS_X_OFFSET + U8_SIZE
const POS_Z_OFFSET: number = POS_Y_OFFSET + U8_SIZE

const VEL_X_OFFSET: number = POS_Z_OFFSET + U8_SIZE
const VEL_Y_OFFSET: number = VEL_X_OFFSET + U8_SIZE
const VEL_Z_OFFSET: number = VEL_Y_OFFSET + U8_SIZE

const SPEED_OFFSET: number = VEL_Z_OFFSET + U8_SIZE
const LAST_TICK_OFFSET: number = SPEED_OFFSET + U8_SIZE

const PATH_NODE_OFFSET: number = LAST_TICK_OFFSET + U16_SIZE
const PATH_VERSION_OFFSET: number = PATH_NODE_OFFSET + U8_SIZE
-- The existing row padding retains a local detour heading without affecting snapshots.
const OBSTACLE_DIRECTION_X_OFFSET: number = PATH_VERSION_OFFSET + U8_SIZE
const OBSTACLE_DIRECTION_Y_OFFSET: number = OBSTACLE_DIRECTION_X_OFFSET + U8_SIZE
const OBSTACLE_DIRECTION_Z_OFFSET: number = OBSTACLE_DIRECTION_Y_OFFSET + U8_SIZE

const BOID_ROW_BYTES: number = 16
BoidStorage.BOID_ROW_BYTES = BOID_ROW_BYTES

BoidStorage.BOID_ID_OFFSET = BOID_ID_OFFSET

BoidStorage.POS_X_OFFSET = POS_X_OFFSET
BoidStorage.POS_Y_OFFSET = POS_Y_OFFSET
BoidStorage.POS_Z_OFFSET = POS_Z_OFFSET

BoidStorage.VEL_X_OFFSET = VEL_X_OFFSET
BoidStorage.VEL_Y_OFFSET = VEL_Y_OFFSET
BoidStorage.VEL_Z_OFFSET = VEL_Z_OFFSET

BoidStorage.SPEED_OFFSET = SPEED_OFFSET
BoidStorage.LAST_TICK_OFFSET = LAST_TICK_OFFSET

BoidStorage.PATH_NODE_OFFSET = PATH_NODE_OFFSET
BoidStorage.PATH_VERSION_OFFSET = PATH_VERSION_OFFSET
BoidStorage.OBSTACLE_DIRECTION_X_OFFSET = OBSTACLE_DIRECTION_X_OFFSET
BoidStorage.OBSTACLE_DIRECTION_Y_OFFSET = OBSTACLE_DIRECTION_Y_OFFSET
BoidStorage.OBSTACLE_DIRECTION_Z_OFFSET = OBSTACLE_DIRECTION_Z_OFFSET

local function boidOffset(slot: number): number
	return slot * BOID_ROW_BYTES
end
BoidStorage.boidOffset = boidOffset

local TIME_COURSENESS: number = 0.25
local TIME_SCALE: number = 1/TIME_COURSENESS

local PAGE_CAPACITY: number = 64
BoidStorage.PAGE_CAPACITY = PAGE_CAPACITY

local WORD_SIZE: number = 4
local SLOTS_PER_WORD: number = 8*WORD_SIZE
local WORD_COUNT: number = math.ceil(PAGE_CAPACITY / (8 * WORD_SIZE))


local function clampU8(value: number): number
	return math.clamp(math.round(value), 0, MAX_U8)
end

local function quantizePositionAxis(axis: number): number
	return clampU8((axis / Quantization.CELL_SIZE) * MAX_U8)
end

local function dequantizePositionAxis(value :number): number
	return (value / MAX_U8) * Quantization.CELL_SIZE
end

local function quantizeVelocityAxis(axis: number): number
	return clampU8(((axis - NORM_VELOCITY_MIN) / NORM_VELOCITY_RANGE) * MAX_U8)
end

local function dequantizeVelocityAxis(value: number): number
	return (value / MAX_U8) * NORM_VELOCITY_RANGE + NORM_VELOCITY_MIN
end

function BoidStorage.WriteBoidId(data: buffer, slot: number, boidId: number): ()
	buffer.writeu16(data, boidOffset(slot) + BOID_ID_OFFSET, boidId)
end

function BoidStorage.ReadBoidId(data: buffer, slot: number): number
	return buffer.readu16(data, boidOffset(slot) + BOID_ID_OFFSET)
end

function BoidStorage.WritePosition(data: buffer, slot: number, x: number, y: number, z: number): ()
	const offset: number = boidOffset(slot)

	buffer.writeu8(data, offset + POS_X_OFFSET, quantizePositionAxis(x))
	buffer.writeu8(data, offset + POS_Y_OFFSET, quantizePositionAxis(y))
	buffer.writeu8(data, offset + POS_Z_OFFSET, quantizePositionAxis(z))
end

function BoidStorage.ReadPosition(data: buffer, slot: number): (number, number, number)
	const offset: number = boidOffset(slot)

	return
		dequantizePositionAxis(buffer.readu8(data, offset + POS_X_OFFSET)),
		dequantizePositionAxis(buffer.readu8(data, offset + POS_Y_OFFSET)),
		dequantizePositionAxis(buffer.readu8(data, offset + POS_Z_OFFSET))
end

function BoidStorage.WriteVelocity(data: buffer, slot: number, x: number, y: number, z: number): ()
	const offset: number = boidOffset(slot)

	buffer.writeu8(data, offset + VEL_X_OFFSET, quantizeVelocityAxis(x))
	buffer.writeu8(data, offset + VEL_Y_OFFSET, quantizeVelocityAxis(y))
	buffer.writeu8(data, offset + VEL_Z_OFFSET, quantizeVelocityAxis(z))
end

function BoidStorage.ReadVelocity(data: buffer, slot: number): (number, number, number)
	const offset: number = boidOffset(slot)

	return
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_X_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_Y_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_Z_OFFSET))
end

function BoidStorage.WriteSpeed(data: buffer, slot: number, speed: number): ()
	buffer.writeu8(data, boidOffset(slot) + SPEED_OFFSET, math.clamp(math.round(speed), 0, MAX_U8))
end

function BoidStorage.ReadSpeed(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + SPEED_OFFSET)
end

function BoidStorage.WriteLastTick(data: buffer, slot: number, tick: number): ()
	buffer.writeu16(data, boidOffset(slot) + LAST_TICK_OFFSET, tick % 65536)
end

function BoidStorage.ReadLastTick(data: buffer, slot: number): number
	return buffer.readu16(data, boidOffset(slot) + LAST_TICK_OFFSET)
end

function BoidStorage.WritePathNode(data: buffer, slot: number, pathNode: number): ()
	buffer.writeu8(data, boidOffset(slot) + PATH_NODE_OFFSET, math.clamp(math.round(pathNode), 0, MAX_U8))
end

function BoidStorage.ReadPathNode(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + PATH_NODE_OFFSET)
end

function BoidStorage.WritePathVersion(data: buffer, slot: number, pathVersion: number): ()
	buffer.writeu8(data, boidOffset(slot) + PATH_VERSION_OFFSET, pathVersion % 256)
end

function BoidStorage.ReadPathVersion(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + PATH_VERSION_OFFSET)
end

function BoidStorage.ReadObstacleDirectionCode(data: buffer, slot: number): number
	const offset = boidOffset(slot)
	return buffer.readu8(data, offset + OBSTACLE_DIRECTION_X_OFFSET)
		+ buffer.readu8(data, offset + OBSTACLE_DIRECTION_Y_OFFSET) * 256
		+ buffer.readu8(data, offset + OBSTACLE_DIRECTION_Z_OFFSET) * 65536
end

function BoidStorage.WriteObstacleDirectionCode(data: buffer, slot: number, code: number): ()
	code = math.clamp(math.floor(code), 0, 0xFFFFFF)
	const offset = boidOffset(slot)
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_X_OFFSET, code % 256)
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_Y_OFFSET, code // 256 % 256)
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_Z_OFFSET, code // 65536)
end

function BoidStorage.ReadObstacleDirection(data: buffer, slot: number): Vector3
	const code = BoidStorage.ReadObstacleDirectionCode(data, slot)
	if code == 0 then
		return Vector3.zero
	end
	const offset = boidOffset(slot)
	const direction = Vector3.new(
		dequantizeVelocityAxis(buffer.readu8(data, offset + OBSTACLE_DIRECTION_X_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + OBSTACLE_DIRECTION_Y_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + OBSTACLE_DIRECTION_Z_OFFSET))
	)
	if direction:Dot(direction) <= 1e-8 then
		return Vector3.zero
	end
	return direction.Unit
end

function BoidStorage.WriteObstacleDirection(data: buffer, slot: number, direction: Vector3): ()
	if direction:Dot(direction) <= 1e-8 then
		BoidStorage.WriteObstacleDirectionCode(data, slot, 0)
		return
	end
	const offset = boidOffset(slot)
	const normalized = direction.Unit
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_X_OFFSET, quantizeVelocityAxis(normalized.X))
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_Y_OFFSET, quantizeVelocityAxis(normalized.Y))
	buffer.writeu8(data, offset + OBSTACLE_DIRECTION_Z_OFFSET, quantizeVelocityAxis(normalized.Z))
end

local nextPageId: number = 0
local function newPage(pagedBuffer:PagedBuffer): Page
	nextPageId += 1

	const page: Page = {
		id = nextPageId,
		setId = pagedBuffer.id,

		index = 0,
		size = 0,

		deadCount = 0,
		firstDeadWord = 0,
		cursor = 0,

		data = buffer.create(PAGE_CAPACITY * BOID_ROW_BYTES),
		dead = buffer.create(WORD_COUNT * U32_SIZE),
	}

	PageRegistry[page.id] = page
	return page
end
BoidStorage.newPage = newPage

local nextPagedBufferId: number = 0
function BoidStorage.NewPagedBuffer():PagedBuffer
	nextPagedBufferId += 1
	
	const pagedBuffer:PagedBuffer = {
		id = nextPagedBufferId,
		pages = {},
		openPages = {},
		pendingPages = {},

		pageCount = 0,
	}
	PagedBufferRegistry[pagedBuffer.id] = pagedBuffer
	
	return pagedBuffer
end

function BoidStorage.DeletePagedBuffer(pagedBufferId: number): ()
	const pagedBuffer:PagedBuffer = PagedBufferRegistry[pagedBufferId]
	if not pagedBuffer then
		return
	end
	PagedBufferRegistry[pagedBufferId] = nil
	
	for _, page: Page in pagedBuffer.pages do
		PageRegistry[page.id] = nil
	end
	table.clear(pagedBuffer.pages)
	table.clear(pagedBuffer.openPages)
	table.clear(pagedBuffer.pendingPages)
	pagedBuffer.pageCount = 0
end

local function takeDeadSlot(page: Page): number?
	if page.deadCount == 0 then
		return nil
	end

	const dead: buffer = page.dead
	
	local offset: number, word: number
	for wordIndex: number = page.firstDeadWord, WORD_COUNT - 1 do
		offset = wordIndex * 4
		word = buffer.readu32(dead, offset)
		
		if word == 0 then
			continue
		end
		
		-- get lowest set bit index
		const bitIndex: number = bit32.countrz(word)
		const slot: number = wordIndex * 32 + bitIndex
		
		const newWord: number = bit32.band(word, bit32.bnot(bit32.lshift(1, bitIndex)))

		-- Clear the dead bit because this slot is being reused.
		buffer.writeu32(dead, offset, newWord)
		
		-- if no more dead words in word, find next word with dead words to draw from
		-- this is likely more efficient as instead of searching all words every time you want to claim a dead slot
		-- you only have to search from the current to the end every time there's no more dead slots here
		if newWord == 0 then
			local nextWord: number = wordIndex + 1
			while nextWord < WORD_COUNT do
				if buffer.readu32(dead, nextWord * 4) ~= 0 then
					break
				end
				nextWord += 1
			end
			
			page.firstDeadWord = nextWord
		else
			page.firstDeadWord = wordIndex
		end

		page.deadCount -= 1
		return slot
	end

	-- Should not happen if deadCount is accurate.
	-- friggin typechecker
	return nil
end

local function allocateSlot(page: Page): number?
	local slot: number? = takeDeadSlot(page)
	if slot then
		return slot
	end
	
	if page.cursor < PAGE_CAPACITY then
		slot = page.cursor
		page.cursor += 1
		return slot
	end
	
	return nil
end

local function pageHasOpenSlot(page: Page): boolean
	return page.deadCount > 0 or page.cursor < PAGE_CAPACITY
end

function BoidStorage.AppendPage(pagedBuffer: PagedBuffer, page: Page): ()
	pagedBuffer.pageCount += 1

	page.index = pagedBuffer.pageCount -- 1-based table index
	pagedBuffer.pages[page.index] = page

	if pageHasOpenSlot(page) then
		pagedBuffer.openPages[page.id] = true
	end
end

-- get open page from active page list. validate page, remove if not usable, return new page if no page available.
local function getOpenPage(pagedBuffer: PagedBuffer): Page
	const openPages = pagedBuffer.openPages

	local pageId = next(openPages)
	local page: Page
	while pageId do
		page = PageRegistry[pageId]
		if page and pageHasOpenSlot(page) then
			return page
		end

		openPages[pageId] = nil
		pageId = next(openPages)
	end

	page = newPage(pagedBuffer)
	BoidStorage.AppendPage(pagedBuffer, page)

	return page
end
BoidStorage.getOpenPage = getOpenPage

function BoidStorage.InsertBoid(
	pagedBuffer: PagedBuffer,
	px: number, py: number, pz: number,
	vx: number, vy: number, vz: number,
	currentTick: number,
	boidId: number,
	cellId: number,
	pathNode: number?,
	pathVersion: number?,
	obstacleDirectionCode: number?
)
	const page: Page = getOpenPage(pagedBuffer)

	const slot: number? = allocateSlot(page)
	if slot == nil then
		error("No slot found for page that promised a slot")
	end

	const velocity: Vector3 = Vector3.new(vx, vy, vz)
	local speed: number = velocity.Magnitude
	
	local dir: Vector3
	if speed > 0.001 then
		dir = velocity / speed
	else
		dir = Vector3.zAxis
		speed = 0
	end
	speed = math.clamp(speed, 0, 255)
	
	local data: buffer = page.data
	BoidStorage.WritePosition(data, slot, px, py, pz)
	BoidStorage.WriteVelocity(data, slot, dir.X, dir.Y, dir.Z)
	BoidStorage.WriteSpeed(data, slot, speed)
	BoidStorage.WriteLastTick(data, slot, currentTick)
	BoidStorage.WriteBoidId(data, slot, boidId)

	BoidStorage.WritePathNode(data, slot, pathNode or 0)
	BoidStorage.WritePathVersion(data, slot, pathVersion or 0)
	BoidStorage.WriteObstacleDirectionCode(data, slot, obstacleDirectionCode or 0)

	page.size += 1
	if page.size >= PAGE_CAPACITY then
		pagedBuffer.openPages[page.id] = nil
	else
		pagedBuffer.openPages[page.id] = true
	end

	local entry: BoidEntry? = BoidRegistry[boidId]
	if not entry then
		entry = {
			pageId = page.id,
			slot = slot,
			cellId = cellId
		}
		BoidRegistry[boidId] = entry
	else
		entry.pageId = page.id
		entry.slot = slot
		entry.cellId = cellId
	end
end

local function deleteBoidAtSlot(page: Page | WorkerPage, slot: number, pagedBuffer: PagedBuffer?): boolean
	const wordIndex: number = slot // 32
	const bitIndex: number = slot % 32
	const offset: number = wordIndex * 4

	const word: number = buffer.readu32(page.dead, offset)
	const bit: number = bit32.lshift(1, bitIndex)

	-- I don't trust my system not to try to double delete
	if bit32.band(word, bit) ~= 0 then
		return false
	end

	buffer.writeu32(page.dead, offset, bit32.bor(word, bit))

	page.deadCount += 1
	page.size -= 1
	page.firstDeadWord = math.min(page.firstDeadWord, wordIndex)
	
	if page.size < PAGE_CAPACITY then
		local owningBuffer = pagedBuffer
		if not owningBuffer then
			owningBuffer = PagedBufferRegistry[(page :: Page).setId]
		end
		if owningBuffer then
			owningBuffer.openPages[page.id] = true
		end
	end
	
	return true
end
BoidStorage.deleteBoidAtSlot = deleteBoidAtSlot

-- Physical slot/page operations do not own coordinator metadata, IDs or notifications.
-- Generalized-for consumes the trailing mask only when the first value is non-nil.
-- The nullable termination pack is kept inside this factory, not at its consumers.
export type LiveWordIterator = () -> (number?, number)
function BoidStorage.LiveWords(page: Page | WorkerPage): LiveWordIterator
	const dead: buffer = page.dead
	const cursor: number = page.cursor

	local wordIndex: number = 0
	const activeWordCount: number = math.ceil(cursor / SLOTS_PER_WORD)
	
	local baseSlot: number, liveWord: number, remaining: number
	return (function(): (number?, number?)
		while wordIndex < activeWordCount do
			baseSlot = wordIndex * SLOTS_PER_WORD
			
			liveWord = bit32.bnot(buffer.readu32(dead, wordIndex * U32_SIZE))

			remaining = cursor - baseSlot
			if remaining < SLOTS_PER_WORD then
				liveWord = bit32.band(liveWord, bit32.lshift(1, remaining) - 1)
			else
				liveWord = bit32.band(liveWord, MAX_U32)
			end

			wordIndex += 1

			if liveWord ~= 0 then
				return baseSlot, liveWord
			end
		end

		return nil, nil
	end) :: LiveWordIterator
end

-- for debugging
function BoidStorage.CountLive(pages: {Page}): number
	local actualLive = 0
	for _, page: Page in pages do
		for baseSlot: number, liveMask: number in (BoidStorage.LiveWords(page)) do
			while liveMask ~= 0 do
				actualLive += 1
				liveMask = bit32.band(liveMask, liveMask - 1)
			end
		end
	end
	return actualLive
end

function BoidStorage.RestorePendingPages(pagedBuffer: PagedBuffer): ()
	if PagedBufferRegistry[pagedBuffer.id] ~= pagedBuffer then
		return
	end
	const openPages: {[number]:boolean} = pagedBuffer.openPages
	const pendingPages: {[number]:boolean} = pagedBuffer.pendingPages
	
	for pageId: number, _ in pendingPages do
		openPages[pageId] = true
	end
	table.clear(pendingPages)
end

-- specifically for marking current pages pending during a job, causes them to be skipped by getOpenPage
function BoidStorage.MarkPagesPending(pagedBuffer: PagedBuffer): ()
	const openPages: {[number]:boolean} = pagedBuffer.openPages
	const pendingPages: {[number]:boolean} = pagedBuffer.pendingPages
	
	--pagedBuffer.pendingPages = pagedBuffer.openPages
	--pagedBuffer.openPages = {}
	
	for pageId: number, _ in pagedBuffer.openPages do
		pendingPages[pageId] = true
	end
	table.clear(openPages)
end

-- specifically intended to be for returned job results
function BoidStorage.OverwriteWithJobResults(dest: PagedBuffer, src: SharedTypes.WorkerPagedBuffer, lockedPageCount: number): ()
	-- Validate the complete locked range before mutating pages or reservations.
	-- A bad later page must not leave an earlier page partially committed.
	assert(PagedBufferRegistry[dest.id] == dest, "Destination buffer is retired")
	for index = 1, lockedPageCount do
		local destPage = dest.pages[index]
		local srcPage = src.pages[index]
		assert(destPage ~= nil, "Missing destination page")
		assert(srcPage ~= nil, "Missing source page")
		assert(srcPage.id == destPage.id, "Job result page id mismatch")
	end
	BoidStorage.RestorePendingPages(dest)
	
	const destPages: {Page} = dest.pages
	const srcPages: {WorkerPage} = src.pages
	const openPages: {[number]:boolean} = dest.openPages
	
	local srcPage: WorkerPage
	local destPage: Page
	for i: number = 1, lockedPageCount do
		srcPage = srcPages[i]
		destPage = destPages[i]
		
		-- check for destPage == nil in case it was removed due to all boids leaving it
		-- then remove page from list
		
		destPage.data = srcPage.data
		destPage.dead = srcPage.dead

		destPage.size = srcPage.size
		destPage.cursor = srcPage.cursor
		destPage.deadCount = srcPage.deadCount
		destPage.firstDeadWord = srcPage.firstDeadWord

		openPages[destPage.id] = nil

		if destPage.size < PAGE_CAPACITY then
			openPages[destPage.id] = true
		end
	end
end

return BoidStorage
