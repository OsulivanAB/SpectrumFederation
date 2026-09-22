-- modules/UI/LootHelper/RosterView.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.RosterView = LH.RosterView or {}
local View = LH.RosterView
View.__index = View

local ROW_HEIGHT = 24
local ROW_SPACING = 2
local HEADER_HEIGHT = 18
local ICON_SIZE = 20
local BTN_SIZE = 20
local BTN_GAP = 3
local POINTS_WIDTH = 40
local ATTENDANCE_WIDTH = 48
local PREP_WIDTH = 48
local BIS_WIDTH = 44
local READY_WIDTH = 18
local COLUMN_GAP = 8
local ROW_LEFT_PAD = 4
local ROW_RIGHT_PAD = 4
local NAME_ICON_GAP = 8
local ACTION_COLUMN_GAP = 6
local NAME_MIN_CHARS = 3
local NAME_ELLIPSIS = "..."
local NAME_MIN_SAMPLE = "WWW..."
local FALLBACK_CHAR_WIDTH = 8
-- Extra pixels on the window floor so the minimum is usable, not flush.
-- Must stay below one glance column (width + gap) or the floor would show
-- a column the responsive policy just hid.
View.MIN_WIDTH_COMFORT = 12

local COLUMN_KEYS_RIGHT_TO_LEFT = {
    { key = "readiness", width = READY_WIDTH },
    { key = "bis", width = BIS_WIDTH },
    { key = "preparedness", width = PREP_WIDTH },
    { key = "attendance", width = ATTENDANCE_WIDTH },
    { key = "points", width = POINTS_WIDTH },
}

-- Hide optional glance columns in this order once the name is at its floor.
local OPTIONAL_HIDE_ORDER = { "bis", "preparedness", "attendance" }
local READY_TEXTURE = {
    not_ready = "Interface\\RaidFrame\\ReadyCheck-NotReady",
}

-- Ready and unknown rows show no icon. The column still occupies READY_WIDTH
-- so Att./BiS/Points stay aligned with not-ready rows.
function View.ShowsReadinessIcon(state)
    return state == "not_ready"
end

function View.GlanceColumns(model)
    if type(model) ~= "table" or model.type ~= "PROFILE_MEMBER" then
        return {
            points = false,
            attendance = false,
            preparedness = false,
            bis = false,
            readiness = false,
        }
    end
    return {
        points = model.showPoints and true or false,
        attendance = true,
        preparedness = true,
        bis = true,
        readiness = true,
    }
end

local function CodepointEnds(text)
    local ends = {}
    local i = 1
    local len = string.len(text)
    while i <= len do
        local b = string.byte(text, i)
        local step = 1
        if b >= 240 then
            step = 4
        elseif b >= 224 then
            step = 3
        elseif b >= 192 then
            step = 2
        end
        local nextIndex = i + step
        if nextIndex > len + 1 then
            nextIndex = len + 1
        end
        ends[#ends + 1] = nextIndex - 1
        i = nextIndex
    end
    return ends
end

function View.MinimumNameWidth(measure)
    if measure then
        local width = measure(NAME_MIN_SAMPLE)
        if type(width) == "number" and width > 0 then
            return width
        end
    end
    return FALLBACK_CHAR_WIDTH * string.len(NAME_MIN_SAMPLE)
end

-- Fit text into maxWidth. Longer names keep at least NAME_MIN_CHARS plus an ellipsis.
function View.TruncateToWidth(text, maxWidth, measure)
    text = tostring(text or "")
    if text == "" then
        return ""
    end
    maxWidth = tonumber(maxWidth) or 0
    if not measure then
        return text
    end
    local fullWidth = measure(text)
    if type(fullWidth) == "number" and fullWidth <= maxWidth then
        return text
    end

    local ends = CodepointEnds(text)
    if #ends == 0 then
        return text
    end
    local minChars = NAME_MIN_CHARS
    if minChars > #ends then
        minChars = #ends
    end
    if minChars < 1 then
        minChars = 1
    end

    local function candidate(charCount)
        return string.sub(text, 1, ends[charCount]) .. NAME_ELLIPSIS
    end

    local best = minChars
    local lo = minChars
    local hi = #ends
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local width = measure(candidate(mid))
        if type(width) == "number" and width <= maxWidth + 0.01 then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    if best >= #ends then
        local full = measure(text)
        if type(full) == "number" and full <= maxWidth + 0.01 then
            return text
        end
    end
    return candidate(best)
end

-- Right-edge insets for the shared row/header column stack.
-- Returns the map of column key -> right inset, and the name's right inset.
local function WalkColumns(shown, hasAction)
    local inset = ROW_RIGHT_PAD
    if hasAction then
        inset = inset + BTN_SIZE
    end
    local any = false
    if type(shown) == "table" then
        for i = 1, #COLUMN_KEYS_RIGHT_TO_LEFT do
            if shown[COLUMN_KEYS_RIGHT_TO_LEFT[i].key] then
                any = true
                break
            end
        end
    end
    local rights = {}
    if not any then
        local nameRight = ROW_RIGHT_PAD
        if hasAction then
            nameRight = inset + COLUMN_GAP
        end
        return rights, nameRight
    end
    if hasAction then
        inset = inset + ACTION_COLUMN_GAP
    end
    local leftmostLeft = nil
    for i = 1, #COLUMN_KEYS_RIGHT_TO_LEFT do
        local col = COLUMN_KEYS_RIGHT_TO_LEFT[i]
        if shown[col.key] then
            rights[col.key] = inset
            leftmostLeft = inset + col.width
            inset = leftmostLeft + COLUMN_GAP
        end
    end
    return rights, (leftmostLeft or ROW_RIGHT_PAD) + COLUMN_GAP
end

function View.ColumnRightInset(shown, hasAction, key)
    local rights = WalkColumns(shown, hasAction ~= false)
    return rights[key]
end

function View.NameRightInset(shown, hasAction)
    local _, nameRight = WalkColumns(shown, hasAction ~= false)
    return nameRight
end

function View.FixedWidthExcludingName(shown, hasAction)
    return (ROW_LEFT_PAD + ICON_SIZE + NAME_ICON_GAP) + View.NameRightInset(shown, hasAction)
end

function View.ScrollBarInset()
    if LH.Window and LH.Window.ScrollBarInset then
        return LH.Window.ScrollBarInset(nil)
    end
    local constants = LH.Constants or {}
    return (constants.SCROLLBAR_WIDTH or 20) + (constants.SCROLLBAR_GAP or 6)
end

function View.WindowWidthForContent(contentWidth, reserveScrollbar)
    local constants = LH.Constants or {}
    local padding = constants.CONTENT_PADDING or 10
    local width = (padding * 2) + (tonumber(contentWidth) or 0)
    if reserveScrollbar then
        width = width + View.ScrollBarInset()
    end
    return width
end

function View.ContentWidthForWindow(windowWidth, reserveScrollbar)
    local constants = LH.Constants or {}
    local padding = constants.CONTENT_PADDING or 10
    local width = (tonumber(windowWidth) or 0) - (padding * 2)
    if reserveScrollbar then
        width = width - View.ScrollBarInset()
    end
    return width
end

-- Single responsive decision for the current content width.
-- request flags are the columns the loot mode wants. Optional columns drop in
-- OPTIONAL_HIDE_ORDER only after the name is at its protected minimum.
function View.ResolveResponsiveLayout(availableWidth, request, nameMinWidth)
    availableWidth = tonumber(availableWidth) or 0
    nameMinWidth = tonumber(nameMinWidth) or View.MinimumNameWidth(nil)
    if nameMinWidth < 1 then
        nameMinWidth = 1
    end
    request = type(request) == "table" and request or {}
    local shown = {
        points = request.points and true or false,
        attendance = request.attendance and true or false,
        preparedness = request.preparedness and true or false,
        bis = request.bis and true or false,
        readiness = request.readiness and true or false,
    }
    local hasAction = request.hasAction ~= false

    local function fits()
        return View.FixedWidthExcludingName(shown, hasAction) + nameMinWidth <= availableWidth + 0.01
    end

    if not fits() then
        for i = 1, #OPTIONAL_HIDE_ORDER do
            local key = OPTIONAL_HIDE_ORDER[i]
            if shown[key] then
                shown[key] = false
                if fits() then
                    break
                end
            end
        end
    end

    local nameWidth = availableWidth - View.FixedWidthExcludingName(shown, hasAction)
    if nameWidth < nameMinWidth then
        nameWidth = nameMinWidth
    end
    shown.nameWidth = nameWidth
    shown.hasAction = hasAction
    return shown
end

function View.ResolveMinimumWindowWidth(measure, reserveScrollbar)
    local nameMin = View.MinimumNameWidth(measure)
    local content = View.FixedWidthExcludingName({
        points = true,
        attendance = false,
        preparedness = false,
        bis = false,
        readiness = true,
    }, true) + nameMin
    local rosterWidth = View.WindowWidthForContent(content, reserveScrollbar ~= false)
    local titleWidth = 0
    if LH.Window and LH.Window.MinimumTitleWidth then
        titleWidth = LH.Window.MinimumTitleWidth(nameMin)
    end
    local comfort = View.MIN_WIDTH_COMFORT or 12
    return math.floor(math.max(rosterWidth, titleWidth) + comfort + 0.5)
end

-- Cropping presets you can tweak quickly:
local CROP_PLUS   = 0.18  -- plus button has padding too
local NO_CROP     = false -- special: full texture (0..1)


-- local function CreateSmallIconButton(parent, texturePath, size)
--     local b = CreateFrame("Button", nil, parent)
--     b:SetSize(size or BTN_SIZE, size or BTN_SIZE)

--     local t = b:CreateTexture(nil, "ARTWORK")
--     t:SetAllPoints(b)
--     t:SetTexture(texturePath)
--     t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
--     b.Icon = t

--     local hl = b:CreateTexture(nil, "HIGHLIGHT")
--     hl:SetAllPoints(b)
--     hl:SetColorTexture(1, 1, 1, 0.15)

--     return b
-- end

-- Default crop that makes WoW inventory-style icons look crisp
local DEFAULT_ICON_CROP = 0.07

local function NormalizeClassToken(className)
    if type(className) ~= "string" or className == "" then
        return nil
    end
    local normalized = className:upper():gsub("[%s%-%_]", "")
    if normalized == "" then
        return nil
    end
    return normalized
end

local function ApplyIconCrop(tex, opts)
	opts = opts or {}

	-- Explicit "no crop"
	if opts.noCrop or opts.crop == false or opts.texCoord == false then
		tex:SetTexCoord(0, 1, 0, 1)
		return
	end

	-- Manual texcoord overrides (l, r, t, b)
	if type(opts.texCoord) == "table" then
		local l, r, t, b = opts.texCoord[1], opts.texCoord[2], opts.texCoord[3], opts.texCoord[4]
		if type(l) == "number" and type(r) == "number" and type(t) == "number" and type(b) == "number" then
			tex:SetTexCoord(l, r, t, b)
			return
		end
	end

	-- Symmetric crop (easy tuning): crop = 0.18 -> {0.18, 0.82, 0.18, 0.82}
	local c = opts.crop
	if type(c) ~= "number" then
		c = DEFAULT_ICON_CROP
	end

	-- Safety clamps (avoid inverted coords)
	if c < 0 then c = 0 end
	if c > 0.49 then c = 0.49 end

	tex:SetTexCoord(c, 1 - c, c, 1 - c)
end

-- Create an icon button with optional cropping controls.
-- opts supports:
--   opts.crop (number)       -> symmetric crop (recommended tuning knob)
--   opts.texCoord (table)    -> {l,r,t,b} manual override
--   opts.noCrop (boolean)    -> full texture (0..1)
local function CreateSmallIconButton(parent, texturePath, size, opts)
	opts = opts or {}

	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size or BTN_SIZE, size or BTN_SIZE)

	local t = b:CreateTexture(nil, "ARTWORK")
	t:SetAllPoints(b)
	b.Icon = t

	-- Make it easy to retune later if you want
	function b:SetIcon(texture, iconOpts)
		if texture then
			t:SetTexture(texture)
		end
		ApplyIconCrop(t, iconOpts or opts)
	end

	function b:SetCrop(crop)
		ApplyIconCrop(t, { crop = crop })
	end

	function b:SetTexCoordTable(tc)
		ApplyIconCrop(t, { texCoord = tc })
	end

	b:SetIcon(texturePath, opts)

	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b)
	hl:SetColorTexture(1, 1, 1, 0.15)

	return b
end

local function GetClassIcon(className)
    local normalized = NormalizeClassToken(className)
    if normalized and SF.WOW_CLASSES and SF.WOW_CLASSES[normalized] and SF.WOW_CLASSES[normalized].textureFile then
        return SF.WOW_CLASSES[normalized].textureFile
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function GetClassColor(className)
	local normalized = NormalizeClassToken(className)
	local c = normalized and SF.WOW_CLASSES and SF.WOW_CLASSES[normalized] and SF.WOW_CLASSES[normalized].colorCode
	if c then
		return c.r or 1, c.g or 1, c.b or 1
	end
	return 1, 1, 1
end

local function FormatPointAmount(amount)
	amount = tonumber(amount) or 0
	if amount == math.floor(amount) then
		return tostring(amount)
	end

	local text = string.format("%.2f", amount)
	text = text:gsub("0+$", ""):gsub("%.$", "")
	return text
end

local function TryGetSpecIcon(unit, memberId)
    -- If no unit but memberId is provided, check if it's the player
    if not unit and memberId then
        if SF.NameUtil and SF.NameUtil.GetSelfId then
            local selfId = SF.NameUtil.GetSelfId()
            if selfId and SF.NameUtil.SamePlayer and SF.NameUtil.SamePlayer(memberId, selfId) then
                unit = "player"
            end
        end
    end

    if not unit then return nil end

    if UnitIsUnit(unit, "player") and GetSpecialization and GetSpecializationInfo then
        local specIndex = GetSpecialization()
        if specIndex then
            local _, _, _, icon = GetSpecializationInfo(specIndex)
            if icon then return icon end
        end
    end

    if GetInspectSpecialization and GetSpecializationInfoByID and CanInspect and CanInspect(unit) then
        local specID = GetInspectSpecialization(unit)
        if specID and specID > 0 then
            local _, _, _, icon = GetSpecializationInfoByID(specID)
            if icon then return icon end
        end
    end

    return nil
end

function View.new(contentFrame, controller)
    local self = setmetatable({}, View)
    self.content = contentFrame
    self.scroll = contentFrame.Scroll
    self.child = contentFrame.Child
    self.controller = controller
    self.rows = {}

    -- Empty text
    local empty = self.child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("TOPLEFT", self.child, "TOPLEFT", 10, -10)
    empty:SetPoint("RIGHT", self.child, "RIGHT", -10, 0)
    empty:SetJustifyH("LEFT")
    empty:SetJustifyV("TOP")
    empty:SetText("")
    self.emptyText = empty

    self._measure = self.child:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    if self._measure.Hide then
        self._measure:Hide()
    end
    self._layoutApplyCount = 0

    -- Keep child width in sync so TOPRIGHT anchors work, then recompute the
    -- responsive column set from that width. Presentation only: no model rebuild.
    if self.scroll then
        self.scroll:HookScript("OnSizeChanged", function()
            local w = self.scroll:GetWidth() or 1
            self.child:SetWidth(math.max(1, w))
            self:ApplyResponsiveLayout(false)
        end)
    end

    return self
end

function View:ApplyStyle(fontPath, fontSize)
    local fontChanged = self.fontPath ~= fontPath or self.fontSize ~= fontSize
    self.fontPath = fontPath
    self.fontSize = fontSize

    -- Apply to existing rows
    for _, r in ipairs(self.rows) do
        if r.Name and r.Name.SetFont then
            r.Name:SetFont(fontPath, fontSize, "")
        end
        if r.Points and r.Points.SetFont then
            r.Points:SetFont(fontPath, fontSize, "")
        end
        if r.Attendance and r.Attendance.SetFont then
            r.Attendance:SetFont(fontPath, fontSize, "")
        end
        if r.Preparedness and r.Preparedness.SetFont then
            r.Preparedness:SetFont(fontPath, fontSize, "")
        end
        if r.Bis and r.Bis.SetFont then
            r.Bis:SetFont(fontPath, fontSize, "")
        end
    end

    if self.header then
        for _, label in ipairs({ self.header.Name, self.header.Points, self.header.Attendance, self.header.Preparedness, self.header.Bis }) do
            if label and label.SetFont then
                label:SetFont(fontPath, fontSize, "")
            end
        end
    end

    if self.emptyText and self.emptyText.SetFont then
        self.emptyText:SetFont(fontPath, fontSize, "")
    end
    if self._measure and self._measure.SetFont then
        self._measure:SetFont(fontPath, fontSize, "")
    end
    self:_RefreshMinimumWidth()
    -- Data refreshes call ApplyStyle before Render. Re-truncate only when the
    -- font actually changed so those refreshes do not layout twice.
    if fontChanged then
        self:ApplyResponsiveLayout(true)
    end
end

function View:_EnsureRow(i)
    if self.rows[i] then return self.rows[i] end

    local r = CreateFrame("Frame", nil, self.child)
    r:SetHeight(ROW_HEIGHT)

    -- Icon
    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", r, "LEFT", ROW_LEFT_PAD, 0)
    r.Icon = icon

    -- Actions container (right side)
    local actions = CreateFrame("Frame", nil, r)
    actions:SetPoint("RIGHT", r, "RIGHT", -ROW_RIGHT_PAD, 0)
    actions:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -ROW_RIGHT_PAD, 0)
    actions:SetWidth(1)
    r.Actions = actions

    -- Glance columns
    local pts = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    pts:SetJustifyH("RIGHT")
    pts:SetWidth(POINTS_WIDTH)
    r.Points = pts

    local attendance = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    attendance:SetJustifyH("RIGHT")
    attendance:SetWidth(ATTENDANCE_WIDTH)
    r.Attendance = attendance

    local preparedness = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    preparedness:SetJustifyH("RIGHT")
    preparedness:SetWidth(PREP_WIDTH)
    r.Preparedness = preparedness

    local bis = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    bis:SetJustifyH("RIGHT")
    bis:SetWidth(BIS_WIDTH)
    r.Bis = bis

    local ready = CreateFrame("Frame", nil, r)
    ready:SetSize(READY_WIDTH, READY_WIDTH)
    ready:EnableMouse(true)
    local readyIcon = ready:CreateTexture(nil, "ARTWORK")
    readyIcon:SetAllPoints(ready)
    ready.Icon = readyIcon
    r.Readiness = ready

    -- Helmet / equipment toggle: this texture tends to look best without heavy crop.
    r.BtnHelmet = CreateSmallIconButton(actions,
        "Interface\\PaperDollInfoFrame\\UI-GearManager-Button",
        BTN_SIZE,
        { crop = NO_CROP }
    )

    r.BtnPlus = CreateSmallIconButton(actions,
        "Interface\\Buttons\\UI-PlusButton-Up",
        BTN_SIZE,
        { crop = CROP_PLUS }
    )

    -- Name
    local name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetMaxLines(1)
    if name.SetNonSpaceWrap then
        name:SetNonSpaceWrap(false)
    end
    name:SetPoint("LEFT", icon, "RIGHT", NAME_ICON_GAP, 0)
    r.Name = name

    -- Basic row highlight
    local hl = r:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(r)
    hl:SetColorTexture(1, 1, 1, 0.03)
    r.Highlight = hl

    -- Apply style if available
    if self.fontPath and self.fontSize then
        r.Name:SetFont(self.fontPath, self.fontSize, "")
        r.Points:SetFont(self.fontPath, self.fontSize, "")
        r.Attendance:SetFont(self.fontPath, self.fontSize, "")
        r.Preparedness:SetFont(self.fontPath, self.fontSize, "")
        r.Bis:SetFont(self.fontPath, self.fontSize, "")
    end

    self.rows[i] = r
    return r
end

function View:_LayoutButtons(r, model)
	local actions = r.Actions
	local x = 0

	local function Place(btn)
		btn:ClearAllPoints()
		btn:SetPoint("RIGHT", actions, "RIGHT", -x, 0)
		x = x + BTN_SIZE + BTN_GAP
	end

	-- Hide all first
	r.BtnHelmet:Hide()
	r.BtnPlus:Hide()

	local columns = View.GlanceColumns(model)
	r.__sfWants = columns
	r.__sfDisplayName = model.displayName or ""
	if columns.points then
		r.Points:Show()
		r.Points:SetText(FormatPointAmount(model.points or 0))
	else
		r.Points:Hide()
		r.Points:SetText("")
	end

	if columns.attendance then
		r.Attendance:Show()
		r.Attendance:SetText(model.attendanceText or "—")
		r.Preparedness:Show()
		r.Preparedness:SetText(model.preparednessText or "—")
		r.Bis:Show()
		r.Bis:SetText(model.bisText or "—")
		r.Readiness:Show()
		if View.ShowsReadinessIcon(model.readinessState) then
			r.Readiness.Icon:SetTexture(READY_TEXTURE.not_ready)
			r.Readiness.Icon:Show()
			r.Readiness:EnableMouse(true)
			r.Readiness:SetScript("OnEnter", function(frame)
				local tooltip = model.readinessTooltip
				if tooltip and tooltip ~= "" and GameTooltip then
					GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
					GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
					GameTooltip:Show()
				end
			end)
			r.Readiness:SetScript("OnLeave", function()
				if GameTooltip then
					GameTooltip:Hide()
				end
			end)
		else
			r.Readiness.Icon:SetTexture(nil)
			r.Readiness.Icon:Hide()
			r.Readiness:EnableMouse(false)
			r.Readiness:SetScript("OnEnter", nil)
			r.Readiness:SetScript("OnLeave", nil)
		end
	else
		r.Attendance:Hide()
		r.Attendance:SetText("")
		r.Preparedness:Hide()
		r.Preparedness:SetText("")
		r.Bis:Hide()
		r.Bis:SetText("")
		r.Readiness:Hide()
		r.Readiness:SetScript("OnEnter", nil)
		r.Readiness:SetScript("OnLeave", nil)
	end

	-- Buttons depending on row type/admin
	if model.type == "RAID_NONMEMBER" then
		if model.canAdmin then
			r.BtnPlus:Show()
			r.BtnPlus:Enable()
			Place(r.BtnPlus)
		end
	else
		-- For PROFILE_MEMBER rows: helmet is visible and enabled for everyone (opens equipment window)
		r.BtnHelmet:Show()
		r.BtnHelmet:Enable()
		Place(r.BtnHelmet)
	end

	-- Calculate the real width of the visible button stack
	local buttonsWidth = 0
	if x > 0 then
		buttonsWidth = x - BTN_GAP -- remove the trailing gap
	end

	-- Make the actions frame only as wide as needed for the buttons
	actions:SetWidth(math.max(1, buttonsWidth))
	r.__sfHasAction = buttonsWidth > 0
end

function View:_BindRowActions(r, model)
    -- Clear old scripts
    r.BtnHelmet:SetScript("OnClick", nil)
    r.BtnPlus:SetScript("OnClick", nil)

    -- Profile member actions
    if model.type == "PROFILE_MEMBER" then
        -- Helmet button (visible for everyone)
        r.BtnHelmet:SetScript("OnClick", function()
            if self.controller and self.controller.OnEquipmentClicked then
                self.controller:OnEquipmentClicked(model)
            end
            if SF.Debug then
                SF.Debug:Info("LH_ROSTER_VIEW", "EquipmentClicked: %s", tostring(model.memberId))
            end
        end)
    end

    -- Raid non-member action
    if model.type == "RAID_NONMEMBER" and model.canAdmin then
        r.BtnPlus:SetScript("OnClick", function()
            if self.controller and self.controller.OnAddRaidNonMember then
                self.controller:OnAddRaidNonMember(model)
            end
            if SF.Debug then
                SF.Debug:Info("LH_ROSTER_VIEW", "AddRaidNonMember: %s", tostring(model.memberId))
            end
        end)
    end
end

function View:_EnsureHeader()
    if self.header then
        return self.header
    end

    local h = CreateFrame("Frame", nil, self.child)
    h:SetHeight(HEADER_HEIGHT)

    local function MakeLabel(justify)
        local text = h:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        text:SetJustifyH(justify or "RIGHT")
        text:SetTextColor(0.8, 0.8, 0.8)
        return text
    end

    h.Name = MakeLabel("LEFT")
    h.Points = MakeLabel("RIGHT")
    h.Attendance = MakeLabel("RIGHT")
    h.Preparedness = MakeLabel("RIGHT")
    h.Bis = MakeLabel("RIGHT")
    h.Name:SetText("Raider")
    h.Name:SetWordWrap(false)
    if h.Name.SetMaxLines then
        h.Name:SetMaxLines(1)
    end
    h.Attendance:SetText("Att.")
    h.Preparedness:SetText("Prep.")
    h.Bis:SetText("BiS")

    if self.fontPath and self.fontSize then
        h.Name:SetFont(self.fontPath, self.fontSize, "")
        h.Points:SetFont(self.fontPath, self.fontSize, "")
        h.Attendance:SetFont(self.fontPath, self.fontSize, "")
        h.Preparedness:SetFont(self.fontPath, self.fontSize, "")
        h.Bis:SetFont(self.fontPath, self.fontSize, "")
    end

    self.header = h
    return h
end

function View:_TextMeasure()
    return function(text)
        local measured = self:_MeasureName(text)
        if type(measured) == "number" and measured > 0 then
            return measured
        end
        return FALLBACK_CHAR_WIDTH * string.len(tostring(text or ""))
    end
end

function View:_MeasureName(text)
    local fs = self._measure
    if not fs or not fs.SetText or not fs.GetStringWidth then
        return nil
    end
    fs:SetText(text or "")
    local width = fs:GetStringWidth()
    if type(width) ~= "number" or width <= 0 then
        return nil
    end
    return width
end

function View:_NameMinWidth()
    return View.MinimumNameWidth(self:_TextMeasure())
end

function View:_AvailableWidth()
    if self.scroll and self.scroll.GetWidth then
        local width = self.scroll:GetWidth()
        if type(width) == "number" and width > 1 then
            return width
        end
    end
    if self.child and self.child.GetWidth then
        local width = self.child:GetWidth()
        if type(width) == "number" and width > 1 then
            return width
        end
    end
    return nil
end

function View:_EffectiveColumns(wants)
    local decision = self._layoutDecision or {}
    local function on(key)
        return wants[key] and decision[key] and true or false
    end
    return {
        points = on("points"),
        attendance = on("attendance"),
        preparedness = on("preparedness"),
        bis = on("bis"),
        readiness = on("readiness"),
    }
end

function View:_ApplyRowPresentation(r)
    local wants = r.__sfWants or {}
    local shown = self:_EffectiveColumns(wants)
    local hasAction = r.__sfHasAction and true or false
    local widgets = {
        { key = "readiness", widget = r.Readiness, width = READY_WIDTH },
        { key = "bis", widget = r.Bis, width = BIS_WIDTH },
        { key = "preparedness", widget = r.Preparedness, width = PREP_WIDTH },
        { key = "attendance", widget = r.Attendance, width = ATTENDANCE_WIDTH },
        { key = "points", widget = r.Points, width = POINTS_WIDTH },
    }
    for i = 1, #widgets do
        local entry = widgets[i]
        local widget = entry.widget
        if widget then
            if shown[entry.key] then
                widget:Show()
                widget:ClearAllPoints()
                if entry.key ~= "readiness" and widget.SetWidth then
                    widget:SetWidth(entry.width)
                end
                local inset = View.ColumnRightInset(shown, hasAction, entry.key)
                if inset then
                    widget:SetPoint("RIGHT", r, "RIGHT", -inset, 0)
                end
            else
                widget:Hide()
            end
        end
    end

    local available = self._lastLayoutWidth or 0
    local nameWidth = available - View.FixedWidthExcludingName(shown, hasAction)
    local nameMin = self:_NameMinWidth()
    if nameWidth < nameMin then
        nameWidth = nameMin
    end
    local fullName = r.__sfDisplayName or ""
    local shownText = View.TruncateToWidth(fullName, nameWidth, self:_TextMeasure())
    if not r.Name.GetText or r.Name:GetText() ~= shownText then
        r.Name:SetText(shownText)
    end
    r.Name:ClearAllPoints()
    r.Name:SetPoint("LEFT", r.Icon, "RIGHT", NAME_ICON_GAP, 0)
    r.Name:SetPoint("RIGHT", r, "RIGHT", -View.NameRightInset(shown, hasAction), 0)
    r.__sfNameWidth = nameWidth
end

function View:_HasPresentableRows()
    for i = 1, #self.rows do
        local row = self.rows[i]
        if row.IsShown and row:IsShown() and row.__sfWants then
            return true
        end
    end
    return false
end

-- Recompute column visibility and name truncation from the current width.
-- Same-width calls are ignored. Nested size events cannot re-enter, and a
-- real width change discovered while applying is handled at most once more.
function View:ApplyResponsiveLayout(force, depth)
    depth = depth or 0
    if depth > 1 then
        return
    end
    if self._applyingLayout then
        self._layoutDirty = true
        return
    end

    local width = self:_AvailableWidth()
    if not width then
        if not force then
            return
        end
        width = 10000
    end
    if not self._headerRequested and not self:_HasPresentableRows() then
        self._lastLayoutWidth = width
        return
    end
    if not force and self._lastLayoutWidth and math.abs(self._lastLayoutWidth - width) < 0.5 then
        return
    end

    self._applyingLayout = true
    self._lastLayoutWidth = width
    self._layoutApplyCount = (self._layoutApplyCount or 0) + 1

    local request = self._layoutRequest or {
        points = false,
        attendance = true,
        preparedness = true,
        bis = true,
        readiness = true,
        hasAction = true,
    }
    self._layoutDecision = View.ResolveResponsiveLayout(width, request, self:_NameMinWidth())

    if self._headerRequested then
        self:_LayoutHeader(self._pointName)
    end
    for i = 1, #self.rows do
        local row = self.rows[i]
        if row.IsShown and row:IsShown() and row.__sfWants then
            self:_ApplyRowPresentation(row)
        end
    end

    self._applyingLayout = false
    if self._layoutDirty then
        self._layoutDirty = false
        local again = self:_AvailableWidth()
        if again and math.abs(again - width) >= 0.5 then
            self:ApplyResponsiveLayout(false, depth + 1)
        end
    end
end

function View:_RefreshMinimumWidth()
    local minWidth = View.ResolveMinimumWindowWidth(self:_TextMeasure(), true)
    if LH.Window and LH.Window.RefreshMinimumWidth then
        LH.Window:RefreshMinimumWidth(minWidth)
        return
    end
    if LH.Constants and type(minWidth) == "number" and minWidth > 0 then
        LH.Constants.MIN_WIDTH = minWidth
    end
end

function View:_LayoutHeader(pointName)
    local h = self:_EnsureHeader()
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)

    local decision = self._layoutDecision or {}
    local shown = {
        points = decision.points and true or false,
        attendance = decision.attendance and true or false,
        preparedness = decision.preparedness and true or false,
        bis = decision.bis and true or false,
        readiness = decision.readiness and true or false,
    }
    local hasAction = true

    local function place(widget, key, width)
        widget:ClearAllPoints()
        widget:SetWidth(width)
        if shown[key] then
            widget:Show()
            local inset = View.ColumnRightInset(shown, hasAction, key)
            if inset then
                widget:SetPoint("RIGHT", h, "RIGHT", -inset, 0)
            end
        else
            widget:Hide()
        end
    end

    h.Bis:SetText("BiS")
    h.Preparedness:SetText("Prep.")
    h.Attendance:SetText("Att.")
    place(h.Bis, "bis", BIS_WIDTH)
    place(h.Preparedness, "preparedness", PREP_WIDTH)
    place(h.Attendance, "attendance", ATTENDANCE_WIDTH)
    if shown.points then
        h.Points:SetText(pointName or self._pointName or "Points")
    else
        h.Points:SetText("")
    end
    place(h.Points, "points", POINTS_WIDTH)

    h.Name:ClearAllPoints()
    h.Name:SetPoint("LEFT", h, "LEFT", ROW_LEFT_PAD + ICON_SIZE + NAME_ICON_GAP, 0)
    h.Name:SetPoint("RIGHT", h, "RIGHT", -View.NameRightInset(shown, hasAction), 0)
    h:Show()
    return h
end

function View:Render(models, meta)
    meta = meta or {}

    if SF.Debug then
        SF.Debug:Verbose("LH_ROSTER_VIEW", "Render: Rendering %d rows", models and #models or 0)
    end

    -- Empty state
    if not models or #models == 0 then
        if self.header then
            self.header:Hide()
        end
        for i = 1, #self.rows do
            self.rows[i]:Hide()
        end

        if meta.emptyText and meta.emptyText ~= "" then
            self.emptyText:SetText(meta.emptyText)
            self.emptyText:Show()
            self.child:SetHeight(80)
        else
            self.emptyText:SetText("")
            self.emptyText:Hide()
            self.child:SetHeight(1)
        end
        self._headerRequested = false
        if LH.Window and LH.Window.RequestScrollInsetsUpdate then
            LH.Window:RequestScrollInsetsUpdate()
        end
        return
    end

    self.emptyText:Hide()

    local showPoints = false
    local pointName = "Points"
    for i = 1, #models do
        local model = models[i]
        if model.type == "PROFILE_MEMBER" and model.showPoints then
            showPoints = true
            if type(model.pointName) == "string" and model.pointName ~= "" then
                pointName = model.pointName
            end
        end
    end
    self._pointName = pointName
    self._layoutRequest = {
        points = showPoints,
        attendance = true,
        preparedness = true,
        bis = true,
        readiness = true,
        hasAction = true,
    }
    self._headerRequested = true

    local y = HEADER_HEIGHT + 2
    for i = 1, #models do
        local model = models[i]
        local r = self:_EnsureRow(i)

        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, -y)

        -- Icon: spec icon when available (pass memberId for player detection when not in raid), else class
        local specIcon = TryGetSpecIcon(model.unit, model.memberId)
        local classIcon = GetClassIcon(model.class)
        local icon = specIcon or classIcon
        r.Icon:SetTexture(icon)
        if SF.Debug then
            local path = specIcon and "spec" or ((classIcon ~= "Interface\\Icons\\INV_Misc_QuestionMark") and "class" or "fallback")
            SF.Debug:Verbose("LH_ICON", "Render row icon (member=%s path=%s classRaw=%s unit=%s guid=%s)",
                tostring(model.memberId), path, tostring(model.class), tostring(model.unit), tostring(model.guid))
            if path == "fallback" then
                SF.Debug:Warn("LH_ICON", "Missing/invalid class metadata for icon fallback (member=%s classRaw=%s)",
                    tostring(model.memberId), tostring(model.class))
            end
        end

        -- Name
        r.Name:SetText(model.displayName or "")
        local cr, cg, cb = GetClassColor(model.class)
        r.Name:SetTextColor(cr, cg, cb)

        -- Buttons/points
        self:_LayoutButtons(r, model)
        self:_BindRowActions(r, model)

        r:Show()
        y = y + ROW_HEIGHT + ROW_SPACING
    end

    for i = #models + 1, #self.rows do
        self.rows[i]:Hide()
    end

    if y > 0 then y = y - ROW_SPACING end
    self.child:SetHeight(math.max(1, y))
    self:ApplyResponsiveLayout(true)
    if LH.Window and LH.Window.RequestScrollInsetsUpdate then
        LH.Window:RequestScrollInsetsUpdate()
    end
end

do
    local minWidth = View.ResolveMinimumWindowWidth(nil, true)
    if LH.Constants and type(minWidth) == "number" and minWidth > 0 then
        LH.Constants.MIN_WIDTH = minWidth
    end
end
