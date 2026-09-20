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
local MANUAL_POINT_STEP = 0.5
local MANUAL_ATTENDANCE_STEP = 1
local READY_TEXTURE = {
    not_ready = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    unknown = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}

-- Ready players show no icon, but the column still occupies READY_WIDTH so
-- Att./BiS/Points stay aligned with not-ready and unknown rows.
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

-- Cropping presets you can tweak quickly:
local CROP_ICON   = 0.07  -- great for Interface\Icons\
local CROP_ARROW  = 0.18  -- zooms in UI scrollbar arrows
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

    -- Keep child width in sync so TOPRIGHT anchors work
    if self.scroll then
        self.scroll:HookScript("OnSizeChanged", function()
            local w = self.scroll:GetWidth() or 1
            self.child:SetWidth(math.max(1, w))
        end)
    end

    return self
end

function View:ApplyStyle(fontPath, fontSize)
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
end

function View:_EnsureRow(i)
    if self.rows[i] then return self.rows[i] end

    local r = CreateFrame("Frame", nil, self.child)
    r:SetHeight(ROW_HEIGHT)

    -- Icon
    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.Icon = icon

    -- Actions container (right side)
    local actions = CreateFrame("Frame", nil, r)
    actions:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    actions:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 0)
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

    -- -- Buttons 
    -- r.BtnUp = CreateSmallIconButton(actions, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up", BTN_SIZE)
    -- r.BtnDown = CreateSmallIconButton(actions, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up", BTN_SIZE)
    -- -- r.BtnHelmet = CreateSmallIconButton(actions, "Interface\\Icons\\INV_HELMET_03", BTN_SIZE)
    -- r.BtnHelmet = CreateSmallIconButton(actions, "Interface\\PaperDollInfoFrame\\UI-EquipmentManager-Toggle", BTN_SIZE)
    -- r.BtnPlus = CreateSmallIconButton(actions, "Interface\\Buttons\\UI-PlusButton-Up", BTN_SIZE)

    -- Buttons
    r.BtnUp = CreateSmallIconButton(actions,
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        BTN_SIZE,
        { crop = CROP_ARROW }
    )

    r.BtnDown = CreateSmallIconButton(actions,
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        BTN_SIZE,
        { crop = CROP_ARROW }
    )

    -- Helmet / equipment toggle: this texture tends to look best without heavy crop.
    -- Try NO_CROP first; if it looks too small, switch to { crop = 0.10 } or { crop = CROP_ICON }.
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
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", actions, "LEFT", -8, 0)  -- BUG: Should this be anchored to points?
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
        r.Bis:SetFont(self.fontPath, self.fontSize, "")
    end

    self.rows[i] = r
    return r
end

-- function View:_LayoutButtons(r, model)
--     local actions = r.Actions
--     local x = 0

--     -- Helper to place visible buttons from right to left
--     local function Place(btn)
--         btn:ClearAllPoints()
--         btn:SetPoint("RIGHT", actions, "RIGHT", -x, 0)
--         x = x + BTN_SIZE + BTN_GAP
--     end

--     -- Hide all first
--     r.BtnUp:Hide()
--     r.BtnDown:Hide()
--     r.BtnHelmet:Hide()
--     r.BtnPlus:Hide()

--     -- Default: points visible only for profile members
--     if model.type == "PROFILE_MEMBER" then
--         r.Points:Show()
--         r.Points:SetText(tostring(model.points or 0))
--     else
--         r.Points:Hide()
--         r.Points:SetText("")
--     end

--     -- Buttons depending on row type/admin
--     if model.type == "RAID_NONMEMBER" then
--         if model.canAdmin then
--             r.BtnPlus:Show()
--         end
--     else
--         if model.canAdmin then
--             r.BtnHelmet:Show()
--             Place(r.BtnHelmet)

--             r.BtnDown:Show()
--             Place(r.BtnDown)

--             r.BtnUp:Show()
--             Place(r.BtnUp)
--         end
--     end

--     -- Place points to the left of the button stack
--     r.Points:ClearAllPoints()
--     if r.Points:IsShown() then
--         local rightPad = (x > 0) and (x + 6) or 0
--         r.Points:SetPoint("RIGHT", actions, "RIGHT", -rightPad, 0)
--     end
-- end

function View:_LayoutButtons(r, model)
	local actions = r.Actions
	local x = 0

	local function Place(btn)
		btn:ClearAllPoints()
		btn:SetPoint("RIGHT", actions, "RIGHT", -x, 0)
		x = x + BTN_SIZE + BTN_GAP
	end

	-- Hide all first
	r.BtnUp:Hide()
	r.BtnDown:Hide()
	r.BtnHelmet:Hide()
	r.BtnPlus:Hide()

	local columns = View.GlanceColumns(model)
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
		r.Readiness.Icon:SetTexture(READY_TEXTURE[model.readinessState])
		r.Readiness:Show()
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

		-- Up/Down buttons are admin-only (hide for non-admins)
		if model.canAdmin then
			r.BtnDown:Show()
			r.BtnDown:Enable()
			Place(r.BtnDown)

			r.BtnUp:Show()
			r.BtnUp:Enable()
			Place(r.BtnUp)
		end
	end

	-- Calculate the real width of the visible button stack
	local buttonsWidth = 0
	if x > 0 then
		buttonsWidth = x - BTN_GAP -- remove the trailing gap
	end

	-- Make the actions frame only as wide as needed for the buttons
	actions:SetWidth(math.max(1, buttonsWidth))

	local rightAnchor = r
	local rightOffset = -4
	if buttonsWidth > 0 then
		rightAnchor = actions
		rightOffset = -6
	end

	local function PlaceColumn(widget, shown, width)
		widget:ClearAllPoints()
		if shown then
			widget:SetPoint("RIGHT", rightAnchor, "LEFT", rightOffset, 0)
			rightAnchor = widget
			rightOffset = -COLUMN_GAP
			return width
		end
		return 0
	end

	PlaceColumn(r.Readiness, columns.readiness, READY_WIDTH)
	PlaceColumn(r.Bis, columns.bis, BIS_WIDTH)
	PlaceColumn(r.Preparedness, columns.preparedness, PREP_WIDTH)
	PlaceColumn(r.Attendance, columns.attendance, ATTENDANCE_WIDTH)
	PlaceColumn(r.Points, columns.points, POINTS_WIDTH)

	r.Name:ClearAllPoints()
	r.Name:SetPoint("LEFT", r.Icon, "RIGHT", 8, 0)
	if rightAnchor ~= r or buttonsWidth > 0 then
		r.Name:SetPoint("RIGHT", rightAnchor, "LEFT", -COLUMN_GAP, 0)
	else
		r.Name:SetPoint("RIGHT", r, "RIGHT", -4, 0)
	end
end

function View:_BindRowActions(r, model)
    -- Clear old scripts
    r.BtnUp:SetScript("OnClick", nil)
    r.BtnDown:SetScript("OnClick", nil)
    r.BtnHelmet:SetScript("OnClick", nil)
    r.BtnPlus:SetScript("OnClick", nil)

    -- Profile member actions
    if model.type == "PROFILE_MEMBER" then
        -- Up/Down buttons (admin only)
        if model.canAdmin and model.member then
            r.BtnUp:SetScript("OnClick", function()
                if model.rewardPot then
                    if model.member.IncrementAttendance then
                        pcall(function()
                            model.member:IncrementAttendance({
                                amount = MANUAL_ATTENDANCE_STEP,
                                reason = "MANUAL",
                                profile = model.profile,
                            })
                        end)
                    end
                elseif model.member.IncrementPoints then
                    pcall(function()
                        model.member:IncrementPoints({
                            amount = MANUAL_POINT_STEP,
                            reason = "MANUAL",
                            profile = model.profile,
                        })
                    end)
                end
                -- DATA_CHANGED event is automatically fired via Events.lua hook
                if SF.Debug then
                    SF.Debug:Info("LH_ROSTER_VIEW", "%s: %s", model.rewardPot and "IncrementAttendance" or "IncrementPoints", tostring(model.memberId))
                end
            end)
            
            r.BtnDown:SetScript("OnClick", function()
                if model.rewardPot then
                    if model.member.DecrementAttendance then
                        pcall(function()
                            model.member:DecrementAttendance({
                                amount = MANUAL_ATTENDANCE_STEP,
                                reason = "MANUAL",
                                profile = model.profile,
                            })
                        end)
                    end
                elseif model.member.DecrementPoints then
                    pcall(function()
                        model.member:DecrementPoints({
                            amount = MANUAL_POINT_STEP,
                            reason = "MANUAL",
                            profile = model.profile,
                        })
                    end)
                end
                -- DATA_CHANGED event is automatically fired via Events.lua hook
                if SF.Debug then
                    SF.Debug:Info("LH_ROSTER_VIEW", "%s: %s", model.rewardPot and "DecrementAttendance" or "DecrementPoints", tostring(model.memberId))
                end
            end)
        end
        
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

function View:_LayoutHeader(showPoints, pointName, hasAdmin)
    local h = self:_EnsureHeader()
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, 0)
    h:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, 0)

    local actionWidth = BTN_SIZE
    if hasAdmin then
        actionWidth = (3 * BTN_SIZE) + (2 * BTN_GAP)
    end
    local rightOffset = -(actionWidth + 4)
    local rightAnchor = h

    h.Bis:ClearAllPoints()
    h.Bis:SetWidth(BIS_WIDTH)
    h.Bis:SetPoint("RIGHT", rightAnchor, "RIGHT", rightOffset - READY_WIDTH - COLUMN_GAP, 0)

    h.Preparedness:ClearAllPoints()
    h.Preparedness:SetWidth(PREP_WIDTH)
    h.Preparedness:SetPoint("RIGHT", h.Bis, "LEFT", -COLUMN_GAP, 0)

    h.Attendance:ClearAllPoints()
    h.Attendance:SetWidth(ATTENDANCE_WIDTH)
    h.Attendance:SetPoint("RIGHT", h.Preparedness, "LEFT", -COLUMN_GAP, 0)

    h.Points:ClearAllPoints()
    h.Points:SetWidth(POINTS_WIDTH)
    if showPoints then
        h.Points:SetText(pointName or "Points")
        h.Points:Show()
        h.Points:SetPoint("RIGHT", h.Attendance, "LEFT", -COLUMN_GAP, 0)
    else
        h.Points:SetText("")
        h.Points:Hide()
    end

    h.Name:ClearAllPoints()
    h.Name:SetPoint("LEFT", h, "LEFT", 4 + ICON_SIZE + 8, 0)
    if showPoints then
        h.Name:SetPoint("RIGHT", h.Points, "LEFT", -COLUMN_GAP, 0)
    else
        h.Name:SetPoint("RIGHT", h.Attendance, "LEFT", -COLUMN_GAP, 0)
    end
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
        if LH.Window and LH.Window.RequestScrollInsetsUpdate then
            LH.Window:RequestScrollInsetsUpdate()
        end
        return
    end

    self.emptyText:Hide()

    local showPoints = false
    local pointName = "Points"
    local hasAdmin = false
    for i = 1, #models do
        local model = models[i]
        if model.type == "PROFILE_MEMBER" and model.showPoints then
            showPoints = true
            if type(model.pointName) == "string" and model.pointName ~= "" then
                pointName = model.pointName
            end
        end
        if model.canAdmin then
            hasAdmin = true
        end
    end
    self:_LayoutHeader(showPoints, pointName, hasAdmin)

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
    if LH.Window and LH.Window.RequestScrollInsetsUpdate then
        LH.Window:RequestScrollInsetsUpdate()
    end
end
