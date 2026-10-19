--!strict
-- Check committed fixtures against the same generators used by Studio.
-- --emit prints replacement sources as JSON for a reviewed source update.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local luau = require("@lune/luau")
local process = require("@lune/process")

local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
type Entry = {generator: string, source: string, target: string}
local entries: {Entry} = {
	{generator = "PrepareWorkerFixture", source = "Boids/WorkerCore.luau", target = "WorkerCoreStep01"},
	{generator = "PrepareSchedulerFixture", source = "Boids/JobBuilder/init.luau", target = "SchedulerDispatch"},
}
local sources: {[string]: string} = {}
for _, entry in entries do
	local generate: (string?) -> string = luau.load(fs.readFile(root .. "tests/UnitTest/" .. entry.generator .. ".luau"))()
	local generated = generate(fs.readFile(root .. "src/BoidsSystem/BoidsReplicated/" .. entry.source))
	local target = root .. "tests/UnitTest/Fixtures/" .. entry.target .. ".luau"
	sources[target] = generated
	if process.args[1] ~= "--emit" then
		assert(fs.readFile(target):gsub("\r\n", "\n") == generated:gsub("\r\n", "\n"), target .. " is stale")
		print("PASS generated fixture matches production", entry.target)
	end
end
if process.args[1] == "--emit" then print(serde.encode("json", sources)) end
