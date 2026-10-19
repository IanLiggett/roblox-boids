--!strict
-- Sole client camera-report policy. Never writes a camera or rendering state.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local cameraUpdate: UnreliableRemoteEvent = BoidsReplicated.Remotes.CameraUpdate
local CameraReporter = {}
local isStarted = false
local lastReportTime = 0
local lastPosition = Vector3.zero
local REPORT_INTERVAL = 1
local JUMP_DISTANCE = 128
local MIN_JUMP_INTERVAL = 1 / 30

local function send(cframe: CFrame, now: number): ()
 lastReportTime = now
 lastPosition = cframe.Position
 cameraUpdate:FireServer(cframe)
end

function CameraReporter.Start(): ()
 if isStarted then return end
 isStarted = true
 lastReportTime = workspace:GetServerTimeNow()
 local camera = workspace.CurrentCamera
 lastPosition = if camera then camera.CFrame.Position else Vector3.zero
end

-- Called through the existing render callback using the actual viewing camera.
function CameraReporter.Update(cframe: CFrame, now: number): ()
 if not isStarted then return end
 local jumped = (cframe.Position - lastPosition).Magnitude >= JUMP_DISTANCE
 if now > lastReportTime + REPORT_INTERVAL or (jumped and now - lastReportTime >= MIN_JUMP_INTERVAL) then
  send(cframe, now)
 end
end

-- Observation entry, replacement and explicit jumps reuse the same reporter.
-- Updating its clock prevents a second periodic report of that same pose.
function CameraReporter.ReportNow(cframe: CFrame): ()
 assert(isStarted, "Client runtime must start before camera reporting")
 send(cframe, workspace:GetServerTimeNow())
end

return CameraReporter
