-- Grab the namespace
local addonName, SF = ...

SF.SettingsSchema = {
    VERSION = 1,

    DEFAULTS = {
        version = 1,

        global = {
            windowStyle = "default",
            fontStyle   = "FrizQT",
            fontSize    = 12,
        },

        lootHelper = {
            enabled = true,

            activeProfile = "Default",

            profiles = {
                Default = {
                    safeMode = false,
                },
            },
        },
    },

    FIELDS = {
        ["ui.windowStyle"] = {
            type = "enum",
            label = "Window Style",
            tooltip = "Controls the overall look of Spectrum Federation windows.",
            options = { "Default", "Compact" },
        },

        ["ui.fontStyle"] = {
            type = "enum",
            label = "Font Style",
            tooltip = "Font used in Spectrum Federation UI.",
            options = { "FrizQT", "ArialNarrow", "Morpheus", "Skurri" },
        },

        ["ui.fontSize"] = {
            type = "number",
            label = "Font Size",
            tooltip = "Size of UI text.",
            min = 8,
            max = 24,
            step = 1,
        },

        ["lootHelper.enabled"] = {
            type = "boolean",
            label = "Enable Loot Helper",
            tooltip = "Turns the Loot Helper system on or off.",
        },

        ["lootHelper.activeProfile"] = {
            type = "string",
            label = "Active Profile",
            tooltip = "Which Loot Helper profile is currently active.",
        },
    },
}