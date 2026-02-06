-- modules/UI/LootHelper/RosterView.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.RosterView = LH.RosterView or {}
local View = LH.RosterView
View.__index = View

local ROW_HEIGHT = 24
local ROW_SPACING = 2
local ICON_SIZE = 20
local BTN_SIZE = 20
local BTN_GAP = 3
local POINTS_WIDTH = 18

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
    className = className and string.upper(className) or "UNKNOWN"
    if SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].textureFile then
        return SF.WOW_CLASSES[className].textureFile
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function GetClassColor(className)
	className = className and string.upper(className) or "UNKNOWN"
	local c = SF.WOW_CLASSES and SF.WOW_CLASSES[className] and SF.WOW_CLASSES[className].colorCode
	if c then
		return c.r or 1, c.g or 1, c.b or 1
	end
	return 1, 1, 1
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

    -- Points
    local pts = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    pts:SetJustifyH("RIGHT")
    pts:SetWidth(POINTS_WIDTH)
    r.Points = pts

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

	-- Points: only for profile members
	if model.type == "PROFILE_MEMBER" then
		r.Points:Show()
		r.Points:SetText(tostring(model.points or 0))
	else
		r.Points:Hide()
		r.Points:SetText("")
	end

	-- Buttons depending on row type/admin
	if model.type == "RAID_NONMEMBER" then
		if model.canAdmin then
			r.BtnPlus:Show()
			r.BtnPlus:Enable()
			Place(r.BtnPlus)
		end
	else
		-- For PROFILE_MEMBER rows: helmet is visible for everyone
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

	-- Place points relative to either the button stack or the row edge
	r.Points:ClearAllPoints()
	if r.Points:IsShown() then
		if buttonsWidth > 0 then
			r.Points:SetPoint("RIGHT", actions, "LEFT", -6, 0)
		else
			r.Points:SetPoint("RIGHT", r, "RIGHT", -4, 0)
		end
	end

	-- IMPORTANT: Anchor the name to the actual right-side content (not the container)
	r.Name:ClearAllPoints()
	r.Name:SetPoint("LEFT", r.Icon, "RIGHT", 8, 0)

	if r.Points:IsShown() then
		r.Name:SetPoint("RIGHT", r.Points, "LEFT", -8, 0)
	elseif buttonsWidth > 0 then
		r.Name:SetPoint("RIGHT", actions, "LEFT", -8, 0)
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
                if model.member.IncrementPoints then
                    pcall(function() model.member:IncrementPoints() end)
                end
                -- DATA_CHANGED event is automatically fired via Events.lua hook
                if SF.Debug then
                    SF.Debug:Info("LH_ROSTER_VIEW", "IncrementPoints: %s", tostring(model.memberId))
                end
            end)
            
            r.BtnDown:SetScript("OnClick", function()
                if model.member.DecrementPoints then
                    pcall(function() model.member:DecrementPoints() end)
                end
                -- DATA_CHANGED event is automatically fired via Events.lua hook
                if SF.Debug then
                    SF.Debug:Info("LH_ROSTER_VIEW", "DecrementPoints: %s", tostring(model.memberId))
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

function View:Render(models, meta)
    meta = meta or {}

    if SF.Debug then
        SF.Debug:Verbose("LH_ROSTER_VIEW", "Render: Rendering %d rows", models and #models or 0)
    end

    -- Empty state
    if not models or #models == 0 then
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

    local y = 0
    for i = 1, #models do
        local model = models[i]
        local r = self:_EnsureRow(i)

        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -y)
        r:SetPoint("TOPRIGHT", self.child, "TOPRIGHT", 0, -y)

        -- Icon: spec icon when available (pass memberId for player detection when not in raid), else class
        local icon = TryGetSpecIcon(model.unit, model.memberId) or GetClassIcon(model.class)
        r.Icon:SetTexture(icon)

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