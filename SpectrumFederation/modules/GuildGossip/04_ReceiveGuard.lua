-- Bound AceComm multipart reassembly for the gossip prefix on the *active*
-- LibStub AceComm instance (including a newer copy from another addon).
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

GG._recvGuard = GG._recvGuard or {
    installed = false,
    aceComm = nil,
    partials = {}, -- [key] = { bytes = n, parts = {...}|string, lastAt = t }
    partialBytes = 0,
    partialCount = 0,
}

local function partialKey(prefix, distribution, sender)
    return tostring(prefix) .. "\t" .. tostring(distribution) .. "\t" .. tostring(sender)
end

local function releasePartial(st, key)
    local p = st.partials[key]
    if not p then
        return
    end
    st.partialBytes = math.max(0, (st.partialBytes or 0) - (p.bytes or 0))
    st.partialCount = math.max(0, (st.partialCount or 0) - 1)
    st.partials[key] = nil
end

function GG.ExpireStalePartials(now)
    local st = GG._recvGuard
    now = now or GG._Now()
    local idle = GG.REASSEMBLY_IDLE_SEC
    local keys = {}
    for key, p in pairs(st.partials) do
        if (now - (p.lastAt or 0)) >= idle then
            keys[#keys + 1] = key
        end
    end
    for i = 1, #keys do
        releasePartial(st, keys[i])
        GG._DVerbose("Reassembly expired key=%s", keys[i])
    end
end

function GG.ClearAllPartials()
    local st = GG._recvGuard
    st.partials = {}
    st.partialBytes = 0
    st.partialCount = 0
end

local function admitFragment(st, key, addBytes, now)
    GG.ExpireStalePartials(now)
    local p = st.partials[key]
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
        st.partials[key] = { bytes = addBytes, lastAt = now, started = true }
        st.partialCount = (st.partialCount or 0) + 1
        st.partialBytes = (st.partialBytes or 0) + addBytes
        return true, nil
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
    p.lastAt = now
    return true, nil
end

-- Install wrappers on the AceComm table returned by LibStub("AceComm-3.0").
-- Re-run after Init so a newer library wins; always wrap the live instance.
function GG.InstallReceiveGuard(aceComm)
    local st = GG._recvGuard
    if not aceComm then
        return false
    end
    -- Already wrapping this exact instance.
    if st.installed and st.aceComm == aceComm and aceComm._SF_GG_RecvGuard then
        return true
    end

    local prefix = GG.PREFIX
    local origFirst = aceComm.OnReceiveMultipartFirst
    local origNext = aceComm.OnReceiveMultipartNext
    local origLast = aceComm.OnReceiveMultipartLast

    if type(origFirst) ~= "function" or type(origNext) ~= "function" or type(origLast) ~= "function" then
        GG._DWarn("AceComm multipart hooks unavailable; cannot install receive guard")
        return false
    end

    -- Preserve any prior SF wrapper when re-installing on a new instance.
    aceComm.OnReceiveMultipartFirst = function(self, pfx, message, distribution, sender)
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

    aceComm.OnReceiveMultipartNext = function(self, pfx, message, distribution, sender)
        if pfx ~= prefix then
            return origNext(self, pfx, message, distribution, sender)
        end
        local key = partialKey(pfx, distribution, sender)
        if not st.partials[key] then
            -- No admitted FIRST; ignore.
            return
        end
        local ok, err = admitFragment(st, key, #(message or ""), GG._Now())
        if not ok then
            GG._DVerbose("Drop gossip multipart NEXT (%s)", tostring(err))
            -- Best-effort clear AceComm spool for this key.
            if aceComm.multipart_spool then
                aceComm.multipart_spool[key] = nil
            end
            return
        end
        return origNext(self, pfx, message, distribution, sender)
    end

    aceComm.OnReceiveMultipartLast = function(self, pfx, message, distribution, sender)
        if pfx ~= prefix then
            return origLast(self, pfx, message, distribution, sender)
        end
        local key = partialKey(pfx, distribution, sender)
        if not st.partials[key] then
            return
        end
        local ok, err = admitFragment(st, key, #(message or ""), GG._Now())
        releasePartial(st, key)
        if not ok then
            GG._DVerbose("Drop gossip multipart LAST (%s)", tostring(err))
            if aceComm.multipart_spool then
                aceComm.multipart_spool[key] = nil
            end
            return
        end
        return origLast(self, pfx, message, distribution, sender)
    end

    aceComm._SF_GG_RecvGuard = true
    st.aceComm = aceComm
    st.installed = true
    GG._DInfo("Gossip receive guard installed on AceComm instance %s", tostring(aceComm))
    return true
end

function GG.GetReceiveGuardStats()
    local st = GG._recvGuard
    return {
        partialCount = st.partialCount or 0,
        partialBytes = st.partialBytes or 0,
        installed = st.installed and true or false,
        aceComm = st.aceComm,
    }
end
