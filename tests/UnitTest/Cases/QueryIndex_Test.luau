--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local QueryIndex = require(package.BoidQueryIndex)
	local function contains(index: QueryIndex.Index, id: number, position: Vector3): boolean
		for _, hit in index:QueryRadius(position, 0.01) do
			if hit.boidId == id then return true end
		end
		return false
	end
	t.test("query bucket swap removal repairs the moved entry before migration", function(): ()
		local index = QueryIndex.new()
		for id = 1, 3 do index:Update(id, Vector3.new(id, 1, 1), 2) end
		index:Remove(1)
		index:Update(3, Vector3.new(65, 1, 1), 2)
		t.expect.truthy(contains(index, 2, Vector3.new(2, 1, 1)))
		t.expect.truthy(contains(index, 3, Vector3.new(65, 1, 1)))
		t.expect.equal(index:GetCount(), 2)
	end)
	t.test("query bucket removal and reused IDs preserve neighboring entries", function(): ()
		local index = QueryIndex.new()
		for id = 1, 5 do index:Update(id, Vector3.new(id, 1, 1), 2) end
		index:Remove(2)
		index:Remove(5)
		index:Update(2, Vector3.new(-65, 1, 1), 2)
		index:Update(4, Vector3.new(96, 1, 1), 2)
		for id, position in {[1] = Vector3.new(1, 1, 1), [2] = Vector3.new(-65, 1, 1), [3] = Vector3.new(3, 1, 1), [4] = Vector3.new(96, 1, 1)} do
			t.expect.truthy(contains(index, id, position))
		end
		t.expect.equal(index:GetCount(), 4)
	end)
	t.test("repeated query-index cell migration retains exact local discoverability", function(): ()
		local index = QueryIndex.new()
		local positions: {Vector3} = {}
		for id = 1, 64 do
			positions[id] = Vector3.new(id % 8, 1, id // 8)
			index:Update(id, positions[id], 2)
		end
		for step = 1, 1024 do
			local id = (step * 37) % 64 + 1
			positions[id] = Vector3.new((step % 5 - 2) * 32 + id % 8, 1, (step % 3 - 1) * 32 + id // 8)
			index:Update(id, positions[id], 2)
			t.expect.truthy(contains(index, id, positions[id]))
			if step % 64 == 0 then
				for otherId, position in positions do t.expect.truthy(contains(index, otherId, position)) end
			end
		end
		t.expect.equal(index:GetCount(), 64)
	end)
end
