--!strict
--!native

local module = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated") :: typeof(script.Parent.Parent.BoidsReplicated)

local SharedTypes = require(BoidsReplicated.SharedTypes)
local Quantization = require(BoidsReplicated.Quantization)

local writeQuantizedPositionU8 = Quantization.writeQuantizedPositionU8
local writeQuantizedVelocityU8 = Quantization.writeQuantizedVelocityU8
local writeQuantizedPositionU16 = Quantization.writeQuantizedPositionU16
local writeQuantizedVelocityU16 = Quantization.writeQuantizedVelocityU16

local readQuantizedPositionU8 = Quantization.readQuantizedPositionU8
local readQuantizedVelocityU8 = Quantization.readQuantizedVelocityU8
local readQuantizedPositionU16 = Quantization.readQuantizedPositionU16
local readQuantizedVelocityU16 = Quantization.readQuantizedVelocityU16

local writeLastTick = Quantization.writeLastTick
local readLastTick = Quantization.readLastTick

local NORM_VELOCITY_MIN:number = Quantization.NORM_VELOCITY_MIN
local NORM_VELOCITY_RANGE:number = Quantization.NORM_VELOCITY_RANGE

type Page = SharedTypes.Page
type PagedBuffer = SharedTypes.PagedBuffer

local PageRegistry:{[number]:Page} = {}
module.PageRegistry = PageRegistry

local PagedBufferRegistry:{[number]:PagedBuffer} = {}

type BoidEntry = {
	pageId:number,
	slot:number,
	cellId:number
}
local BoidRegistry:{[number]:BoidEntry} = {}
module.BoidRegistry = BoidRegistry

local PAGE_COMPACTION_THRESHOLD:number = 0.25
module.PAGE_COMPACTION_THRESHOLD = PAGE_COMPACTION_THRESHOLD

local BOID_POSITION_AXIS_SIZE:number = 1
module.BOID_POSITION_AXIS_SIZE = BOID_POSITION_AXIS_SIZE

local BOID_VELOCITY_AXIS_SIZE:number = 1
module.BOID_VELOCITY_AXIS_SIZE = BOID_VELOCITY_AXIS_SIZE

local BOID_ID_SIZE:number = 2
module.BOID_ID_SIZE = BOID_ID_SIZE

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
-- 13-15   pad

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

const BOID_ROW_BYTES: number = 16
module.BOID_ROW_BYTES = BOID_ROW_BYTES

module.BOID_ID_OFFSET = BOID_ID_OFFSET

module.POS_X_OFFSET = POS_X_OFFSET
module.POS_Y_OFFSET = POS_Y_OFFSET
module.POS_Z_OFFSET = POS_Z_OFFSET

module.VEL_X_OFFSET = VEL_X_OFFSET
module.VEL_Y_OFFSET = VEL_Y_OFFSET
module.VEL_Z_OFFSET = VEL_Z_OFFSET

module.SPEED_OFFSET = SPEED_OFFSET
module.LAST_TICK_OFFSET = LAST_TICK_OFFSET

module.PATH_NODE_OFFSET = PATH_NODE_OFFSET
module.PATH_VERSION_OFFSET = PATH_VERSION_OFFSET

local function boidOffset(slot: number): number
	return slot * BOID_ROW_BYTES
end
module.boidOffset = boidOffset

local TIME_COURSENESS: number = 0.25
local TIME_SCALE: number = 1/TIME_COURSENESS

local PAGE_CAPACITY: number = 64
module.PAGE_CAPACITY = PAGE_CAPACITY

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

function module.writeBoidId(data: buffer, slot: number, boidId: number)
	buffer.writeu16(data, boidOffset(slot) + BOID_ID_OFFSET, boidId)
end

function module.readBoidId(data: buffer, slot: number): number
	return buffer.readu16(data, boidOffset(slot) + BOID_ID_OFFSET)
end

function module.writePosition(data: buffer, slot: number, x: number, y: number, z: number)
	const offset: number = boidOffset(slot)

	buffer.writeu8(data, offset + POS_X_OFFSET, quantizePositionAxis(x))
	buffer.writeu8(data, offset + POS_Y_OFFSET, quantizePositionAxis(y))
	buffer.writeu8(data, offset + POS_Z_OFFSET, quantizePositionAxis(z))
end

function module.readPosition(data: buffer, slot: number): (number, number, number)
	const offset: number = boidOffset(slot)

	return
		dequantizePositionAxis(buffer.readu8(data, offset + POS_X_OFFSET)),
		dequantizePositionAxis(buffer.readu8(data, offset + POS_Y_OFFSET)),
		dequantizePositionAxis(buffer.readu8(data, offset + POS_Z_OFFSET))
end

function module.writeVelocity(data: buffer, slot: number, x: number, y: number, z: number)
	const offset: number = boidOffset(slot)

	buffer.writeu8(data, offset + VEL_X_OFFSET, quantizeVelocityAxis(x))
	buffer.writeu8(data, offset + VEL_Y_OFFSET, quantizeVelocityAxis(y))
	buffer.writeu8(data, offset + VEL_Z_OFFSET, quantizeVelocityAxis(z))
end

function module.readVelocity(data: buffer, slot: number): (number, number, number)
	const offset: number = boidOffset(slot)

	return
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_X_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_Y_OFFSET)),
		dequantizeVelocityAxis(buffer.readu8(data, offset + VEL_Z_OFFSET))
end

function module.writeSpeed(data: buffer, slot: number, speed: number)
	buffer.writeu8(data, boidOffset(slot) + SPEED_OFFSET, math.clamp(math.round(speed), 0, MAX_U8))
end

function module.readSpeed(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + SPEED_OFFSET)
end

function module.writeLastTick(data: buffer, slot: number, tick: number)
	buffer.writeu16(data, boidOffset(slot) + LAST_TICK_OFFSET, tick % 65536)
end

function module.readLastTick(data: buffer, slot: number): number
	return buffer.readu16(data, boidOffset(slot) + LAST_TICK_OFFSET)
end

function module.writePathNode(data: buffer, slot: number, pathNode: number)
	buffer.writeu8(data, boidOffset(slot) + PATH_NODE_OFFSET, math.clamp(math.round(pathNode), 0, MAX_U8))
end

function module.readPathNode(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + PATH_NODE_OFFSET)
end

function module.writePathVersion(data: buffer, slot: number, pathVersion: number)
	buffer.writeu8(data, boidOffset(slot) + PATH_VERSION_OFFSET, pathVersion % 256)
end

function module.readPathVersion(data: buffer, slot: number): number
	return buffer.readu8(data, boidOffset(slot) + PATH_VERSION_OFFSET)
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
module.newPage = newPage

local nextPagedBufferId: number = 0
function module.newPagedBuffer():PagedBuffer
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

function module.deletePagedBuffer(pagedBufferId: number)
	const pagedBuffer:PagedBuffer = PagedBufferRegistry[pagedBufferId]
	if not pagedBuffer then
		return
	end
	PagedBufferRegistry[pagedBufferId] = nil
	
	for _, page: Page in pagedBuffer.pages do
		PageRegistry[page.id] = nil
	end
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

function module.appendPage(pagedBuffer: PagedBuffer, page: Page)
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
	module.appendPage(pagedBuffer, page)

	return page
end
module.getOpenPage = getOpenPage

function module.insertBoid(
	pagedBuffer: PagedBuffer,
	px: number, py: number, pz: number,
	vx: number, vy: number, vz: number,
	currentTick: number,
	boidId: number,
	cellId: number
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
	module.writePosition(data, slot, px, py, pz)
	module.writeVelocity(data, slot, dir.X, dir.Y, dir.Z)
	module.writeSpeed(data, slot, speed)
	module.writeLastTick(data, slot, currentTick)
	module.writeBoidId(data, slot, boidId)

	module.writePathNode(data, slot, 0)
	module.writePathVersion(data, slot, 0)

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

local function deleteBoidAtSlot(page: Page, slot: number, pagedBuffer: PagedBuffer?): boolean
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
		pagedBuffer = pagedBuffer or PagedBufferRegistry[page.setId]
		pagedBuffer.openPages[page.id] = true
	end
	
	return true
end
module.deleteBoidAtSlot = deleteBoidAtSlot

function module.deleteBoid(boidId: number)
	const boidEntry: BoidEntry? = BoidRegistry[boidId]
	if not boidEntry then
		return
	end
	
	deleteBoidAtSlot(PageRegistry[boidEntry.pageId], boidEntry.slot)
end

function module.removePage(pagedBuffer: PagedBuffer, page: Page)
	const pages: {Page} = pagedBuffer.pages
	const swapPage: Page = pages[pagedBuffer.pageCount]
	
	pages[page.index] = swapPage
	swapPage.index = page.index
	
	pagedBuffer.pageCount -= 1
	pagedBuffer.openPages[page.id] = nil
	PageRegistry[page.id] = nil
end

function module.liveWords(page: Page):()->(number?, number?)
	const dead: buffer = page.dead
	const cursor: number = page.cursor

	local wordIndex: number = 0
	const activeWordCount: number = math.ceil(cursor / SLOTS_PER_WORD)
	
	local baseSlot: number, liveWord: number, remaining: number
	return function():(number?, number?)
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
	end
end

-- for debugging
function module.countLive(pages: {Page}): number
	local actualLive = 0
	for _, page: Page in pages do
		for baseSlot: number, liveMask: number in module.liveWords(page) :: () -> (number, number) do
			while liveMask ~= 0 do
				actualLive += 1
				liveMask = bit32.band(liveMask, liveMask - 1)
			end
		end
	end
	return actualLive
end

function module.restorePendingPages(pagedBuffer: PagedBuffer)
	const openPages: {[number]:boolean} = pagedBuffer.openPages
	const pendingPages: {[number]:boolean} = pagedBuffer.pendingPages
	
	for pageId: number, _ in pendingPages do
		openPages[pageId] = true
	end
	table.clear(pendingPages)
end

-- specifically for marking current pages pending during a job, causes them to be skipped by getOpenPage
function module.markPagesPending(pagedBuffer: PagedBuffer)
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
function module.overwriteWithJobResults(dest: PagedBuffer, src: PagedBuffer, lockedPageCount: number)
	module.restorePendingPages(dest)
	
	const destPages: {Page} = dest.pages
	const srcPages: {Page} = src.pages
	const openPages: {[number]:boolean} = dest.openPages
	
	local srcPage: Page
	local destPage: Page
	for i: number = 1, lockedPageCount do
		srcPage = srcPages[i]
		destPage = destPages[i]
		
		-- check for destPage == nil in case it was removed due to all boids leaving it
		-- then remove page from list
		
		-- for debugging
		assert(destPage ~= nil, "Missing destination page")
		assert(srcPage ~= nil, "Missing source page")
		assert(srcPage.id == destPage.id, "Job result page id mismatch")

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

return module
