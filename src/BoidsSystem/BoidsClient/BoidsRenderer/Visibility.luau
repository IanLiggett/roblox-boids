--!strict
-- Pure cell visibility policy; the renderer owns membership, budgets and Instances.
local Visibility = {}

export type View = {cframe: CFrame, position: Vector3, tanHorizontal: number, tanVertical: number, horizontalRadiusScale: number, verticalRadiusScale: number}
export type State = {
	isEligible: boolean,
	targetOpacity: number,
	appliedOpacity: number,
	passOpacity: number,
}

function Visibility.New(): State
	return {isEligible = false, targetOpacity = 0, appliedOpacity = 0, passOpacity = 0}
end

function Visibility.CreateView(cframe: CFrame, fieldOfView: number, viewport: Vector2): View
	-- The wider view lets cells resume before they enter the actual viewport.
	local tanVertical = math.tan(math.rad(math.min(175, fieldOfView + 10) * 0.5))
	local tanHorizontal = tanVertical * viewport.X / math.max(1, viewport.Y)
	return {cframe = cframe, position = cframe.Position, tanHorizontal = tanHorizontal, tanVertical = tanVertical,
		horizontalRadiusScale = math.sqrt(1 + tanHorizontal * tanHorizontal), verticalRadiusScale = math.sqrt(1 + tanVertical * tanVertical)}
end

function Visibility.IsInView(center: Vector3, radius: number, view: View): boolean
	local relative: Vector3 = view.cframe:PointToObjectSpace(center)
	local depth = -relative.Z
	return depth >= -radius
		and math.abs(relative.X) <= depth * view.tanHorizontal + radius * view.horizontalRadiusScale
		and math.abs(relative.Y) <= depth * view.tanVertical + radius * view.verticalRadiusScale
end

function Visibility.DistanceOpacity(distance: number, farDistance: number): number
	return if distance < farDistance then 1 else 0
end

-- Only boundary crossings restart a bounded membership pass.
function Visibility.SetTarget(state: State, opacity: number): boolean
	local isEligible = opacity > 0
	local changed = isEligible ~= state.isEligible
	state.isEligible = isEligible
	state.targetOpacity = opacity
	return changed
end

function Visibility.NeedsPass(state: State): boolean
	return state.isEligible or state.appliedOpacity ~= state.targetOpacity
end

function Visibility.BeginPass(state: State): ()
	state.passOpacity = state.targetOpacity
end

function Visibility.CompletePass(state: State): ()
	state.appliedOpacity = state.passOpacity
end

return Visibility
