local _, SF = ...

local Page = {
	id = "nicheFeatures",
	name = "Gameplay",
	navLabel = "Gameplay",
	group = "Core",
	description = "Manage character-specific gameplay toggles and automation.",
	order = 15,
}

local function GetCurrentSpecID()
	if not GetSpecialization or not GetSpecializationInfo then
		return nil
	end

	local specIndex = GetSpecialization()
	if not specIndex then
		return nil
	end

	local specID = GetSpecializationInfo(specIndex)
	return specID
end

local function BuildSpecCheckboxes(store)
	if not UnitClass or not GetNumSpecializationsForClassID or not GetSpecializationInfoForClassID then
		return {
			{
				type = "help",
				text = "Specialization data is not available right now.",
			},
		}
	end

	local _, _, classID = UnitClass("player")
	if not classID then
		return {
			{
				type = "help",
				text = "Unable to determine this character's class.",
			},
		}
	end

	local specCount = GetNumSpecializationsForClassID(classID)
	local items = {}

	for specIndex = 1, (specCount or 0) do
		local specID, specName = GetSpecializationInfoForClassID(classID, specIndex)
		if specID and specName then
			table.insert(items, {
				type = "checkbox",
				label = specName,
				tooltip = ("Enable Press and Hold Casting automatically whenever %s is your active specialization."):format(specName),
				get = function()
					return store:GetPressAndHoldCastingBySpec(specID) and true or false
				end,
				set = function(value)
					store:SetPressAndHoldCastingBySpec(specID, value and true or false)
					if SF.SettingsApply and SF.SettingsApply.QueuePressAndHoldCastingApply and GetCurrentSpecID() == specID then
						SF.SettingsApply:QueuePressAndHoldCastingApply()
					end
				end,
			})
		end
	end

	if #items == 0 then
		table.insert(items, {
			type = "help",
			text = "No specializations are available for this character.",
		})
	end

	return items
end

function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building Niche Features settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local store = SF.SettingsStore

	local def = {
		sections = {
			{
				id = "pressAndHoldCasting",
				title = "Press and Hold Casting",
				tooltip = "Controls Press and Hold Casting by specialization. This can help avoid accidental double-press behavior while still allowing it on specs where one-touch rotation is preferred.",
				items = BuildSpecCheckboxes(store),
			},
		},
	}

	renderer:Build(panel, def)
end

function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)
