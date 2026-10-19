--!strict

local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local allocator = require(package.Boids.IdAllocator)

	t.test("opposite ends, reservations and idempotent release", function()
		local pool = allocator.New()
		t.expect.equal(allocator.Take(pool, false), 0)
		t.expect.equal(allocator.Take(pool, true), 65535)
		t.expect.truthy(allocator.Reserve(pool, 1))
		t.expect.falsy(allocator.Reserve(pool, 1))
		t.expect.equal(allocator.Take(pool, false), 2)
		t.expect.truthy(allocator.Release(pool, 0))
		t.expect.falsy(allocator.Release(pool, 0))
		t.expect.equal(allocator.Take(pool, false), 0)
		t.expect.equal(allocator.Take(pool, true), 65534)
	end)

	t.test("all u16 slots exhaust and summaries recover across every level", function()
		local pool = allocator.New()
		for id = 0, 65535 do
			t.expect.equal(allocator.Take(pool, false), id)
			if id % 1024 == 0 then task.wait() end
		end
		t.expect.equal(allocator.Take(pool, false), nil)
		t.expect.equal(allocator.Take(pool, true), nil)
		for _, id in {0, 31, 32, 1023, 1024, 32767, 32768, 65535} do
			t.expect.truthy(allocator.Release(pool, id))
			t.expect.equal(allocator.Take(pool, true), id)
			t.expect.equal(allocator.Take(pool, false), nil)
		end
	end)
end
