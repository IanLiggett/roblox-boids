--!strict
return function(t: any): ()
	local codec = require(game.ReplicatedStorage.BoidsReplicated.Boids.StatsCodec)
	t.test("round trips the canonical 16 byte stats row", function()
		local data = buffer.create(codec.ROW_BYTES)
		codec.WriteBoidRow(data, 0, 42, 20, 1, 16, 2, 3, 4, 5, 6, 7, 8)
		t.expect.equal(buffer.len(data), 16)
		t.expect.deepEqual({ codec.ReadBoidRow(data, 0) }, { 42, 20, 1, 16, 2, 3, 4, 5, 6, 7, 8 })
	end)
end