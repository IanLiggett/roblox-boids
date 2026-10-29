--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local viewer = require(package.Boids.JobBuilder.ViewerLOD)
	local config = require(package.LODConfig)

	t.test("network presets use independent position and velocity accuracy", function()
		local low, medium, high = config.GetPreset("low").network, config.GetPreset("medium").network, config.GetPreset("high").network
		t.expect.equal(low.nearPositionError, 4)
		t.expect.equal(low.farPositionError, 16)
		t.expect.equal(low.nearVelocityError, 2)
		t.expect.equal(low.farVelocityError, 8)
		t.expect.equal(medium.nearPositionError, 2)
		t.expect.equal(medium.farPositionError, 8)
		t.expect.equal(medium.nearVelocityError, 1)
		t.expect.equal(medium.farVelocityError, 4)
		t.expect.equal(high.nearPositionError, 1)
		t.expect.equal(high.farPositionError, 4)
		t.expect.equal(high.nearVelocityError, 1)
		t.expect.equal(high.farVelocityError, 2)
	end)

	t.test("observer distance chooses squared tolerances and disabled viewers have no interest", function()
		local id = 123456789
		local origin = Vector3.zero
		local center = Vector3.one * 32
		local active = config.GetActive().network
		viewer.SetViewerObservers(id, false, {center})
		local nearPosition, nearVelocity = viewer.GetNetworkTolerances(id, origin)
		t.expect.equal(nearPosition, active.nearPositionError ^ 2)
		t.expect.equal(nearVelocity, active.nearVelocityError ^ 2)
		viewer.SetViewerObservers(id, false, {center + Vector3.xAxis * active.farDistance})
		local farPosition, farVelocity = viewer.GetNetworkTolerances(id, origin)
		t.expect.equal(farPosition, active.farPositionError ^ 2)
		t.expect.equal(farVelocity, active.farVelocityError ^ 2)
		viewer.SetViewerObservers(id, false, {center + Vector3.xAxis * (active.farDistance + 1)})
		t.expect.equal(viewer.GetNetworkTolerances(id, origin), nil)
		viewer.SetViewerObservers(id, false, {})
		t.expect.equal(viewer.GetNetworkTolerances(id, origin), nil)
	end)
end
