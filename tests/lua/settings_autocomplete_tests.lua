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
    function region:SetVerticalScroll() end
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
        function region.ScrollBar:SetValue() end
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
