-- modules/UI/LootHelper/Window.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow
local C = LH.Constants

local PLAY_BUTTON_ICON = "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"
local STOP_BUTTON_ICON = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"

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
    if f.__sfMinimized then
        h = C.MINIMIZED_HEIGHT
    else
        h = Clamp(h, C.MIN_HEIGHT, C.MAX_HEIGHT)
    end
    f:SetSize(w, h)
end

function Window:_UpdateResizeHandleState()
    local f = self._frame
    if not f then return end

    local canResize = not f.__sfLocked and not f.__sfMinimized

    if f.ResizeHandle then
        f.ResizeHandle:SetShown(canResize)
        f.ResizeHandle:EnableMouse(canResize)
    end

    if canResize then
        self:_ApplyResizeBounds(f)
    else
        f:SetResizable(false)
    end
end

function Window:_UpdateMinimizeButtonState()
    local f = self._frame
    if not f or not f.Title or not f.Title.Minimize then return end

    local btn = f.Title.Minimize
    local minimized = f.__sfMinimized and true or false

    if btn:GetNormalTexture() then
        btn:GetNormalTexture():SetAtlas(minimized and "ui-questtrackerbutton-secondary-expand" or "ui-questtrackerbutton-secondary-collapse", true)
    end
    if btn:GetPushedTexture() then
        btn:GetPushedTexture():SetAtlas(minimized and "ui-questtrackerbutton-secondary-expand-pressed" or "ui-questtrackerbutton-secondary-collapse-pressed", true)
    end

    btn.__sfTooltipTitle = minimized and "Restore" or "Minimize"
    btn.__sfTooltipText = minimized
        and "Restore the Loot Helper window to its full size."
        or "Collapse the Loot Helper window to its title bar."
end

function Window:_ApplyMinimizedState()
    local f = self._frame
    if not f then return end

    local st = self:_GetWindowStateTable()
    local minimized = f.__sfMinimized and true or false

    if minimized then
        local w = Clamp(st.width or f:GetWidth() or C.DEFAULT_WIDTH, C.MIN_WIDTH, C.MAX_WIDTH)
        f:SetSize(w, C.MINIMIZED_HEIGHT)
    else
        local w = Clamp(st.width or f:GetWidth() or C.DEFAULT_WIDTH, C.MIN_WIDTH, C.MAX_WIDTH)
        local h = Clamp(st.expandedHeight or st.height or f:GetHeight() or C.DEFAULT_HEIGHT, C.MIN_HEIGHT, C.MAX_HEIGHT)
        f:SetSize(w, h)
    end

    if f.Content then
        f.Content:SetShown(not minimized)
    end

    self:_UpdateResizeHandleState()
    self:_UpdateMinimizeButtonState()
    self:RequestScrollInsetsUpdate()
end

function Window:IsMinimized()
    local f = self._frame
    return f and f.__sfMinimized and true or false
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
      f.__sfMinimized = st.minimized and true or false

      -- Position
      local point = st.point or C.DEFAULT_POINT
     local relativePoint = st.relativePoint or C.DEFAULT_RELATIVE_POINT
     local x = tonumber(st.x) or C.DEFAULT_X
     local y = tonumber(st.y) or C.DEFAULT_Y

      f:ClearAllPoints()
      f:SetPoint(point, UIParent, relativePoint, x, y)
      self:_ApplyMinimizedState()

      if SF.Debug then
          SF.Debug:Verbose("LH_WINDOW", "LoadState: size=%dx%d, minimized=%s, position=%s->%s at (%d,%d)", w, h, tostring(f.__sfMinimized), point, relativePoint, x, y)
      end

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
    local point, _, relPoint, x, y = f:GetPoint(1)

    st.width = Round(w)
    if f.__sfMinimized then
        local expandedHeight = st.expandedHeight or st.height or C.DEFAULT_HEIGHT
        st.height = Round(Clamp(expandedHeight, C.MIN_HEIGHT, C.MAX_HEIGHT))
        st.expandedHeight = st.height
    else
        st.height = Round(Clamp(h, C.MIN_HEIGHT, C.MAX_HEIGHT))
        st.expandedHeight = st.height
    end
    st.minimized = f.__sfMinimized and true or false
    st.point = point or C.DEFAULT_POINT
    st.relativePoint = relPoint or C.DEFAULT_RELATIVE_POINT
    st.x = Round(x)
    st.y = Round(y)

    if SF.Debug then
        SF.Debug:Verbose("LH_WINDOW", "SaveState: size=%dx%d, minimized=%s, position=%s->%s at (%d,%d)", st.width, st.height, tostring(st.minimized), st.point, st.relativePoint, st.x, st.y)
    end
end

function Window:SetMinimized(minimized)
    local f = self._frame
    if not f then return end

    minimized = minimized and true or false
    if f.__sfMinimized == minimized then
        self:_ApplyMinimizedState()
        return
    end

    local st = self:_GetWindowStateTable()

    if minimized then
        local w, h = f:GetSize()
        st.width = Round(Clamp(w, C.MIN_WIDTH, C.MAX_WIDTH))
        st.height = Round(Clamp(h, C.MIN_HEIGHT, C.MAX_HEIGHT))
        st.expandedHeight = st.height
    end

    f.__sfMinimized = minimized
    st.minimized = minimized

    self:_ApplyMinimizedState()
    self:SaveState()
end

function Window:ToggleMinimized()
    self:SetMinimized(not self:IsMinimized())
end

function Window:_ReadLockSetting()
    if SF.SettingsStore and SF.SettingsStore.Get then  
        return SF.SettingsStore:Get("lootHelper.lockLootWindow") and true or false  
    end  

    local db = SF.lootHelperDB or (SpectrumFederationDB and SpectrumFederationDB.lootHelper)  
    return db and db.lockLootWindow and true or false  
end

function Window:SetLocked(locked)
    local f = self._frame
    if not f then return end

    locked = locked and true or false
    f.__sfLocked = locked

    if SF.Debug then
        SF.Debug:Info("LH_WINDOW", "SetLocked: locked=%s", tostring(locked))
    end

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

    self:_UpdateResizeHandleState()
    self:RequestScrollInsetsUpdate()
end

-- Attach a tooltip to a region
-- @param region Frame Region to attach tooltip to
-- @param title string Tooltip title
-- @param text string Tooltip text
local function AttachTooltip(region, title, text)
    region:EnableMouse(true)
    region:HookScript("OnEnter", function(self)
        local resolvedTitle = type(title) == "function" and title(self) or title
        local resolvedText = type(text) == "function" and text(self) or text
        if not resolvedText or resolvedText == "" then return end

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(resolvedTitle or "", 1, 1, 1)
        GameTooltip:AddLine(resolvedText, nil, nil, nil, true)
        GameTooltip:Show()
    end)

    region:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Create a simple icon button with highlight effect
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
    btn.SetIcon = ApplyIcon

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(btn)
    hl:SetColorTexture(1, 1, 1, 0.18)
    btn.Highlight = hl

    return btn
end

local function CreateObjectiveTrackerToggleButton(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(16, 16)

    local normal = btn:CreateTexture(nil, "ARTWORK")
    normal:SetAtlas("ui-questtrackerbutton-secondary-collapse", true)
    btn:SetNormalTexture(normal)

    local pushed = btn:CreateTexture(nil, "ARTWORK")
    pushed:SetAtlas("ui-questtrackerbutton-secondary-collapse-pressed", true)
    btn:SetPushedTexture(pushed)

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAtlas("ui-questtrackerbutton-yellow-highlight", true)
    highlight:SetBlendMode("ADD")
    btn:SetHighlightTexture(highlight)

    return btn
end

-- Create the main window frame
-- @return Frame Created main window frame
function Window:Create()
    if self._frame then
        return self._frame
    end

    if SF.Debug then
        SF.Debug:Info("LH_WINDOW", "Creating main window frame")
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

    -- Gear button
    local gear = CreateIconButton(title, "Interface\\Buttons\\UI-OptionsButton", C.ICON_BUTTON_SIZE)
    title.Gear = gear
    AttachTooltip(gear, "Settings", "Open the Loot Helper settings window.")

    -- Play button
    local play = CreateIconButton(title, PLAY_BUTTON_ICON, C.ICON_BUTTON_SIZE)
    title.Play = play
    play.__sfTooltipTitle = "Start Session"
    play.__sfTooltipText = "Start a Loot Helper session for the active profile."
    AttachTooltip(play, function(self) return self.__sfTooltipTitle end, function(self) return self.__sfTooltipText end)

    -- Minimize/restore button
    local minimize = CreateObjectiveTrackerToggleButton(title)
    minimize:SetPoint("RIGHT", title, "RIGHT", -4, 0)
    title.Minimize = minimize
    minimize.__sfTooltipTitle = "Minimize"
    minimize.__sfTooltipText = "Collapse the Loot Helper window to its title bar."
    gear:SetPoint("RIGHT", minimize, "LEFT", -6, 0)
    play:SetPoint("RIGHT", gear, "LEFT", -6, 0)
    AttachTooltip(minimize, function(self) return self.__sfTooltipTitle end, function(self) return self.__sfTooltipText end)

    -- Profile Name
    local profileName = title:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    profileName:SetJustifyH("LEFT")
    profileName:SetText("No Active Profile")
    profileName:SetWordWrap(false)
    profileName:SetMaxLines(1)
    title.ProfileName = profileName

    -- Point name
    local pointName = title:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    pointName:SetJustifyH("CENTER")
    pointName:SetWordWrap(false)
    pointName:SetMaxLines(1)
    pointName:SetText("")
    pointName:SetTextColor(0.82, 0.82, 0.82)
    title.PointName = pointName
    
    local TITLE_LEFT_PAD = 8    -- between logo and title text
    local TITLE_RIGHT_PAD = 10  -- between title text and play button
    local TITLE_GAP = 10    -- gap between title text and point name text
    local POINT_NAME_EXTRA = 6   -- slight padding so point name doesn't feel cramped

    local function UpdateTitleLayout()
        -- Need actual geometry for this to work reliably
        local logoR = logo:GetRight()
        local actionAnchor = play:IsShown() and play or gear
        local actionL = actionAnchor:GetLeft()
        if not logoR or not actionL then return end

        local leftX = logoR + TITLE_LEFT_PAD
        local rightX = actionL - TITLE_RIGHT_PAD
        local totalW = rightX - leftX
        if totalW < 80 then return end

        -- Measure string widths (true text size)
        local titleW = profileName:GetStringWidth() or 0
        local pointW = pointName:GetStringWidth() or 0
        local wantPointW = pointW + POINT_NAME_EXTRA

        -- Show point name only if both strings fit side-by-side without forcing truncation.
        local canShowPointName = pointW > 0 and (titleW + TITLE_GAP + wantPointW) <= totalW

        -- Reset anchors
        profileName:ClearAllPoints()
        pointName:ClearAllPoints()

        profileName:SetPoint("LEFT", logo, "RIGHT", TITLE_LEFT_PAD, 0)

        if canShowPointName then
            pointName:Show()
            pointName:SetWidth(wantPointW)
            pointName:SetPoint("RIGHT", actionAnchor, "LEFT", -TITLE_RIGHT_PAD, 0)

            profileName:SetPoint("RIGHT", pointName, "LEFT", -TITLE_GAP, 0)
        else
            pointName:Hide()
            profileName:SetPoint("RIGHT", actionAnchor, "LEFT", -TITLE_RIGHT_PAD, 0)
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

    -- Initial visibility check for header text
    if C_Timer and C_Timer.After then
        C_Timer.After(0, UpdateTitleLayout)   -- Delay to allow layout to settle
    else
        UpdateTitleLayout()
    end

    -- Button handlers (Controller assigns callbacks)
    play:SetScript("OnClick", function()
        if frame.OnPlayClicked then frame:OnPlayClicked() end
    end)
    gear:SetScript("OnClick", function()
        if frame.OnGearClicked then frame:OnGearClicked() end
    end)
    minimize:SetScript("OnClick", function()
        if frame.OnMinimizeClicked then frame:OnMinimizeClicked() end
    end)
    
    -- =====================================================
    -- Content Area
    -- =====================================================

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", C.CONTENT_PADDING, -(C.TITLE_HEIGHT + C.CONTENT_PADDING + 6))
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -C.CONTENT_PADDING, C.CONTENT_PADDING)
    frame.Content = content

    local potHeader = CreateFrame("Frame", nil, content)
    potHeader:SetHeight(C.POT_HEADER_HEIGHT or 22)
    potHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    potHeader:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    potHeader:Hide()
    content.PotHeader = potHeader

    local potText = potHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    potText:SetPoint("LEFT", potHeader, "LEFT", 4, 0)
    potText:SetPoint("RIGHT", potHeader, "RIGHT", -4, 0)
    potText:SetJustifyH("LEFT")
    potText:SetWordWrap(false)
    potText:SetMaxLines(1)
    potText:SetText("")
    potHeader.Text = potText

    local scroll = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local sb = scroll.ScrollBar
    local sbw = (sb and sb:GetWidth()) or 20
    if sbw < 16 then sbw = 20 end
    local RIGHT_GAP = 6
    content.Scroll = scroll

    scroll:HookScript("OnScrollRangeChanged", function()
        Window:RequestScrollInsetsUpdate()
    end)

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
    self:RequestScrollInsetsUpdate()

    -- Re-apply when window resizes
    frame:HookScript("OnSizeChanged", function()
        Window:RequestScrollInsetsUpdate()
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

function Window:SetPointName(name)
    local f = self._frame
    if not f or not f.Title or not f.Title.PointName then return end

    local text = tostring(name or "")
    text = text:match("^%s*(.-)%s*$") or ""
    f.Title.PointName:SetText(text)

    if f.Title and f.Title.UpdateTitleLayout then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, f.Title.UpdateTitleLayout)
        else
            f.Title.UpdateTitleLayout()
        end        
    end
end

function Window:SetRewardPotHeader(isVisible, text)
    local f = self._frame
    if not f or not f.Content or not f.Content.PotHeader then return end

    local header = f.Content.PotHeader
    isVisible = isVisible and true or false
    header:SetShown(isVisible)
    if header.Text then
        if isVisible then
            header.Text:SetText(tostring(text or ""))
        else
            header.Text:SetText("")
        end
    end
    self:RequestScrollInsetsUpdate()
end

function Window:SetPlayButtonVisible(isVisible)
    local f = self._frame
    if not f or not f.Title or not f.Title.Play then return end

    isVisible = isVisible and true or false
    f.Title.Play:SetShown(isVisible)
    f.Title.Play:EnableMouse(isVisible)

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
    if not f or not f.Title or not f.Title.Play or not f.Title.Play.Icon then return end

    if isActive then
        f.Title.Play:SetIcon(STOP_BUTTON_ICON)
        f.Title.Play.Icon:SetVertexColor(0.30, 1.00, 0.30, 1)
        f.Title.Play.__sfTooltipTitle = "Stop Session"
        f.Title.Play.__sfTooltipText = "End the current Loot Helper session."
    else
        f.Title.Play:SetIcon(PLAY_BUTTON_ICON)
        f.Title.Play.Icon:SetVertexColor(1, 1, 1, 1)
        f.Title.Play.__sfTooltipTitle = "Start Session"
        f.Title.Play.__sfTooltipText = "Start a Loot Helper session for the active profile."
    end
end



function Window:RequestScrollInsetsUpdate()
	local f = self._frame
	if not f then return end

	if f.__sfScrollInsetsScheduled then return end
	f.__sfScrollInsetsScheduled = true

	local function Run()
		local f2 = self._frame
		if not f2 then return end
		f2.__sfScrollInsetsScheduled = false
		self:UpdateScrollInsets()
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, Run)
	else
		Run()
	end
end

function Window:UpdateScrollInsets()
	local f = self._frame
	if not f or not f.Content or not f.Content.Scroll then return end

	local content = f.Content
	local scroll = content.Scroll
	local sb = scroll.ScrollBar

    if f.__sfMinimized then
        if sb then
            sb:Hide()
        end
        if scroll.SetVerticalScroll then
            scroll:SetVerticalScroll(0)
        end
        return
    end

	-- Determine whether scrolling is actually needed
	local range = 0
	if scroll.GetVerticalScrollRange then
		range = scroll:GetVerticalScrollRange() or 0
	end
	local needScroll = range > 0.5

	-- Show/hide scrollbar based on need
	if sb then
		sb:SetShown(needScroll)
	end

	-- If scrollbar is hidden, keep scroll position at top
	if not needScroll and scroll.SetVerticalScroll then
		scroll:SetVerticalScroll(0)
	end

	-- Reserve right inset ONLY if scrollbar is shown
	local rightInset = 0
	if needScroll and sb then
		local sbw = (sb:GetWidth() or 0)
		if sbw < 16 then sbw = 20 end
		rightInset = sbw + (C.SCROLLBAR_GAP or 6)
	end

	-- Reserve bottom inset if resize handle is shown (unlocked)
	local bottomInset = 0
	if f.ResizeHandle and f.ResizeHandle:IsShown() then
		local h = f.ResizeHandle:GetHeight() or (C.RESIZE_HANDLE_SIZE or 16)
		bottomInset = h + (C.RESIZE_HANDLE_GAP or 6)
	end

	-- Reserve top inset if the Reward Pot header is shown
	local topInset = 0
	local potHeader = content.PotHeader
	if potHeader and potHeader:IsShown() then
		topInset = potHeader:GetHeight() or (C.POT_HEADER_HEIGHT or 22)
	end

	-- Apply anchors
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -topInset)
	scroll:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -rightInset, bottomInset)

	-- Clamp scroll offset if content shrank while scrolled
	if scroll.GetVerticalScroll and scroll.SetVerticalScroll and scroll.GetVerticalScrollRange then
		local cur = scroll:GetVerticalScroll() or 0
		local maxRange = scroll:GetVerticalScrollRange() or 0
		if cur > maxRange then
			scroll:SetVerticalScroll(maxRange)
		end
	end
end
