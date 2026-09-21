-- Production-Lua tests for Loot Helper responsive width (#292).
-- Run from the repository root: lua5.1 tests/lua/loot_helper_responsive_layout_tests.lua

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

UIParent = {
    width = 1920,
    height = 1080,
}
function UIParent:GetWidth()
    return self.width
end
function UIParent:GetHeight()
    return self.height
end

SpectrumFederationDB = {
    lootHelper = {
        window = {
            width = 620,
            height = 520,
        },
    },
}

GameTooltip = {
    SetOwner = function() end,
    SetText = function() end,
    Show = function() end,
    Hide = function() end,
}

local function makeWidget(kind)
    local widget = {
        kind = kind,
        shown = true,
        text = "",
        width = 0,
        height = 0,
        points = {},
        scripts = {},
        hooks = {},
        texture = nil,
    }

    function widget:SetText(text)
        self.text = text
    end
    function widget:GetText()
        return self.text
    end
    function widget:Show()
        self.shown = true
    end
    function widget:Hide()
        self.shown = false
    end
    function widget:SetShown(shown)
        self.shown = shown and true or false
    end
    function widget:IsShown()
        return self.shown and true or false
    end
    function widget:SetWidth(width)
        self.width = width
    end
    function widget:GetWidth()
        return self.width
    end
    function widget:SetHeight(height)
        self.height = height
    end
    function widget:GetHeight()
        return self.height
    end
    function widget:SetSize(width, height)
        self.width = width
        self.height = height
    end
    function widget:SetPoint(a, b, c, d, e)
        self.points[#self.points + 1] = { a, b, c, d, e }
    end
    function widget:ClearAllPoints()
        self.points = {}
    end
    function widget:SetScript(event, fn)
        self.scripts[event] = fn
    end
    function widget:HookScript(event, fn)
        self.hooks[event] = fn
    end
    function widget:SetTexture(texture)
        self.texture = texture
    end
    function widget:GetStringWidth()
        return nil
    end
    function widget:CreateFontString()
        return makeWidget("FontString")
    end
    function widget:CreateTexture()
        local texture = makeWidget("Texture")
        texture.shown = true
        return texture
    end

    return setmetatable(widget, {
        __index = function()
            return function() end
        end,
    })
end

function CreateFrame()
    return makeWidget("Frame")
end

local function makeFrame(width, height)
    local frame = {
        width = width,
        height = height,
        left = 0,
        bottom = 0,
        point = "CENTER",
        relativeTo = UIParent,
        relativePoint = "CENTER",
        x = 0,
        y = 0,
        __sfMinimized = false,
        __sfLocked = false,
    }

    function frame:GetLeft()
        return self.left
    end
    function frame:GetRight()
        return self.left + self.width
    end
    function frame:GetBottom()
        return self.bottom
    end
    function frame:GetTop()
        return self.bottom + self.height
    end
    function frame:GetWidth()
        return self.width
    end
    function frame:GetHeight()
        return self.height
    end
    function frame:GetSize()
        return self.width, self.height
    end
    function frame:GetPoint()
        return self.point, self.relativeTo, self.relativePoint, self.x, self.y
    end
    function frame:ClearAllPoints()
        self.point = nil
        self.relativeTo = nil
        self.relativePoint = nil
        self.x = nil
        self.y = nil
    end
    function frame:SetResizable()
    end
    function frame:SetResizeBounds()
    end
    function frame:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = point
        self.relativeTo = relativeTo
        self.relativePoint = relativePoint
        self.x = x
        self.y = y
        if point == "TOPLEFT" and relativePoint == "BOTTOMLEFT" then
            self.left = x
            self.bottom = y - self.height
            return
        end
        if point == "CENTER" and relativePoint == "CENTER" then
            local parent = relativeTo or UIParent
            local cx = (parent:GetWidth() / 2) + (x or 0)
            local cy = (parent:GetHeight() / 2) + (y or 0)
            self.left = cx - (self.width / 2)
            self.bottom = cy - (self.height / 2)
        end
    end
    function frame:SetSize(nextWidth, nextHeight)
        local oldWidth, oldHeight = self.width, self.height
        if self.point == "CENTER" then
            local cx = self.left + (oldWidth / 2)
            local cy = self.bottom + (oldHeight / 2)
            self.width = nextWidth
            self.height = nextHeight
            self.left = cx - (nextWidth / 2)
            self.bottom = cy - (nextHeight / 2)
            return
        end
        if self.point == "TOPLEFT" then
            local top = self.bottom + oldHeight
            self.width = nextWidth
            self.height = nextHeight
            self.bottom = top - nextHeight
            return
        end
        self.width = nextWidth
        self.height = nextHeight
    end

    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    return frame
end

local SF = { LootHelperWindow = {} }
local constChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Constants.lua"))
constChunk("SpectrumFederation", SF)
local windowChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/Window.lua"))
windowChunk("SpectrumFederation", SF)
local viewChunk = assert(loadfile("SpectrumFederation/modules/UI/LootHelper/RosterView.lua"))
viewChunk("SpectrumFederation", SF)

local Window = SF.LootHelperWindow.Window
local View = SF.LootHelperWindow.RosterView
local C = SF.LootHelperWindow.Constants

local insetUpdates = 0
Window.RequestScrollInsetsUpdate = function()
    insetUpdates = insetUpdates + 1
end

local function measure(text)
    return string.len(tostring(text or "")) * 8
end

local pointRequest = {
    points = true,
    attendance = true,
    preparedness = true,
    bis = true,
    readiness = true,
    hasAction = true,
}
local potRequest = {
    points = false,
    attendance = true,
    preparedness = true,
    bis = true,
    readiness = true,
    hasAction = true,
}
local nameMin = View.MinimumNameWidth(measure)

assertTrue(C.MIN_WIDTH < 480, "minimum width is below the previous 480 floor")
assertTrue(C.MIN_WIDTH > 160, "minimum width still fits mandatory controls")
assertEq(C.DEFAULT_WIDTH, 620, "default width is unchanged")
assertEq(C.DEFAULT_HEIGHT, 520, "default height is unchanged")
assertTrue(C.DEFAULT_WIDTH > C.MIN_WIDTH, "default width remains above the new minimum")
assertTrue(View.MIN_WIDTH_COMFORT < 48 + 8, "comfort padding cannot resurrect a hidden glance column")

local metrics = Window.TitleMetrics
local expectedTitle = (metrics.frameInset + C.TITLE_PADDING_X + C.LOGO_SIZE + metrics.leftPad)
    + (metrics.frameInset + metrics.closeRightOffset + metrics.closeSize
        + metrics.minimizeGap + metrics.minimizeSize
        + metrics.gearGap + C.ICON_BUTTON_SIZE
        + metrics.playGap + C.ICON_BUTTON_SIZE
        + metrics.rightPad)
assertEq(Window.MinimumTitleWidth(0), expectedTitle, "title minimum matches the shared control metrics")
assertTrue(C.MIN_WIDTH >= Window.MinimumTitleWidth(nameMin), "window minimum keeps title controls usable")
assertTrue(
    expectedTitle > C.LOGO_SIZE + C.ICON_BUTTON_SIZE + C.ICON_BUTTON_SIZE + metrics.minimizeSize + metrics.closeSize,
    "title minimum includes logo, start/stop, settings, minimize, and close"
)

local narrowTitle = Window.ResolveTitleLayout(40, 220, 80)
assertEq(narrowTitle.showPointName, false, "narrow title hides the point name instead of overlapping controls")
assertEq(narrowTitle.profileWidth, 40, "narrow title still reserves the remaining profile width")
local wideTitle = Window.ResolveTitleLayout(420, 90, 40)
assertEq(wideTitle.showPointName, true, "wide title still shows the point name when both strings fit")
assertTrue(wideTitle.profileWidth > 0 and wideTitle.profileWidth < 420, "wide title leaves room for the point name")

local function firstWidth(pred)
    for width = 1, 900 do
        local decision = View.ResolveResponsiveLayout(width, pointRequest, nameMin)
        if pred(decision) then
            return width, decision
        end
    end
    return nil
end

local allWidth, allDecision = firstWidth(function(decision)
    return decision.bis and decision.preparedness and decision.attendance and decision.points and decision.readiness
end)
assertTrue(allWidth ~= nil, "a wide roster still fits every glance column")
assertAlmost(allDecision.nameWidth, nameMin, 1.01, "columns stay until the name reaches its protected minimum")
local beforeBisDrop = View.ResolveResponsiveLayout(allWidth - 1, pointRequest, nameMin)
assertTrue(not beforeBisDrop.bis, "BiS is the first glance column to hide")
assertTrue(beforeBisDrop.preparedness and beforeBisDrop.attendance, "Prep. and Att. remain when BiS first hides")
assertTrue(beforeBisDrop.points and beforeBisDrop.readiness, "Points and readiness remain when BiS hides")
assertTrue(beforeBisDrop.nameWidth >= nameMin - 0.01, "name stays at the floor when BiS hides")

local prepWidth = firstWidth(function(decision)
    return (not decision.bis) and decision.preparedness and decision.attendance
end)
assertTrue(prepWidth ~= nil, "Prep. remains after BiS hides")
local beforePrepDrop = View.ResolveResponsiveLayout(prepWidth - 1, pointRequest, nameMin)
assertTrue(not beforePrepDrop.bis and not beforePrepDrop.preparedness, "Prep. hides only after BiS")
assertTrue(beforePrepDrop.attendance, "Att. remains when Prep. first hides")
assertTrue(beforePrepDrop.points and beforePrepDrop.readiness, "Points and readiness remain when Prep. hides")

local attWidth = firstWidth(function(decision)
    return (not decision.bis) and (not decision.preparedness) and decision.attendance
end)
assertTrue(attWidth ~= nil, "Att. remains after Prep. hides")
local beforeAttDrop = View.ResolveResponsiveLayout(attWidth - 1, pointRequest, nameMin)
assertTrue(not beforeAttDrop.attendance and not beforeAttDrop.preparedness and not beforeAttDrop.bis, "Att. hides last")
assertTrue(beforeAttDrop.points and beforeAttDrop.readiness, "Points and readiness remain after Att. hides")
assertTrue(beforeAttDrop.nameWidth >= nameMin - 0.01, "name floor holds after every optional column is hidden")

local hidden = {}
local seen = { bis = true, preparedness = true, attendance = true }
local narrowingOk = true
for width = 900, 1, -1 do
    local decision = View.ResolveResponsiveLayout(width, pointRequest, nameMin)
    if decision.nameWidth < nameMin - 0.01 or not decision.points or not decision.readiness then
        narrowingOk = false
        fail("narrowing dropped the name floor, Points, or readiness at width " .. tostring(width))
        break
    end
    for _, key in ipairs({ "bis", "preparedness", "attendance" }) do
        if seen[key] and not decision[key] then
            hidden[#hidden + 1] = key
        end
        if not seen[key] and decision[key] then
            narrowingOk = false
            fail(key .. " returned while the width was still decreasing")
            break
        end
    end
    seen = {
        bis = decision.bis,
        preparedness = decision.preparedness,
        attendance = decision.attendance,
    }
end
assertTrue(narrowingOk, "narrowing keeps the name floor, Points, and readiness, and does not restore hidden columns")
assertEq(hidden[1], "bis", "narrowing hides BiS first")
assertEq(hidden[2], "preparedness", "narrowing hides Prep. second")
assertEq(hidden[3], "attendance", "narrowing hides Att. third")
assertEq(#hidden, 3, "each optional column hides once")

local restored = {}
seen = { bis = false, preparedness = false, attendance = false }
for width = 1, 900 do
    local decision = View.ResolveResponsiveLayout(width, pointRequest, nameMin)
    for _, key in ipairs({ "attendance", "preparedness", "bis" }) do
        if (not seen[key]) and decision[key] then
            restored[#restored + 1] = key
        end
    end
    if seen.bis and not decision.bis then
        fail("BiS hid again while widening")
    end
    if seen.preparedness and not decision.preparedness then
        fail("Prep. hid again while widening")
    end
    if seen.attendance and not decision.attendance then
        fail("Att. hid again while widening")
    end
    seen = {
        bis = decision.bis,
        preparedness = decision.preparedness,
        attendance = decision.attendance,
    }
end
assertEq(restored[1], "attendance", "widening restores Att. first")
assertEq(restored[2], "preparedness", "widening restores Prep. second")
assertEq(restored[3], "bis", "widening restores BiS last")

local longName = "Osulivan-Stormrage"
local truncateAt = View.ResolveResponsiveLayout(allWidth + 40, pointRequest, nameMin)
assertTrue(truncateAt.bis and truncateAt.preparedness and truncateAt.attendance, "name truncates while every column is still visible")
assertTrue(truncateAt.nameWidth < measure(longName), "the sample name does not fit in the shrunk name column")
local truncated = View.TruncateToWidth(longName, truncateAt.nameWidth, measure)
assertTrue(truncated ~= longName, "long raider names gain an ellipsis before columns drop")
assertEq(string.sub(truncated, -3), "...", "truncated names end with an ellipsis")
assertTrue(measure(truncated) <= truncateAt.nameWidth + 0.01, "truncated name fits the allocated width")
assertTrue(string.len(truncated) >= 6, "ellipsis form keeps at least three visible characters")
assertEq(View.TruncateToWidth("Osulivan", nameMin, measure), "Osu...", "the protected name floor is three characters plus ellipsis")
assertEq(View.TruncateToWidth("Bo", 200, measure), "Bo", "short names are not ellipsized")

local function codepointCount(text)
    local count = 0
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
        count = count + 1
        i = i + step
    end
    return count
end

local function utfMeasure(text)
    return codepointCount(text) * 8
end

local utfMin = View.MinimumNameWidth(utfMeasure)
local utfName = "Ábcdefghij"
local utfTruncated = View.TruncateToWidth(utfName, utfMin, utfMeasure)
assertEq(utfTruncated, "Ábc...", "multibyte names truncate on character boundaries")
assertEq(string.byte(utfTruncated, 1), string.byte(utfName, 1), "truncation keeps the leading UTF-8 byte")

local contentAtMin = View.ContentWidthForWindow(C.MIN_WIDTH, true)
local atMin = View.ResolveResponsiveLayout(contentAtMin, pointRequest, nameMin)
assertTrue(atMin.points and atMin.readiness, "point-based minimum keeps Points and readiness")
assertTrue(not atMin.bis and not atMin.preparedness and not atMin.attendance, "optional columns are hidden at the minimum")
assertTrue(atMin.nameWidth >= nameMin - 0.01, "minimum width still honors the name floor")

local potAtMin = View.ResolveResponsiveLayout(contentAtMin, potRequest, nameMin)
assertTrue(not potAtMin.points, "reward pot does not show Points")
assertTrue(potAtMin.readiness, "reward pot keeps readiness at the minimum")
assertTrue(potAtMin.nameWidth >= nameMin - 0.01, "reward pot keeps the name floor")

local defaultContent = View.ContentWidthForWindow(C.DEFAULT_WIDTH, true)
local atDefault = View.ResolveResponsiveLayout(defaultContent, pointRequest, nameMin)
assertTrue(atDefault.bis and atDefault.preparedness and atDefault.attendance and atDefault.points and atDefault.readiness, "default width shows every column")

local previousMinimumContent = View.ContentWidthForWindow(480, true)
local atPreviousMinimum = View.ResolveResponsiveLayout(previousMinimumContent, pointRequest, nameMin)
assertTrue(atPreviousMinimum.nameWidth >= nameMin, "the old 480 minimum still has a usable name")

-- Saved widths above the new floor load unchanged. Widths below it clamp up.
SpectrumFederationDB.lootHelper.window = { width = 700, height = 520, expandedHeight = 520 }
Window._frame = makeFrame(700, 520)
Window:LoadState()
assertEq(Window._frame:GetWidth(), 700, "saved width above the minimum loads unchanged")

SpectrumFederationDB.lootHelper.window = { width = 50, height = 520, expandedHeight = 520 }
Window._frame = makeFrame(50, 520)
Window:LoadState()
assertEq(Window._frame:GetWidth(), C.MIN_WIDTH, "saved width below the minimum clamps to the new floor")
assertEq(Window._frame:GetHeight(), 520, "clamping width preserves the saved height")

local businessCalls = 0
local function business()
    businessCalls = businessCalls + 1
end

local content = makeWidget("Frame")
content.Scroll = makeWidget("ScrollFrame")
content.Child = makeWidget("Frame")
content.Scroll.width = allWidth + 80
function content.Scroll:GetWidth()
    return self.width
end

local view = View.new(content, {
    OnEquipmentClicked = business,
    OnAddRaidNonMember = business,
    RefreshRoster = business,
})
function view._measure:GetStringWidth()
    return measure(self.text)
end

local rowModel = {
    type = "PROFILE_MEMBER",
    displayName = longName,
    class = "MAGE",
    showPoints = true,
    points = 12,
    pointName = "DKP",
    attendanceText = "96%",
    preparednessText = "80%",
    bisText = "5/16",
    readinessState = "not_ready",
    readinessTooltip = "Chest Enchant",
    memberId = "Osulivan-Area52",
    canAdmin = true,
}

insetUpdates = 0
view:Render({ rowModel }, {})
assertEq(insetUpdates, 1, "render requests one scroll-inset update")
assertEq(view._layoutApplyCount, 1, "render applies responsive layout once")
assertTrue(view.header.Bis:IsShown(), "wide render shows the BiS header")
assertTrue(view.header.Preparedness:IsShown(), "wide render shows the Prep. header")
assertTrue(view.header.Attendance:IsShown(), "wide render shows the Att. header")
assertTrue(view.header.Points:IsShown(), "wide render shows the Points header")
assertEq(view.header.Points:GetText(), "DKP", "points header uses the profile point name")

local row = view.rows[1]
assertTrue(row.BtnHelmet:IsShown(), "equipment button is available when the roster is wide")
assertTrue(row.Readiness:IsShown(), "readiness column is available when the roster is wide")
assertTrue(row.Readiness.Icon:IsShown(), "not-ready rows still draw the readiness icon")
assertEq(row.Points:GetText(), "12", "points value is shown")
assertTrue(row.Bis:IsShown() and row.Attendance:IsShown() and row.Preparedness:IsShown(), "wide row shows every glance column")
assertTrue(row.Name:GetText() ~= longName, "wide-but-finite row truncates the long raider name")
assertEq(string.sub(row.Name:GetText(), -3), "...", "rendered truncation uses an ellipsis")
assertTrue(string.len(row.Name:GetText()) >= 6, "rendered name keeps at least three characters")

local function rightInset(widget)
    local point = widget.points[#widget.points]
    if not point then
        return nil
    end
    return -(point[4] or 0)
end

assertTrue(rightInset(view.header.Points) > rightInset(view.header.Attendance), "Points header sits left of Att.")
assertTrue(rightInset(view.header.Attendance) > rightInset(view.header.Preparedness), "Att. header sits left of Prep.")
assertTrue(rightInset(view.header.Preparedness) > rightInset(view.header.Bis), "Prep. header sits left of BiS")

local sizeHook = content.Scroll.hooks["OnSizeChanged"]
local appliesAfterRender = view._layoutApplyCount
for _ = 1, 30 do
    sizeHook()
end
assertEq(view._layoutApplyCount, appliesAfterRender, "same-width resize does no further layout work")
assertEq(insetUpdates, 1, "same-width resize does not request another scroll-inset update")
assertEq(businessCalls, 0, "resize does not run roster business callbacks")

content.Scroll.width = contentAtMin
sizeHook()
assertEq(view._layoutApplyCount, appliesAfterRender + 1, "a real width change applies layout once")
assertTrue(not view.header.Bis:IsShown(), "minimum width hides the BiS header")
assertTrue(not view.header.Preparedness:IsShown(), "minimum width hides the Prep. header")
assertTrue(not view.header.Attendance:IsShown(), "minimum width hides the Att. header")
assertTrue(view.header.Points:IsShown(), "minimum width keeps the Points header")
assertTrue(row.BtnHelmet:IsShown(), "equipment button remains at the minimum width")
assertTrue(row.Readiness:IsShown(), "readiness remains at the minimum width")
assertTrue(row.Readiness.Icon:IsShown(), "not-ready icon remains at the minimum width")
assertTrue(row.Points:IsShown(), "Points value remains at the minimum width")
assertEq(row.Points:GetText(), "12", "hiding glance columns does not clear Points")
assertTrue(not row.Bis:IsShown() and not row.Preparedness:IsShown() and not row.Attendance:IsShown(), "minimum width hides optional row columns")
assertEq(row.Bis:GetText(), "5/16", "hidden BiS text is kept for when the column returns")
local narrowName = row.Name:GetText()
assertEq(string.sub(narrowName, -3), "...", "minimum width still ellipsizes the raider name")
assertTrue(string.len(narrowName) >= 6, "minimum width keeps at least three name characters")
assertTrue((row.__sfNameWidth or 0) >= nameMin - 0.01, "row name allocation stays at the protected minimum")

local appliesAtMin = view._layoutApplyCount
for _ = 1, 20 do
    sizeHook()
end
assertEq(view._layoutApplyCount, appliesAtMin, "holding the minimum width does not keep laying out")

content.Scroll.width = allWidth + 80
sizeHook()
assertTrue(view.header.Bis:IsShown() and view.header.Preparedness:IsShown() and view.header.Attendance:IsShown(), "widening brings the glance headers back")
assertTrue(row.Bis:IsShown() and row.Preparedness:IsShown() and row.Attendance:IsShown(), "widening brings the glance columns back")
assertEq(row.Bis:GetText(), "5/16", "restored BiS column keeps its value without a model rebuild")
assertEq(row.Points:GetText(), "12", "restored layout keeps Points")
assertTrue(row.BtnHelmet:IsShown() and row.Readiness:IsShown(), "restored layout keeps equipment and readiness")

-- A nested size event during layout must not recurse.
local nested = 0
local originalSetPoint = row.Name.SetPoint
function row.Name:SetPoint(...)
    nested = nested + 1
    if nested == 1 then
        sizeHook()
    end
    return originalSetPoint(self, ...)
end
local beforeNested = view._layoutApplyCount
content.Scroll.width = allWidth + 40
sizeHook()
assertTrue(view._layoutApplyCount <= beforeNested + 2, "nested resize layout stays bounded")
assertTrue(view._layoutApplyCount >= beforeNested + 1, "nested resize still applies the new width")
assertEq(businessCalls, 0, "nested resize still does not run business callbacks")

-- Reward pot hides Points and still keeps the equipment button and readiness.
content.Scroll.width = contentAtMin
local potModel = {
    type = "PROFILE_MEMBER",
    displayName = "Osulivan",
    class = "MAGE",
    showPoints = false,
    attendanceText = "96%",
    preparednessText = "80%",
    bisText = "5/16",
    readinessState = "not_ready",
    memberId = "Osulivan-Area52",
}
view:Render({ potModel }, {})
assertTrue(not row.Points:IsShown(), "reward pot row hides Points")
assertTrue(not view.header.Points:IsShown(), "reward pot header hides Points")
assertTrue(row.BtnHelmet:IsShown(), "reward pot keeps the equipment button")
assertTrue(row.Readiness:IsShown(), "reward pot keeps readiness")
assertEq(string.sub(row.Name:GetText(), 1, 3), "Osu", "reward pot name keeps a three-character prefix")

local beforeStyle = view._layoutApplyCount
view:ApplyStyle("Fonts\\FRIZQT__.TTF", 12)
view:ApplyStyle("Fonts\\FRIZQT__.TTF", 12)
assertEq(view._layoutApplyCount, beforeStyle + 1, "applying a font layouts once")
view:ApplyStyle("Fonts\\FRIZQT__.TTF", 12)
assertEq(view._layoutApplyCount, beforeStyle + 1, "repeating the same font does no further layout")
view:ApplyStyle("Fonts\\FRIZQT__.TTF", 16)
assertEq(view._layoutApplyCount, beforeStyle + 2, "a font size change layouts once")
assertEq(businessCalls, 0, "font changes do not run roster business callbacks")

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
