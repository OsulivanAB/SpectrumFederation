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
        self.text = tostring(text or "")
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

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
