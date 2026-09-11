-- Production-Lua tests for Settings Section + PageBuilder fill-height layout.
-- Catches the OnSizeChanged / fill-height reflow loop that froze Raid Equipment
-- for users who saw a Section message (historically: no Loot Helper profile).
-- Run from the repository root: lua5.1 tests/lua/settings_section_layout_tests.lua

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

local function assertFalse(cond, message)
    assertTrue(not cond, message)
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local function assertAlmost(actual, expected, epsilon, message)
    if type(actual) ~= "number" or type(expected) ~= "number" then
        fail(message .. " (non-numeric)")
        return
    end
    if math.abs(actual - expected) <= epsilon then
        pass(message)
    else
        fail(string.format("%s (expected %s ± %s, got %s)", message, tostring(expected), tostring(epsilon), tostring(actual)))
    end
end

local MAX_SIZE_CHANGES = 250
local MAX_SIZE_CHANGE_DEPTH = 20
local MAX_REFLOWS = 40
local sizeChangeCount = 0
local sizeChangeDepth = 0
local reflowCount = 0
local layoutLoopError = nil

local function resetCounters()
    sizeChangeCount = 0
    sizeChangeDepth = 0
    reflowCount = 0
    layoutLoopError = nil
end

GameTooltip = {
    Hide = function() end,
    SetOwner = function() end,
    SetText = function() end,
    AddLine = function() end,
    Show = function() end,
}

local function estimateStringWidth(text)
    return math.max(1, #(text or "") * 7)
end

local function estimateStringHeight(region)
    local text = region.text or ""
    if text == "" then
        return 0
    end
    local width = math.max(1, region.width or 300)
    local charsPerLine = math.max(8, math.floor(width / 7))
    local lines = math.max(1, math.ceil(#text / charsPerLine))
    return lines * 12
end

local function fireEvent(region, event, ...)
    if event == "OnSizeChanged" then
        sizeChangeCount = sizeChangeCount + 1
        sizeChangeDepth = sizeChangeDepth + 1
        if sizeChangeDepth > MAX_SIZE_CHANGE_DEPTH then
            layoutLoopError = "OnSizeChanged recursion exceeded " .. MAX_SIZE_CHANGE_DEPTH .. " (possible layout loop)"
            error(layoutLoopError)
        end
        if sizeChangeCount > MAX_SIZE_CHANGES then
            layoutLoopError = "OnSizeChanged exceeded " .. MAX_SIZE_CHANGES .. " (possible layout loop)"
            error(layoutLoopError)
        end
    end

    local script = region.scripts and region.scripts[event]
    if script then
        script(region, ...)
    end
    for _, hook in ipairs((region.hooks and region.hooks[event]) or {}) do
        hook(region, ...)
    end

    if event == "OnSizeChanged" then
        sizeChangeDepth = sizeChangeDepth - 1
    end
end

local function makeRegion(kind, name, parent)
    local region = {
        kind = kind,
        name = name,
        parent = parent,
        shown = true,
        height = 0,
        width = 0,
        points = {},
        scripts = {},
        hooks = {},
        text = "",
    }

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

    function region:SetHeight(height)
        height = tonumber(height) or 0
        local oldWidth, oldHeight = self.width, self.height
        self.height = height
        if oldHeight ~= height then
            fireEvent(self, "OnSizeChanged", oldWidth, height)
        end
    end

    function region:GetHeight()
        return self.height
    end

    function region:SetWidth(width)
        width = tonumber(width) or 0
        local oldWidth, oldHeight = self.width, self.height
        self.width = width
        if oldWidth ~= width then
            fireEvent(self, "OnSizeChanged", width, oldHeight)
        end
    end

    function region:GetWidth()
        return self.width
    end

    function region:SetSize(width, height)
        width = tonumber(width) or 0
        height = tonumber(height) or 0
        local oldWidth, oldHeight = self.width, self.height
        self.width = width
        self.height = height
        if oldWidth ~= width or oldHeight ~= height then
            fireEvent(self, "OnSizeChanged", width, height)
        end
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

    function region:SetAllPoints(target)
        self.allPoints = target or self.parent
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

    function region:SetHitRectInsets()
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
        return estimateStringWidth(self.text)
    end

    function region:GetStringHeight()
        return estimateStringHeight(self)
    end

    function region:SetScript(event, fn)
        self.scripts[event] = fn
    end

    function region:HookScript(event, fn)
        self.hooks[event] = self.hooks[event] or {}
        table.insert(self.hooks[event], fn)
    end

    function region:SetScrollChild(child)
        self.scrollChild = child
    end

    function region:GetScrollChild()
        return self.scrollChild
    end

    function region:EnableMouse()
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

    return region
end

function CreateFrame(frameType, name, parent)
    return makeRegion(frameType or "Frame", name, parent)
end

local SF = {}
assert(loadfile("SpectrumFederation/modules/UI/Settings/Style.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Widgets/Section.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/PageBuilder.lua"))("SpectrumFederation", SF)

local PageBuilder = SF.SettingsUI.PageBuilder
local originalReflow = PageBuilder.Reflow
function PageBuilder:Reflow()
    reflowCount = reflowCount + 1
    if reflowCount > MAX_REFLOWS then
        layoutLoopError = "PageBuilder:Reflow exceeded " .. MAX_REFLOWS .. " (possible layout loop)"
        error(layoutLoopError)
    end
    return originalReflow(self)
end

local LONG_MESSAGE = "Select an active Loot Helper profile to apply raid check expectations. This warning is long enough to wrap when the Settings window is narrow."

local function buildFillHeightPage(opts)
    opts = opts or {}
    local panelWidth = opts.width or 800
    local panelHeight = opts.height or 600
    local panel = CreateFrame("Frame", nil, nil)
    panel:SetSize(panelWidth, panelHeight)
    panel.__sfPageLayout = { disablePageScroll = true }

    local pageBuilder = SF.SettingsUI:CreatePage(panel)
    pageBuilder.scrollFrame:SetSize(panelWidth, panelHeight)
    pageBuilder.content:SetWidth(panelWidth)

    local intro = pageBuilder:AddSection({
        title = "Raid Equipment",
        tooltip = "Shows the current-Retail equipment audit. No Loot Helper profile or session is required.",
    })
    intro:AddRow(28)

    local tableSection = pageBuilder:AddSection({
        title = "Current Group Equipment",
        tooltip = "Shows the last seen gear in each slot for every visible raid member.",
    })
    tableSection.__sfFillHeight = true
    tableSection.Content:SetWidth(panelWidth - 32)
    tableSection:AddRow(260, nil, { fillHeight = true })

    if opts.secondFillRow then
        tableSection:AddRow(40, nil, { fillHeight = true })
    end

    pageBuilder:Finalize()
    resetCounters()
    return pageBuilder, tableSection, intro, panel
end

local function runBounded(label, fn)
    resetCounters()
    local ok, err = pcall(fn)
    if not ok then
        fail(label .. " (" .. tostring(err or layoutLoopError or "error") .. ")")
        return false
    end
    if layoutLoopError then
        fail(label .. " (" .. layoutLoopError .. ")")
        return false
    end
    return true
end

-- Fill-height + visible message must terminate with stable dimensions.
do
    local pageBuilder, tableSection
    local fillRow
    local heightAfterFirst
    local widthAfterFirst
    local ok = runBounded("fill-height section with visible message", function()
        pageBuilder, tableSection = buildFillHeightPage()
        fillRow = tableSection._rows[1]
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        pageBuilder:Reflow()
        pageBuilder:Reflow()
        pageBuilder:Reflow()
        heightAfterFirst = tableSection:GetHeight()
        widthAfterFirst = tableSection.Content:GetWidth()
        pageBuilder:Reflow()
    end)
    if ok then
        assertTrue(tableSection.MessageRow:IsShown(), "SetMessage shows the message row")
        assertTrue(fillRow.__sfFillHeight, "equipment table row is fill-height")
        assertTrue((fillRow:GetHeight() or 0) >= 260, "fill row stays at least its base height")
        assertAlmost(tableSection:GetHeight(), heightAfterFirst, 0.5, "repeated reflow keeps a stable section height")
        assertAlmost(tableSection.Content:GetWidth(), widthAfterFirst, 0.5, "repeated reflow keeps a stable content width")
        assertTrue(reflowCount <= MAX_REFLOWS, "page reflow count stays bounded with a visible message")
        assertTrue(sizeChangeCount <= MAX_SIZE_CHANGES, "OnSizeChanged count stays bounded with a visible message")
    end
end

-- Height-only content size changes must not re-enter message layout.
do
    local tableSection
    local reflowsBefore
    local sizeBefore
    local ok = runBounded("height-only size change with visible message", function()
        local pageBuilder
        pageBuilder, tableSection = buildFillHeightPage()
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        pageBuilder:Reflow()
        reflowsBefore = reflowCount
        sizeBefore = sizeChangeCount
        local currentHeight = tableSection.Content:GetHeight() or 0
        tableSection.Content:SetHeight(currentHeight)
        tableSection.Content:SetHeight(currentHeight + 24)
        tableSection.Content:SetHeight(currentHeight)
    end)
    if ok then
        assertEq(reflowCount, reflowsBefore, "height-only Content size changes do not notify PageBuilder")
        assertTrue(sizeChangeCount <= sizeBefore + 2, "height-only changes fire OnSizeChanged without extra layout")
        assertTrue(tableSection.MessageRow:IsShown(), "message stays visible after height-only size changes")
    end
end

-- Width changes still remeasure wrapped messages.
do
    local tableSection
    local heightAtWide
    local heightAtNarrow
    local ok = runBounded("width change remeasures wrapped message", function()
        local pageBuilder
        pageBuilder, tableSection = buildFillHeightPage({ width = 900 })
        tableSection.Content:SetWidth(800)
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        pageBuilder:Reflow()
        heightAtWide = tableSection.MessageRow:GetHeight()
        tableSection.Content:SetWidth(120)
        pageBuilder:Reflow()
        heightAtNarrow = tableSection.MessageRow:GetHeight()
    end)
    if ok then
        assertTrue(heightAtNarrow > heightAtWide, "narrower section width increases wrapped message height")
        assertTrue(tableSection.MessageRow:IsShown(), "message stays visible after width change")
    end
end

-- Message hidden -> shown -> hidden remains bounded.
do
    local tableSection
    local fillRow
    local hiddenHeight
    local shownHeight
    local fillHidden
    local fillShown
    local ok = runBounded("message shown and hidden on fill-height section", function()
        local pageBuilder
        pageBuilder, tableSection = buildFillHeightPage()
        fillRow = tableSection._rows[1]
        pageBuilder:Reflow()
        hiddenHeight = tableSection:GetHeight()
        fillHidden = fillRow:GetHeight()
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        pageBuilder:Reflow()
        shownHeight = tableSection:GetHeight()
        fillShown = fillRow:GetHeight()
        tableSection:ClearMessage()
        pageBuilder:Reflow()
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        tableSection:ClearMessage()
        pageBuilder:Reflow()
    end)
    if ok then
        assertFalse(tableSection.MessageRow:IsShown(), "ClearMessage hides the message row")
        assertAlmost(shownHeight, hiddenHeight, 0.5, "showing a message keeps the assigned fill-height section height")
        assertTrue(fillShown < fillHidden, "visible message consumes leftover fill-row height")
        assertTrue(fillShown >= 260, "fill row never drops below its base height while a message is shown")
        assertAlmost(tableSection:GetHeight(), hiddenHeight, 0.5, "hiding the message restores the prior section height")
        assertTrue((fillRow:GetHeight() or 0) >= 260, "fill row keeps its base height after message hide")
        assertTrue(reflowCount <= MAX_REFLOWS, "show/hide message reflow count stays bounded")
    end
end

-- Viewport height-only change (Settings window height) stays bounded.
do
    local pageBuilder, tableSection
    local fillAtTall
    local fillAtShort
    local ok = runBounded("settings window height-only change", function()
        pageBuilder, tableSection = buildFillHeightPage({ height = 700 })
        tableSection:SetMessage(LONG_MESSAGE, "warn")
        pageBuilder:Reflow()
        fillAtTall = tableSection._rows[1]:GetHeight()
        pageBuilder.scrollFrame:SetHeight(420)
        pageBuilder:Reflow()
        fillAtShort = tableSection._rows[1]:GetHeight()
        pageBuilder.scrollFrame:SetHeight(700)
        pageBuilder:Reflow()
    end)
    if ok then
        assertTrue(fillAtTall >= fillAtShort, "shorter viewport does not expand the fill row further")
        assertTrue((tableSection._rows[1]:GetHeight() or 0) >= 260, "fill row never drops below its base height")
        assertTrue(reflowCount <= MAX_REFLOWS, "viewport height changes stay bounded")
    end
end

-- Multiple fill rows share leftover height from natural bases, not expanded heights.
do
    local tableSection
    local first
    local second
    local ok = runBounded("two fill rows use stable base heights", function()
        local pageBuilder
        pageBuilder, tableSection = buildFillHeightPage({ secondFillRow = true, height = 800 })
        first = tableSection._rows[1]
        second = tableSection._rows[2]
        tableSection:SetMessage("Warning", "warn")
        pageBuilder:Reflow()
        local firstHeight = first:GetHeight()
        local secondHeight = second:GetHeight()
        pageBuilder:Reflow()
        pageBuilder:Reflow()
        assertAlmost(first:GetHeight(), firstHeight, 0.5, "first fill row stays stable across reflows")
        assertAlmost(second:GetHeight(), secondHeight, 0.5, "second fill row stays stable across reflows")
    end)
    if ok then
        assertTrue((first:GetHeight() or 0) >= 260, "first fill row keeps its 260 base")
        assertTrue((second:GetHeight() or 0) >= 40, "second fill row keeps its 40 base")
        assertTrue(math.abs((first:GetHeight() - 260) - (second:GetHeight() - 40)) <= 0.5, "extra fill height is shared equally")
    end
end

-- Non-fill section messages still layout without a loop.
do
    local section
    local ok = runBounded("non-fill section message", function()
        local panel = CreateFrame("Frame")
        panel:SetSize(640, 480)
        panel.__sfPageLayout = { disablePageScroll = true }
        local pageBuilder = SF.SettingsUI:CreatePage(panel)
        pageBuilder.scrollFrame:SetSize(640, 480)
        pageBuilder.content:SetWidth(640)
        section = pageBuilder:AddSection("General")
        section.Content:SetWidth(600)
        section:AddRow(24)
        pageBuilder:Finalize()
        resetCounters()
        section:SetMessage("Copied Mouse Tracer settings.", "success")
        pageBuilder:Refresh()
        pageBuilder:Reflow()
        section:ClearMessage()
        pageBuilder:Reflow()
    end)
    if ok then
        assertFalse(section.MessageRow:IsShown(), "non-fill section can hide its message")
        assertTrue(reflowCount <= MAX_REFLOWS, "non-fill section message layout stays bounded")
    end
end

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
