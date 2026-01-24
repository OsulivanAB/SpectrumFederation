-- modules/UI/LootHelper/Window.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow
local C = LH.Constants

LH.Window = LH.Window or {}
local Window = LH.Window

-- Attach a tooltip to a region
-- @param region Frame Region to attach tooltip to
-- @param title string Tooltip title
-- @param text string Tooltip text
local function AttachTooltip(region, title, text)
    if not text or text == "" then return end
    region:EnableMouse(true)
    region:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title or "", 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)

    region:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Create an icon button with highlight effect
-- @param parent Frame Parent frame
-- @param atlas string Atlas name for the icon texture
-- @param size number Size of the button (width and height)
-- @return Button Created button
local function CreateIconButton(parent, atlas, size)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size or 20, size or 20)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(btn)
    btn.Icon = icon
    if atlas then
        icon:SetAtlas(atlas, true)
    end

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(btn)
    hl:SetColorTexture(1, 1, 1, 0.18)
    btn.Highlight = hl

    return btn
end

-- Create the main window frame
-- @return Frame Created main window frame
function Window:Create()
    if self._frame then
        return self._frame
    end

    local frame = CreateFrame("Frame", C.FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(C.DEFAULT_WIDTH, C.DEFAULT_HEIGHT)
    frame:SetPoint(C.DEFAULT_POINT, UIParent, C.DEFAULT_RELATIVE_POINT, C.DEFAULT_X, C.DEFAULT_Y)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("MEDIUM")
    frame:Hide()

    -- Backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4},
    })
    frame:SetBackdropColor(0, 0, 0, 0.60)
    frame:SetBackdropBorderColor(0.65, 0.65, 0.65, 0.65)

    -- =====================================================
    -- Title Bar
    -- =====================================================
    local title = CreateFrame("Frame", nil, frame)
    title:SetHeight(C.TITLE_HEIGHT)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    title:EnableMouse(true)
    frame.Title = title

    local titleBG = title:CreateTexture(nil, "BACKGROUND")
    titleBG:SetAllPoints(title)
    titleBG:SetColorTexture(0.08, 0.08, 0.08, 0.85)
    title.BG = titleBG

    -- Logo
    local logo = title:CreateTexture(nil, "ARTWORK")
    logo:SetSize(C.LOGO_SIZE, C.LOGO_SIZE)
    logo:SetPoint("LEFT", title, "LEFT", C.TITLE_PADDING_X, 0)
    logo:SetTexture("Interface\\AddOns\\SpectrumFederation\\media\\Icons\\SpectrumFederationIcon.tga")
    title.Logo = logo

    -- Close button
    local close = CreateFrame("Button", nil, title, "UIPanelCloseButton")
    close:SetPoint("RIGHT", title, "RIGHT", -4, 0)
    close:SetSize(20, 20)
    AttachTooltip(close, "Close", "Disables LootHelper")

    -- Gear button
    local gear = CreateIconButton(title, "common-icon-settings", C.ICON_BUTTON_SIZE)
    gear:SetPoint("RIGHT", close, "LEFT", -6, 0)
    title.Gear = gear
    AttachTooltip(gear, "Settings", "Open Loot Helper Settings")

    -- Profile Name
    -- TODO: Maybe update this to point name?
    local profileName = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    profileName:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    profileName:SetPoint("RIGHT", gear, "LEFT", -140, 0)
    profileName:SetJustifyH("LEFT")
    profileName:SetText("No Active Profile")
    profileName:SetWordWrap(false)
    profileName:SetMaxLines(1)
    title.ProfileName = profileName

    -- Session indicator
    local session = title:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    session:SetPoint("LEFT", profileName, "RIGHT", 10, 0)
    session:SetPoint("RIGHT", gear, "LEFT", -10, 0)
    session:SetJustifyH("CENTER")
    session:SetWordWrap(false)
    session:SetMaxLines(1)
    title.Session = session

    session:SetText("No Active Session")    -- TODO: Determine if session is active or not
    session:SetTextColor(1, 0.2, 0.2)

    -- Only show session if it fits
    local function UpdateSessionVisibility()
        session:Show()

        local w = session:GetWidth() or 0
        local needed = session:GetStringWidth() or 0

        -- If it won't fit, hide
        if w < (needed + 6) then
            session:Hide()
        end
    end

    title:HookScript("OnSizeChanged", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, UpdateSessionVisibility)
        else
            UpdateSessionVisibility()
        end
    end)

    -- Button handlers (Controller assigns callbacks)
    gear:SetScript("OnClick", function()
        if frame.OnGearClicked then frame:OnGearClicked() end
    end)
    close:SetScript("OnClick", function()
        if frame.OnCloseClicked then frame:OnCloseClicked() end
    end)
    
    -- =====================================================
    -- Content Area
    -- =====================================================

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", C.CONTENT_PADDING, -(C.TITLE_HEIGHT + C.CONTENT_PADDING + 6))
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -C.CONTENT_PADDING, C.CONTENT_PADDING)
    frame.Content = content

    local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local sb = scroll.ScrollBar
    local sbw = (sb and sb:GetWidth()) or 20
    if sbw < 16 then sbw = 20 end
    local RIGHT_GAP = 6
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -(sbw + RIGHT_GAP), 0)
    content.Scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    content.Child = child

    -- TODO: Remove Placeholder
    local placeholder = child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    placeholder:SetPoint("TOPLEFT", child, "TOPLEFT", 10, -10)
    placeholder:SetText("Loot Helper Window (skeleton)\n\n Rows + logic will be added later")
    content.Placeholder = placeholder

    -- Store and apply initial sytling
    self._frame = frame

    if LH.Style and LH.Style.Apply then
        LH.Style:Apply(frame)
    end

    -- Initial visibility check for session text
    if C_Timer and C_Timer.After then
        C_Timer.After(0, UpdateSessionVisibility)   -- Delay to allow layout to settle
    end

    return frame
end

-- Get the main window frame
-- @return Frame Main window frame
function Window:GetFrame()
    return self._frame
end

-- Set the profile name displayed in the window title
-- @param name string Profile name to display
function Window:SetProfileName(name)
    local f = self._frame
    if not f or not f.Title or not f.Title.ProfileName then return end
    f.Title.ProfileName:SetText(tostring(name or "No Active Profile"))
end

function Window:SetSessionActive(isActive)
    local f = self._frame
    if not f or not f.Title or not f.Title.Session then return end

    -- TODO: real session logic later
    if isActive then
        f.Title.Session:SetText("Session Active")
        f.Title.Session:SetTextColor(0.2, 1, 0.2)
    else
        f.Title.Session:SetText("No Active Session")
        f.Title.Session:SetTextColor(1, 0.2, 0.2)
    end
end