-- Production-Lua tests for AddLogTable size-change reentrancy (F-03).
-- Run from the repository root: lua5.1 tests/lua/settings_log_table_tests.lua

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
        value = 0,
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
        -- Mirror WoW FontString:SetText — reject non-string/number so callable
        -- emptyText must be resolved before the first SetText (#453).
        local valueType = type(text)
        if valueType ~= "string" and valueType ~= "number" and text ~= nil then
            error("FontString:SetText invalid argument type: " .. valueType, 2)
        end
        self.text = text == nil and "" or tostring(text)
    end

    function region:SetTextColor()
    end

    function region:SetJustifyH()
    end

    function region:SetJustifyV()
    end

    function region:SetWordWrap()
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

    function region:SetTexCoord()
    end

    function region:SetVertexColor()
    end

    function region:SetBlendMode()
    end

    function region:SetVerticalScroll(offset)
        self.verticalScroll = tonumber(offset) or 0
        fireEvent(self, "OnVerticalScroll", self.verticalScroll)
    end

    function region:GetVerticalScroll()
        return self.verticalScroll or 0
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
        function region.ScrollBar:GetValue()
            return self.value or 0
        end
        function region.ScrollBar:SetValue(v)
            self.value = tonumber(v) or 0
        end
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

local ROW_HEIGHT = 22
local ROW_SPACING = 1
local HEADER_HEIGHT = 24
local VIEWPORT_ROWS = 6

local function makeRows(count)
    local rows = {}
    for index = 1, count do
        rows[index] = { text = "Log " .. index }
    end
    return rows
end

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

local function buildLogTable(rowCount)
    local panel = CreateFrame("Frame")
    panel:SetSize(600, 400)
    panel.__sfPageLayout = { disablePageScroll = true }
    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    local section = pageBuilder:AddSection("Loot Logs")
    section.Content:SetWidth(560)

    local nestedFires = 0
    local getRowsCalls = 0
    local firingNested = false
    local scroll

    SF.SettingsUI.Controls:AddLogTable(section, {
        columns = { { key = "text", label = "Log" } },
        rowHeight = ROW_HEIGHT,
        rowSpacing = ROW_SPACING,
        headerHeight = HEADER_HEIGHT,
        height = 180,
        fillHeight = true,
        getRows = function()
            getRowsCalls = getRowsCalls + 1
            if getRowsCalls > 80 then
                error("AddLogTable Refresh exceeded 80 getRows calls (possible size loop)")
            end
            if firingNested and scroll then
                nestedFires = nestedFires + 1
                fireEvent(scroll, "OnSizeChanged", scroll:GetWidth() or 0, scroll:GetHeight() or 0)
            end
            return makeRows(rowCount)
        end,
    })

    scroll = findScroll(section)
    local visibleHeight = VIEWPORT_ROWS * (ROW_HEIGHT + ROW_SPACING)
    if scroll then
        scroll:SetSize(560, visibleHeight)
    end
    pageBuilder:Finalize()
    return section, scroll, function()
        return getRowsCalls
    end, function(enabled)
        firingNested = enabled
    end, function()
        return nestedFires
    end, pageBuilder
end

-- Nested OnSizeChanged during Refresh must not recurse.
do
    local _, scroll, getCalls, setNested, getNested = buildLogTable(VIEWPORT_ROWS)
    local before = getCalls()
    setNested(true)
    fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
    setNested(false)
    local after = getCalls()
    assertTrue(after - before <= 2, "nested OnSizeChanged does not recursively refresh AddLogTable")
    assertTrue(getNested() >= 1, "nested size notification was delivered during Refresh")
    assertTrue(after <= 80, "getRows stays bounded")
end

-- Scrollbar threshold: N-1, N, N+1, N+2 all terminate.
do
    for _, count in ipairs({ VIEWPORT_ROWS - 1, VIEWPORT_ROWS, VIEWPORT_ROWS + 1, VIEWPORT_ROWS + 2 }) do
        local _, scroll, getCalls = buildLogTable(count)
        local before = getCalls()
        fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
        fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
        local after = getCalls()
        assertTrue(after - before <= 3, "scrollbar-threshold refresh terminates for " .. tostring(count) .. " rows")
    end
end

-- Repeated same-size notifications remain idle after the first refresh.
do
    local _, scroll, getCalls = buildLogTable(VIEWPORT_ROWS + 1)
    fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
    local afterFirst = getCalls()
    fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
    fireEvent(scroll, "OnSizeChanged", 560, scroll:GetHeight())
    assertEq(getCalls(), afterFirst + 2, "same-size notifications still invoke Refresh but each call terminates")
    assertTrue(getCalls() <= afterFirst + 2, "repeated same-size Refresh stays bounded")
end

local function findLogTableRow(section)
    for _, row in ipairs(section._rows or {}) do
        if type(row.__sfLogTableRefresh) == "function" then
            return row
        end
    end
    return nil
end

local function visibleRowTexts(row)
    local texts = {}
    local scroll = row.__sfLogTableScroll
    local content = scroll and scroll.scrollChild
    if not content then
        return texts
    end
    for _, child in ipairs(content.children or {}) do
        if child.kind == "Button" and child:IsShown() and child.Cells then
            local cell = child.Cells[1]
            local value = cell and cell.Text and cell.Text.text or nil
            if type(value) == "string" then
                texts[#texts + 1] = value
            end
        end
    end
    return texts
end

-- #453: callable emptyText must resolve during construction (FontString rejects functions).
do
    local panel = CreateFrame("Frame")
    panel:SetSize(600, 400)
    panel.__sfPageLayout = { disablePageScroll = true }
    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    local section = pageBuilder:AddSection("Callable empty")
    section.Content:SetWidth(560)
    local emptyCalls = 0
    local ok, err = pcall(function()
        SF.SettingsUI.Controls:AddLogTable(section, {
            columns = { { key = "text", label = "Log" } },
            rowHeight = ROW_HEIGHT,
            height = 180,
            emptyText = function()
                emptyCalls = emptyCalls + 1
                return "No matching logs yet."
            end,
            getRows = function()
                return {}
            end,
        })
    end)
    assertTrue(ok, "callable emptyText constructs without FontString type error: " .. tostring(err))
    assertTrue(emptyCalls >= 1, "callable emptyText invoked during construction")
    local row = findLogTableRow(section)
    assertTrue(row ~= nil, "callable emptyText log table row exists")
    pageBuilder:Finalize()
    if row and row.__sfLogTableRefresh then
        row.__sfLogTableRefresh()
    end
    assertTrue(emptyCalls >= 2, "callable emptyText resolves again on refresh")
end

-- #453: scroll context reset/clamp while preserving ordinary same-context refresh.
do
    local panel = CreateFrame("Frame")
    panel:SetSize(600, 400)
    panel.__sfPageLayout = { disablePageScroll = true }
    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    local section = pageBuilder:AddSection("Scroll context")
    section.Content:SetWidth(560)

    local contextKey = "campaign-a|all|all"
    local dataCount = 40
    SF.SettingsUI.Controls:AddLogTable(section, {
        columns = { { key = "text", label = "Log" } },
        rowHeight = ROW_HEIGHT,
        rowSpacing = ROW_SPACING,
        headerHeight = HEADER_HEIGHT,
        height = 180,
        fillHeight = true,
        virtualize = true,
        getScrollContextKey = function()
            return contextKey
        end,
        getRows = function()
            return makeRows(dataCount)
        end,
    })

    local row = findLogTableRow(section)
    local scroll = row and row.__sfLogTableScroll
    assertTrue(row ~= nil and scroll ~= nil, "virtualized log table exposes scroll hooks")
    local visibleHeight = VIEWPORT_ROWS * (ROW_HEIGHT + ROW_SPACING)
    scroll:SetSize(560, visibleHeight)
    pageBuilder:Finalize()
    row.__sfLogTableRefresh()

    local stride = ROW_HEIGHT + ROW_SPACING
    local contentHeight = dataCount * stride - ROW_SPACING
    local maxScroll = math.max(0, contentHeight - visibleHeight)
    assertTrue(maxScroll > stride * 20, "40 rows require scrolling past 25 entries")

    row.__sfLogTableSetVerticalScroll(maxScroll)
    assertEq(row.__sfLogTableGetVerticalScroll(), maxScroll, "scroll reaches oldest entries")
    local bottomTexts = visibleRowTexts(row)
    local sawOldest = false
    for i = 1, #bottomTexts do
        if bottomTexts[i] == "Log 40" then
            sawOldest = true
        end
    end
    assertTrue(sawOldest, "scrolled window includes oldest entry (Log 40)")

    local beforePreserve = row.__sfLogTableGetVerticalScroll()
    row.__sfLogTableRefresh()
    assertEq(row.__sfLogTableGetVerticalScroll(), beforePreserve,
        "same-context refresh preserves scroll offset")

    contextKey = "campaign-b|all|all"
    row.__sfLogTableRefresh()
    assertEq(row.__sfLogTableGetVerticalScroll(), 0,
        "campaign/dataset context change resets scroll")

    row.__sfLogTableSetVerticalScroll(maxScroll)
    contextKey = "campaign-b|Bob|10"
    row.__sfLogTableRefresh()
    assertEq(row.__sfLogTableGetVerticalScroll(), 0,
        "filter context change resets scroll")

    row.__sfLogTableSetVerticalScroll(maxScroll)
    local beforeShrink = row.__sfLogTableGetVerticalScroll()
    dataCount = 8
    row.__sfLogTableRefresh()
    -- Match AddLogTable's viewport: scroll:GetHeight() - 2.
    local shrunkVisible = math.max(1, (scroll:GetHeight() or 0) - 2)
    local shrunkMax = math.max(0, (dataCount * stride - ROW_SPACING) - shrunkVisible)
    local afterShrink = row.__sfLogTableGetVerticalScroll()
    assertTrue(afterShrink <= shrunkMax,
        "shrinking results clamps scroll into range")
    assertTrue(afterShrink < beforeShrink,
        "shrink clamp moves offset down from the prior oversized scroll")

    dataCount = 40
    row.__sfLogTableRefresh()
    row.__sfLogTableSetVerticalScroll(maxScroll)
    dataCount = 0
    row.__sfLogTableRefresh()
    assertEq(row.__sfLogTableGetVerticalScroll(), 0, "empty results reset scroll")

    -- Pool stays bounded across large histories and open/close-style refreshes.
    dataCount = 40
    local poolBefore = row.__sfLogTableRowCount()
    for _ = 1, 6 do
        row.__sfLogTableRefresh()
        row.__sfLogTableSetVerticalScroll(maxScroll)
        row.__sfLogTableSetVerticalScroll(0)
    end
    local poolAfter = row.__sfLogTableRowCount()
    assertTrue(poolBefore > 0, "virtualize creates a row pool")
    assertTrue(poolAfter <= poolBefore + 2, "row-frame pool stays bounded across refreshes")
    assertTrue(poolAfter < 25, "pool is far smaller than a 40-row history")
end

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
