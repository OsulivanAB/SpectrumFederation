-- modules/UI/LootHelper/Constants.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.Constants = LH.Constants or {
    FRAME_NAME = "SpectrumFederationLootHelperWindow",

    -- Layout
    TITLE_HEIGHT = 28,
    TITLE_PADDING_X = 10,
    CONTENT_PADDING = 10,

    -- Default placement
    DEFAULT_POINT = "CENTER",
    DEFAULT_RELATIVE_POINT = "CENTER",
    DEFAULT_X = 0,
    DEFAULT_Y = 0,

    -- Default size
    DEFAULT_WIDTH = 480,
    DEFAULT_HEIGHT = 520,
    
    -- Guardrails
    MIN_WIDTH = 320,
    MIN_HEIGHT = 260,
    MAX_WIDTH = 1000,
    MAX_HEIGHT = 900,

    -- Title bar visuals
    LOGO_SIZE = 18,
    ICON_BUTTON_SIZE = 18,

    -- Resize Handle
    RESIZE_HANDLE_SIZE = 16,
    RESIZE_HANDLE_GAP = 6,
    SCROLLBAR_GAP = 6
}