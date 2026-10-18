--!strict

-- Hosts may integrate controls without the package knowing their implementation.
export type Cleanup = () -> ()
export type Server = { SuspendInput: (Player) -> Cleanup }
export type Client = { Suspend: () -> Cleanup }

return {}
