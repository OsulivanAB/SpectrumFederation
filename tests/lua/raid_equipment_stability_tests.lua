-- Production-Lua stability tests for Raid Equipment refresh/listener lifecycle.
-- Run from the repository root: lua5.1 tests/lua/raid_equipment_stability_tests.lua

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

local now = 0
function GetTime()
    return now
end

local timers = {}
C_Timer = {
    After = function(delay, fn)
        local handle = {
            due = now + (tonumber(delay) or 0),
            fn = fn,
            cancelled = false,
        }
        function handle:Cancel()
            self.cancelled = true
        end
        timers[#timers + 1] = handle
        return handle
    end,
}

local function pendingTimers()
    local count = 0
    for i = 1, #timers do
        if not timers[i].cancelled then
            count = count + 1
        end
    end
    return count
end

local function flushTimers(advance)
    now = now + (tonumber(advance) or 0)
    local safety = 0
    local progressed = true
    while progressed and safety < 80 do
        progressed = false
        safety = safety + 1
        local index = 1
        while index <= #timers do
            local handle = timers[index]
            if handle.cancelled then
                table.remove(timers, index)
            elseif now + 1e-9 >= handle.due then
                table.remove(timers, index)
                handle.fn()
                progressed = true
            else
                index = index + 1
            end
        end
    end
end

GameTooltip = {
    Hide = function() end,
    SetOwner = function() end,
    SetText = function() end,
    AddLine = function() end,
    Show = function() end,
}

local allFrames = {}

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
        minValue = 0,
        maxValue = 0,
    }
    allFrames[#allFrames + 1] = region
    if parent and parent.children then
        parent.children[#parent.children + 1] = region
    end

    function region:GetObjectType()
        return self.kind or "Frame"
    end

    function region:GetParent()
        return self.parent
    end

    function region:SetParent(newParent)
        self.parent = newParent
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
        local oldWidth, oldHeight = self.width, self.height
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
        local wasShown = self.shown
        self.shown = true
        if not wasShown then
            fireEvent(self, "OnShow")
        end
    end

    function region:Hide()
        local wasShown = self.shown
        self.shown = false
        if wasShown then
            fireEvent(self, "OnHide")
        end
    end

    function region:IsShown()
        return self.shown and true or false
    end

    function region:IsVisible()
        return self.shown and true or false
    end

    function region:SetShown(shown)
        if shown then
            self:Show()
        else
            self:Hide()
        end
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

    function region:SetClipsChildren()
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

    function region:SetMaxLines()
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

    function region:SetDesaturated()
    end

    function region:SetBlendMode()
    end

    function region:SetHitRectInsets()
    end

    function region:SetChecked(value)
        self.checked = value and true or false
    end

    function region:GetChecked()
        return self.checked and true or false
    end

    function region:Click()
        if self.scripts.OnClick then
            self.scripts.OnClick(self)
        end
    end

    function region:SetObeyStepOnDrag()
    end

    function region:SetValueStep()
    end

    function region:SetMinMaxValues(minValue, maxValue)
        self.minValue = minValue
        self.maxValue = maxValue
    end

    function region:GetValue()
        return self.value
    end

    function region:SetValue(value)
        self.value = value
        if self.scripts.OnValueChanged then
            self.scripts.OnValueChanged(self, value)
        end
    end

    function region:SetVerticalScroll()
    end

    function region:SetHorizontalScroll()
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

    function region:CreateAnimationGroup()
        local group = {}
        function group:SetLooping()
        end
        function group:CreateAnimation()
            local animation = {}
            function animation:SetOrder()
            end
            function animation:SetFromAlpha()
            end
            function animation:SetToAlpha()
            end
            function animation:SetDuration()
            end
            return animation
        end
        function group:Play()
        end
        function group:Stop()
        end
        function group:IsPlaying()
            return false
        end
        return group
    end

    if template == "UIPanelScrollFrameTemplate" then
        region.ScrollBar = makeRegion("Slider", nil, region)
        region.ScrollBar:SetWidth(20)
    elseif template == "OptionsSliderTemplate" then
        region.Low = makeRegion("FontString", nil, region)
        region.High = makeRegion("FontString", nil, region)
        region.Text = makeRegion("FontString", nil, region)
    elseif template == "UICheckButtonTemplate" then
        region.Text = makeRegion("FontString", nil, region)
        region.checked = false
    end

    return region
end

function CreateFrame(frameType, name, parent, template)
    return makeRegion(frameType or "Frame", name, parent, template)
end

local function collectByKind(kind)
    local found = {}
    for i = 1, #allFrames do
        if allFrames[i].kind == kind then
            found[#found + 1] = allFrames[i]
        end
    end
    return found
end

local capturedErrors = {}
function geterrorhandler()
    return function(message)
        capturedErrors[#capturedErrors + 1] = tostring(message)
    end
end

local SF = {}
SF.SettingsNavigationModel = {
    NormalizePageRelationship = function(page)
        return page.categoryId or page.parentId
    end,
    GetContentPages = function()
        return {}
    end,
}

local autoRefresh = false
SF.SettingsStore = {
    Get = function(_, path)
        if path == "lootHelper.raidCheckAuditAutoRefresh" then
            return autoRefresh
        end
        return nil
    end,
    Set = function(_, path, value)
        if path == "lootHelper.raidCheckAuditAutoRefresh" then
            autoRefresh = value and true or false
        end
    end,
}

local snapshotCalls = 0
local snapshotVersion = 1
local snapshotRows = {
    {
        name = "Freshplayer",
        displayName = "Freshplayer",
        itemLevelText = "600",
        inspectStatus = "ready",
        slots = {},
    },
}

local function makeRows(count)
    local rows = {}
    for index = 1, count do
        rows[index] = {
            name = "Player" .. index,
            displayName = "Player" .. index,
            itemLevelText = tostring(500 + index),
            inspectStatus = "ready",
            slots = {},
        }
    end
    return rows
end

SF.RaidCheck = {
    listeners = {},
    GetTroubleshootingColumns = function()
        return {
            { key = "head", shortLabel = "H", label = "Head" },
            { key = "chest", shortLabel = "C", label = "Chest" },
        }
    end,
    GetTroubleshootingSnapshot = function(self)
        snapshotCalls = snapshotCalls + 1
        return {
            rows = snapshotRows,
            version = snapshotVersion,
            hasActiveProfile = false,
            columns = self:GetTroubleshootingColumns(),
        }
    end,
    RegisterTroubleshootingListener = function(self, key, callback)
        self.listeners[key] = callback
    end,
    UnregisterTroubleshootingListener = function(self, key)
        self.listeners[key] = nil
    end,
    CountTroubleshootingListeners = function(self)
        local count = 0
        for _ in pairs(self.listeners) do
            count = count + 1
        end
        return count
    end,
    SetBackgroundInspectEnabled = function()
    end,
    RequestTroubleshootingRefresh = function()
    end,
}

assert(loadfile("SpectrumFederation/modules/UI/Settings/Style.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Widgets/Section.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/PageBuilder.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Control/Controls.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Registry.lua"))("SpectrumFederation", SF)
assert(loadfile("SpectrumFederation/modules/UI/Settings/Pages/RaidEquipment.lua"))("SpectrumFederation", SF)

local page = SF.SettingsUI.pagesById.raidEquipmentAudit
assertTrue(page ~= nil, "Raid Equipment page registered")

local originalReflow = SF.SettingsUI.PageBuilder.Reflow
local reflowCount = 0
function SF.SettingsUI.PageBuilder:Reflow()
    reflowCount = reflowCount + 1
    if reflowCount > 80 then
        error("PageBuilder:Reflow exceeded 80 (possible layout loop)")
    end
    return originalReflow(self)
end

local function buildPage(opts)
    opts = opts or {}
    autoRefresh = opts.autoRefresh and true or false
    snapshotRows = makeRows(opts.rowCount or 1)
    snapshotVersion = opts.version or 1
    snapshotCalls = 0
    reflowCount = 0
    capturedErrors = {}
    timers = {}
    allFrames = {}
    SF.RaidCheck.listeners = {}

    local panel = CreateFrame("Frame", nil, nil)
    panel:SetSize(opts.width or 1280, opts.height or 720)
    panel.__sfPageLayout = page.layout
    page:Build(panel)
    flushTimers(1)
    return panel, panel.__sfPageBuilder
end

local function findAuditScroll(panel)
    local scrolls = collectByKind("ScrollFrame")
    for i = 1, #scrolls do
        if scrolls[i].parent and scrolls[i].parent ~= panel then
            return scrolls[i]
        end
    end
    return scrolls[1]
end

-- F-01: visible idle page settles after layout.
do
    local panel = buildPage({ rowCount = 1 })
    local scroll = findAuditScroll(panel)
    local callsAfterBuild = snapshotCalls
    local reflowsAfterBuild = reflowCount
    for _ = 1, 8 do
        fireEvent(scroll, "OnSizeChanged", scroll:GetWidth() or 800, scroll:GetHeight() or 400)
        flushTimers(0.2)
    end
    local callsAfterSameSize = snapshotCalls
    local pendingAfterIdle = pendingTimers()
    flushTimers(2)
    assertTrue(callsAfterSameSize - callsAfterBuild <= 2, "same-size OnSizeChanged does not keep refreshing")
    assertEq(snapshotCalls, callsAfterSameSize, "idle time advancement does not refresh Raid Equipment")
    assertEq(pendingAfterIdle, 0, "no refresh remains queued after same-size notifications")
    assertTrue(reflowCount - reflowsAfterBuild <= 4, "idle same-size notifications keep reflow bounded")
end

-- F-01: real width/height changes relayout once then idle.
do
    local panel = buildPage({ rowCount = 20 })
    local scroll = findAuditScroll(panel)
    local callsBefore = snapshotCalls
    scroll:SetWidth(900)
    flushTimers(0.2)
    local afterWidth = snapshotCalls
    flushTimers(2)
    assertTrue(afterWidth >= callsBefore, "width change can schedule a refresh")
    assertEq(snapshotCalls, afterWidth, "width change settles instead of cycling")

    local beforeHeight = snapshotCalls
    scroll:SetHeight(380)
    flushTimers(0.2)
    local afterHeight = snapshotCalls
    flushTimers(2)
    assertTrue(afterHeight >= beforeHeight, "height change can schedule a refresh")
    assertEq(snapshotCalls, afterHeight, "height change settles instead of cycling")
end

-- F-01: 40-player table still becomes idle.
do
    local panel = buildPage({ rowCount = 40 })
    local scroll = findAuditScroll(panel)
    local afterBuild = snapshotCalls
    scroll:SetSize(1000, 500)
    flushTimers(0.2)
    local afterResize = snapshotCalls
    fireEvent(scroll, "OnSizeChanged", 1000, 500)
    fireEvent(scroll, "OnSizeChanged", 1000, 500)
    flushTimers(2)
    assertTrue(afterResize - afterBuild <= 2, "40-player resize refresh stays bounded")
    assertEq(snapshotCalls, afterResize, "40-player table is idle after layout")
    assertTrue(reflowCount <= 40, "40-player layout reflow stays bounded")
end

-- F-04: open/close does not multiply listeners.
do
    local panel = buildPage({ rowCount = 5 })
    assertEq(SF.RaidCheck:CountTroubleshootingListeners(), 1, "visible Raid Equipment registers one listener")
    local listenerMax = 0
    local hiddenOk = true
    local shownOk = true
    for _ = 1, 100 do
        panel:Hide()
        if SF.RaidCheck:CountTroubleshootingListeners() ~= 0 then
            hiddenOk = false
        end
        panel:Show()
        local shownCount = SF.RaidCheck:CountTroubleshootingListeners()
        if shownCount ~= 1 then
            shownOk = false
        end
        if shownCount > listenerMax then
            listenerMax = shownCount
        end
    end
    assertTrue(hiddenOk, "hidden page unregisters the listener on every close")
    assertTrue(shownOk, "shown page registers exactly one listener on every open")
    assertEq(listenerMax, 1, "100 open/close cycles never multiply listeners")
    panel:Hide()
    local hiddenCalls = snapshotCalls
    if SF.RaidCheck._ScheduleTooltipDataRefresh then
        SF.RaidCheck:_ScheduleTooltipDataRefresh()
    end
    local notified = 0
    for _, callback in pairs(SF.RaidCheck.listeners) do
        notified = notified + 1
        callback()
    end
    flushTimers(1)
    assertEq(notified, 0, "hidden page has no troubleshooting listeners to notify")
    assertEq(snapshotCalls, hiddenCalls, "hidden page does not refresh from leftover listeners")
    panel:Show()
    assertEq(SF.RaidCheck:CountTroubleshootingListeners(), 1, "reopening resubscribes a single listener")
end

-- F-07: unexpected refresh errors are observable and do not stick the refresh flag.
do
    local panel, pageBuilder = buildPage({ rowCount = 1 })
    local callsBefore = snapshotCalls
    local originalSnapshot = SF.RaidCheck.GetTroubleshootingSnapshot
    function SF.RaidCheck:GetTroubleshootingSnapshot()
        error("synthetic refresh boom")
    end
    pageBuilder:Refresh()
    assertTrue(#capturedErrors >= 1, "unexpected refresh errors reach geterrorhandler")
    SF.RaidCheck.GetTroubleshootingSnapshot = originalSnapshot
    snapshotVersion = snapshotVersion + 1
    pageBuilder:Refresh()
    flushTimers(0.2)
    assertTrue(snapshotCalls > callsBefore, "refresh flag is cleared after a failure so later refreshes run")
end

-- Fresh SavedVariables / no profile: page builds and idles.
do
    local panel = buildPage({ rowCount = 1 })
    assertEq(#capturedErrors, 0, "fresh install Raid Equipment build does not error")
    local afterBuild = snapshotCalls
    flushTimers(3)
    assertEq(snapshotCalls, afterBuild, "fresh install page does not keep refreshing while idle")
    assertTrue(SF.RaidCheck:CountTroubleshootingListeners() <= 1, "fresh install listener count stays at most one")
end

io.stdout:write(string.format("%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
