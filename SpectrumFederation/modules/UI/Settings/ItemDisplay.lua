-- Session-only item names and icons for Raid Supplies lists and the deposit assistant.
-- Authority: campaign and ledger item IDs stay the identity. Names and icons are
-- read from Retail C_Item and are not stored in SavedVariables.
-- Guarantee: a visible row shows the localized name and icon when the client can
-- resolve them. Until then it shows "Loading item…". After one load fails, or the
-- client cannot request data, it shows "Unknown item" and does not invent a name.
-- A later successful ITEM_DATA_LOAD_RESULT for that same item refreshes visible
-- rows when a name is now readable. It does not request the item again.
-- Lifecycle: one ITEM_DATA_LOAD_RESULT frame. Each item is requested at most once
-- per session. Completion coalesces a single refresh for registered consumers.
-- Hidden pages and unrelated item ids do no follow-up work. A callback error
-- restores the dispatch guard before it propagates.
local _, SF = ...

local ItemDisplay = {}
SF.ItemDisplay = ItemDisplay

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"
ItemDisplay.QUESTION_MARK = QUESTION_MARK

local inflight = {}
local failed = {}
local resolved = {}
local listeners = {}
local watchFrame = nil
local watchFramesCreated = 0
local notifyQueued = false
local notifyDepth = 0

local Dispatch

local function Loc(key, default)
    if SF.LocaleText then
        return SF.LocaleText(key, default)
    end
    return default or key
end

local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn and SF.Debug.IsEnabled and SF.Debug:IsEnabled() then
        SF.Debug:Warn("ITEM_DISPLAY", fmt, ...)
    end
end

function ItemDisplay.NormalizeItemId(itemId)
    local id = tonumber(itemId)
    if not id or id ~= id or id == math.huge or id == -math.huge then
        return nil
    end
    if id ~= math.floor(id) or id < 1 or id > 2147483647 then
        return nil
    end
    return id
end

function ItemDisplay.LoadingName()
    return Loc("GUILD_SUPPLIES_ITEM_LOADING", "Loading item…")
end

function ItemDisplay.UnknownName()
    return Loc("GUILD_SUPPLIES_ITEM_UNKNOWN", "Unknown item")
end

function ItemDisplay.ReadCachedName(itemId)
    local id = ItemDisplay.NormalizeItemId(itemId)
    if not id then
        return nil
    end
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, value = pcall(C_Item.GetItemInfo, id)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    if type(GetItemInfo) == "function" then
        local ok, value = pcall(GetItemInfo, id)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function UsableIcon(value)
    if type(value) == "number" then
        if value ~= value or value <= 0 or value == math.huge then
            return nil
        end
        return value
    end
    if type(value) == "string" and value ~= "" and value ~= QUESTION_MARK then
        return value
    end
    return nil
end

-- Icon file data is available from the local item database. Prefer C_Item over
-- the deprecated global GetItemIcon, which is absent or cache-gated on Retail.
function ItemDisplay.ReadIcon(itemId)
    local id = ItemDisplay.NormalizeItemId(itemId)
    if not id then
        return nil
    end
    if C_Item and type(C_Item.GetItemIconByID) == "function" then
        local ok, icon = pcall(C_Item.GetItemIconByID, id)
        if ok then
            local usable = UsableIcon(icon)
            if usable then
                return usable
            end
        end
    end
    if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
        local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, id)
        if ok then
            local usable = UsableIcon(icon)
            if usable then
                return usable
            end
        end
    end
    if type(GetItemIcon) == "function" then
        local ok, icon = pcall(GetItemIcon, id)
        if ok then
            local usable = UsableIcon(icon)
            if usable then
                return usable
            end
        end
    end
    return nil
end

function ItemDisplay.NoteInterest(itemId)
    local id = ItemDisplay.NormalizeItemId(itemId)
    if not id or inflight[id] or resolved[id] or failed[id] then
        return false
    end
    if ItemDisplay.ReadCachedName(id) and ItemDisplay.ReadIcon(id) then
        resolved[id] = true
        return false
    end
    if not (C_Item and type(C_Item.RequestLoadItemDataByID) == "function") then
        resolved[id] = true
        if not ItemDisplay.ReadCachedName(id) then
            failed[id] = true
        end
        return false
    end
    inflight[id] = true
    local ok = pcall(C_Item.RequestLoadItemDataByID, id)
    if not ok then
        inflight[id] = nil
        resolved[id] = true
        if not ItemDisplay.ReadCachedName(id) then
            failed[id] = true
        end
        DebugWarn("RequestLoadItemDataByID failed for item %s", tostring(id))
        return false
    end
    return true
end

function ItemDisplay.Describe(itemId)
    local id = ItemDisplay.NormalizeItemId(itemId)
    if not id then
        return {
            itemId = nil,
            status = "unknown",
            name = ItemDisplay.UnknownName(),
            icon = nil,
        }
    end
    local name = ItemDisplay.ReadCachedName(id)
    local icon = ItemDisplay.ReadIcon(id)
    if name then
        failed[id] = nil
        if icon then
            resolved[id] = true
            inflight[id] = nil
        elseif not resolved[id] and not inflight[id] then
            ItemDisplay.NoteInterest(id)
        end
        return {
            itemId = id,
            status = "ready",
            name = name,
            icon = icon,
        }
    end
    if failed[id] then
        return {
            itemId = id,
            status = "unknown",
            name = ItemDisplay.UnknownName(),
            icon = icon,
        }
    end
    if not resolved[id] then
        ItemDisplay.NoteInterest(id)
    end
    if failed[id] or (resolved[id] and not inflight[id]) then
        return {
            itemId = id,
            status = "unknown",
            name = ItemDisplay.UnknownName(),
            icon = icon,
        }
    end
    return {
        itemId = id,
        status = "loading",
        name = ItemDisplay.LoadingName(),
        icon = icon,
    }
end

-- True when a consumer should refresh. Unrelated item ids stay idle.
-- A failed item stays failed across further failures. A later success with a
-- readable name clears that failure and refreshes once, without another request.
function ItemDisplay.ConsumeLoadResult(itemId, success)
    local id = ItemDisplay.NormalizeItemId(itemId)
    if not id then
        return false
    end
    local wasInflight = inflight[id] and true or false
    local wasFailed = failed[id] and true or false
    if not wasInflight and not wasFailed then
        return false
    end
    inflight[id] = nil
    local name = ItemDisplay.ReadCachedName(id)
    if success ~= false and name then
        failed[id] = nil
        resolved[id] = true
        return true
    end
    if wasInflight then
        resolved[id] = true
        failed[id] = true
        return true
    end
    return false
end

function ItemDisplay.IconOrFallback(itemId)
    local icon = ItemDisplay.ReadIcon(itemId)
    if icon then
        return icon
    end
    ItemDisplay.NoteInterest(itemId)
    return QUESTION_MARK
end

function ItemDisplay.ListenerCount()
    local count = 0
    for _ in pairs(listeners) do
        count = count + 1
    end
    return count
end

function ItemDisplay.WatchFrameCount()
    return watchFramesCreated
end

function ItemDisplay.InFlightCount()
    local count = 0
    for _ in pairs(inflight) do
        count = count + 1
    end
    return count
end

function ItemDisplay.ResetSession()
    inflight = {}
    failed = {}
    resolved = {}
end

Dispatch = function()
    if notifyDepth > 0 then
        return
    end
    notifyDepth = notifyDepth + 1
    local ok, err = pcall(function()
        local passes = 0
        while passes < 2 do
            passes = passes + 1
            notifyQueued = false
            local snapshot = {}
            for _, callback in pairs(listeners) do
                snapshot[#snapshot + 1] = callback
            end
            for i = 1, #snapshot do
                snapshot[i]()
            end
            if not notifyQueued then
                break
            end
        end
    end)
    notifyQueued = false
    notifyDepth = notifyDepth - 1
    if not ok then
        error(err, 0)
    end
end

function ItemDisplay.Notify()
    if notifyQueued or notifyDepth > 0 then
        notifyQueued = true
        return
    end
    notifyQueued = true
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, Dispatch)
    else
        Dispatch()
    end
end

function ItemDisplay.EnsureWatch()
    if watchFrame or type(CreateFrame) ~= "function" then
        return
    end
    local frame = CreateFrame("Frame")
    watchFrame = frame
    ItemDisplay._watchFrame = frame
    watchFramesCreated = watchFramesCreated + 1
    if frame.RegisterEvent then
        frame:RegisterEvent("ITEM_DATA_LOAD_RESULT")
    end
    frame:SetScript("OnEvent", function(_, event, itemId, success)
        if event ~= "ITEM_DATA_LOAD_RESULT" then
            return
        end
        if ItemDisplay.ConsumeLoadResult(itemId, success) then
            ItemDisplay.Notify()
        end
    end)
end

-- ownerKey replaces the previous callback so page reloads do not accumulate.
function ItemDisplay.RegisterRefresh(ownerKey, callback)
    if type(ownerKey) ~= "string" or ownerKey == "" or type(callback) ~= "function" then
        return
    end
    listeners[ownerKey] = callback
    ItemDisplay.EnsureWatch()
end
