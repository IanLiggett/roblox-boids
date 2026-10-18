--!strict

-- Client feature notifications and value contracts, not a generic event/RPC layer.
export type ChangeDomain = "Session" | "Selection" | "Camera" | "Streaming" | "Inspection" | "Groups" | "Capture"
export type StreamingStatus = {
	state: "Inactive" | "Disabled" | "Loading" | "Incomplete" | "Requested",
	total: number,
	loading: number,
	incomplete: number,
	needsAttention: boolean,
}

return {}
