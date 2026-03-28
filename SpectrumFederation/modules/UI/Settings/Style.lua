-- Grab the namespace
local addonName, SF = ...

SF.SettingsUI = SF.SettingsUI or {}
local UI = SF.SettingsUI

UI.Style = {
    Page = {
        paddingTop      = 12,
        paddingBottom   = 16,
        paddingX        = 16,
        sectionSpacing  = 1,
    },
        
    Section = {
        headerHeight = 22,
        lineThickness = 1,
        lineAlpha = 0.28,
        titleGap = 10,
        infoButtonSize = 14,
        infoButtonGap = 2,
        infoButtonOffsetY = 4,

        contentInsetX = 12,
        paddingTop = 10,
        paddingBottom = 12,
        rowSpacing = 8,

        messagePaddingX = 10,
        messagePaddingY = 6,
        messageBgAlpha = 0.18,
    },

    Row = {
        labelWidth = 220,
        gutter = 16,
        controlWidth = 240,
    },
}