-- modules/LootHelper/Events.lua
local addonName, SF = ...

SF.LootHelperEvents = SF.LootHelperEvents or {}
local E = SF.LootHelperEvents

E._listeners = E._listeners or {}   -- [event] = { {owner=..., fn=...}, ... }
E._hooked = E._hooked or {}       -- tracks hook keys so we never double-hook

-- Register(eventName, fn, owner)
-- fn is called as: fn(owner, eventName, ...)
function E:Register(eventName, fn, owner)
    if type(eventName) ~= "string" or eventName == "" then return end
    if type(fn) ~= "function" then return end

    self._listeners[eventName] = self._listeners[eventName] or {}
    table.insert(self._listeners[eventName], { owner = owner, fn = fn })

    if SF.Debug then
        SF.Debug:Verbose("LH_EVENTS", "Registered listener for event: %s", tostring(eventName))
    end
end

function E:Fire(eventName, ...)
    local list = self._listeners[eventName]
    if not list then return end

    if SF.Debug then
        SF.Debug:Verbose("LH_EVENTS", "Firing event: %s (%d listeners)", tostring(eventName), #list)
    end

    for i = 1, #list do
        local cb = list[i]
        local ok, err = pcall(cb.fn, cb.owner, eventName, ...)
        if not ok then
            if SF.Debug and SF.Debug.Error then
                SF.Debug:Error("LH_EVENTS", "Callback error for %s: %s", tostring(eventName), tostring(err))
            end
        end
    end
end

function E:NotifyDataChanged(reason, payload)
    self:Fire("DATA_CHANGED", reason, payload)
end

-- ===================================================
-- Hook Helpers
-- ===================================================
local function HookOnce(key, tbl, methodName, hookFn)
    if E._hooked[key] then return true end
    if type(tbl) ~= "table" then return false end
    if type(tbl[methodName]) ~= "function" then return false end

    hooksecurefunc(tbl, methodName, hookFn)
    E._hooked[key] = true
    return true
end

function E:_TryHookLootProfile()
    local LP = SF.LootProfile
    if type(LP) ~= "table" then return false end

    local okAny = false

    local function Hook(methodName, reasonPrefix)
        local key = "LootProfile:" .. methodName
        local ok = HookOnce(key, LP, methodName, function(profileSelf, ...)
            local pid = (profileSelf and profileSelf.GetProfileId and profileSelf:GetProfileId()) or nil
            self:NotifyDataChanged(reasonPrefix .. methodName, { profileId = pid })
        end)
        okAny = okAny or ok
    end

    -- Things that should trigger a roster refresh
    Hook("AddMember",       "LP:")
    Hook("AddAdminUser",    "LP:")
    Hook("AddLootLog",      "LP:")
    Hook("MergeLogTables",  "LP:")
    Hook("ImportSnapshot",  "LP:")
    Hook("SetProfileName",  "LP:")
    Hook("SetPointName",    "LP:")

    return okAny
end

function E:_TryHookMember()
    local M = SF.Member
    if type(M) ~= "table" then return false end

    local okAny = false

    local function Hook(methodName, reasonPrefix)
        local key = "Member:" .. methodName
        local ok = HookOnce(key, M, methodName, function(memberSelf, ...)
            local id = (memberSelf and memberSelf.GetFullIdentifier and memberSelf:GetFullIdentifier()) or nil
            self:NotifyDataChanged(reasonPrefix .. methodName, { memberId = id })
        end)
        okAny = okAny or ok
    end

    -- Points / membership-related changes
    Hook("IncrementPoints",       "M:")
    Hook("DecrementPoints",       "M:")
    Hook("ToggleEquipment",       "M:")

    return okAny
end

function E:InitDataHooks()
    if self._initHookTicker then return end

    if SF.Debug then
        SF.Debug:Info("LH_EVENTS", "Initializing data hooks for LootProfile and Member")
    end

    local tries = 0
    local function Try()
        tries = tries +1

        local ok1 = self:_TryHookLootProfile()
        local ok2 = self:_TryHookMember()

        -- Stop retrying once we have at least attempted hooks
        if (ok1 or ok2) or (tries >= 10) then
            if self._initHookTicker and self._initHookTicker.Cancel then
                pcall(function() self._initHookTicker:Cancel() end)
            end
            self._initHookTicker = nil
        end
    end

    Try()
    if C_Timer and C_Timer.NewTicker then
        self._initHookTicker = C_Timer.NewTicker(1.0, Try, 10)
    end
end