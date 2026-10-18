--!strict
--!native

local IdAllocator = {}

export type Allocator = {
	levels: {buffer},
}

local WORD_COUNTS: {number} = {2048, 64, 2, 1}
local FULL_WORD = 0xFFFFFFFF

function IdAllocator.New(): Allocator
	local levels: {buffer} = {}
	for level, count in WORD_COUNTS do
		local data = buffer.create(count * 4)
		for word = 0, count - 1 do buffer.writeu32(data, word * 4, FULL_WORD) end
		levels[level] = data
	end
	-- Only two children exist beneath the root.
	buffer.writeu32(levels[4], 0, 3)
	return {levels = levels}
end

local function setFree(self: Allocator, id: number, isFree: boolean): boolean
	local index = id
	for level = 1, 4 do
		local wordIndex = math.floor(index / 32)
		local offset = wordIndex * 4
		local mask = bit32.lshift(1, index % 32)
		local data = self.levels[level]
		local previous = buffer.readu32(data, offset)
		local updated = if isFree then bit32.bor(previous, mask) else bit32.band(previous, bit32.bnot(mask))
		if previous == updated then return level ~= 1 end
		buffer.writeu32(data, offset, updated)
		-- Ancestors describe whether this word has any free children.
		if (previous == 0) == (updated == 0) then return true end
		isFree = updated ~= 0
		index = wordIndex
	end
	return true
end

function IdAllocator.Reserve(self: Allocator, id: number): boolean
	return setFree(self, id, false)
end

function IdAllocator.Release(self: Allocator, id: number): boolean
	return setFree(self, id, true)
end

function IdAllocator.Take(self: Allocator, highest: boolean): number?
	if buffer.readu32(self.levels[4], 0) == 0 then return nil end
	local index = 0
	for level = 4, 1, -1 do
		local word = buffer.readu32(self.levels[level], index * 4)
		local bit = if highest then 31 - bit32.countlz(word) else bit32.countrz(word)
		index = index * 32 + bit
	end
	IdAllocator.Reserve(self, index)
	return index
end

return IdAllocator
