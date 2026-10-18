--!strict
-- Privileged Edit-only fixture generation, following PrepareWorkerFixture.
return function(): string
	assert(not game:GetService("RunService"):IsRunning(), "Prepare scheduler fixture before Play")
	local builder=game.ServerScriptService.BoidsSystem.BoidsReplicated.Boids.JobBuilder
	local source=builder.Source
	local first=assert(source:find('local RunService =',1,true))
	local last=assert(source:find('local JobBuilder = {}',first,true))+#'local JobBuilder = {}'
	local prelude=[==[return function(environment)
local RunService = environment.RunService
local workspace = environment.workspace
local os = {clock=environment.Clock}
local SharedTypes = {}
local BoidStorage = environment.BoidStorage
local RuntimeMetrics = environment.RuntimeMetrics
local ResultCommit = environment.ResultCommit
local ViewerLOD = environment.ViewerLOD
local DispatchPump = environment.DispatchPump
local ActorsInitializer = environment.ActorsInitializer
local Schedulers = environment.Schedulers
local BinaryHeaps = {}
local Benchmarkers = {}
local metrics = RuntimeMetrics.State
local detailedMetrics = false
local JobBuilder = {}]==]
	local generated=source:sub(1,first-1)..prelude..source:sub(last)
	local exports=[==[JobBuilder.TestAssign = assignWork
JobBuilder.TestSelect = getNextGroupWithWork
JobBuilder.TestSetRegistry = function(registry)
 groups=registry
 actorCount=#ActorsInitializer.actors
end
return JobBuilder
end]==]
	local boundary=assert(generated:find("return JobBuilder",1,true))
	generated=generated:sub(1,boundary-1)..exports
	local folder=script.Parent.Fixtures
	local fixture=folder:FindFirstChild("SchedulerDispatch") :: ModuleScript?
	if not fixture then
		fixture=Instance.new("ModuleScript");fixture.Name="SchedulerDispatch";fixture.Parent=folder
	else
		assert(fixture:GetAttribute("GeneratedSchedulerFixture")==true,"Do not overwrite a hand-edited fixture")
	end
	fixture.Source=generated
	fixture:SetAttribute("GeneratedSchedulerFixture",true)
	return fixture:GetFullName()
end
