-- Focused Settings autocomplete dropdown behavior:
-- empty focus, filtering, height cap + scroll, selection dismiss.
-- Run from repository root: lua5.1 tests/lua/settings_autocomplete_tests.lua

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

_G = _G or {}
UIParent = UIParent or {}
strtrim = strtrim or function(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$")) or ""
end

-- Deferred timers so focus-loss delay and MouseUp After(0) ordering can be tested.
local timerQueue = {}
C_Timer = {
    After = function(delay, fn)
        if type(fn) == "function" then
            timerQueue[#timerQueue + 1] = { delay = tonumber(delay) or 0, fn = fn }
        end
    end,
}
local function flushTimers(maxDelay)
    maxDelay = tonumber(maxDelay) or math.huge
    local keep = {}
    local run = {}
    for i = 1, #timerQueue do
        local entry = timerQueue[i]
        if entry.delay <= maxDelay then
            run[#run + 1] = entry
        else
            keep[#keep + 1] = entry
        end
    end
    table.sort(run, function(a, b)
        return a.delay < b.delay
    end)
    timerQueue = keep
    for i = 1, #run do
        run[i].fn()
    end
end

local created = {}

local function makeRegion(objectType, name, parent, template)
    local region = {
        objectType = objectType or "Frame",
        name = name,
        parent = parent,
        template = template,
        _scripts = {},
        _hooks = {},
        _points = {},
        _text = "",
        _shown = true,
        _width = 240,
        _height = 22,
        _alpha = 1,
        _children = {},
        focused = false,
        _scroll = 0,
        _value = 0,
        ScrollBar = nil,
        scrollChild = nil,
        Instructions = nil,
    }
    function region:GetObjectType()
        return self.objectType
    end
    function region:SetParent(p)
        self.parent = p
    end
    function region:GetParent()
        return self.parent
    end
    function region:SetSize(w, h)
        self._width = w
        self._height = h
    end
    function region:SetWidth(w)
        self._width = w
    end
    function region:SetHeight(h)
        self._height = h
    end
    function region:GetWidth()
        return self._width or 0
    end
    function region:GetHeight()
        return self._height or 0
    end
    function region:SetPoint(anchor, rel, relAnchor, x, y)
        self._points[#self._points + 1] = {
            anchor = anchor,
            rel = rel,
            relAnchor = relAnchor,
            x = x,
            y = y,
        }
    end
    function region:ClearAllPoints()
        self._points = {}
    end
    function region:Show()
        self._shown = true
    end
    function region:Hide()
        self._shown = false
    end
    function region:IsShown()
        return self._shown and true or false
    end
    function region:SetShown(v)
        self._shown = v and true or false
    end
    function region:SetText(t)
        self._text = tostring(t or "")
    end
    function region:GetText()
        return self._text
    end
    function region:SetTextColor() end
    function region:SetHighlightColor() end
    function region:SetAutoFocus() end
    function region:SetMaxLetters() end
    function region:Enable() end
    function region:Disable() end
    function region:EnableMouse() end
    function region:SetAlpha(a)
        self._alpha = a
    end
    function region:SetScript(ev, fn)
        self._scripts[ev] = fn
    end
    function region:GetScript(ev)
        return self._scripts[ev]
    end
    function region:HookScript(ev, fn)
        self._hooks[ev] = self._hooks[ev] or {}
        self._hooks[ev][#self._hooks[ev] + 1] = fn
    end
    function region:HasFocus()
        return self.focused
    end
    function region:SetFocus()
        self.focused = true
        local fn = self._scripts.OnEditFocusGained
        if fn then
            fn(self)
        end
    end
    function region:ClearFocus()
        self.focused = false
        local fn = self._scripts.OnEditFocusLost
        if fn then
            fn(self)
        end
    end
    function region:SetCursorPosition() end
    function region:GetCursorPosition()
        return 0
    end
    function region:SetFrameStrata() end
    function region:SetClampedToScreen() end
    function region:SetScrollChild(child)
        self.scrollChild = child
    end
    function region:SetVerticalScroll(v)
        self._scroll = tonumber(v) or 0
    end
    function region:GetVerticalScroll()
        return self._scroll or 0
    end
    function region:SetValue(v)
        self._value = tonumber(v) or 0
    end
    function region:GetValue()
        return self._value or 0
    end
    function region:SetJustifyH() end
    function region:SetWordWrap() end
    function region:GetStringHeight()
        return 12
    end
    function region:GetStringWidth()
        return 40
    end
    function region:SetColorTexture() end
    function region:SetAllPoints() end
    function region:SetBackdrop() end
    function region:SetBackdropColor() end
    function region:SetBackdropBorderColor() end
    function region:CreateFontString()
        return makeRegion("FontString", nil, self)
    end
    function region:CreateTexture()
        return makeRegion("Texture", nil, self)
    end
    function region:TypeText(text)
        self._text = tostring(text or "")
        local fn = self._scripts.OnTextChanged
        if fn then
            fn(self, true)
        end
    end
    function region:Click()
        local fn = self._scripts.OnClick
        if fn then
            fn(self)
        end
    end
    if template and tostring(template):find("ScrollFrame", 1, true) then
        region.ScrollBar = makeRegion("Slider", nil, region)
        region.ScrollBar:SetWidth(18)
        region.ScrollBar._shown = false
        function region.ScrollBar:SetShown(v)
            self._shown = v and true or false
        end
        function region.ScrollBar:IsShown()
            return self._shown
        end
        function region.ScrollBar:Enable() end
        function region.ScrollBar:Disable() end
    end
    if template and tostring(template):find("InputBox", 1, true) then
        region.objectType = "EditBox"
        region.Instructions = makeRegion("FontString", nil, region)
        function region.Instructions:SetText(t)
            self._text = tostring(t or "")
        end
    end
    created[#created + 1] = region
    return region
end

function CreateFrame(frameType, name, parent, template)
    return makeRegion(frameType or "Frame", name, parent, template)
end

UIParent = makeRegion("Frame", "UIParent")

-- Minimal Controls host: Style OpaqueMenu + Controls AddAutocomplete only.
local SF = {
    SettingsUI = {},
    SettingsStore = {
        Get = function()
            return nil
        end,
        Set = function() end,
    },
}

do
    local chunk = assert(loadfile("SpectrumFederation/modules/UI/Settings/Style.lua"))
    chunk("SpectrumFederation", SF)
end

-- Stub InitRow / AddRow / RegisterRefresh / ResolveGetSet dependencies used by Controls.
-- Load Controls after installing a tiny Section shim via first AddAutocomplete call path.
local controlsChunk = assert(loadfile("SpectrumFederation/modules/UI/Settings/Control/Controls.lua"))
controlsChunk("SpectrumFederation", SF)
local Controls = SF.SettingsUI.Controls
assertTrue(type(Controls) == "table" and type(Controls.AddAutocomplete) == "function",
    "Controls:AddAutocomplete available")

-- Provide the private helpers AddAutocomplete needs through a fake section.
local refreshFns = {}
local function makeSection()
    return {
        __sfPageBuilder = {
            RegisterRefresh = function(_, fn)
                refreshFns[#refreshFns + 1] = fn
            end,
        },
        AddRow = function(_, _height, builder)
            local row = makeRegion("Frame", nil, UIParent)
            -- InitRow is called inside builder; patch Controls methods used there.
            builder(row)
            return row
        end,
        RequestReflow = function() end,
    }
end

-- Patch InitRow / _ApplyRowState if needed by invoking through real Controls.
-- Controls:InitRow expects section layout helpers; provide a lightweight stand-in.
local origInitRow = Controls.InitRow
Controls.InitRow = function(self, row, opts)
    local control = makeRegion("Frame", nil, row)
    control:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.__sfLabel = makeRegion("FontString", nil, row)
    return row.__sfLabel, control
end
Controls._ApplyRowState = function()
    return true, true
end

local names = {}
for i = 1, 40 do
    names[i] = string.format("Player%02d-Garona", i)
end

local function suggestionsFor(prefix)
    local q = string.lower(strtrim(prefix or ""))
    local out = {}
    if q == "" then
        return out
    end
    for i = 1, #names do
        local name = names[i]
        if string.find(string.lower(name), q, 1, true) then
            out[#out + 1] = { value = name, label = name, text = name }
        end
    end
    return out
end

local textValue = ""
local resolved = nil
local section = makeSection()
Controls:AddAutocomplete(section, {
    label = "Find",
    width = 240,
    maxSuggestions = 48,
    maxDropdownHeight = 220,
    emptySuggestionsText = "No matches",
    get = function()
        return textValue
    end,
    set = function(v)
        textValue = tostring(v or "")
    end,
    getSuggestions = suggestionsFor,
    onResolved = function(item)
        resolved = item
    end,
})

local edit, drop, showFn, hideFn
for i = 1, #created do
    local obj = created[i]
    if obj.objectType == "EditBox" then
        edit = obj
    end
end
-- Row stores helpers after AddAutocomplete.
for i = 1, #created do
    local obj = created[i]
    if obj.__sfAutocompleteEdit then
        edit = obj.__sfAutocompleteEdit
        drop = obj.__sfAutocompleteDrop
        showFn = obj.__sfAutocompleteShow
        hideFn = obj.__sfAutocompleteHide
        break
    end
end

assertTrue(edit ~= nil, "autocomplete edit created")
assertTrue(drop ~= nil, "autocomplete drop created")
assertTrue(type(showFn) == "function", "ShowSuggestions helper exposed")

-- Empty focus must not open the dropdown.
edit:SetFocus()
assertTrue(not drop:IsShown(), "empty focus keeps dropdown hidden")

-- Whitespace-only typing stays closed.
edit:TypeText("   ")
assertTrue(not drop:IsShown(), "whitespace typing keeps dropdown hidden")

-- Typing a prefix opens a height-capped dropdown.
edit:TypeText("player")
assertTrue(drop:IsShown(), "nonempty typing opens dropdown")
assertTrue((drop:GetHeight() or 0) <= 220, "dropdown height <= 220")
assertTrue((drop:GetHeight() or 0) >= 80, "dropdown height is usable")
assertEq(drop:GetWidth(), edit:GetWidth(), "dropdown width matches search field")

-- Many matches: scrollbar shown (content taller than cap).
local sb = nil
for i = 1, #created do
    local obj = created[i]
    if obj.template and tostring(obj.template):find("ScrollFrame", 1, true) then
        sb = obj.ScrollBar
        break
    end
end
assertTrue(sb ~= nil, "scroll frame present for suggestions")
assertTrue(sb:IsShown(), "scrollbar shown for overflowing suggestion list")

-- Unmatched query shows empty-results state rather than vanishing without feedback.
edit:TypeText("zzzz-nomatch")
assertTrue(drop:IsShown(), "unmatched query shows empty-results dropdown")
assertTrue((drop:GetHeight() or 0) <= 220, "empty-results dropdown stays capped")

-- Clearing closes suggestions.
edit:TypeText("")
assertTrue(not drop:IsShown(), "clearing the field closes dropdown")

-- Selection closes dropdown and resolves.
edit:TypeText("Player01")
assertTrue(drop:IsShown(), "prefix reopen works after clear")
local clicked = false
for i = 1, #created do
    local obj = created[i]
    if obj.objectType == "Button" and obj.Text and obj.Text._text == "Player01-Garona" and obj._scripts.OnClick then
        if obj._scripts.OnMouseDown then
            obj._scripts.OnMouseDown(obj)
        end
        obj:Click()
        clicked = true
        break
    end
end
-- Fallback: Text may store via SetText on FontString as _text
if not clicked then
    for i = 1, #created do
        local obj = created[i]
        if obj.objectType == "Button" and obj.Text and tostring(obj.Text._text or obj.Text:GetText()) == "Player01-Garona" then
            if obj._scripts.OnMouseDown then
                obj._scripts.OnMouseDown(obj)
            end
            obj:Click()
            clicked = true
            break
        end
    end
end
assertTrue(clicked, "suggestion button clicked")
assertTrue(not drop:IsShown(), "selecting a suggestion closes dropdown")
assertTrue(resolved ~= nil and resolved.value == "Player01-Garona", "selection resolves chosen character")
flushTimers() -- drain deferred MouseUp / focus-loss work from the click

local scrollFrame = nil
for i = 1, #created do
    local obj = created[i]
    if obj.__sfAutocompleteScroll then
        scrollFrame = obj.__sfAutocompleteScroll
        break
    end
end
assertTrue(scrollFrame ~= nil, "autocomplete scroll frame exposed on row")

local function findSuggestionButton(label)
    for i = 1, #created do
        local obj = created[i]
        if obj.objectType == "Button" and obj.Text then
            local text = tostring(obj.Text._text or (obj.Text.GetText and obj.Text:GetText()) or "")
            if text == label and obj._scripts.OnMouseDown then
                return obj
            end
        end
    end
    return nil
end

-- Held press across the focus-loss delay must still select on release/click.
resolved = nil
edit:TypeText("Player02")
assertTrue(drop:IsShown(), "held-press setup opens dropdown")
local heldBtn = findSuggestionButton("Player02-Garona")
assertTrue(heldBtn ~= nil, "held-press target suggestion exists")
heldBtn._scripts.OnMouseDown(heldBtn)
edit:ClearFocus()
assertTrue(not edit:HasFocus(), "edit loses focus while suggestion is held")
flushTimers(0.15)
assertTrue(drop:IsShown(), "focus-loss timer keeps dropdown open while press is held")
assertTrue(resolved == nil, "held press does not resolve before release")
heldBtn:Click()
if heldBtn._scripts.OnMouseUp then
    heldBtn._scripts.OnMouseUp(heldBtn)
end
flushTimers()
assertTrue(not drop:IsShown(), "held press selects and closes dropdown after release")
assertTrue(resolved ~= nil and resolved.value == "Player02-Garona", "held press resolves chosen character")

-- Cancelled suggestion press: MouseDown, drag away, MouseUp without OnClick.
resolved = nil
edit:TypeText("Player03")
assertTrue(drop:IsShown(), "cancelled-click setup opens dropdown")
local cancelBtn = findSuggestionButton("Player03-Garona")
assertTrue(cancelBtn ~= nil, "cancelled-click target suggestion exists")
cancelBtn._scripts.OnMouseDown(cancelBtn)
edit:ClearFocus()
assertTrue(not edit:HasFocus(), "edit loses focus after cancelled press starts")
flushTimers(0.15)
assertTrue(drop:IsShown(), "focus-loss timer does not treat held cancel as finished")
-- Release outside the button (no OnClick). Deferred MouseUp clears the guard.
cancelBtn._scripts.OnMouseUp(cancelBtn)
flushTimers(0)
assertTrue(not drop:IsShown(), "cancelled suggestion press dismisses dropdown after MouseUp")
assertTrue(resolved == nil, "cancelled suggestion press does not resolve")

-- Normal quick click still selects.
resolved = nil
edit:TypeText("Player04")
assertTrue(drop:IsShown(), "quick-click setup opens dropdown")
local quickBtn = findSuggestionButton("Player04-Garona")
assertTrue(quickBtn ~= nil, "quick-click target exists")
quickBtn._scripts.OnMouseDown(quickBtn)
quickBtn:Click()
if quickBtn._scripts.OnMouseUp then
    quickBtn._scripts.OnMouseUp(quickBtn)
end
flushTimers()
assertTrue(not drop:IsShown(), "quick click closes dropdown")
assertTrue(resolved ~= nil and resolved.value == "Player04-Garona", "quick click resolves chosen character")

-- Outside click (focus loss without a suggestion press) dismisses suggestions.
resolved = nil
edit:TypeText("Player05")
assertTrue(drop:IsShown(), "outside-click setup opens dropdown")
edit:ClearFocus()
flushTimers(0.15)
assertTrue(not drop:IsShown(), "outside click dismisses suggestions after focus-loss delay")
assertTrue(resolved == nil, "outside click does not resolve a suggestion")

-- Scroll position resets when suggestion results change.
edit:TypeText("player")
assertTrue(drop:IsShown(), "scroll-reset large list opens")
assertTrue(scrollFrame.ScrollBar and scrollFrame.ScrollBar:IsShown(), "large list shows scrollbar")
scrollFrame:SetVerticalScroll(120)
scrollFrame.ScrollBar:SetValue(120)
assertEq(scrollFrame:GetVerticalScroll(), 120, "scroll primed away from top")

-- large → large (still overflowing; "playe" still matches all 40)
edit:TypeText("playe")
assertEq(scrollFrame:GetVerticalScroll(), 0, "large-to-large resets vertical scroll")
assertEq(scrollFrame.ScrollBar:GetValue(), 0, "large-to-large resets scrollbar value")
assertTrue(scrollFrame.ScrollBar:IsShown(), "large-to-large keeps scrollbar")
assertTrue((drop:GetHeight() or 0) <= 220, "large-to-large keeps height cap")

-- large → small (fits without scrollbar)
scrollFrame:SetVerticalScroll(80)
scrollFrame.ScrollBar:SetValue(80)
edit:TypeText("Player01")
assertEq(scrollFrame:GetVerticalScroll(), 0, "large-to-small resets vertical scroll")
assertEq(scrollFrame.ScrollBar:GetValue(), 0, "large-to-small resets scrollbar value")
assertTrue(not scrollFrame.ScrollBar:IsShown(), "large-to-small hides scrollbar")
assertTrue(drop:IsShown(), "large-to-small keeps dropdown open")

-- large → no results
edit:TypeText("player")
scrollFrame:SetVerticalScroll(90)
scrollFrame.ScrollBar:SetValue(90)
edit:TypeText("zzzz-nomatch")
assertEq(scrollFrame:GetVerticalScroll(), 0, "large-to-empty resets vertical scroll")
assertEq(scrollFrame.ScrollBar:GetValue(), 0, "large-to-empty resets scrollbar value")
assertTrue(drop:IsShown(), "large-to-empty keeps empty-results dropdown")
assertTrue((drop:GetHeight() or 0) <= 220, "large-to-empty stays height-capped")

-- allowEmptyPrefix still supports Guild Supplies-style empty menus.
created = {}
textValue = ""
section = makeSection()
Controls:AddAutocomplete(section, {
    label = "Attr",
    width = 220,
    maxSuggestions = 8,
    allowEmptyPrefix = true,
    get = function()
        return textValue
    end,
    set = function(v)
        textValue = tostring(v or "")
    end,
    getSuggestions = function(prefix)
        local q = string.lower(strtrim(prefix or ""))
        if q == "" then
            return { { value = false, label = "Unassigned", text = "" } }
        end
        return {}
    end,
})
edit, drop = nil, nil
for i = 1, #created do
    local obj = created[i]
    if obj.__sfAutocompleteEdit then
        edit = obj.__sfAutocompleteEdit
        drop = obj.__sfAutocompleteDrop
        break
    end
end
edit:SetFocus()
assertTrue(drop:IsShown(), "allowEmptyPrefix opens on empty focus")

io.stdout:write(string.format("\n%d passed, %d failed\n", passes, failures))
if failures > 0 then
    os.exit(1)
end
os.exit(0)
