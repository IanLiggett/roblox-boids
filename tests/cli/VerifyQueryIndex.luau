--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = (require("@lune/roblox") :: unknown) :: {Vector3: typeof(Vector3)}
local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base = root .. "src/BoidsSystem/BoidsReplicated/"
local environment = {Vector3 = roblox.Vector3, workspace = {GetServerTimeNow = function(): number return 0 end}}
local quantization = luau.load(fs.readFile(base .. "Quantization.luau"), {injectGlobals = true, environment = environment})()
local function loadIndex(source: string)
	return luau.load(source, {injectGlobals = true, environment = {
		Vector3 = roblox.Vector3, script = {Parent = {Quantization = quantization}},
		require = function(value) return value end,
	}})()
end
local Vector3 = roblox.Vector3
local function verify(source: string): ()
	local index = loadIndex(source).new()
	for id = 1, 3 do index:Update(id, Vector3.new(id, 1, 1), 2) end
	index:Remove(1)
	index:Update(3, Vector3.new(65, 1, 1), 2)
	local found = false
	for _, hit in index:QueryRadius(Vector3.new(2, 1, 1), 0.01) do
		if hit.boidId == 2 then found = true end
	end
	assert(found, "Swapped neighbor disappeared from its spatial bucket")
	local positions = {}
	index = loadIndex(source).new()
	for id = 1, 64 do
		positions[id] = Vector3.new(id % 8, 1, id // 8)
		index:Update(id, positions[id], 2)
	end
	for step = 1, 1024 do
		local id = (step * 37) % 64 + 1
		positions[id] = Vector3.new((step % 5 - 2) * 32 + id % 8, 1, (step % 3 - 1) * 32 + id // 8)
		index:Update(id, positions[id], 2)
		if step % 32 == 0 then
			for otherId, position in positions do
				local present = false
				for _, hit in index:QueryRadius(position, 0.01) do
					if hit.boidId == otherId then present = true end
				end
				assert(present, "Migrating neighbor disappeared at step " .. step .. " id " .. otherId)
			end
		end
	end
end
local main = process.exec("git", {"-C", if root == "" then "." else root, "show", "c2b35bbf:src/BoidsSystem/BoidsReplicated/BoidQueryIndex.luau"})
assert(main.ok, main.stderr)
assert(not pcall(verify, main.stdout), "Pinned main no longer reproduces the expected bucket bug")
verify(fs.readFile(base .. "BoidQueryIndex.luau"))
print("PASS query-index regression reproduces on pinned main and passes with slot repair")
