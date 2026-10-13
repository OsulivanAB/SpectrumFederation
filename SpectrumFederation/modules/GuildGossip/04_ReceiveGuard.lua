-- Bound AceComm multipart reassembly for the gossip prefix on the *active*
-- LibStub AceComm instance (including a newer copy from another addon).
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

GG._recvGuard = GG._recvGuard or {
    installed = false,
    aceComm = nil,
    partials = {}, -- [key] = { bytes, fragments, lastAt, lastProgressAt }
    partialBytes = 0,
    partialCount = 0,
    expiryTimer = nil,
    lifecycleFrame = nil,
}

local function partialKey(prefix, distribution, sender)
    return tostring(prefix) .. "\t" .. tostring(distribution) .. "\t" .. tostring(sender)
end

local function clearPhysicalSpool(st, key)
    local ace = st.aceComm
    if ace and ace.multipart_spool then
        ace.multipart_spool[key] = nil
    end
end

local function releasePartial(st, key)
    local p = st.partials[key]
    if not p then
        clearPhysicalSpool(st, key)
        return
    end
    st.partialBytes = math.max(0, (st.partialBytes or 0) - (p.bytes or 0))
    st.partialCount = math.max(0, (st.partialCount or 0) - 1)
    st.partials[key] = nil
    clearPhysicalSpool(st, key)
end

local function ensurePartialExpiry(st)
    if not next(st.partials) then
        if st.expiryTimer and st.expiryTimer.Cancel then
            pcall(function() st.expiryTimer:Cancel() end)
        end
        st.expiryTimer = nil
        return
    end
    if st.expiryTimer or not (C_Timer and C_Timer.NewTimer) then
        return
    end
    st.expiryTimer = C_Timer.NewTimer(GG.REASSEMBLY_IDLE_SEC, function()
        st.expiryTimer = nil
        GG.ExpireStalePartials(GG._Now())
        ensurePartialExpiry(st)
    end)
end

function GG.ExpireStalePartials(now)
    local st = GG._recvGuard
    now = now or GG._Now()
    local idle = GG.REASSEMBLY_IDLE_SEC
    local keys = {}
    for key, p in pairs(st.partials) do
        local last = p.lastProgressAt or p.lastAt or 0
        if (now - last) >= idle then
            keys[#keys + 1] = key
        end
    end
    for i = 1, #keys do
        releasePartial(st, keys[i])
        GG._DVerbose("Reassembly expired key=%s", keys[i])
    end
    ensurePartialExpiry(st)
end

function GG.ClearAllPartials()
    local st = GG._recvGuard
    local keys = {}
    for key in pairs(st.partials) do
        keys[#keys + 1] = key
    end
    for i = 1, #keys do
        releasePartial(st, keys[i])
    end
    st.partials = {}
    st.partialBytes = 0
    st.partialCount = 0
    ensurePartialExpiry(st)
end

local function admitFragment(st, key, addBytes, now)
    GG.ExpireStalePartials(now)
    local p = st.partials[key]
    local progress = (addBytes or 0) > 0
    if not p then
        if (st.partialCount or 0) >= GG.MAX_PARTIAL_MESSAGES then
            return false, "partial count cap"
        end
        if addBytes > GG.MAX_PARTIAL_BYTES_EACH then
            return false, "partial each cap"
        end
        if (st.partialBytes or 0) + addBytes > GG.MAX_PARTIAL_BYTES_TOTAL then
            return false, "partial total cap"
        end
        st.partials[key] = {
            bytes = addBytes,
            fragments = 1,
            lastAt = now,
            lastProgressAt = now,
        }
        st.partialCount = (st.partialCount or 0) + 1
        st.partialBytes = (st.partialBytes or 0) + addBytes
        ensurePartialExpiry(st)
        return true, nil
    end

    local nextFrags = (p.fragments or 0) + 1
    if nextFrags > (GG.MAX_PARTIAL_FRAGMENTS or 32) then
        releasePartial(st, key)
        return false, "partial fragment cap"
    end

    local nextBytes = (p.bytes or 0) + addBytes
    if nextBytes > GG.MAX_PARTIAL_BYTES_EACH then
        releasePartial(st, key)
        return false, "partial each cap"
    end
    if (st.partialBytes or 0) - (p.bytes or 0) + nextBytes > GG.MAX_PARTIAL_BYTES_TOTAL then
        releasePartial(st, key)
        return false, "partial total cap"
    end
    st.partialBytes = (st.partialBytes or 0) - (p.bytes or 0) + nextBytes
    p.bytes = nextBytes
    p.fragments = nextFrags
    p.lastAt = now
    if progress then
        p.lastProgressAt = now
    end
    ensurePartialExpiry(st)
    return true, nil
end

function GG.InstallReceiveGuard(aceComm)
    local st = GG._recvGuard
    if not aceComm then
        return false
    end
    if st.installed and st.aceComm == aceComm and aceComm._SF_GG_RecvGuard
        and aceComm.OnReceiveMultipartFirst == st.wrapperFirst
        and aceComm.OnReceiveMultipartNext == st.wrapperNext
        and aceComm.OnReceiveMultipartLast == st.wrapperLast then
        return true
    end

    -- Switching LibStub instances abandons the prior physical spool; reset
    -- accounting so caps remain meaningful on the active table.
    if st.aceComm and st.aceComm ~= aceComm then
        GG.ClearAllPartials()
    end

    local prefix = GG.PREFIX
    local origFirst = aceComm.OnReceiveMultipartFirst
    local origNext = aceComm.OnReceiveMultipartNext
    local origLast = aceComm.OnReceiveMultipartLast

    if type(origFirst) ~= "function" or type(origNext) ~= "function" or type(origLast) ~= "function" then
        GG._DWarn("AceComm multipart hooks unavailable; cannot install receive guard")
        return false
    end

    local wrapperFirst = function(self, pfx, message, distribution, sender)
        if pfx ~= prefix then
            return origFirst(self, pfx, message, distribution, sender)
        end
        local key = partialKey(pfx, distribution, sender)
        local ok, err = admitFragment(st, key, #(message or ""), GG._Now())
        if not ok then
            GG._DVerbose("Drop gossip multipart FIRST (%s)", tostring(err))
            releasePartial(st, key)
            return
        end
        return origFirst(self, pfx, message, distribution, sender)
    end

    local wrapperNext = function(self, pfx, message, distribution, sender)
        if pfx ~= prefix then
            return origNext(self, pfx, message, distribution, sender)
        end
        local key = partialKey(pfx, distribution, sender)
        if not st.partials[key] then
            return
        end
        local ok, err = admitFragment(st, key, #(message or ""), GG._Now())
        if not ok then
            GG._DVerbose("Drop gossip multipart NEXT (%s)", tostring(err))
            releasePartial(st, key)
            return
        end
        return origNext(self, pfx, message, distribution, sender)
    end

    local wrapperLast = function(self, pfx, message, distribution, sender)
        if pfx ~= prefix then
            return origLast(self, pfx, message, distribution, sender)
        end
        local key = partialKey(pfx, distribution, sender)
        if not st.partials[key] then
            return
        end
        local ok, err = admitFragment(st, key, #(message or ""), GG._Now())
        -- Always release accounting; LAST either completes or is dropped.
        local ace = st.aceComm
        if not ok then
            GG._DVerbose("Drop gossip multipart LAST (%s)", tostring(err))
            releasePartial(st, key)
            return
        end
        -- Clear our accounting before AceComm completes (it clears its spool).
        local p = st.partials[key]
        if p then
            st.partialBytes = math.max(0, (st.partialBytes or 0) - (p.bytes or 0))
            st.partialCount = math.max(0, (st.partialCount or 0) - 1)
            st.partials[key] = nil
        end
        ensurePartialExpiry(st)
        return origLast(self, pfx, message, distribution, sender)
    end

    aceComm.OnReceiveMultipartFirst = wrapperFirst
    aceComm.OnReceiveMultipartNext = wrapperNext
    aceComm.OnReceiveMultipartLast = wrapperLast
    aceComm._SF_GG_RecvGuard = true
    st.aceComm = aceComm
    st.installed = true
    st.wrapperFirst = wrapperFirst
    st.wrapperNext = wrapperNext
    st.wrapperLast = wrapperLast
    GG._DInfo("Gossip receive guard installed on AceComm instance %s", tostring(aceComm))
    return true
end

-- Rebind the LibStub-selected AceComm without forcing callers to know about it.
function GG.EnsureReceiveGuard()
    if not LibStub then
        return false
    end
    local AceComm = LibStub("AceComm-3.0", true)
    if not AceComm then
        return false
    end
    return GG.InstallReceiveGuard(AceComm)
end

-- Late load-on-demand addons can upgrade AceComm after PLAYER_LOGIN. Re-check
-- wrappers on ADDON_LOADED; InstallReceiveGuard is idempotent when unchanged.
function GG.InitReceiveGuardLifecycle()
    local st = GG._recvGuard
    if st.lifecycleFrame then
        return true
    end
    if not CreateFrame then
        return false
    end
    local frame = CreateFrame("Frame", "SFGuildGossipReceiveGuard")
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(_, event)
        if event ~= "ADDON_LOADED" then
            return
        end
        GG.EnsureReceiveGuard()
    end)
    st.lifecycleFrame = frame
    return true
end

function GG.GetReceiveGuardStats()
    local st = GG._recvGuard
    local physical = 0
    if st.aceComm and st.aceComm.multipart_spool then
        for key, v in pairs(st.aceComm.multipart_spool) do
            if type(key) == "string" and key:sub(1, #GG.PREFIX) == GG.PREFIX then
                if type(v) == "table" then
                    physical = physical + #v
                elseif v ~= nil then
                    physical = physical + 1
                end
            end
        end
    end
    return {
        partialCount = st.partialCount or 0,
        partialBytes = st.partialBytes or 0,
        physicalFragments = physical,
        installed = st.installed and true or false,
        aceComm = st.aceComm,
    }
end
