--!strict
-- Formatting and opt-in output only. The running coordinator owns all reads.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local SharedTypes = require(BoidsReplicated.SharedTypes)

local Logs = {printInterval = 5}
type Reader = {GetRuntimeDiagnostics: () -> SharedTypes.RuntimeDiagnostics}
local connection: RBXScriptConnection? = nil

local function printStats(stats: SharedTypes.NumericStatsSummary, prefix: string?): ()
	local message = (prefix or "") .. `TOTAL: {stats.sampleCount} | AVG: {stats.average} | MED: {stats.median} | MIN: {stats.minimum or "n/a"} | MAX: {stats.maximum or "n/a"} | SD: {stats.standardDeviation}`
	if stats.staleThreshold then message ..= ` | STALE: {stats.staleCount}` end
	if stats.staleCount > 0 then warn(message) else print(message) end
end

local function printLogs(diagnostics: SharedTypes.RuntimeDiagnostics): ()
	for _, actor in diagnostics.actors do
		print(`ACTOR {actor.index}: TIME IDLE BETWEEN JOBS`)
		printStats(actor.idleSeconds)
	end
	local cells = diagnostics.cells
	warn(`cells total={cells.total}, valid={cells.valid}, scheduled={cells.scheduled} oldestAge={cells.oldestAge}`)
	for _, group in diagnostics.groups do
		print(`Group {group.groupId}:`)
		printStats(group.jobMs, "\tWorker elapsed execution: ms | ")
		if group.neighborWorkPerJob then
			printStats(group.neighborWorkPerJob, "\tDetailed-only mixed neighbor work/Job | ")
		else
			print("\tDetailed-only mixed neighbor work/Job | n/a")
		end
		printStats(group.inboundMs, "\tInbound transfer + scheduling: ms | ")
		printStats(group.outboundMs, "\tOutbound transfer + scheduling: ms | ")
		printStats(group.cellsPerSecond, "\tCells/s | ")
		printStats(group.boidsPerSecond, "\tBoids/s | ")
	end
end

function Logs.Start(reader: Reader): ()
	if connection then return end
	local lastPrint = os.clock()
	connection = RunService.PostSimulation:Connect(function()
		local now = os.clock()
		if now - lastPrint < Logs.printInterval then return end
		lastPrint = now
		printLogs(reader.GetRuntimeDiagnostics())
	end)
end

function Logs.Stop(): ()
	if not connection then return end
	connection:Disconnect()
	connection = nil
end

return Logs
