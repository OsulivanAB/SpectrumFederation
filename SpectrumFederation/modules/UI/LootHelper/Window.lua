-- modules/UI/LootHelper/Window.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow
local C = LH.Constants

LH.Window = LH.Window or {}
local Window = LH.Window

local function Clamp(v, minV, maxV)
    v = tonumber(v) or minV
    if v < minV then return minV end
    if v > maxV then return maxV end
    return v
end

local function Round(v)
    v = tonumber(v) or 0
    return math.floor(v + 0.5)
end

function Window:_GetWindowStateTable()
    -- Persist per-account in SpectrumFederationDB.lootHelper.window
    SpectrumFederationDB = SpectrumFederationDB or {}
    SpectrumFederationDB.lootHelper = SpectrumFederationDB.lootHelper or {}
    SpectrumFederationDB.lootHelper.window = SpectrumFederationDB.lootHelper.window or {}

    -- Keep SF.lootHelperDB in sync if it exists
    if SF.lootHelperDB and SF.lootHelperDB.window ~= SpectrumFederationDB.lootHelper.window then
        SF.lootHelperDB.window = SpectrumFederationDB.lootHelper.window
    end

    return SpectrumFederationDB.lootHelper.window
end

function Window:_ApplyResizeBounds(frame)
    if not frame then return end

    frame:SetResizable(true)

    if frame.SetResizeBounds then
        frame:SetResizeBounds(C.MIN_WIDTH, C.MIN_HEIGHT, C.MAX_WIDTH, C.MAX_HEIGHT)
    else
        if frame.SetMinResize then frame:SetMinResize(C.MIN_WIDTH, C.MIN_HEIGHT) end
        if frame.SetMaxResize then frame:SetMaxResize(C.MAX_WIDTH, C.MAX_HEIGHT) end
    end
end

function Window:ClampSizeToBounds()
    local f = self._frame
    if not f then return end

    local w, h = f:GetSize()
    w = Clamp(w, C.MIN_WIDTH, C.MAX_WIDTH)
    h = Clamp(h, C.MIN_HEIGHT, C.MAX_HEIGHT)
    f:SetSize(w, h)
end

function Window:EnsureOnScreen()
    local f = self._frame
    if not f then return end

    local uiW = UIParent:GetWidth()
    local uiH = UIParent:GetHeight()
    if not uiW or not uiH or uiW <= 0 or uiH <= 0 then return end

    local left, right, top, bottom = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not left or not right or not top or not bottom then return end

    -- If it somehow ended up off-screen, reset to defaults
    if left < 0 or right > uiW or bottom < 0 or top > uiH then
        f:ClearAllPoints()
        f:SetPoint(C.DEFAULT_POINT, UIParent, C.DEFAULT_RELATIVE_POINT, C.DEFAULT_X, C.DEFAULT_Y)
    end
end

function Window:LoadState()
    local f = self._frame
    if not f then return end
     local st = self:_GetWindowStateTable()

     -- Size
     local w = Clamp(st.width or C.DEFAULT_WIDTH, C.MIN_WIDTH, C.MAX_WIDTH)
     local h = Clamp(st.height or C.DEFAULT_HEIGHT, C.MIN_HEIGHT, C.MAX_HEIGHT)
     f:SetSize(w, h)

     -- Position
     local point = st.point or C.DEFAULT_POINT
     local relativePoint = st.relativePoint or C.DEFAULT_RELATIVE_POINT
     local x = tonumber(st.x) or C.DEFAULT_X
     local y = tonumber(st.y) or C.DEFAULT_Y

     f:ClearAllPoints()
     f:SetPoint(point, UIParent, relativePoint, x, y)

     -- Ensure safe after layout settles
     if C_Timer and C_Timer.After then
         C_Timer.After(0, function()
             self:EnsureOnScreen()
         end)
     else
         self:EnsureOnScreen()        
     end
end

function Window:SaveState()
    local f = self._frame
    if not f then return end

    local st = self:_GetWindowStateTable()

    -- Clamp size to bounds before saving
    self:ClampSizeToBounds()

    local w, h = f:GetSize()

    local w, h = f:GetSize()
    local point, _, relPoint, x, y = f:GetPoint(1)

    st.width = Round(w)
    st.height = Round(h)
    st.point = point or C.DEFAULT_POINT
    st.relativePoint = relPoint or C.DEFAULT_RELATIVE_POINT
    st.x = Round(x)
    st.y = Round(y)
end

function Window:_ReadLockSetting()
    if SF.SettingStore and SF.SettingsStore.Get then
        return SF.SettingsStore:Get("lootHelper.lockLootWindow") and true or false
    end

    local db = SF.lootHelperDB or (SpectrumFederationDB and SpectrumFederationDB.lootHelper)
    return db and db.lockWindow and true or false
end

function Window:SetLocked(locked)
    local f = self._frame
    if not f then return end

    locked = locked and true or false
    f.__sfLocked = locked

    -- Dragging (title bar)
    if f.Title then
        -- Always keep the title mouse-enabled so Gear/Close still work
        f.Title:EnableMouse(true)

        if locked then
            if f.Title.UnregisterForDrag then
                f.Title:UnregisterForDrag("LeftButton")
            end
            f.Title:SetScript("OnDragStart", nil)
            f.Title:SetScript("OnDragStop", nil)
        else
            f.Title:RegisterForDrag("LeftButton")

            f.Title:SetScript("OnDragStart", function()
                if f.__sfLocked then return end
                f:StartMoving()
            end)

            f.Title:SetScript("OnDragStop", function()
                f:StopMovingOrSizing()
                Window:SaveState()
            end)
        end
    end

    -- Resizing (bottom-right handle)
    if f.ResizeHandle then
        f.ResizeHandle:SetShown(not locked)
        f.ResizeHandle:EnableMouse(not locked)
    end

    -- Frame resizable toggle
    if locked then
        f:SetResizable(false)
    else
        self:_ApplyResizeBounds(f)
    end

    self:UpdateScrollInsets()
end

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
-- atlasOrTexture can be either:
--   * an atlas name (preferred when valid)
--   * a texture file path (fallback)
local function CreateIconButton(parent, atlasOrTexture, size)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size or 20, size or 20)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(btn)
    btn.Icon = icon

    local function ApplyIcon(value)
        if type(value) ~= "string" or value == "" then return end

        -- If it's a valid atlas, use it
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(value) then
            icon:SetAtlas(value, true)
            icon:SetTexCoord(0, 1, 0, 1)
            return
        end

        -- Otherwise treat it as a texture path
        icon:SetTexture(value)
        icon:SetTexCoord(0, 1, 0, 1)
    end

    ApplyIcon(atlasOrTexture)

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

    -- Enable moving + resizing
    frame:SetMovable(true)
    self:_ApplyResizeBounds(frame)

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
    local gear = CreateIconButton(title, "Interface\\Buttons\\UI-OptionsButton", C.ICON_BUTTON_SIZE)
    gear:SetPoint("RIGHT", close, "LEFT", -6, 0)
    title.Gear = gear
    AttachTooltip(gear, "Settings", "Open Loot Helper Settings")

    -- Profile Name
    -- TODO: Maybe update this to point name?
    local profileName = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    -- profileName:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    -- profileName:SetPoint("RIGHT", gear, "LEFT", -140, 0)
    profileName:SetJustifyH("LEFT")
    profileName:SetText("No Active Profile")
    profileName:SetWordWrap(false)
    profileName:SetMaxLines(1)
    title.ProfileName = profileName

    -- Session indicator
    local session = title:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    -- session:SetPoint("LEFT", profileName, "RIGHT", 10, 0)
    -- session:SetPoint("RIGHT", gear, "LEFT", -10, 0)
    session:SetJustifyH("CENTER")
    session:SetWordWrap(false)
    session:SetMaxLines(1)
    session:SetText("No Active Session")    -- TODO: Determine if session is active or not
    session:SetTextColor(1, 0.2, 0.2)
    title.Session = session
    
    local TITLE_LEFT_PAD = 8    -- between logo and title text
    local TITLE_RIGHT_PAD = 10  -- between title/session and gear button
    local TITLE_GAP = 10    -- gap between title text and session text
    local SESSION_EXTRA = 6   -- slight padding so session doesn't feel cramped

    local function UpdateTitleLayout()
        -- Need actual geometry for this to work reliably
        local logoR = logo:GetRight()
        local gearL = gear:GetLeft()
        if not logoR or not gearL then return end

        local leftX = logoR + TITLE_LEFT_PAD
        local rightX = gearL - TITLE_RIGHT_PAD
        local totalW = rightX - leftX
        if totalW < 80 then return end

        -- Measure string widths (true text size)
        local titleW = profileName:GetStringWidth() or 0
        local sessionW = session:GetStringWidth() or 0
        local wantSessionW = sessionW + SESSION_EXTRA

        -- Show session ONLY if both strings can fit side-by-side without forcing truncation
        local canShowSession = (titleW + TITLE_GAP + wantSessionW) <= totalW

        -- Reset anchors
        profileName:ClearAllPoints()
        session:ClearAllPoints()

        profileName:SetPoint("LEFT", logo, "RIGHT", TITLE_LEFT_PAD, 0)

        if canShowSession then
            session:Show()
            session:SetWidth(wantSessionW)
            session:SetPoint("RIGHT", gear, "LEFT", -TITLE_RIGHT_PAD, 0)

            profileName:SetPoint("RIGHT", session, "LEFT", -TITLE_GAP, 0)
        else
            session:Hide()
            profileName:SetPoint("RIGHT", gear, "LEFT", -TITLE_RIGHT_PAD, 0)
        end
    end

    -- Expose to setters so changing text triggers a re-layout
    title.UpdateTitleLayout = UpdateTitleLayout

    -- -- Only show session if it fits
    -- local function UpdateSessionVisibility()
    --     session:Show()

    --     local w = session:GetWidth() or 0
    --     local needed = session:GetStringWidth() or 0

    --     -- If it won't fit, hide
    --     if w < (needed + 6) then
    --         session:Hide()
    --     end
    -- -- end

    -- title.UpdateSessionVisibility = UpdateSessionVisibility

    title:HookScript("OnSizeChanged", function()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, UpdateTitleLayout)
        else
            UpdateTitleLayout()
        end
    end)

    -- Initial visibility check for session text
    if C_Timer and C_Timer.After then
        C_Timer.After(0, UpdateTitleLayout)   -- Delay to allow layout to settle
    else
        UpdateTitleLayout()
    end

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

    -- Bottom-right resize handle (shown only when unlocked)
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(C.RESIZE_HANDLE_SIZE or 16, C.RESIZE_HANDLE_SIZE or 16)
    resize:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -2, -2)

    -- Chat-style grabber textures
    resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    
    resize:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        if frame.__sfLocked then return end
        frame:StartSizing("BOTTOMRIGHT")
    end)

    resize:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StopMovingOrSizing()
        Window:ClampSizeToBounds()
        Window:SaveState()
    end)

    frame.ResizeHandle = resize

    -- Apply scroll layout now + once more next frame
    self:UpdateScrollInsets()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            self:UpdateScrollInsets()
        end)
    end

    -- Re-apply when window resizes
    frame:HookScript("OnSizeChanged", function()
        Window:UpdateScrollInsets()
    end)

    -- Store and apply initial sytling
    self._frame = frame

    -- Load saved position/size
    self:LoadState()

    -- Apply lock state immediately
    self:SetLocked(self:_ReadLockSetting())

    -- Apply initial styling
    if LH.Style and LH.Style.Apply then
        LH.Style:Apply(frame)
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

    if f.Title and f.Title.UpdateTitleLayout then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, f.Title.UpdateTitleLayout)
        else
            f.Title.UpdateTitleLayout()
        end
    end
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

    if f.Title and f.Title.UpdateTitleLayout then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, f.Title.UpdateTitleLayout)
        else
            f.Title.UpdateTitleLayout()
        end        
    end
end



function Window:UpdateScrollInsets()
    local f = self._frame
    if not f or not f.Content or not f.Content.Scroll then return end

    local content = f.Content
    local scroll = content.Scroll

    -- Reserve space for the scrollbar
    local sb = scroll.ScrollBar
    local sbw = (sb and sb:GetWidth()) or 0
    if sbw < 16 then sbw = 20 end

    local rightInset = sbw + (C.SCROLLBAR_GAP or 6)

    -- Reserve space for the resize handle corner when unlocked
    local bottomInset = 0
    if f.ResizeHandle and f.ResizeHandle:IsShown() then
        local h = f.ResizeHandle:GetHeight() or (C.RESIZE_HANDLE_SIZE or 16)
        bottomInset = h + (C.RESIZE_HANDLE_GAP or 6)
    end

    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -rightInset, bottomInset)
end