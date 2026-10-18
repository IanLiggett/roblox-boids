--!strict
-- Run from the package or host root: lune run <package>/tests/cli/VerifyDynamicIds.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")
local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base = root .. "src/BoidsSystem/BoidsReplicated/"
local totals = {run = 0, passed = 0, failed = 0}
local t = {expect = {}}
function t.expect.equal(a, b) assert(a == b, `expected {b}, got {a}`) end
function t.expect.truthy(a) assert(a, "expected truthy") end
function t.expect.falsy(a) assert(not a, "expected falsy") end
function t.test(name, fn)
	totals.run += 1
	local ok, err = pcall(fn)
	if ok then totals.passed += 1; print("PASS", name)
	else totals.failed += 1; warn("FAIL", name, err) end
end
local function load(path, environment)
	return luau.load(fs.readFile(path), {debugName = path, environment = environment, injectGlobals = true})()
end
local allocator = load(base .. "Boids/IdAllocator.luau", {})
local package = {Boids = {IdAllocator = allocator}}
local function identity(value) return value end
load(root .. "tests/UnitTest/Cases/IdAllocator_Test.luau", {
	game = {ReplicatedStorage = {BoidsReplicated = package}}, require = identity, task = task,
})(t)

-- Load the unchanged production client intake against deterministic services.
local function event()
	local callbacks = {}
	return {
		Connect = function(_, callback) table.insert(callbacks, callback); return {Disconnect = function() end} end,
		Fire = function(_, ...) for _, callback in callbacks do callback(...) end end,
	}
end

local function coordinatorFixture(isClient)
	local heartbeat = event()
	local storage = {BoidRegistry = {}, PageRegistry = {[1] = {data = buffer.create(1)}}}
	local dependencies = {
		SharedTypes = {BoidModels = {Boid = 0}},
		Quantization = {GetNumericalKey = function() return 0 end, ConvertCoordsToGrid = function() return 0, 0, 0 end, CurrentSimTick = function() return 0 end},
		BoidStorage = storage,
		RuntimeMetrics = {State = {}}, RuntimeConfig = {Resolve = function() return {actorCount = 0, targetActorJobMs = 4} end},
		Dependencies = {Benchmarker = {Value = {newBenchmarker = function() return {} end}}},
	}
	local packets, serverDeletes = {}, 0
	local function nothing() end
	local noops = setmetatable({}, {__index = function() return nothing end})
	dependencies.NetworkResults = noops
	dependencies.DebugPresentation = noops
	dependencies.LODConfig = {}
	dependencies.ClientRendererBridge = {ReceiveDeleteGroup = nothing, ReceiveDeleteBoidBatch = function(packet) table.insert(packets, buffer.readu16(packet, 0)) end}
	dependencies.SimulationReplication = setmetatable({ServerDeleteBoids = function() serverDeletes += 1 end}, {__index = function() return nothing end})
	local cells = {WakeTime = nothing, IsDue = nothing}
	function cells.AddBoid(group, cellId, _, _, id)
		storage.BoidRegistry[id] = {cellId = cellId, pageId = 1, slot = id}
		local cell = group.activeCells[cellId]
		if not cell then
			cell = {id = cellId, boidCount = 0, pages = {}}
			group.activeCells[cellId] = cell
			group.cellCount += 1
		end
		cell.boidCount += 1
	end
	function cells.Remove(group, cell) group.activeCells[cell.id] = nil; group.cellCount -= 1 end
	function storage.deleteBoidAtSlot() return true end
	local scheduler = {NewScheduler = function() return {schedulees = {}} end, RebuildSchedulerHeap = nothing}
	local batches = setmetatable({NewBoidsStatsUpdate = function() return {} end}, {__index = function() return nothing end})
	local actor = {instance = {Parent = {SendMessage = nothing}}}
	local script = {Parent = dependencies, Scheduler = scheduler, BoidBatches = batches, JobBuilder = noops,
		ActorsInitializer = {actors = {actor}, InitializeBoidActors = nothing, CancelGroup = nothing},
		Diagnostics = {}, Cells = cells, IdAllocator = allocator, ResultCommit = {},
	}
	local service = {IsClient = function() return isClient end, IsServer = function() return not isClient end, Heartbeat = heartbeat}
	local boids = load(base .. "Boids/init.luau", {script = script, require = identity,
		game = {GetService = function(_, name) return if name == "RunService" then service else {} end},
		workspace = {GetServerTimeNow = function() return 100 end},
	})
	boids.Start()
	local group = boids.NewGroup(0)
	local function spawn(id) return boids.NewBoid(group, roblox.Vector3.zero, roblox.Vector3.zero, 20, 3, 60, 35, 200, 0, 3, 100, 10, 50, nil, id) end
	return {boids = boids, group = group, spawn = spawn, heartbeat = heartbeat, packets = packets, actor = actor,
		serverDeletes = function() return serverDeletes end, storage = storage}
end

t.test("production coordinator reserves IDs across deletion notifications and server takeover", function()
	local f = coordinatorFixture(true)
	t.expect.equal(f.spawn(), 65535)
	t.expect.falsy(f.boids.IsServerBoid(65535))
	f.boids.ReserveServerBoidId(65535)
	local stop = f.boids.SubscribeDeleted(function(ids)
		t.expect.equal(ids[1], 65535)
		t.expect.truthy(f.boids.IsDeletionPending(65535))
		t.expect.equal(f.spawn(), 65534)
	end)
	f.boids.QueueDeleteBoid(65535)
	f.heartbeat:Fire()
	stop()
	t.expect.equal(f.spawn(), 65533)
	t.expect.equal(f.spawn(65535), 65535)
	f.boids.ReleaseServerBoidId(65535)
	t.expect.truthy(f.boids.IsServerBoid(65535))
	f.boids.QueueDeleteBoid(65535)
	t.expect.falsy(f.boids.IsServerBoid(65535))
	f.heartbeat:Fire()
	t.expect.equal(f.spawn(), 65535)
	t.expect.falsy(f.boids.IsServerBoid(65535))
end)

t.test("production coordinator supports full-u16 group deletion on both processes", function()
	for _, client in {false, true} do
		local f = coordinatorFixture(client)
		for id = 0, 65535 do
			t.expect.equal(f.spawn(), if client then 65535 - id else id)
			if id % 1024 == 0 then task.wait() end
		end
		-- Exhaustion is checked by the allocator test without emitting a runtime warning.
		f.boids.DestroyGroup(f.group)
		t.expect.equal(next(f.storage.BoidRegistry), nil)
		if client then
			t.expect.equal(#f.packets, 2)
			t.expect.equal(f.packets[1], 65535)
			t.expect.equal(f.packets[2], 1)
		else t.expect.equal(f.serverDeletes(), 1) end
		f.group = f.boids.NewGroup(0)
		-- The spawn closure keeps its original group, so create explicitly here.
		t.expect.equal(f.boids.NewBoid(f.group, roblox.Vector3.zero, roblox.Vector3.zero, 20, 3, 60, 35, 200, 0, 3, 100, 10, 50), if client then 65535 else 0)
	end
end)

t.test("production coordinator holds a collision ID until the worker-owned cell settles", function()
	local f = coordinatorFixture(true)
	f.spawn()
	f.boids.ReserveServerBoidId(65535)
	f.group.scheduler.schedulees[0] = {alreadyScheduled = true}
	f.boids.QueueDeleteBoid(65535)
	f.heartbeat:Fire()
	t.expect.truthy(f.boids.HasBoid(65535))
	t.expect.truthy(f.boids.IsDeletionPending(65535))
	t.expect.equal(#f.packets, 0)
	f.group.scheduler.schedulees[0].alreadyScheduled = false
	f.heartbeat:Fire()
	t.expect.falsy(f.boids.HasBoid(65535))
	t.expect.equal(#f.packets, 1)
	t.expect.equal(f.spawn(), 65534)
	f.boids.ReleaseServerBoidId(65535)
	t.expect.equal(f.spawn(), 65535)
end)

t.test("retiring groups stop reporting server ownership before a yielded commit settles", function()
	local f = coordinatorFixture(false)
	f.spawn()
	f.actor.execution = {group = f.group, phase = "completing"}
	f.boids.DestroyGroup(f.group)
	t.expect.truthy(f.boids.HasBoid(0))
	t.expect.falsy(f.boids.IsServerBoid(0))
	f.actor.execution = nil
	f.heartbeat:Fire()
	t.expect.falsy(f.boids.HasBoid(0))
end)

local function fixture()
	local heartbeat, incoming = event(), event()
	local pool = allocator.New()
	local live, pendingDeletion, holds = {}, {}, {}
	local deletions = 0
	local boids = {}
	function boids.HasBoid(id) return live[id] ~= nil end
	function boids.IsServerBoid(id) return live[id] == "server" and not pendingDeletion[id] end
	function boids.IsDeletionPending(id) return pendingDeletion[id] == true end
	function boids.ReserveServerBoidId(id) holds[id] = (holds[id] or 0) + 1; allocator.Reserve(pool, id) end
	function boids.ReleaseServerBoidId(id)
		assert(holds[id], "unbalanced reservation")
		holds[id] -= 1
		if holds[id] == 0 then holds[id] = nil; if not live[id] then allocator.Release(pool, id) end end
	end
	function boids.QueueDeleteBoid(id)
		if live[id] and not pendingDeletion[id] then deletions += 1; pendingDeletion[id] = true end
	end
	function boids.NewGroup(_, id) return {id = id} end
	function boids.NewBoid(_, _, _, _, _, _, _, _, _, _, _, _, _, _, id)
		assert(not live[id] and not pendingDeletion[id], "overwrote live ID")
		allocator.Reserve(pool, id); live[id] = "server"; return id
	end
	local groupRetiring = {}
	function boids.IsGroupRetiring(id) return groupRetiring[id] == true end
	function boids.DestroyGroup(group)
		for id, owner in live do if owner == "server" then boids.QueueDeleteBoid(id) end end
	end
	function boids.SetReconciliationTargets() end
	local retirements = {}
	local correction = {New = function() return {
		Retire = function(id, cutoff) retirements[id] = cutoff or 0 end,
		Consume = function() end,
	} end}
	local runService = {IsClient = function() return true end, IsServer = function() return false end, Heartbeat = heartbeat}
	local remotes = {SimulationState = {OnClientEvent = incoming}, RequestSimulationState = {FireServer = function() end}, BoidJobUpdate = {OnClientEvent = event()}}
	local shared = {Remotes = remotes, SharedTypes = {}, NetworkResults = {}, RuntimeTypes = {}}
	local script = {Parent = shared, CorrectionIntake = correction, Replay = {}, Bootstrap = {}}
	local workspace = {DescendantAdded = event()}
	local replication = load(base .. "SimulationReplication/init.luau", {
		script = script, require = identity, Vector3 = roblox.Vector3, workspace = workspace,
		game = {GetService = function(_, name) return if name == "RunService" then runService else {} end},
	})
	replication.StartClient(boids)
	local function spawn(group, ids)
		local data = buffer.create(#ids * 37)
		for row, id in ids do buffer.writeu16(data, (row - 1) * 37, id) end
		incoming:Fire("Boids", group, data)
	end
	local function settle(id)
		live[id], pendingDeletion[id] = nil, nil
		if not holds[id] then allocator.Release(pool, id) end
	end
	local function localSpawn()
		local id = allocator.Take(pool, true)
		if id then live[id] = "local" end
		return id
	end
	return {live = live, holds = holds, incoming = incoming, spawn = spawn, settle = settle,
		heartbeat = heartbeat, localSpawn = localSpawn, retiring = groupRetiring,
		deletions = function() return deletions end, pendingDeletion = pendingDeletion}
end

t.test("collision waits for deletion, reserves slot, and preserves other local IDs", function()
	local f = fixture()
	f.incoming:Fire("Group", 0, 0)
	t.expect.equal(f.localSpawn(), 65535)
	t.expect.equal(f.localSpawn(), 65534)
	f.spawn(0, {65535})
	t.expect.equal(f.live[65535], "local")
	t.expect.equal(f.deletions(), 1)
	f.spawn(0, {65535})
	t.expect.equal(f.deletions(), 1)
	t.expect.equal(f.holds[65535], 1)
	f.settle(65535)
	t.expect.equal(f.localSpawn(), 65533)
	f.heartbeat:Fire()
	t.expect.equal(f.live[65535], "server")
	t.expect.equal(f.live[65534], "local")
	t.expect.equal(f.holds[65535], nil)
	f.spawn(0, {65535})
	t.expect.equal(f.deletions(), 1)
end)

t.test("server deletion cancels takeover without leaking reservations", function()
	local f = fixture()
	f.incoming:Fire("Group", 0, 0)
	f.localSpawn()
	f.spawn(0, {65535})
	f.incoming:Fire("DeleteBoids", {65535}, 10)
	t.expect.equal(f.holds[65535], nil)
	f.settle(65535)
	f.heartbeat:Fire()
	t.expect.equal(f.live[65535], nil)
	t.expect.equal(f.localSpawn(), 65535)
end)

t.test("queued group replacement reserves rows and handles delete/reuse order", function()
	local f = fixture()
	f.retiring[0] = true
	f.incoming:Fire("Group", 0, 0)
	f.spawn(0, {65535, 65534})
	f.incoming:Fire("DeleteBoids", {65535}, 10)
	f.spawn(0, {65535})
	t.expect.equal(f.holds[65535], 2)
	t.expect.equal(f.localSpawn(), 65533)
	f.retiring[0] = nil
	f.heartbeat:Fire()
	t.expect.truthy(f.pendingDeletion[65535])
	f.settle(65535)
	f.heartbeat:Fire()
	t.expect.equal(f.live[65535], "server")
	t.expect.equal(f.live[65534], "server")
	t.expect.equal(next(f.holds), nil)
end)

t.test("group destruction cancels pending collision spawns", function()
	local f = fixture()
	f.incoming:Fire("Group", 0, 0)
	f.localSpawn()
	f.spawn(0, {65535})
	f.incoming:Fire("DestroyGroup", 0)
	f.settle(65535)
	f.heartbeat:Fire()
	t.expect.equal(f.live[65535], nil)
	t.expect.equal(next(f.holds), nil)
end)

local hitStreamerPath = "src/StarterPlayer/StarterPlayerScripts/BoidHitStreamer.luau"
if fs.isFile(hitStreamerPath) then
	t.test("hit reports exclude locals, retired IDs and ownership changes; Stop disconnects", function()
		local live = {[1] = true, [65535] = true}
		local callbacks, packets = {}, {}
		local deletion
		local api = {
			IsServerBoid = function(id) return live[id] == true end,
			SubscribeDeleted = function(callback) deletion = callback; return function() deletion = nil end end,
		}
		local remote = {FireServer = function(_, packet) table.insert(packets, packet) end}
		local function child(self, name) return self[name] end
		local shared = {WaitForChild = child, Boids = api, Remotes = {WaitForChild = child, ReportBoidHits = remote}}
		local replicatedStorage = {WaitForChild = child, BoidsReplicated = shared}
		local streamer = load(hitStreamerPath, {require = identity, Vector3 = roblox.Vector3,
			game = {GetService = function() return replicatedStorage end},
			task = {delay = function(_, callback) table.insert(callbacks, callback) end},
		})
		streamer.QueueHits(1, roblox.Vector3.zero, {{boidId = 42}})
		t.expect.equal(#callbacks, 0)
		streamer.QueueHits(1, roblox.Vector3.zero, {{boidId = 1}, {boidId = 65535}, {boidId = 42}})
		callbacks[1]()
		t.expect.equal(buffer.readu16(packets[1], 44), 2)
		t.expect.equal(buffer.readu16(packets[1], 46), 1)
		t.expect.equal(buffer.readu16(packets[1], 48), 65535)
		streamer.QueueHits(1, roblox.Vector3.zero, {{boidId = 1}, {boidId = 65535}})
		deletion({1})
		live[1], live[65535] = true, nil
		callbacks[2]()
		t.expect.equal(buffer.readu16(packets[2], 44), 0)
		streamer.QueueHits(1, roblox.Vector3.zero, {}, true)
		callbacks[3]()
		t.expect.equal(buffer.readu16(packets[3], 44), 0)
		streamer.QueueHits(1, roblox.Vector3.zero, {{boidId = 1}})
		streamer.Stop()
		t.expect.equal(deletion, nil)
		callbacks[4]()
		t.expect.equal(#packets, 3)
	end)
end

-- Compile every edited production source without starting a runtime.
for _, path in {
	base .. "Boids/init.luau", base .. "RuntimeTypes.luau", base .. "SimulationReplication/CorrectionIntake.luau",
	root .. "src/BoidsSystem/BoidsClient/Scenarios/Observation/init.luau",
	root .. "src/BoidsSystem/BoidsClient/Scenarios/Observation/Inspector/init.luau",
	root .. "src/BoidsSystem/Server/Scenarios/Observation.luau",
	"src/StarterPlayer/StarterPlayerScripts/BoidHitStreamer.luau",
} do
	if fs.isFile(path) then t.test("compile " .. path, function() luau.compile(fs.readFile(path)) end) end
end
print(totals)
assert(totals.failed == 0, "dynamic ID checks failed")
