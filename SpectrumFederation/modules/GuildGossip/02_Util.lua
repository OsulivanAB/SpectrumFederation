-- Shared helpers for Guild Gossip (hash, time, debug, identity).
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

function GG._Now()
    if GetTime then
        return GetTime()
    end
    if SF.Now then
        return SF:Now()
    end
    return time()
end

local function debugEnabled()
    local D = SF.Debug
    if not D then
        return false
    end
    if D.IsEnabled then
        return D:IsEnabled() and true or false
    end
    -- If IsEnabled is absent, only emit when Debug methods exist and callers
    -- already treat Debug as the opt-in diagnostic surface.
    return true
end

function GG._Debug(level, fmt, ...)
    local D = SF.Debug
    if not D or not debugEnabled() then
        return
    end
    local fn = D[level]
    if type(fn) == "function" then
        fn(D, "GUILD_GOSSIP", fmt, ...)
    end
end

function GG._DVerbose(fmt, ...)
    GG._Debug("Verbose", fmt, ...)
end

function GG._DInfo(fmt, ...)
    GG._Debug("Info", fmt, ...)
end

function GG._DWarn(fmt, ...)
    GG._Debug("Warn", fmt, ...)
end

function GG._DError(fmt, ...)
    GG._Debug("Error", fmt, ...)
end

-- Deterministic 32-bit mix (djb2). Identical bytes → identical bucket/fingerprint
-- on every compatible client. Does not authenticate content.
function GG.Hash32(s)
    if type(s) ~= "string" then
        s = tostring(s or "")
    end
    local hash = 5381
    for i = 1, #s do
        hash = (hash * 33 + s:byte(i)) % 4294967296
    end
    return hash
end

function GG.BucketForId(recordId)
    return GG.Hash32(tostring(recordId or "")) % GG.BUCKET_COUNT
end

-- Order-independent advisory fingerprint contribution.
function GG.CombineFingerprint(fp, id, versionFp)
    local piece = tostring(id or "") .. "\0" .. tostring(versionFp or "")
    local h = GG.Hash32(piece)
    return ((tonumber(fp) or 0) + h) % 4294967296
end

function GG.SelfId()
    if SF.NameUtil and SF.NameUtil.GetSelfId then
        return SF.NameUtil.GetSelfId()
    end
    local name, realm = UnitFullName and UnitFullName("player")
    realm = realm or (GetRealmName and GetRealmName())
    if realm then
        realm = realm:gsub("%s+", "")
    end
    if name and realm then
        return name .. "-" .. realm
    end
    return name
end

function GG.NormalizePlayer(name)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name)
    end
    return name
end

function GG.SamePlayer(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

function GG.RandomInRange(lo, hi)
    lo = tonumber(lo) or 0
    hi = tonumber(hi) or lo
    if hi < lo then
        lo, hi = hi, lo
    end
    if hi == lo then
        return lo
    end
    return lo + math.random() * (hi - lo)
end

function GG.ShallowCopy(t)
    if type(t) ~= "table" then
        return t
    end
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end
