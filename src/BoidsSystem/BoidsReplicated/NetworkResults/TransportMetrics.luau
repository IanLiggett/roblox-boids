--!strict
-- Copied metrics never grant transport ownership.
local TransportMetrics = {}
export type Recipient = {
	sentPackets: number, sentPayloadBytes: number, sentRows: number,
	capDroppedPackets: number, capDroppedRows: number,
	queueDelayTotalMs: number, queueDelayMaxMs: number,
	baselineCount: number, stateBufferBytes: number, pendingRows: number,
}
export type Snapshot = {
	sentPackets: number, sentPayloadBytes: number, sentRows: number,
	candidateRows: number, recipientComparisons: number, selectedRows: number, selectionMs: number,
	capDroppedPackets: number, capDroppedRows: number,
	configuredPacketsPerClientSecond: number, batchingSeconds: number,
	recipients: {[number]: Recipient},
}
local state: Snapshot = {
	sentPackets = 0, sentPayloadBytes = 0, sentRows = 0,
	candidateRows = 0, recipientComparisons = 0, selectedRows = 0, selectionMs = 0,
	capDroppedPackets = 0, capDroppedRows = 0,
	configuredPacketsPerClientSecond = 0, batchingSeconds = 0, recipients = {},
}

local function getRecipient(userId: number): Recipient
	local recipient = state.recipients[userId]
	if recipient then return recipient end
	recipient = {sentPackets = 0, sentPayloadBytes = 0, sentRows = 0, capDroppedPackets = 0, capDroppedRows = 0,
		queueDelayTotalMs = 0, queueDelayMaxMs = 0, baselineCount = 0, stateBufferBytes = 0, pendingRows = 0}
	state.recipients[userId] = recipient
	return recipient
end

function TransportMetrics.Configure(cap: number, batchingSeconds: number): ()
	state.configuredPacketsPerClientSecond = cap
	state.batchingSeconds = batchingSeconds
end

function TransportMetrics.RecordSelection(candidates: number, comparisons: number, selected: number, elapsedMs: number): ()
	state.candidateRows += candidates
	state.recipientComparisons += comparisons
	state.selectedRows += selected
	state.selectionMs += elapsedMs
end

function TransportMetrics.RecordSent(userId: number, payloadBytes: number, rows: number, queueDelayMs: number): ()
	state.sentPackets += 1
	state.sentPayloadBytes += payloadBytes
	state.sentRows += rows
	local recipient = getRecipient(userId)
	recipient.sentPackets += 1
	recipient.sentPayloadBytes += payloadBytes
	recipient.sentRows += rows
	recipient.queueDelayTotalMs += queueDelayMs
	recipient.queueDelayMaxMs = math.max(recipient.queueDelayMaxMs, queueDelayMs)
end

function TransportMetrics.RecordCapDrop(userId: number, packets: number, rows: number): ()
	state.capDroppedPackets += packets
	state.capDroppedRows += rows
	local recipient = getRecipient(userId)
	recipient.capDroppedPackets += packets
	recipient.capDroppedRows += rows
end

function TransportMetrics.SetRecipientState(userId: number, baselines: number, bytes: number, pending: number): ()
	local recipient = getRecipient(userId)
	recipient.baselineCount = baselines
	recipient.stateBufferBytes = bytes
	recipient.pendingRows = pending
end

function TransportMetrics.RemoveRecipient(userId: number): () state.recipients[userId] = nil end

function TransportMetrics.Read(): Snapshot
	local copy = table.clone(state)
	copy.recipients = {}
	for userId, recipient in state.recipients do copy.recipients[userId] = table.clone(recipient) end
	return copy
end

return TransportMetrics
