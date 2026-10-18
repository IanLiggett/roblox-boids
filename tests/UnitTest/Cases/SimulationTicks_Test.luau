--!strict

local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local Quantization = require(game.ReplicatedStorage.BoidsReplicated.Quantization)

	t.test("background prediction preserves twelve seconds plus scheduling delay", function()
		t.expect.equal(Quantization.TickDeltaSeconds(25261, 24539), 722 / 60)
		t.expect.equal(Quantization.TickDeltaSeconds(25289, 24561), 728 / 60)
	end)

	t.test("background elapsed time survives u16 tick wrap", function()
		t.expect.equal(Quantization.TickDeltaSeconds(186, 65000), 722 / 60)
	end)

	t.test("same tick and ordinary simulation intervals remain exact", function()
		t.expect.equal(Quantization.TickDeltaSeconds(100, 100), 0)
		t.expect.equal(Quantization.TickDeltaSeconds(101, 100), 1 / 60)
		t.expect.equal(Quantization.TickDeltaSeconds(0, 65535), 1 / 60)
	end)

	t.test("scheduling headroom includes the thirty two second boundary", function()
		t.expect.equal(Quantization.TickDeltaSeconds(2020, 100), 32)
	end)

	t.test("implausible stale and backward ticks remain rejected", function()
		t.expect.equal(Quantization.TickDeltaSeconds(2021, 100), 0)
		t.expect.equal(Quantization.TickDeltaSeconds(99, 100), 0)
	end)
end
