local _, SF = ...

-- Gameplay is a parent-owned category with no content pages yet.
-- Registering the category (not a synthetic page) shows the empty-state widget.
SF.SettingsUI:RegisterCategory({
	id = "nicheFeatures",
	name = "Gameplay",
	navLabel = "Gameplay",
	group = "Core",
	description = "Manage character-specific gameplay toggles and automation.",
	order = 15,
})
