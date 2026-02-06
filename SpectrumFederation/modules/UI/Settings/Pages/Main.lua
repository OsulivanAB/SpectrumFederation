-- Grab the namespace
local addonName, SF = ...

local Page = {
    id = "main",
    name = "Spectrum Federation Settings",
    order = 10,
}

function Page:Build(panel)
    -- Build the main settings page UI
    -- @param panel Frame Settings panel frame
    -- @return nil
    if SF.Debug then
        SF.Debug:Verbose("UI", "Building Main settings page")
    end

    local schema = SF.SettingsSchema
    local renderer = SF.SettingsUI.DefinitionRenderer

    local def = {
        sections = {
            {
                id = "general",
                title = "General",
                items = {
                    {
                        type = "checkbox",
                        label = "Enable cross-expansion Crafting Orders scan button",
                        tooltip = "When enabled, adds a 'Scan All' button to the Professions Crafting Orders UI to scan all expansion skill lines.\n\nTo use: Open Professions at a crafting table, go to the Crafting Orders tab, and look for the button next to the search box.",
                        path = "global.enable_cross_expansion_crafting_orders_scan_button",
                    },
                },
            },

            {
                id = "appearance",
                title = "Appearance",
                items = {
                    {
                    type = "dropdown",
                    label = "Window Style",
                    tooltip = "Controls the overall look of Spectrum Federation windows.",
                    path = "global.windowStyle",
                    options = schema.ENUMS.windowStyle,
                    defaultText = "Select style",
                    },
                    {
                        type = "help",
                        text = "Tip: Choose a style that matches the amount of information you want on screen.",
                        indent = "label",
                    },                    
                    {
                        type = "dropdown",
                        label = "Font Style",
                        tooltip = "Font used in Spectrum Federation UI.",
                        path = "global.fontStyle",
                        options = schema.ENUMS.fontStyle,
                        defaultText = "Select font",
                    },
                    {
                        type = "help",
                        text = "This will affect text across Spectrum Federation windows.",
                        indent = "label",
                    },
                    {
                        type = "slider",
                        label = "Font Size",
                        tooltip = "Size of UI text.",
                        path = "global.fontSize",
                        min = 8, max = 24, step = 1,
                    },
                },

                reset = {
                    label = "Reset Appearance",
                    buttonText = "Reset",
                    confirmText = "Reset Appearance settings to defaults?",
                    paths = {
                        "global.windowStyle",
                        "global.fontStyle",
                        "global.fontSize",},
                    successMessage = "Appearance settings reset to defaults.",
                },
            },

            {
                id = "actions",
                title = "Actions",
                items = {
                    {
                        type = "button",
                        label = "Reset All Settings",
                        buttonText = "Reset All",
                        width = 140,
                        tooltip = "Resets all Spectrum Federation settings to their default values.",

                        onClick = function(ctx)
                            if SF.Debug then
                                SF.Debug:Info("UI", "Reset All Settings button clicked")
                            end
                            ctx.section:ClearMessage()
                            ctx.ui.Dialogs:Confirm(
                                "Reset ALL Spectrum Federation settings to defaults?",
                                "Reset All",
                                function()
                                    if SF.Debug then
                                        SF.Debug:Info("UI", "User confirmed reset all settings")
                                    end
                                    ctx.store:ResetAll()
                                    ctx.pageBuilder:Refresh()
                                    ctx.pageBuilder:Reflow()
                                    ctx.section:SetMessage("All settings have been reset to defaults.", "success")
                                end
                            )
                        end,
                    },
                },
            },
        },
    }

    renderer:Build(panel, def)
end

function Page:Refresh(panel)
    -- Refresh the main settings page
    -- @param panel Frame Settings panel frame
    -- @return nil
    SF.SettingsUI.DefinitionRenderer:Refresh(panel)
end

SF.SettingsUI:RegisterPage(Page)