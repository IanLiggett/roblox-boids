--!strict
--[[ Global session-start configuration for the optional boid query indexes. ]]
local RunService = game:GetService("RunService")

local QueryIndexConfig = {}

export type Mode = "none" | "client" | "server" | "both"

local ATTRIBUTE_NAME = "BoidQueryIndexMode"
local DEFAULT_MODE: Mode = "none"
local cachedMode: Mode? = nil
local locked = false
local usesExternalBudget=false

local function isValidMode(mode: unknown): boolean
	return mode == "none" or mode == "client" or mode == "server" or mode == "both"
end

function QueryIndexConfig.GetMode(): Mode
	if cachedMode then
		return cachedMode
	end
	local mode = script.Parent:GetAttribute(ATTRIBUTE_NAME)
	local resolved: Mode = if isValidMode(mode) then mode :: Mode else DEFAULT_MODE
	cachedMode = resolved
	return resolved
end

function QueryIndexConfig.SetMode(mode: Mode): boolean
	if not RunService:IsServer() or locked or not isValidMode(mode) then
		return false
	end
	script.Parent:SetAttribute(ATTRIBUTE_NAME, mode)
	cachedMode = mode
	return true
end

function QueryIndexConfig.IsLocked(): boolean
	return locked
end
function QueryIndexConfig.SetExternalBudget(isExternal: boolean): boolean
	if not RunService:IsServer() or locked then return false end
	usesExternalBudget=isExternal
	return true
end
function QueryIndexConfig.UsesExternalBudget(): boolean return usesExternalBudget end

function QueryIndexConfig.Lock(): boolean
	if not RunService:IsServer() then
		return false
	end
	locked = true
	if not isValidMode(script.Parent:GetAttribute(ATTRIBUTE_NAME)) then
		script.Parent:SetAttribute(ATTRIBUTE_NAME, DEFAULT_MODE)
		cachedMode = DEFAULT_MODE
	elseif not cachedMode then
		cachedMode = script.Parent:GetAttribute(ATTRIBUTE_NAME) :: Mode
	end
	return true
end

function QueryIndexConfig.IsEnabledForClient(): boolean
	local mode = QueryIndexConfig.GetMode()
	return mode == "client" or mode == "both"
end

function QueryIndexConfig.IsEnabledForServer(): boolean
	local mode = QueryIndexConfig.GetMode()
	return mode == "server" or mode == "both"
end

return QueryIndexConfig
