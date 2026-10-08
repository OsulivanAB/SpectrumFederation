-- Production-Lua tests for AddConsumableRequestedList flowing layout (#362).
-- Run from the repository root:
--   lua5.1 tests/lua/consumable_requested_list_layout_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. message .. "\n")
end

local function assertTrue(cond, message)
    if cond then
        pass(message)
    else
        fail(message)
    end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

GameTooltip = {
    Hide = function() end,
    SetOwner = function() end,
    SetText = function() end,
    AddLine = function() end,
    Show = function() end,
}

local function fireEvent(region, event, ...)
    local script = region.scripts and region.scripts[event]
    if script then
        script(region, ...)
    end
    for _, hook in ipairs((region.hooks and region.hooks[event]) or {}) do
        hook(region, ...)
    end
end

local function makeRegion(kind, name, parent, template)
    local region = {
        kind = kind,
        name = name,
        parent = parent,
        shown = true,
        height = 0,
        width = 0,
        alpha = 1,
        points = {},
        scripts = {},
        hooks = {},
        children = {},
        text = "",
        enabled = true,
        focused = false,
        numeric = false,
    }
    if parent and parent.children then
        parent.children[#parent.children + 1] = region
    end

    function region:GetObjectType()
        return self.kind or "Frame"
    end

    function region:SetPoint(point, relativeTo, relativePoint, x, y)
        if type(relativeTo) == "number" then
            x, y = relativeTo, relativePoint
            relativeTo, relativePoint = nil, point
        elseif type(relativePoint) == "number" then
            x, y = relativePoint, x
            relativePoint = point
        end
        table.insert(self.points, {
            point = point,
            relativeTo = relativeTo,
            relativePoint = relativePoint,
            x = x or 0,
            y = y or 0,
        })
    end

    function region:ClearAllPoints()
        self.points = {}
    end

    function region:SetAllPoints(target)
        self.allPoints = target or self.parent
        if self.allPoints then
            self.width = self.allPoints.width or self.width
            self.height = self.allPoints.height or self.height
        end
    end

    function region:SetHeight(height)
        height = tonumber(height) or 0
        local oldHeight = self.height
        self.height = height
        if oldHeight ~= height then
            fireEvent(self, "OnSizeChanged", self.width, height)
        end
    end

    function region:GetHeight()
        return self.height
    end

    function region:SetWidth(width)
        width = tonumber(width) or 0
        local oldWidth = self.width
        self.width = width
        if oldWidth ~= width then
            fireEvent(self, "OnSizeChanged", width, self.height)
        end
    end

    function region:GetWidth()
        return self.width
    end

    function region:SetSize(width, height)
        self:SetWidth(width)
        self:SetHeight(height)
    end

    function region:Show()
        self.shown = true
    end

    function region:Hide()
        self.shown = false
    end

    function region:IsShown()
        return self.shown and true or false
    end

    function region:SetShown(shown)
        self.shown = shown and true or false
    end

    function region:SetAlpha(alpha)
        self.alpha = alpha
    end

    function region:SetScript(event, fn)
        self.scripts[event] = fn
    end

    function region:HookScript(event, fn)
        self.hooks[event] = self.hooks[event] or {}
        table.insert(self.hooks[event], fn)
    end

    function region:EnableMouse()
    end

    function region:SetHitRectInsets()
    end

    function region:SetEnabled(enabled)
        self.enabled = enabled and true or false
    end

    function region:IsEnabled()
        return self.enabled
    end

    function region:Enable()
        self.enabled = true
    end

    function region:Disable()
        self.enabled = false
    end

    function region:SetText(text)
        self.text = tostring(text or "")
    end

    function region:GetText()
        return self.text
    end

    function region:SetTextColor()
    end

    function region:SetJustifyH()
    end

    function region:SetJustifyV()
    end

    function region:SetWordWrap()
    end

    function region:SetNonSpaceWrap()
    end

    function region:SetMaxLines()
    end

    function region:SetAutoFocus()
    end

    function region:SetNumeric(numeric)
        self.numeric = numeric and true or false
    end

    function region:SetMaxLetters()
    end

    function region:SetHighlightColor()
    end

    function region:SetCursorPosition()
    end

    function region:HasFocus()
        return self.focused and true or false
    end

    function region:ClearFocus()
        self.focused = false
        fireEvent(self, "OnEditFocusLost")
    end

    function region:GetStringWidth()
        return math.max(1, #(self.text or "") * 7)
    end

    function region:GetStringHeight()
        return 12
    end

    function region:SetColorTexture()
    end

    function region:SetTexture()
    end

    function region:SetAtlas()
    end

    function region:SetTexCoord()
    end

    function region:SetVertexColor()
    end

    function region:SetBlendMode()
    end

    function region:SetVerticalScroll()
    end

    function region:SetScrollChild(child)
        self.scrollChild = child
    end

    function region:CreateTexture()
        return makeRegion("Texture", nil, self)
    end

    function region:CreateFontString()
        return makeRegion("FontString", nil, self)
    end

    function region:CreateFrame()
        return makeRegion("Frame", nil, self)
    end

    if template == "UIPanelScrollFrameTemplate" then
        region.ScrollBar = makeRegion("Slider", nil, region)
        region.ScrollBar:SetWidth(20)
        region.ScrollBar.shown = false
    end

    return region
end

function CreateFrame(frameType, name, parent, template)
    return makeRegion(frameType or "Frame", name, parent, template)
end

local SF = {}
assert(loadfile("SpectrumFederation/modules/UI/Settings/Style.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Widgets/Section.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/PageBuilder.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Control/Controls.lua"))("SpectrumFederation", SF)

local Controls = SF.SettingsUI.Controls

local function findScroll(section)
    local function walk(node)
        if not node then
            return nil
        end
        if node.kind == "ScrollFrame" then
            return node
        end
        for i = 1, #(node.children or {}) do
            local found = walk(node.children[i])
            if found then
                return found
            end
        end
        return nil
    end
    return walk(section)
end

local function findRequestedRows(content)
    local found = {}
    for _, child in ipairs(content.children or {}) do
        if child.Text and child.GoalLabel and child.GoalEdit and child.Remove then
            found[#found + 1] = child
        end
    end
    return found
end

local function pointAnchor(region, pointName)
    for _, point in ipairs(region.points or {}) do
        if point.point == pointName then
            return point
        end
    end
    return nil
end

local function leftAnchor(region)
    return pointAnchor(region, "LEFT")
end

local function rightAnchor(region)
    return pointAnchor(region, "RIGHT")
end

local function buildList(items, scrollWidth)
    local panel = CreateFrame("Frame")
    panel:SetSize(700, 400)
    panel.__sfPageLayout = { disablePageScroll = true }
    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    local section = pageBuilder:AddSection("Consumables")
    section.Content:SetWidth(640)

    local getItemsCalls = 0
    Controls:AddConsumableRequestedList(section, {
        label = "Requested Items",
        height = 180,
        maxHeight = 180,
        getItems = function()
            getItemsCalls = getItemsCalls + 1
            if getItemsCalls > 80 then
                error("AddConsumableRequestedList Refresh exceeded 80 getItems calls")
            end
            return items
        end,
        onRemove = function() end,
        onGoalCommit = function() end,
    })

    local scroll = findScroll(section)
    assertTrue(scroll ~= nil, "requested list creates a scroll frame")
    if scroll then
        -- InitRow places the control after the label column; size the scroll to the
        -- usable control width that Settings rows expose at runtime.
        scroll:SetSize(scrollWidth or 380, 180)
    end
    pageBuilder:Finalize()
    return section, scroll, function()
        return getItemsCalls
    end, pageBuilder, function()
        return findRequestedRows(scroll and scroll.scrollChild)
    end
end

-- Pure helpers: reserved width and clamping.
do
    local maxWide, reserved = Controls.ConsumableRequestedTextMaxWidth(400)
    assertTrue(reserved > 0, "reserved controls width is positive")
    assertEq(maxWide, 400 - reserved, "wide viewport yields available minus reserved")

    local shortName = "Flask (123)"
    local shortWidth = Controls.ConsumableRequestedTextWidth(400, #shortName * 7)
    assertEq(shortWidth, (#shortName * 7) + 4, "short names use natural string width")

    local longName = "Wonderfully Long Consumable Item Name (345678)"
    local longNatural = (#longName * 7) + 4
    local longWidth = Controls.ConsumableRequestedTextWidth(160, #longName * 7)
    local longMax = Controls.ConsumableRequestedTextMaxWidth(160)
    assertTrue(longNatural > longMax, "fixture long name exceeds a narrow viewport")
    assertEq(longWidth, longMax, "long names clamp to textMaxWidth")

    local order = Controls.CONSUMABLE_REQUESTED_CONTROL_ORDER
    assertEq(table.concat(order, ","), "text,goalLabel,goalEdit,remove",
        "control order is Item Name → Goal → Input → Remove")

    local effectiveGap, visualGap, inputInset = Controls.ConsumableRequestedGoalEditGap()
    assertEq(visualGap, 8, "Goal→input visual gap targets ~8px clear separation")
    assertTrue(inputInset > 0, "Goal→input gap accounts for InputBoxTemplate left inset")
    assertEq(effectiveGap, visualGap + inputInset, "effective Goal→input gap is visual plus inset")
end

-- Runtime order and flowing widths for short vs long names.
do
    local shortText = "Flask (111)"
    local longText = "Wonderfully Long Consumable Item Name (345678)"
    local _, scroll, getCalls, _, getRows = buildList({
        { text = shortText, itemId = 111, goal = 10, canRemove = true, canEditGoal = true },
        { text = longText, itemId = 222, goal = 20, canRemove = true, canEditGoal = true },
    }, 380)

    fireEvent(scroll, "OnSizeChanged", scroll:GetWidth(), scroll:GetHeight())
    local rows = getRows()
    assertEq(#rows, 2, "two requested rows are built")

    local shortRow, longRow = rows[1], rows[2]
    local shortTextAnchor = leftAnchor(shortRow.Text)
    local shortGoalAnchor = rightAnchor(shortRow.GoalLabel)
    local shortEditAnchor = leftAnchor(shortRow.GoalEdit)
    local shortRemoveAnchor = leftAnchor(shortRow.Remove)
    local effectiveGap = Controls.ConsumableRequestedGoalEditGap()
    local defaults = Controls.CONSUMABLE_REQUESTED_DEFAULTS
    assertTrue(shortTextAnchor and shortTextAnchor.relativeTo == shortRow, "item name anchors to row")
    assertTrue(shortEditAnchor and shortEditAnchor.relativeTo == shortRow.Text,
        "Goal input follows the item name in the flowing chain")
    assertEq(
        shortEditAnchor and shortEditAnchor.x or nil,
        defaults.goalLabelGap + defaults.goalLabelWidth + effectiveGap,
        "Goal input offset reserves label width plus Goal→input visual/inset gap"
    )
    assertTrue(shortGoalAnchor and shortGoalAnchor.relativeTo == shortRow.GoalEdit,
        "Goal label is vertically centered against the input box")
    assertEq(shortGoalAnchor and shortGoalAnchor.x or nil, -effectiveGap,
        "Goal label keeps the effective clear gap before the input")
    assertEq(shortGoalAnchor and shortGoalAnchor.y or nil, 0,
        "Goal label uses a zero vertical offset against the input")
    assertTrue(shortRemoveAnchor and shortRemoveAnchor.relativeTo == shortRow.GoalEdit,
        "Remove follows Goal input")
    assertEq(shortRemoveAnchor and shortRemoveAnchor.x or nil, defaults.removeColumnGap,
        "Remove keeps a small consistent gap after the input")

    local availableWidth = scroll.scrollChild:GetWidth()
    local expectedShort = Controls.ConsumableRequestedTextWidth(availableWidth, #shortText * 7)
    local expectedLong = Controls.ConsumableRequestedTextWidth(availableWidth, #longText * 7)
    assertEq(shortRow.Text.width, expectedShort, "short name uses natural flowing width")
    assertEq(longRow.Text.width, expectedLong, "long name uses clamped flowing width")
    assertTrue(shortRow.Text.width < longRow.Text.width,
        "rows keep flowing widths rather than a shared fixed name column")
    local _, reserved = Controls.ConsumableRequestedTextMaxWidth(availableWidth)
    assertTrue(shortRow.Text.width + reserved <= availableWidth + 0.5,
        "short row controls fit inside available width")
    assertTrue(longRow.Text.width + reserved <= availableWidth + 0.5,
        "long row controls fit inside available width")
    assertTrue(getCalls() <= 80, "getItems stays bounded during layout")
end

-- Narrow resize clamps names; wide resize restores fuller names.
do
    local longText = "Wonderfully Long Consumable Item Name (345678)"
    local _, scroll, getCalls, _, getRows = buildList({
        { text = longText, itemId = 333, goal = 5, canRemove = true, canEditGoal = true },
    }, 200)

    fireEvent(scroll, "OnSizeChanged", 200, 180)
    local narrowRow = getRows()[1]
    local narrowWidth = narrowRow.Text.width
    local narrowMax = Controls.ConsumableRequestedTextMaxWidth(scroll.scrollChild:GetWidth())
    assertEq(narrowWidth, narrowMax, "narrow viewport clamps the item name")

    scroll:SetSize(420, 180)
    fireEvent(scroll, "OnSizeChanged", 420, 180)
    local wideRow = getRows()[1]
    local wideWidth = wideRow.Text.width
    local natural = (#longText * 7) + 4
    local wideMax = Controls.ConsumableRequestedTextMaxWidth(scroll.scrollChild:GetWidth())
    assertTrue(wideWidth > narrowWidth, "widening the list increases name width")
    assertEq(wideWidth, math.min(natural, wideMax),
        "wide viewport uses natural width when space allows, else clamps")
    assertTrue(getCalls() <= 80, "resize refreshes stay bounded")
end

-- Nested OnSizeChanged during Refresh must not recurse.
do
    local items = {
        { text = "Flask (111)", itemId = 111, goal = 1, canRemove = true, canEditGoal = true },
    }
    local panel = CreateFrame("Frame")
    panel:SetSize(700, 400)
    panel.__sfPageLayout = { disablePageScroll = true }
    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    local section = pageBuilder:AddSection("Consumables")
    section.Content:SetWidth(640)

    local getItemsCalls = 0
    local nestedFires = 0
    local firingNested = false
    local scroll
    Controls:AddConsumableRequestedList(section, {
        label = "Requested Items",
        height = 180,
        getItems = function()
            getItemsCalls = getItemsCalls + 1
            if getItemsCalls > 80 then
                error("AddConsumableRequestedList Refresh exceeded 80 getItems calls")
            end
            if firingNested and scroll then
                nestedFires = nestedFires + 1
                fireEvent(scroll, "OnSizeChanged", scroll:GetWidth() or 0, scroll:GetHeight() or 0)
            end
            return items
        end,
    })
    scroll = findScroll(section)
    scroll:SetSize(380, 180)
    pageBuilder:Finalize()

    local before = getItemsCalls
    firingNested = true
    fireEvent(scroll, "OnSizeChanged", 380, 180)
    firingNested = false
    local after = getItemsCalls
    assertTrue(after - before <= 2, "nested OnSizeChanged does not recursively refresh requested list")
    assertTrue(nestedFires >= 1, "nested size notification was delivered during Refresh")
    assertTrue(after <= 80, "getItems stays bounded under nested size events")
end

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
