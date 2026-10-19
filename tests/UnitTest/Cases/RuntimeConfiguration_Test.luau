--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local config = require(package.RuntimeConfig)
	local defaultActorCount = if game:GetService("RunService"):IsClient() then 16 else 2
	t.test("generic configuration defaults and independent overrides", function()
		local defaults = config.Resolve(nil)
		t.expect.equal(defaults.actorCount,defaultActorCount)
		t.expect.equal(defaults.targetActorJobMs,4)
		t.expect.equal(config.Resolve({actorCount=1}).targetActorJobMs,4)
		t.expect.equal(config.Resolve({targetActorJobMs=8}).actorCount,defaultActorCount)
		local resolved = config.Resolve({actorCount=32,targetActorJobMs=0.5})
		t.expect.equal(resolved.actorCount,32)
		t.expect.equal(resolved.targetActorJobMs,0.5)
		t.expect.truthy(table.isfrozen(resolved))
	end)
	t.test("invalid trusted startup options fail at the configuration boundary", function()
		for _, count in {0,33,1.5,math.huge} do
			t.expect.throws(function() config.Resolve({actorCount=count}) end)
		end
		for _, duration in {0,-1,math.huge,0/0} do
			t.expect.throws(function() config.Resolve({targetActorJobMs=duration}) end)
		end
	end)
end
