local _, SF = ...

SF.SettingsUI:RegisterCategory({
	id = "nicheFeatures",
	name = "Gameplay",
	navLabel = "Gameplay",
	group = "Core",
	description = "Manage character-specific gameplay toggles and automation.",
	order = 15,
})

local Page = {
	id = "uiEnhancements",
	categoryId = "nicheFeatures",
	name = "UI Enhancements",
	navLabel = "UI Enhancements",
	contentHeading = "UI Enhancements",
	group = "Core",
	description = "Optional on-screen enhancements for this character, including Mouse Tracer.",
	order = 15,
}

local function TracerEnabled()
	local store = SF.SettingsStore
	if not store or not store.GetCharacter then
		return false
	end
	return store:GetCharacter("mouseTracer.enabled") and true or false
end

local function CharacterGet(path)
	return function()
		local store = SF.SettingsStore
		if not store or not store.GetCharacter then
			return nil
		end
		return store:GetCharacter(path)
	end
end

local function CharacterSet(path)
	return function(value)
		local store = SF.SettingsStore
		if store and store.SetCharacter then
			store:SetCharacter(path, value)
		end
	end
end

function Page:Build(panel)
	if SF.Debug then
		SF.Debug:Verbose("UI", "Building UI Enhancements settings page")
	end

	local renderer = SF.SettingsUI.DefinitionRenderer
	local tracer = SF.MouseTracer

	local def = {
		sections = {
			{
				id = "mouseTracer",
				title = "Mouse Tracer",
				tooltip = "Leave a fading rainbow trail behind this character's mouse cursor. The trail is off by default and only uses this character's settings.",
				items = {
					{
						type = "checkbox",
						label = "Enable Mouse Tracer",
						tooltip = "Show a rainbow trail behind the mouse cursor on this character. When this is off, Mouse Tracer does no continuous work and any visible trail is removed immediately.",
						get = CharacterGet("mouseTracer.enabled"),
						set = CharacterSet("mouseTracer.enabled"),
						onValueChanged = function(ctx)
							if ctx.pageBuilder then
								ctx.pageBuilder:Refresh()
							end
						end,
					},
					{
						type = "slider",
						label = "Trail Length",
						tooltip = "How far the trail can extend behind the cursor, in UI pixels.",
						min = 80,
						max = 400,
						step = 10,
						get = CharacterGet("mouseTracer.trailLength"),
						set = CharacterSet("mouseTracer.trailLength"),
						enabled = TracerEnabled,
					},
					{
						type = "slider",
						label = "Fade Duration",
						tooltip = "How many seconds the trail takes to disappear after you stop moving.",
						min = 0.2,
						max = 1.5,
						step = 0.1,
						get = CharacterGet("mouseTracer.fadeDuration"),
						set = CharacterSet("mouseTracer.fadeDuration"),
						enabled = TracerEnabled,
					},
					{
						type = "slider",
						label = "Trail Thickness",
						tooltip = "Visual width of the trail, in UI pixels.",
						min = 6,
						max = 28,
						step = 1,
						get = CharacterGet("mouseTracer.thickness"),
						set = CharacterSet("mouseTracer.thickness"),
						enabled = TracerEnabled,
					},
					{
						type = "slider",
						label = "Rainbow Cycle Speed",
						tooltip = "How quickly rainbow colors travel along the trail. This does not change trail length.",
						min = 0.25,
						max = 3.0,
						step = 0.25,
						get = CharacterGet("mouseTracer.rainbowSpeed"),
						set = CharacterSet("mouseTracer.rainbowSpeed"),
						enabled = TracerEnabled,
					},
					{
						type = "slider",
						label = "Trail Opacity",
						tooltip = "Overall visibility of the trail. Lower values keep more of the UI readable underneath.",
						min = 0.2,
						max = 1.0,
						step = 0.05,
						get = CharacterGet("mouseTracer.opacity"),
						set = CharacterSet("mouseTracer.opacity"),
						enabled = TracerEnabled,
					},
					{
						type = "dropdown",
						label = "Copy From Character",
						tooltip = "Replace this character's Mouse Tracer settings with another character's last saved settings. The other character must have logged in with Spectrum Federation so a snapshot exists. The current character is not listed.",
						defaultText = "Select a character",
						options = function()
							if tracer and tracer.GetCopyOptions then
								return tracer:GetCopyOptions()
							end
							return {}
						end,
						get = function()
							if tracer and tracer.GetCopySource then
								return tracer:GetCopySource()
							end
							return panel.__sfMouseTracerCopySource
						end,
						set = function(value)
							panel.__sfMouseTracerCopySource = value
							if tracer and tracer.SetCopySource then
								tracer:SetCopySource(value)
							end
						end,
						enabled = function()
							return tracer and tracer.HasCopySources and tracer:HasCopySources()
						end,
						onValueChanged = function(ctx)
							if ctx.pageBuilder then
								ctx.pageBuilder:Refresh()
							end
						end,
					},
					{
						type = "button",
						label = "",
						buttonText = "Copy",
						width = 90,
						tooltip = "Overwrite this character's Mouse Tracer settings with the selected character's saved settings. This cannot be undone except by copying back or changing the sliders.",
						enabled = function()
							return tracer and tracer.CanCopy and tracer:CanCopy() or false
						end,
						onClick = function(ctx)
							ctx.section:ClearMessage()
							local source = tracer and tracer.GetCopySource and tracer:GetCopySource() or panel.__sfMouseTracerCopySource
							if not source then
								ctx.section:SetMessage("Select a character first.", "error")
								return
							end
							local dialogs = ctx.ui and ctx.ui.Dialogs
							local message = ("Replace this character's Mouse Tracer settings with those from %s?"):format(source)
							local function DoCopy()
								if not tracer or not tracer.CopyFromCharacter then
									ctx.section:SetMessage("Mouse Tracer copy is not available.", "error")
									return
								end
								local ok, err = tracer:CopyFromCharacter(source)
								if not ok then
									ctx.section:SetMessage(err or "Copy failed.", "error")
									return
								end
								if ctx.pageBuilder then
									ctx.pageBuilder:Refresh()
								end
								ctx.section:SetMessage("Mouse Tracer settings copied.", "success")
							end
							if dialogs and dialogs.Confirm then
								dialogs:Confirm(message, "Copy", DoCopy)
							else
								DoCopy()
							end
						end,
					},
				},
			},
		},
	}

	renderer:Build(panel, def)
end

function Page:Refresh(panel)
	SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)
