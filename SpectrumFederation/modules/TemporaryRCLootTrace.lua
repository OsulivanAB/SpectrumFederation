local addonName, SF = ...

-- TEMPORARY troubleshooting module for RC Loot Council tracing.
-- Remove this file and its TOC entry after troubleshooting is complete.

local Trace = SF.TemporaryRCLootTrace or {}
SF.TemporaryRCLootTrace = Trace

local MAX_TRACE_LINES = 500
local SECONDS_PER_DAY = 86400
local TRACE_CHAT_EVENTS = {
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
}

Trace.lines = Trace.lines or {}
Trace.enabled = Trace.enabled or false

local function TrimText(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function FormatTimestamp()
    local timestamp = (GetServerTime and GetServerTime()) or (time and time()) or 0
    local secondsOfDay = math.floor(timestamp % SECONDS_PER_DAY)
    local hours = math.floor(secondsOfDay / 3600)
    local minutes = math.floor((secondsOfDay % 3600) / 60)
    local seconds = secondsOfDay % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

local function StringLooksRelevant(message)
    if type(message) ~= "string" or message == "" then
        return false
    end

    return message:find("|Hitem:", 1, true) ~= nil
        or message:find(" awarded ", 1, true) ~= nil
        or message:find("awarded with", 1, true) ~= nil
        or message:find("RCLootCouncil", 1, true) ~= nil
        or message:find("loot council", 1, true) ~= nil
end

local function FormatScalar(value)
    local valueType = type(value)
    if valueType == "string" then
        local text = value:gsub("\r", "\\r"):gsub("\n", "\\n")
        if #text > 240 then
            text = text:sub(1, 240) .. "...<trimmed>"
        end
        return text
    end

    return tostring(value)
end

local function FormatValue(value, depth, seen)
    depth = depth or 0
    if depth >= 2 then
        return "{...}"
    end

    local valueType = type(value)
    if valueType ~= "table" then
        return FormatScalar(value)
    end

    seen = seen or {}
    if seen[value] then
        return "{<cycle>}"
    end
    seen[value] = true

    local parts = {}
    local count = 0
    for key, nestedValue in pairs(value) do
        count = count + 1
        if count > 8 then
            parts[#parts + 1] = "..."
            break
        end

        parts[#parts + 1] = tostring(key) .. "=" .. FormatValue(nestedValue, depth + 1, seen)
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

function Trace:AddLine(message, ...)
    local ok, formatted = pcall(string.format, tostring(message or ""), ...)
    if not ok then
        formatted = tostring(message or "")
    end

    self.lines = self.lines or {}
    self.lines[#self.lines + 1] = string.format("[%s] %s", FormatTimestamp(), formatted)

    while #self.lines > MAX_TRACE_LINES do
        table.remove(self.lines, 1)
    end

    if self.frame and self.frame:IsShown() then
        self:RefreshFrameText(true)
    end
end

function Trace:GetText()
    if not self.lines or #self.lines == 0 then
        return "No RC trace lines captured yet."
    end

    return table.concat(self.lines, "\n")
end

function Trace:RefreshFrameText(keepScrollAtBottom)
    if not self.frame or not self.frame.EditBox then
        return
    end

    local editBox = self.frame.EditBox
    local scrollFrame = self.frame.ScrollFrame
    local wasAtBottom = false
    if scrollFrame then
        local current = scrollFrame:GetVerticalScroll() or 0
        local minValue, maxValue = scrollFrame.ScrollBar and scrollFrame.ScrollBar:GetMinMaxValues()
        maxValue = maxValue or 0
        wasAtBottom = current >= math.max(0, maxValue - 4)
    end

    editBox:SetText(self:GetText())
    editBox:HighlightText(0, 0)

    if scrollFrame then
        scrollFrame:UpdateScrollChildRect()
        if keepScrollAtBottom or wasAtBottom then
            local _, maxValue = scrollFrame.ScrollBar and scrollFrame.ScrollBar:GetMinMaxValues()
            scrollFrame:SetVerticalScroll(maxValue or 0)
        else
            scrollFrame:SetVerticalScroll(0)
        end
    end
end

function Trace:EnsureFrame()
    if self.frame then
        return self.frame
    end

    local frame = CreateFrame("Frame", "SFTemporaryRCLootTraceFrame", UIParent, "BackdropTemplate")
    frame:SetSize(900, 520)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
    frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -40, -14)
    title:SetJustifyH("LEFT")
    title:SetText("Temporary RC Loot Trace")
    frame.Title = title

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -6)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Use /sfrctrace to reset and start capture, then /sfrctracelog to open this window and copy the text.")
    frame.Subtitle = subtitle

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    frame.CloseButton = closeButton

    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 14)
    scrollFrame:EnableMouseWheel(true)
    frame.ScrollFrame = scrollFrame

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetAutoFocus(false)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(820)
    editBox:SetTextInsets(8, 8, 8, 8)
    editBox:SetScript("OnEscapePressed", function()
        frame:Hide()
    end)
    editBox:SetScript("OnTextChanged", function(self)
        self:GetParent():UpdateScrollChildRect()
    end)
    scrollFrame:SetScrollChild(editBox)
    frame.EditBox = editBox

    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local step = 40
        local current = self:GetVerticalScroll() or 0
        local nextValue = current - (delta * step)
        if nextValue < 0 then
            nextValue = 0
        end

        local _, maxValue = self.ScrollBar and self.ScrollBar:GetMinMaxValues()
        maxValue = maxValue or 0
        if nextValue > maxValue then
            nextValue = maxValue
        end

        self:SetVerticalScroll(nextValue)
    end)

    self.frame = frame
    self:RefreshFrameText(false)
    return frame
end

function Trace:ShowFrame()
    local frame = self:EnsureFrame()
    self:RefreshFrameText(false)
    frame:Show()
    frame.EditBox:SetFocus()
    frame.EditBox:HighlightText()
end

function Trace:EnsureEventFrame()
    if self.eventFrame then
        return self.eventFrame
    end

    local eventListenerFrame = CreateFrame("Frame")
    eventListenerFrame:SetScript("OnEvent", function(_, event, ...)
        if not Trace.enabled then
            return
        end

        if event == "ADDON_LOADED" then
            local loadedAddon = ...
            if loadedAddon == "RCLootCouncil" then
                Trace:AddLine("Event ADDON_LOADED addon=%s", tostring(loadedAddon))
                Trace:TryHookRCLootCouncil()
            end
            return
        end

        local message, sender = ...
        if StringLooksRelevant(message) then
            Trace:AddLine("Chat %s sender=%s message=%s", tostring(event), FormatScalar(sender), FormatScalar(message))
        end
    end)

    self.eventFrame = eventListenerFrame
    return eventListenerFrame
end

function Trace:TryHookRCLootCouncil()
    if self._sendMessageHooked then
        return true
    end

    local rcLootCouncil = _G and _G.RCLootCouncil
    if type(rcLootCouncil) ~= "table" then
        self:AddLine("RCLootCouncil table not available yet")
        return false
    end

    if type(rcLootCouncil.SendMessage) ~= "function" then
        self:AddLine("RCLootCouncil.SendMessage is %s", tostring(type(rcLootCouncil.SendMessage)))
        return false
    end

    hooksecurefunc(rcLootCouncil, "SendMessage", function(_, messageName, ...)
        if not Trace.enabled then
            return
        end

        local args = {}
        local count = select("#", ...)
        for index = 1, count do
            args[#args + 1] = FormatValue(select(index, ...))
        end

        Trace:AddLine(
            "RCLootCouncil.SendMessage name=%s args=[%s]",
            tostring(messageName),
            table.concat(args, "; ")
        )
    end)

    self._sendMessageHooked = true
    self:AddLine("Hooked RCLootCouncil.SendMessage")
    return true
end

function Trace:InstallSpectrumHooks()
    if not self._sfHandleAwardHooked and type(SF.HandleRCLootCouncilAwardMessage) == "function" then
        hooksecurefunc(SF, "HandleRCLootCouncilAwardMessage", function(_, message, chatEvent)
            if not Trace.enabled then
                return
            end
            Trace:AddLine(
                "SF.HandleRCLootCouncilAwardMessage event=%s message=%s",
                tostring(chatEvent),
                FormatScalar(message)
            )
        end)
        self._sfHandleAwardHooked = true
    end

    if not self._sfProcessAwardHooked and type(SF.ProcessRCLootCouncilAward) == "function" then
        hooksecurefunc(SF, "ProcessRCLootCouncilAward", function(_, payload)
            if not Trace.enabled then
                return
            end

            Trace:AddLine("SF.ProcessRCLootCouncilAward payload=%s", FormatValue(payload))
        end)
        self._sfProcessAwardHooked = true
    end

    if not self._sfTryHooked and type(SF.TryHookRCLootCouncilIntegration) == "function" then
        hooksecurefunc(SF, "TryHookRCLootCouncilIntegration", function()
            if not Trace.enabled then
                return
            end

            Trace:AddLine("SF.TryHookRCLootCouncilIntegration called")
            Trace:TryHookRCLootCouncil()
        end)
        self._sfTryHooked = true
    end

    if not self._sfInitListenerHooked and type(SF.InitRCLootCouncilListener) == "function" then
        hooksecurefunc(SF, "InitRCLootCouncilListener", function()
            if not Trace.enabled then
                return
            end

            Trace:AddLine("SF.InitRCLootCouncilListener called")
        end)
        self._sfInitListenerHooked = true
    end

    if not self._debugLogHooked and SF.Debug and type(SF.Debug.Log) == "function" then
        hooksecurefunc(SF.Debug, "Log", function(_, level, category, message, ...)
            if not Trace.enabled or tostring(category) ~= "RC_LOOT_COUNCIL" then
                return
            end

            local formattedMessage = tostring(message or "")
            if select("#", ...) > 0 then
                local ok, result = pcall(string.format, formattedMessage, ...)
                if ok then
                    formattedMessage = result
                end
            end

            Trace:AddLine("SF.Debug %s/%s %s", tostring(level), tostring(category), TrimText(formattedMessage))
        end)
        self._debugLogHooked = true
    end
end

function Trace:Start()
    self.lines = {}
    self.enabled = true

    self:AddLine("Temporary RC trace started")
    self:AddLine("Addon=%s player=%s", tostring(addonName), tostring(UnitName and UnitName("player") or "unknown"))

    local eventFrame = self:EnsureEventFrame()
    eventFrame:RegisterEvent("ADDON_LOADED")
    for _, eventName in ipairs(TRACE_CHAT_EVENTS) do
        eventFrame:RegisterEvent(eventName)
    end

    self:InstallSpectrumHooks()
    self:TryHookRCLootCouncil()

    local hasListener = type(SF.InitRCLootCouncilListener) == "function"
    local hasHandler = type(SF.HandleRCLootCouncilAwardMessage) == "function"
    local hasProcessor = type(SF.ProcessRCLootCouncilAward) == "function"
    self:AddLine(
        "SpectrumFederation RC methods listener=%s handler=%s processor=%s",
        tostring(hasListener),
        tostring(hasHandler),
        tostring(hasProcessor)
    )

    if SF and type(SF.PrintSuccess) == "function" then
        SF:PrintSuccess("Temporary RC trace started. Reproduce the issue, then use /sfrctracelog to open the copyable log window.")
    end
end

SLASH_SFTEMPORARYRCTRACE1 = "/sfrctrace"
SlashCmdList["SFTEMPORARYRCTRACE"] = function()
    Trace:Start()
end

SLASH_SFTEMPORARYRCTRACELOG1 = "/sfrctracelog"
SlashCmdList["SFTEMPORARYRCTRACELOG"] = function()
    Trace:ShowFrame()
    if SF and type(SF.PrintInfo) == "function" then
        SF:PrintInfo("Temporary RC trace window opened.")
    end
end
