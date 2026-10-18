--!strict

local SharedTypes = require(script.Parent.Parent.SharedTypes)

-- Trusted command construction only; remote input still requires server validation.
export type SyncCommand = { action: "Sync" }
export type OpenCommand = { action: "Open" }
export type CloseCommand = { action: "Close", sessionId: string }
export type SetCameraEnabledCommand = { action: "SetCameraEnabled", sessionId: string, cameraEnabled: boolean }
export type CreateFixedCommand = { action: "CreateFixed", sessionId: string, position: Vector3 }
export type DeleteFixedCommand = { action: "DeleteFixed", sessionId: string, observerId: number }
export type SelectBoidCommand = { action: "SelectBoid", sessionId: string, selectionRevision: number, boidId: number? }
export type SessionCommand = CloseCommand | SetCameraEnabledCommand | CreateFixedCommand | DeleteFixedCommand | SelectBoidCommand
export type Command = SyncCommand | OpenCommand | SessionCommand

export type FixedObserver = { id: number, position: Vector3 }

export type SessionState = {
	revision: number,
	isAllowed: boolean,
	isActive: boolean,
	sessionId: string?,
	cameraEnabled: boolean,
	fixedObservers: {FixedObserver},
	selectionRevision: number,
	selectedBoidId: number?,
	message: string?,
}

export type ServerSample = {
	sessionId: string,
	selectionRevision: number,
	boidId: number,
	sampledAt: number,
	isAvailable: boolean,
	position: Vector3?,
	velocity: Vector3?,
	state: SharedTypes.BoidObservation?,
	simulationAge: number?,
	isAgeLowerBound: boolean?,
}

return {}
