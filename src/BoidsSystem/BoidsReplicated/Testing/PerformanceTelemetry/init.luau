--!strict
--[[
PerformanceTelemetry
====================
Low-overhead scenario sampler. Engine counters provide process memory and
network throughput; Boids counters provide scheduler and Actor job work volume.
Durations are elapsed measurements, not CPU utilization. Nested phase totals
must not be added together. Detailed-only counters are unavailable in minimal mode.
]]

local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local HttpService = game:GetService("HttpService")
local TransportMetrics = require(script.Parent.Parent.NetworkResults.TransportMetrics)
local SharedTypes = require(script.Parent.Parent.SharedTypes)
local LODConfig = require(script.Parent.Parent.LODConfig)
local Divergence = require(script.Divergence)
local PerformanceTelemetry = {}
type RuntimeMetrics = SharedTypes.RuntimeMetrics
type BoidsApi = {
	SetCorrectionSampling: (boolean) -> (),
	GetRuntimeMetrics: (sinceTotals: {[string]: number}?) -> RuntimeMetrics,
	GetRuntimeSummary: () -> SharedTypes.RuntimeSummary,
	GetRuntimeDiagnostics: () -> SharedTypes.RuntimeDiagnostics,
}

type Divergence = Divergence.Report

type DivergenceSample = Divergence.Sample

type Report = {
	label: string,
	environment: string,
	durationSeconds: number,
	measurementMode: SharedTypes.MeasurementMode,
	elapsedRates: {[string]: number},
	counterDeltas: {[SharedTypes.RuntimeCounterName]: number},
	latency: {[string]: SharedTypes.LatencySummary},
	actors: {{index: number, completedJobs: number, processedBoids: number, workerExecutionMs: number}},
	cellsAtEnd: {total: number, valid: number, scheduled: number, maxPopulation: number, oldestAge: number, oldestId: number},
	metadata: {[string]: string | number | boolean},
	outstandingJobs: number,
	peakOutstandingJobs: number,
	memoryMb: {average: number?, minimum: number?, maximum: number?},
	bandwidthKbps: {sendAverage: number?, receiveAverage: number?},
	boidJobUpdateTransport: {payloadKbps: number, packetsPerSecond: number},
	networkErrorSelection: {rates: {[string]: number}, recipients: {[string]: {[string]: number}}},
	divergence: Divergence?,
}

-- Per-recipient windows expose the population cost without tuning accuracy to
-- a traffic target. Buffer bytes exclude table/allocator overhead; engine Stats
-- above remains the process-level memory/network measurement.
local function summarizeNetwork(first: TransportMetrics.Snapshot, last: TransportMetrics.Snapshot, elapsed: number): {rates: {[string]: number}, recipients: {[string]: {[string]: number}}}
	local rates: {[string]: number} = {
		candidateRowsPerSecond = (last.candidateRows - first.candidateRows) / elapsed,
		comparisonsPerSecond = (last.recipientComparisons - first.recipientComparisons) / elapsed,
		selectedRowsPerSecond = (last.selectedRows - first.selectedRows) / elapsed,
		sentRowsPerSecond = (last.sentRows - first.sentRows) / elapsed,
		selectionMsPerSecond = (last.selectionMs - first.selectionMs) / elapsed,
		capDroppedPackets = last.capDroppedPackets - first.capDroppedPackets,
		capDroppedRows = last.capDroppedRows - first.capDroppedRows,
		configuredPacketsPerClientSecond = last.configuredPacketsPerClientSecond,
		batchingSeconds = last.batchingSeconds,
	}
	local recipients: {[string]: {[string]: number}} = {}
	for userId, current in last.recipients do
		local previous = first.recipients[userId]
		local packets = current.sentPackets - (if previous then previous.sentPackets else 0)
		local payload = current.sentPayloadBytes - (if previous then previous.sentPayloadBytes else 0)
		local delay = current.queueDelayTotalMs - (if previous then previous.queueDelayTotalMs else 0)
		recipients[tostring(userId)] = {
			packetsPerSecond = packets / elapsed, payloadKbps = payload / elapsed / 1000,
			operatingLimitUtilization = packets / elapsed / 500,
			batchingTargetPacketsPerSecond = 400,
			queueDelayAverageMs = if packets > 0 then delay / packets else 0,
			queueDelaySessionMaxMs = current.queueDelayMaxMs,
			baselineCount = current.baselineCount, stateBufferBytes = current.stateBufferBytes,
			pendingRows = current.pendingRows,
		}
	end
	return {rates = rates, recipients = recipients}
end

local reports: {[string]: Report} = {}
local started: {[string]: boolean} = {}

local function mean(values: {number}): number?
	if #values == 0 then
		return nil
	end
	local total = 0
	for _, value in values do
		total += value
	end
	return total / #values
end

local function minValue(values: {number}): number?
	local result: number? = nil
	for _, value in values do
		result = if result == nil then value else math.min(result, value)
	end
	return result
end

local function maxValue(values: {number}): number?
	local result: number? = nil
	for _, value in values do
		result = if result == nil then value else math.max(result, value)
	end
	return result
end

local function median(values: {number}): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local middle = #sorted // 2
	if #sorted % 2 == 1 then
		return sorted[middle + 1]
	end
	return (sorted[middle] + sorted[middle + 1]) / 2
end

local function standardDeviation(values: {number}, average: number?): number?
	if #values == 0 or average == nil then
		return nil
	end
	local squaredDifferenceTotal = 0
	for _, value in values do
		local difference = value - average
		squaredDifferenceTotal += difference * difference
	end
	return math.sqrt(squaredDifferenceTotal / #values)
end

local function totalMemoryMb(): number?
	local ok, value = pcall(function(): number
		return Stats:GetTotalMemoryUsageMb()
	end)
	return if ok and type(value) == "number" then value else nil
end

local function networkKbps(name: string): number?
	local ok, value = pcall(function(): number?
		-- ServerStatsItem is the network summary exposed in both Studio server and
		-- client contexts; its values are directional for the current process.
		local networkStats = Stats :: Stats & {Network: Instance & {ServerStatsItem: Instance}}
		local item = networkStats.Network.ServerStatsItem:FindFirstChild(name) :: StatsItem?
		return item and item:GetValue()
	end)
	return if ok and type(value) == "number" then value else nil
end

local function numberText(value: number?): string
	return if value == nil then "n/a" else string.format("%.3f", value)
end

function PerformanceTelemetry.Start(
	label: string,
	boids: BoidsApi,
	warmupSeconds: number,
	sampleSeconds: number,
	divergenceProvider: (() -> DivergenceSample?)?,
	benchmarkMetadata: {[string]: string | number | boolean}?
): ()
	local environment = if RunService:IsServer() then "server" else "client"
	local key = label .. ":" .. environment
	if started[key] then
		return
	end
	started[key] = true

	task.spawn(function()
		task.wait(warmupSeconds)

		local startMetrics = boids.GetRuntimeMetrics()
		local startDiagnostics = boids.GetRuntimeDiagnostics()
		local startTransportMetrics = TransportMetrics.Read()
		local memorySamples: {number} = {}
		local sendSamples: {number} = {}
		local receiveSamples: {number} = {}

		local divergenceTotal = Divergence.New()
		if divergenceProvider then boids.SetCorrectionSampling(true) end

		local sampleStart = os.clock()
		local sampleEnd = sampleStart + sampleSeconds
		repeat
			local memory = totalMemoryMb()
			if memory then
				table.insert(memorySamples, memory)
			end

			local send = networkKbps("Send kBps")
			if send then
				table.insert(sendSamples, send)
			end
			local receive = networkKbps("Receive kBps")
			if receive then
				table.insert(receiveSamples, receive)
			end

			local readDivergence: (() -> DivergenceSample?)? = divergenceProvider
			if readDivergence then
				local divergence = readDivergence()
				if divergence then
					Divergence.Merge(divergenceTotal, divergence)
				end
			end

			task.wait(1)
		until os.clock() >= sampleEnd

		local elapsed = math.max(os.clock() - sampleStart, 0.001)
		local endMetrics = boids.GetRuntimeMetrics(startMetrics.latencyTotals)
		local endTransportMetrics = TransportMetrics.Read()
		if divergenceProvider then
			local last = divergenceProvider()
			if last then Divergence.Merge(divergenceTotal, last) end
			boids.SetCorrectionSampling(false)
		end
		local divergence = Divergence.Read(divergenceTotal)


		local counterDeltas: {[SharedTypes.RuntimeCounterName]: number} = {}
		local elapsedRates: {[string]: number} = {}
		for name, value in endMetrics.counters do
			if name ~= "outstandingJobs" and name ~= "peakOutstandingJobs" then
				local delta = value - startMetrics.counters[name]
				counterDeltas[name] = delta
				elapsedRates[name .. "PerSecond"] = delta / elapsed
			end
		end
		local summary = boids.GetRuntimeSummary()
		local endDiagnostics = boids.GetRuntimeDiagnostics()
		local actors: {{index: number, completedJobs: number, processedBoids: number, workerExecutionMs: number}} = {}
		for index, actor in endDiagnostics.actors do
			local before = startDiagnostics.actors[index]
			table.insert(actors, {
				index = actor.index, completedJobs = actor.completedJobs - before.completedJobs,
				processedBoids = actor.processedBoids - before.processedBoids,
				workerExecutionMs = actor.workerExecutionMs - before.workerExecutionMs,
			})
		end
		local metadata: {[string]: string | number | boolean} = {
			actorCount = summary.actorCount, groupCount = summary.groupCount,
			populationAtEnd = summary.population, lodPreset = LODConfig.GetPresetName(),
			detailedCountersAvailable = endMetrics.mode == "detailed",
			-- Benchmark metadata may supply the externally recorded engine build.
			studioBuild = "unrecorded", executionSide = environment,
			isStudio = RunService:IsStudio(), warmupSeconds = warmupSeconds,
			requestedSampleSeconds = sampleSeconds,
			nativeStatus = "unverified; --!native is not execution evidence",
			sourceRevision = (script:GetAttribute("MeasurementRevision") :: string?) or "unrecorded",
			latencyPolicy = "last N events within sample interval; nearest-rank quantiles",
			latencyCapacity = endMetrics.latencyCapacity,
		}
		if benchmarkMetadata then
			for name, value in benchmarkMetadata do
				metadata[name] = value
			end
		end

		local report: Report = {
			label = label,
			environment = environment,
			durationSeconds = elapsed,
			measurementMode = endMetrics.mode,
			elapsedRates = elapsedRates,
			counterDeltas = counterDeltas,
			latency = endMetrics.latency,
			actors = actors, cellsAtEnd = endDiagnostics.cells,
			metadata = metadata,
			outstandingJobs = endMetrics.counters.outstandingJobs,
			peakOutstandingJobs = endMetrics.counters.peakOutstandingJobs,
			memoryMb = {
				average = mean(memorySamples),
				minimum = minValue(memorySamples),
				maximum = maxValue(memorySamples),
			},
			bandwidthKbps = {
				sendAverage = mean(sendSamples),
				receiveAverage = mean(receiveSamples),
			},
			boidJobUpdateTransport = {
				payloadKbps = (endTransportMetrics.sentPayloadBytes - startTransportMetrics.sentPayloadBytes) / elapsed / 1000,
				packetsPerSecond = (endTransportMetrics.sentPackets - startTransportMetrics.sentPackets) / elapsed,
			},
			networkErrorSelection = summarizeNetwork(startTransportMetrics, endTransportMetrics, elapsed),
			divergence = divergence,
		}
		reports[key] = report
		-- Tool/plugin VMs have separate require caches. Export the actual runtime report.
		local reportName = "Report_" .. environment
		local existingRecord: StringValue? = script:FindFirstChild(reportName) :: StringValue?
		local record: StringValue
		if existingRecord then
			record = existingRecord
		else
			record = Instance.new("StringValue")
			record.Name = reportName
			record.Parent = script
		end
		record.Value = HttpService:JSONEncode(report)
		local attributePrefix = "LastReport_" .. environment .. "_"
		script:SetAttribute(attributePrefix .. "DurationSeconds", report.durationSeconds)
		script:SetAttribute(attributePrefix .. "MeasurementMode", report.measurementMode)
		script:SetAttribute(attributePrefix .. "WorkerExecutionMsPerSecond", report.elapsedRates.workerExecutionMsPerSecond)
		script:SetAttribute(attributePrefix .. "SkippedBoidsPerSecond", report.elapsedRates.skippedBoidsPerSecond)
		script:SetAttribute(attributePrefix .. "MigratedBoidsPerSecond", report.elapsedRates.migratedBoidsPerSecond)
		script:SetAttribute(attributePrefix .. "ActorJobTurnaroundMsPerSecond", report.elapsedRates.jobTurnaroundMsPerSecond)
		script:SetAttribute(attributePrefix .. "SchedulerMsPerSecond", report.elapsedRates.schedulerMsPerSecond)
		script:SetAttribute(attributePrefix .. "JobsPerSecond", report.elapsedRates.completedJobsPerSecond)
		script:SetAttribute(attributePrefix .. "BoidsPerSecond", report.elapsedRates.processedBoidsPerSecond)
		script:SetAttribute(attributePrefix .. "MemoryAverageMb", report.memoryMb.average)
		script:SetAttribute(attributePrefix .. "BandwidthSendKbps", report.bandwidthKbps.sendAverage)
		script:SetAttribute(attributePrefix .. "BandwidthReceiveKbps", report.bandwidthKbps.receiveAverage)
		script:SetAttribute(attributePrefix .. "BoidJobUpdatePayloadKbps", report.boidJobUpdateTransport.payloadKbps)
		script:SetAttribute(attributePrefix .. "BoidJobUpdatePacketsPerSecond", report.boidJobUpdateTransport.packetsPerSecond)
		if divergence then
			script:SetAttribute(attributePrefix .. "DivergencePositionRmse", divergence.positionRmse)
			script:SetAttribute(attributePrefix .. "DivergencePositionAverage", divergence.positionAverage)
			script:SetAttribute(attributePrefix .. "DivergencePositionMedian", divergence.positionMedian)
			script:SetAttribute(attributePrefix .. "DivergencePositionStandardDeviation", divergence.positionStandardDeviation)
			script:SetAttribute(attributePrefix .. "DivergenceVelocityRmse", divergence.velocityRmse)
			script:SetAttribute(attributePrefix .. "DivergenceVelocityAverage", divergence.velocityAverage)
			script:SetAttribute(attributePrefix .. "DivergenceVelocityMedian", divergence.velocityMedian)
			script:SetAttribute(attributePrefix .. "DivergenceVelocityStandardDeviation", divergence.velocityStandardDeviation)
			script:SetAttribute(attributePrefix .. "DivergenceMaxPosition", divergence.maxPositionError)
			script:SetAttribute(attributePrefix .. "DivergenceSampleCount", divergence.sampleCount)
		end

		local divergenceText = " n/a"
		if divergence then
			divergenceText = string.format(
				" samples=%d position{rmse=%s,avg=%s,median=%s,sd=%s,max=%s} velocity{rmse=%s,avg=%s,median=%s,sd=%s}",
				divergence.sampleCount,
				numberText(divergence.positionRmse),
				numberText(divergence.positionAverage),
				numberText(divergence.positionMedian),
				numberText(divergence.positionStandardDeviation),
				numberText(divergence.maxPositionError),
				numberText(divergence.velocityRmse),
				numberText(divergence.velocityAverage),
				numberText(divergence.velocityMedian),
				numberText(divergence.velocityStandardDeviation)
			)
		end
		print(
			string.format(
				"BOID_BENCHMARK [%s:%s] seconds=%s elapsed{actorJobTurnaroundMs/s=%s,schedulerMs/s=%s,jobs/s=%s,boids/s=%s} memoryMb{avg=%s,min=%s,max=%s} bandwidthKbps{send=%s,receive=%s} boidJobUpdate{payloadKB/s=%s,packets/s=%s} divergence{%s}",
				label,
				environment,
				numberText(elapsed),
				numberText(report.elapsedRates.jobTurnaroundMsPerSecond),
				numberText(report.elapsedRates.schedulerMsPerSecond),
				numberText(report.elapsedRates.completedJobsPerSecond),
				numberText(report.elapsedRates.processedBoidsPerSecond),
				numberText(report.memoryMb.average),
				numberText(report.memoryMb.minimum),
				numberText(report.memoryMb.maximum),
				numberText(report.bandwidthKbps.sendAverage),
				numberText(report.bandwidthKbps.receiveAverage),
				numberText(report.boidJobUpdateTransport.payloadKbps),
				numberText(report.boidJobUpdateTransport.packetsPerSecond),
				divergenceText
			)
		)
	end)
end

function PerformanceTelemetry.GetReport(label: string, environment: string): Report?
	return reports[label .. ":" .. environment]
end

function PerformanceTelemetry.GetReports(): {[string]: Report}
	return reports
end

return PerformanceTelemetry
