--!strict

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ObservationTypes = require(ReplicatedStorage:WaitForChild("BoidsReplicated").Scenarios.ObservationTypes)
local Types = require(script.Parent.Types)
local Dock = {}

export type Page = "Inspector" | "Camera" | "Session"
export type Controller = {
	pages: {[Page]: ScrollingFrame},
	gui: ScreenGui,
	Destroy: () -> (),
}
type Api = {
	GetSessionState: () -> ObservationTypes.SessionState,
	GetSelectedBoidId: () -> number?,
	GetStreamingStatus: () -> Types.StreamingStatus,
	Subscribe: (Types.ChangeDomain, () -> ()) -> (() -> ()),
	Open: () -> (),
	Close: () -> (),
}
local BACKGROUND: Color3 = Color3.fromRGB(24, 29, 37)
local BUTTON: Color3 = Color3.fromRGB(52, 67, 86)
local FOREGROUND: Color3 = Color3.fromRGB(235, 240, 247)

function Dock.Start(observation: Api): Controller
	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "BoidsObservation"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 51
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local connections: {RBXScriptConnection} = {}
	local function button(parent: Instance, name: string, text: string, callback: () -> ()): TextButton
		local item: TextButton = Instance.new("TextButton")
		item.Name, item.Text = name, text
		item.Font = Enum.Font.Code
		item.TextSize = 12
		item.TextColor3 = FOREGROUND
		item.BackgroundColor3 = BUTTON
		item.BorderSizePixel = 0
		item.Modal = true
		item.Parent = parent
		table.insert(connections, item.Activated:Connect(function(_input: InputObject, _clickCount: number): ()
			callback()
		end))
		return item
	end

	-- Only the dock occupies a hit-testable rectangle; no full-screen frame blocks picking.
	local shell: Frame = Instance.new("Frame")
	shell.Name = "Dock"
	shell.AnchorPoint = Vector2.new(1, 0)
	shell.Position = UDim2.new(1, -12, 0, 12)
	shell.BackgroundColor3 = BACKGROUND
	shell.BorderSizePixel = 0
	shell.ClipsDescendants = true
	shell.Active = true
	shell.Visible = false
	shell.Parent = gui
	local constraint: UISizeConstraint = Instance.new("UISizeConstraint")
	constraint.Parent = shell

	local tabs: Frame = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromOffset(8, 38)
	tabs.Size = UDim2.new(1, -16, 0, 28)
	tabs.Parent = shell
	local pages: {[Page]: ScrollingFrame} = {}
	local tabButtons: {[Page]: TextButton} = {}
	local collapsed = true
	local selectedPage: Page = "Inspector"
	local isDestroyed = false
	local toggle: TextButton

	local function render(): ()
		if isDestroyed then return end
		local state: ObservationTypes.SessionState = observation.GetSessionState()
		local active = state.isActive and state.isAllowed
		shell.Visible = active
		constraint.MaxSize = Vector2.new(if collapsed then 320 else 420, 100000)
		shell.Size = if collapsed then UDim2.new(1, -24, 0, 32) else UDim2.new(1, -24, 1, -24)
		tabs.Visible = not collapsed
		toggle.Text = if collapsed then "Show [F8]" else "Hide [F8]"
		for name, page in pages do
			page.Visible = active and not collapsed and name == selectedPage
			tabButtons[name].BackgroundColor3 = if name == selectedPage then Color3.fromRGB(65, 85, 110) else BUTTON
		end
	end
	local function releasePageFocus(): ()
		local focused: TextBox? = UserInputService:GetFocusedTextBox()
		if focused and focused:IsDescendantOf(shell) then focused:ReleaseFocus(false) end
	end
	toggle = button(shell, "Toggle", "", function(): ()
		releasePageFocus()
		collapsed = not collapsed
		render()
	end)
	toggle.Position = UDim2.fromOffset(6, 3)
	toggle.Size = UDim2.fromOffset(84, 26)
	local exit: TextButton = button(shell, "Exit", "Exit", observation.Close)
	exit.Position = UDim2.new(1, -56, 0, 3)
	exit.Size = UDim2.fromOffset(50, 26)
	local title: TextLabel = Instance.new("TextLabel")
	title.Name = "Status"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(96, 3)
	title.Size = UDim2.new(1, -158, 0, 26)
	title.Font = Enum.Font.Code
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = shell

	local names: {Page} = {"Inspector", "Camera", "Session"}
	for index, name in names do
		local page: ScrollingFrame = Instance.new("ScrollingFrame")
		page.Name = name
		page.Position = UDim2.fromOffset(0, 72)
		page.Size = UDim2.new(1, 0, 1, -72)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 5
		page.ScrollingDirection = Enum.ScrollingDirection.Y
		page.CanvasSize = UDim2.new()
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.Active = true
		page.Visible = false
		page.Parent = shell
		pages[name] = page
		local tab: TextButton = button(tabs, name, if name == "Session" then "Session / LOD" else name, function(): ()
			releasePageFocus()
			selectedPage = name
			render()
		end)
		tab.Position = UDim2.new((index - 1) / 3, 2, 0, 0)
		tab.Size = UDim2.new(1 / 3, -4, 1, 0)
		tabButtons[name] = tab
	end

	local launcher: TextButton = button(gui, "Open", "Boids observer [F6]", observation.Open)
	launcher.AnchorPoint = Vector2.new(1, 0)
	launcher.Position = UDim2.new(1, -12, 0, 12)
	launcher.Size = UDim2.new(1, -24, 0, 32)
	launcher.Modal = false
	local launcherConstraint: UISizeConstraint = Instance.new("UISizeConstraint")
	launcherConstraint.MaxSize = Vector2.new(230, 32)
	launcherConstraint.Parent = launcher
	local function sync(): ()
		local state: ObservationTypes.SessionState = observation.GetSessionState()
		launcher.Visible = state.isAllowed and not state.isActive
		local streaming: Types.StreamingStatus = observation.GetStreamingStatus()
		local needsAttention = (state.message ~= nil and state.message ~= "")
			or streaming.needsAttention
		local id = observation.GetSelectedBoidId()
		title.Text = "Observer ON" .. (if id ~= nil then " #" .. id else "") .. (if needsAttention then " !" else "")
		title.TextColor3 = if needsAttention then Color3.fromRGB(255, 196, 96) else FOREGROUND
		if not state.isActive or not state.isAllowed then releasePageFocus() end
		render()
	end
	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, wasProcessed: boolean): ()
		if wasProcessed or GuiService.MenuIsOpen or UserInputService:GetFocusedTextBox() then return end
		local state: ObservationTypes.SessionState = observation.GetSessionState()
		if input.KeyCode == Enum.KeyCode.F6 then
			if state.isActive then observation.Close()
			elseif state.isAllowed then observation.Open() end
		elseif input.KeyCode == Enum.KeyCode.F8 and state.isActive and state.isAllowed then
			collapsed = not collapsed
			render()
		end
	end))
	local unsubscribes: {() -> ()} = {
		observation.Subscribe("Session", sync),
		observation.Subscribe("Selection", sync),
		observation.Subscribe("Streaming", sync),
	}
	sync()
	return {
		pages = pages,
		gui = gui,
		Destroy = function(): ()
			if isDestroyed then return end
			isDestroyed = true
			releasePageFocus()
			for _, unsubscribe in unsubscribes do unsubscribe() end
			for _, connection in connections do connection:Disconnect() end
			gui:Destroy()
		end,
	}
end

return Dock
