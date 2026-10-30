--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local viewer = require(package.Boids.JobBuilder.ViewerLOD)
	local config = require(package.LODConfig)

	t.test("network presets use independent position and velocity accuracy", function()
		local low, medium, high = config.GetPreset("low").network.renderer, config.GetPreset("medium").network.renderer, config.GetPreset("high").network.renderer
		t.expect.equal(low.nearPositionError, 8)
		t.expect.equal(low.farPositionError, 32)
		t.expect.equal(low.nearVelocityError, 4)
		t.expect.equal(low.farVelocityError, 16)
		t.expect.equal(medium.nearPositionError, 2)
		t.expect.equal(medium.farPositionError, 8)
		t.expect.equal(medium.nearVelocityError, 1)
		t.expect.equal(medium.farVelocityError, 4)
		t.expect.equal(high.nearPositionError, 1)
		t.expect.equal(high.farPositionError, 4)
		t.expect.equal(high.nearVelocityError, 1)
		t.expect.equal(high.farVelocityError, 2)
	end)

	t.test("simulation profiles triple only error tolerances and both profiles are immutable", function()
		for _, preset in {"low", "medium", "high"} do
			local network = config.GetPreset(preset :: config.PresetName).network
			local simulation, renderer = network.simulation, network.renderer
			t.expect.equal(simulation.minSendIntervalSeconds, 0)
			t.expect.equal(renderer.minSendIntervalSeconds, 0)
			t.expect.equal(simulation.nearDistance, renderer.nearDistance)
			t.expect.equal(simulation.farDistance, renderer.farDistance)
			t.expect.equal(simulation.nearPositionError, renderer.nearPositionError * 3)
			t.expect.equal(simulation.farPositionError, renderer.farPositionError * 3)
			t.expect.equal(simulation.nearVelocityError, renderer.nearVelocityError * 3)
			t.expect.equal(simulation.farVelocityError, renderer.farVelocityError * 3)
			t.expect.truthy(table.isfrozen(simulation))
			t.expect.truthy(table.isfrozen(renderer))
		end
	end)

	t.test("network selection follows presentation mode and live quality changes", function()
		local mode = require(package.ClientPresentationConfig).Resolve()
		local original = config.GetPresetName()
		local ok, err = pcall(function()
			for _, preset in {"low", "medium", "high"} do
				config.SetPreset(preset :: config.PresetName)
				t.expect.equal(config.GetNetworkConfig(), config.GetActive().network[mode])
			end
		end)
		config.SetPreset(original)
		assert(ok, tostring(err))
	end)

	t.test("observer distance chooses squared tolerances and disabled viewers have no interest", function()
		local id = 123456789
		local origin = Vector3.zero
		local center = Vector3.one * 32
		local active = config.GetNetworkConfig()
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
