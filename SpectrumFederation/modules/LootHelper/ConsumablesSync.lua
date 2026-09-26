-- Permission and convergence rules for Consumables sync payloads.
local _, SF = ...

SF.ConsumablesSync = SF.ConsumablesSync or {}
local S = SF.ConsumablesSync
local C = SF.Consumables

local function Same(a, b)
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b) and true or false
    end
    return a ~= nil and a == b
end

S.MAX_REMOTE_OPS = 20
S.REMOTE_OP_WINDOW = 10

function S.AllowRemoteOp(bucket, sender, now)
    if type(bucket) ~= "table" or type(sender) ~= "string" or sender == "" then
        return false
    end
    now = tonumber(now) or 0
    local row = bucket[sender]
    if type(row) ~= "table" or now - (tonumber(row.start) or 0) >= S.REMOTE_OP_WINDOW then
        bucket[sender] = { start = now, count = 1 }
        return true
    end
    if (tonumber(row.count) or 0) >= S.MAX_REMOTE_OPS then
        return false
    end
    row.count = row.count + 1
    return true
end

function S.RemoteEventIdOk(eventId, sender)
    if type(eventId) ~= "string" or type(sender) ~= "string" or sender == "" then
        return false
    end
    if eventId:find(":" .. sender .. ":", 1, true) then return true end
    if eventId:find("-" .. sender .. "-", 1, true) then return true end
    return false
end

function S.AuthorizeOp(profile, op, sender)
    if type(op) ~= "table" then return false end
    if op.name == "add_assignment" or op.name == "remove_assignment" then
        return C.CanEditAssignment(profile, sender, op.crafter, {
            asAdmin = C.IsCanonicalAdmin(profile, sender),
        })
    end
    if op.name == "add_crafter" or op.name == "remove_crafter" or op.name == "set_guild"
        or op.name == "set_bank_tab" or op.name == "clear"
    then
        return C.IsCanonicalAdmin(profile, sender)
    end
    return false
end

function S.SessionEnvelopeOk(state, payload)
    state = state or {}
    if state.active ~= true then return false end
    if type(payload) ~= "table" then return false end
    if type(payload.sessionId) ~= "string" or payload.sessionId == "" then return false end
    if payload.sessionId ~= state.sessionId then return false end
    if type(payload.profileId) ~= "string" or payload.profileId == "" then return false end
    if payload.profileId ~= state.profileId then return false end
    return true
end

function S.RemoteConfigSenderOk(coordinator, sender)
    return Same(coordinator, sender)
end

local coordinatorWatermark = setmetatable({}, { __mode = "k" })

function S.ClearCoordinatorWatermarks()
    local stale = {}
    for profile in pairs(coordinatorWatermark) do
        stale[#stale + 1] = profile
    end
    for i = 1, #stale do
        coordinatorWatermark[stale[i]] = nil
    end
    if S.ClearTradeGrants then
        S.ClearTradeGrants()
    end
end

function S.CoordinatorWatermark(profile)
    return coordinatorWatermark[profile]
end

function S.NoteCoordinatorWatermark(profile, generation, configSeq, epoch)
    if type(profile) ~= "table" then return end
    coordinatorWatermark[profile] = {
        generation = tonumber(generation) or 1,
        configSeq = tonumber(configSeq) or 0,
        epoch = tonumber(epoch) or 0,
    }
end

local function WatermarkIsNewer(remoteGen, remoteSeq, noted, epoch)
    if not noted then return true end
    local notedEpoch = tonumber(noted.epoch) or 0
    local incomingEpoch = tonumber(epoch) or 0
    if incomingEpoch ~= notedEpoch then
        return incomingEpoch > notedEpoch
    end
    if remoteGen > noted.generation then return true end
    if remoteGen == noted.generation and remoteSeq > noted.configSeq then return true end
    return false
end

function S.WatermarkAdmits(profile, remoteGen, remoteSeq, epoch)
    local noted = coordinatorWatermark[profile]
    if not noted then return true end
    local notedEpoch = tonumber(noted.epoch) or 0
    local incomingEpoch = tonumber(epoch) or 0
    if incomingEpoch ~= notedEpoch then
        return incomingEpoch > notedEpoch
    end
    if remoteGen > noted.generation then return true end
    if remoteGen == noted.generation and remoteSeq >= noted.configSeq then return true end
    return false
end

function S.ApplyRemoteConfig(profile, payload, sender, opts)
    if type(payload) ~= "table" then
        return false, "invalid"
    end
    if not C.IsCanonicalAdmin(profile, sender) then
        return false, "unauthorized"
    end
    opts = type(opts) == "table" and opts or {}
    local localDesc = C.Descriptor(profile)
    local remoteGen = tonumber(payload.generation) or 1
    local remoteSeq = tonumber(payload.configSeq) or 0
    local epoch = opts.coordEpoch
    if opts.coordinatorAuthoritative then
        if not WatermarkIsNewer(remoteGen, remoteSeq, coordinatorWatermark[profile], epoch) then
            return true, "stale"
        end
        C.ReplaceConfig(profile, payload)
        S.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
        return true, "applied"
    end
    if remoteGen < localDesc.generation then
        return true, "stale"
    end
    if remoteGen == localDesc.generation and remoteSeq <= localDesc.configSeq then
        return true, "stale"
    end
    if remoteGen > localDesc.generation + 1 or remoteSeq > localDesc.configSeq + 1 then
        return false, "gap"
    end
    C.ReplaceConfig(profile, payload)
    S.NoteCoordinatorWatermark(profile, remoteGen, remoteSeq, epoch)
    return true, "applied"
end

function S.CoordinatorConfigDiffers(localDesc, remote)
    remote = remote or {}
    localDesc = localDesc or {}
    local remoteGen = tonumber(remote.generation)
    local remoteSeq = tonumber(remote.configSeq)
    if remoteGen and remoteGen ~= (localDesc.generation or 1) then return true end
    if remoteSeq and remoteSeq ~= (localDesc.configSeq or 0) then return true end
    local remoteFp = tonumber(remote.configFingerprint)
    local localFp = tonumber(localDesc.configFingerprint)
    if remoteFp and localFp and remoteFp ~= localFp then return true end
    return false
end

function S.CatchUpKind(localDesc, remote)
    if not S.NeedsCatchUp(localDesc, remote) then return "none" end
    remote = remote or {}
    localDesc = localDesc or {}
    local ahead = (tonumber(remote.generation) or 0) > (localDesc.generation or 1)
        or (tonumber(remote.configSeq) or 0) > (localDesc.configSeq or 0)
        or (tonumber(remote.eventCount) or 0) > (localDesc.eventCount or 0)
    if ahead then return "ahead" end
    return "fingerprint"
end

S.MAX_EVENT_QUANTITY = 100000

local function PositiveQuantity(event)
    local qty = tonumber(event.quantity)
    local itemId = tonumber(event.itemId)
    if not itemId or itemId <= 0 or itemId ~= math.floor(itemId) then return false end
    if not qty or qty ~= qty or qty < 1 or qty > S.MAX_EVENT_QUANTITY or qty ~= math.floor(qty) then
        return false
    end
    if type(event.generation) ~= "number" then return false end
    return true
end

S.TRADE_GRANT_TTL = 120
S.MAX_TRADE_GRANTS = 32
S.MAX_TRADE_GRANT_ITEMS = 32

local tradeGrants = setmetatable({}, { __mode = "k" })

function S.ClearTradeGrants()
    local stale = {}
    for profile in pairs(tradeGrants) do
        stale[#stale + 1] = profile
    end
    for i = 1, #stale do
        tradeGrants[stale[i]] = nil
    end
    if S.ClearWithdrawGrants then
        S.ClearWithdrawGrants()
    end
    local sync = SF.LootHelperSync
    if sync and sync._ClearPendingTradeFreezes then
        sync:_ClearPendingTradeFreezes()
    end
end

local function PlayerNameOk(name)
    return type(name) == "string" and name ~= "" and #name <= 64 and not name:find("[%c]")
end

local function TokenOk(token, receiver)
    if type(token) ~= "string" or #token < 8 or #token > 128 then return false end
    if token:find("[%c]") then return false end
    if type(receiver) == "string" and receiver ~= "" and not token:find(receiver, 1, true) then
        return false
    end
    return true
end

local function GrantState(profile)
    local state = tradeGrants[profile]
    if not state then
        state = { byToken = {}, byReceiver = {} }
        tradeGrants[profile] = state
    end
    return state
end

local function GrantCount(state)
    local count = 0
    for _ in pairs(state.byToken) do
        count = count + 1
    end
    return count
end

local function DropGrant(state, token)
    local grant = state.byToken[token]
    state.byToken[token] = nil
    if grant and state.byReceiver[grant.receiver] == token then
        state.byReceiver[grant.receiver] = nil
    end
end

local function PurgeGrants(state, now)
    local stale = {}
    for token, grant in pairs(state.byToken) do
        if type(grant) ~= "table" or now >= (tonumber(grant.expiresAt) or 0) then
            stale[#stale + 1] = token
        end
    end
    for i = 1, #stale do
        DropGrant(state, stale[i])
    end
end

local function CopyGrantItems(profile, receiver, items, liveCheck)
    if type(items) ~= "table" then return nil end
    local count = #items
    if count < 1 or count > S.MAX_TRADE_GRANT_ITEMS then return nil end
    local copied = {}
    local cfg = liveCheck and C.Ensure(profile) or nil
    for i = 1, count do
        local row = items[i]
        if type(row) ~= "table" then return nil end
        local itemId = tonumber(row.itemId)
        local epoch = tonumber(row.epoch)
        if not itemId or itemId <= 0 or itemId ~= math.floor(itemId) then return nil end
        if not epoch or epoch < 1 or epoch ~= math.floor(epoch) then return nil end
        if copied[itemId] then return nil end
        if liveCheck then
            local assignment = cfg.assignments[tostring(itemId)]
            if type(assignment) ~= "table" or tonumber(assignment.epoch) ~= epoch then return nil end
            if not C.CrafterHasItem(profile, receiver, itemId) then return nil end
        end
        copied[itemId] = epoch
    end
    return copied
end

local function StoreTradeGrant(profile, grant, now, liveCheck)
    if type(profile) ~= "table" or type(grant) ~= "table" then return false end
    now = tonumber(now) or 0
    local receiver = grant.receiver
    local donor = grant.donor
    if not PlayerNameOk(receiver) or not PlayerNameOk(donor) or Same(donor, receiver) then return false end
    if not TokenOk(grant.token, receiver) then return false end
    local generation = tonumber(grant.generation)
    if not generation or generation < 1 or generation ~= math.floor(generation) then return false end
    local items = CopyGrantItems(profile, receiver, grant.items, liveCheck)
    if not items then return false end
    local state = GrantState(profile)
    PurgeGrants(state, now)
    local existing = state.byToken[grant.token]
    if not existing and GrantCount(state) >= S.MAX_TRADE_GRANTS then
        return false
    end
    state.byToken[grant.token] = {
        token = grant.token,
        donor = donor,
        receiver = receiver,
        generation = generation,
        items = items,
        used = existing and existing.used or {},
        expiresAt = existing and existing.expiresAt or (now + S.TRADE_GRANT_TTL),
    }
    state.byReceiver[receiver] = grant.token
    return true
end

function S.RegisterTradeGrant(profile, grant, now)
    return StoreTradeGrant(profile, grant, now, true)
end

function S.AcceptCoordinatorTradeGrant(profile, grant, now)
    return StoreTradeGrant(profile, grant, now, false)
end

function S.TradeFreezePayload(frozen)
    if type(frozen) ~= "table" or type(frozen.items) ~= "table" then return nil end
    if not TokenOk(frozen.token, frozen.receiver) then return nil end
    if not PlayerNameOk(frozen.donor) or not PlayerNameOk(frozen.receiver) then return nil end
    if Same(frozen.donor, frozen.receiver) then return nil end
    local generation = tonumber(frozen.generation)
    if not generation or generation < 1 or generation ~= math.floor(generation) then return nil end
    local items = {}
    for key, info in pairs(frozen.items) do
        if #items >= S.MAX_TRADE_GRANT_ITEMS then break end
        if type(info) == "table" and info.assignedToReceiver then
            local itemId = tonumber(info.itemId) or tonumber(key)
            local epoch = tonumber(info.epoch)
            if itemId and epoch and epoch >= 1 and itemId == math.floor(itemId) and epoch == math.floor(epoch) then
                items[#items + 1] = { itemId = itemId, epoch = epoch }
            end
        end
    end
    if #items == 0 then return nil end
    table.sort(items, function(a, b) return a.itemId < b.itemId end)
    return {
        token = frozen.token,
        donor = frozen.donor,
        receiver = frozen.receiver,
        generation = generation,
        items = items,
    }
end

local function GrantSlot(grant, event, writer)
    if type(event) ~= "table" or event.tradeToken ~= grant.token then return nil end
    if type(event.id) ~= "string" or not event.id:find(grant.token, 1, true) then return nil end
    if not Same(writer, grant.receiver) then return nil end
    if tonumber(event.generation) ~= grant.generation then return nil end
    local itemId = tonumber(event.itemId)
    local epoch = tonumber(event.epoch)
    if not itemId or grant.items[itemId] ~= epoch then return nil end
    local kind
    if event.type == C.EVENT.DONATION then
        if event.source ~= "trade" or not Same(event.actor, grant.donor) or not Same(event.crafter, grant.receiver) then
            return nil
        end
        kind = "donation"
    elseif event.type == C.EVENT.RECEIPT then
        if not Same(event.actor, grant.receiver) or not Same(event.crafter, grant.receiver) then
            return nil
        end
        kind = "receipt"
    elseif event.type == C.EVENT.CUSTODY and event.action == C.ACTION.DELIVER then
        if not Same(event.actor, grant.receiver) or not Same(event.toHolder, grant.receiver) or not Same(event.fromHolder, grant.donor) then
            return nil
        end
        kind = "deliver"
    else
        return nil
    end
    local slot = tostring(itemId) .. ":" .. kind
    local used = grant.used and grant.used[slot]
    if used and used ~= event.id then return nil end
    return slot
end

function S.TradeGrantMatches(profile, event, writer, now)
    if type(profile) ~= "table" or type(event) ~= "table" then return false end
    now = tonumber(now) or 0
    local state = tradeGrants[profile]
    if not state then return false end
    PurgeGrants(state, now)
    local grant = state.byToken[event.tradeToken]
    if not grant then return false end
    return GrantSlot(grant, event, writer) ~= nil
end

function S.NoteTradeGrantUse(profile, event)
    if type(profile) ~= "table" or type(event) ~= "table" then return end
    local state = tradeGrants[profile]
    local grant = state and state.byToken[event.tradeToken]
    if not grant then return end
    local slot = GrantSlot(grant, event, grant.receiver)
    if not slot then return end
    grant.used = grant.used or {}
    grant.used[slot] = event.id
end

local withdrawGrants = setmetatable({}, { __mode = "k" })

function S.ClearWithdrawGrants()
    local stale = {}
    for profile in pairs(withdrawGrants) do
        stale[#stale + 1] = profile
    end
    for i = 1, #stale do
        withdrawGrants[stale[i]] = nil
    end
end

local function WithdrawState(profile)
    local state = withdrawGrants[profile]
    if not state then
        state = { byToken = {} }
        withdrawGrants[profile] = state
    end
    return state
end

local function WithdrawCount(state)
    local count = 0
    for _ in pairs(state.byToken) do
        count = count + 1
    end
    return count
end

local function PurgeWithdrawGrants(state, now)
    local stale = {}
    for token, grant in pairs(state.byToken) do
        if type(grant) ~= "table" or now >= (tonumber(grant.expiresAt) or 0) then
            stale[#stale + 1] = token
        end
    end
    for i = 1, #stale do
        state.byToken[stale[i]] = nil
    end
end

local function StoreWithdrawGrant(profile, grant, now, liveCheck)
    if type(profile) ~= "table" or type(grant) ~= "table" then return false end
    now = tonumber(now) or 0
    local receiver = grant.receiver
    if not PlayerNameOk(receiver) or not TokenOk(grant.token, receiver) then return false end
    local itemId = tonumber(grant.itemId)
    local epoch = tonumber(grant.epoch)
    local generation = tonumber(grant.generation)
    if not itemId or itemId <= 0 or itemId ~= math.floor(itemId) then return false end
    if not epoch or epoch < 1 or epoch ~= math.floor(epoch) then return false end
    if not generation or generation < 1 or generation ~= math.floor(generation) then return false end
    if liveCheck then
        local cfg = C.Ensure(profile)
        if generation ~= (tonumber(cfg.generation) or 1) then return false end
        local assignment = cfg.assignments and cfg.assignments[tostring(itemId)]
        if type(assignment) ~= "table" or tonumber(assignment.epoch) ~= epoch then return false end
        if not C.CrafterHasItem(profile, receiver, itemId) then return false end
    end
    local state = WithdrawState(profile)
    PurgeWithdrawGrants(state, now)
    local existing = state.byToken[grant.token]
    if not existing and WithdrawCount(state) >= S.MAX_TRADE_GRANTS then
        return false
    end
    state.byToken[grant.token] = {
        token = grant.token,
        receiver = receiver,
        itemId = itemId,
        epoch = epoch,
        generation = generation,
        used = existing and existing.used or nil,
        expiresAt = existing and existing.expiresAt or (now + S.TRADE_GRANT_TTL),
    }
    return true
end

function S.RegisterWithdrawGrant(profile, grant, now)
    return StoreWithdrawGrant(profile, grant, now, true)
end

function S.AcceptCoordinatorWithdrawGrant(profile, grant, now)
    return StoreWithdrawGrant(profile, grant, now, false)
end

function S.WithdrawGrantMatches(profile, event, writer, now)
    if type(profile) ~= "table" or type(event) ~= "table" then return false end
    if event.type ~= C.EVENT.RECEIPT or event.source ~= "guildbank" then return false end
    now = tonumber(now) or 0
    local state = withdrawGrants[profile]
    if not state then return false end
    PurgeWithdrawGrants(state, now)
    local token = event.withdrawToken
    local grant = type(token) == "string" and state.byToken[token] or nil
    if not grant then return false end
    if type(event.id) ~= "string" or not event.id:find(grant.token, 1, true) then return false end
    if not Same(writer, grant.receiver) then return false end
    if not Same(event.actor, grant.receiver) or not Same(event.crafter, grant.receiver) then return false end
    if tonumber(event.generation) ~= grant.generation then return false end
    if tonumber(event.itemId) ~= grant.itemId or tonumber(event.epoch) ~= grant.epoch then return false end
    if grant.used and grant.used ~= event.id then return false end
    return true
end

function S.NoteWithdrawGrantUse(profile, event)
    if type(profile) ~= "table" or type(event) ~= "table" then return end
    local state = withdrawGrants[profile]
    local grant = state and type(event.withdrawToken) == "string" and state.byToken[event.withdrawToken] or nil
    if not grant or not S.WithdrawGrantMatches(profile, event, grant.receiver, C.Now()) then return end
    grant.used = event.id
end

local function CurrentAssignmentOk(profile, crafter, itemId, epoch)
    if not C.CrafterHasItem(profile, crafter, itemId) then return false end
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return true end
    local cfg = profile._consumables
    local row = cfg and cfg.assignments and cfg.assignments[tostring(itemId)]
    return type(row) == "table" and tonumber(row.epoch) == epoch
end

local function FrozenAssignmentOk(profile, crafter, itemId, epoch, event)
    if CurrentAssignmentOk(profile, crafter, itemId, epoch) then return true end
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return false end
    local now = C.Now()
    if S.TradeGrantMatches(profile, event, crafter, now) then return true end
    return S.WithdrawGrantMatches(profile, event, crafter, now)
end

local function TradeWriter(profile, event, sender)
    if event.source ~= "trade" or not PositiveQuantity(event) then return false end
    if not (event.crafter and Same(event.crafter, sender)) then return false end
    if not (event.actor and not Same(event.actor, sender)) then return false end
    return FrozenAssignmentOk(profile, sender, tonumber(event.itemId), event.epoch, event)
end

local function CustodyWriterOk(profile, event, sender)
    if not PositiveQuantity(event) then return false end
    local action = event.action
    if action == C.ACTION.WITHDRAW or action == C.ACTION.RETURN then
        return event.holder and Same(event.actor, sender) and Same(event.holder, sender)
            and C.IsCanonicalAdmin(profile, sender)
    end
    if action == C.ACTION.TRANSFER then
        return event.toHolder and event.fromHolder
            and Same(event.actor, sender) and Same(event.toHolder, sender)
            and C.IsCanonicalAdmin(profile, event.fromHolder)
            and C.IsCanonicalAdmin(profile, event.toHolder)
    end
    if action == C.ACTION.DELIVER then
        local crafter = event.toHolder or event.crafter
        return crafter and event.fromHolder
            and Same(event.actor, sender) and Same(crafter, sender)
            and FrozenAssignmentOk(profile, sender, tonumber(event.itemId), event.epoch, event)
    end
    return false
end

function S.RelayWriter(event)
    if type(event) ~= "table" then return nil end
    if type(event.writer) == "string" and event.writer ~= "" and S.RemoteEventIdOk(event.id, event.writer) then
        return event.writer
    end
    return nil
end

function S.RemoteEventAdmission(isCoordinator, fromCoordinator, event)
    if type(event) ~= "table" then return false, false end
    if isCoordinator == true then
        event.order = nil
        event.writer = nil
        return true, false
    end
    local order = tonumber(event.order)
    if fromCoordinator == true and order and order > 0 then
        return true, true
    end
    return false, false
end

function S.ClearCapabilityFlags(peers)
    if type(peers) ~= "table" then return end
    for _, peer in pairs(peers) do
        if type(peer) == "table" then
            peer.consumablesCapable = nil
        end
    end
end

function S.ApplyRemoteEvent(profile, event, sender, opts)
    if type(event) ~= "table" or type(event.id) ~= "string" or type(event.type) ~= "string" then
        return false, "invalid"
    end
    opts = type(opts) == "table" and opts or {}
    local writer = sender
    if opts.coordinatorRelay then
        writer = S.RelayWriter(event)
        if not writer then
            return false, "unauthorized"
        end
    elseif not S.RemoteEventIdOk(event.id, sender) then
        return false, "unauthorized"
    end
    if event.type == C.EVENT.RESET or event.type == C.EVENT.RESOLVE then
        if not (event.actor and Same(event.actor, writer) and C.IsCanonicalAdmin(profile, writer)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.DONATION then
        local allowed
        if event.source == "trade" then
            allowed = TradeWriter(profile, event, writer)
        else
            allowed = event.actor and Same(event.actor, writer) and PositiveQuantity(event)
        end
        if not allowed then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.RECEIPT then
        if not (event.actor and Same(event.actor, writer) and event.crafter and Same(event.crafter, writer)
            and PositiveQuantity(event)
            and FrozenAssignmentOk(profile, writer, tonumber(event.itemId), event.epoch, event)) then
            return false, "unauthorized"
        end
    elseif event.type == C.EVENT.CUSTODY then
        if not CustodyWriterOk(profile, event, writer) then
            return false, "unauthorized"
        end
    else
        return false, "invalid"
    end
    event.writer = writer
    local ok, status = C.AppendEvent(profile, event, {
        replaceOrder = opts.coordinatorRelay == true,
    })
    if ok and status ~= "duplicate" then
        S.NoteTradeGrantUse(profile, event)
        S.NoteWithdrawGrantUse(profile, event)
    end
    return ok, status
end

function S.NeedsCatchUp(localDesc, remote)
    remote = remote or {}
    local remoteGen = tonumber(remote.generation)
    local remoteSeq = tonumber(remote.configSeq)
    local remoteEvents = tonumber(remote.eventCount)
    local remoteArchiveCount = tonumber(remote.archiveCount)
    local remoteArchiveFingerprint = tonumber(remote.archiveFingerprint)
    if not remoteGen and not remoteSeq and not remoteEvents
        and not remoteArchiveCount and not remoteArchiveFingerprint then
        return false
    end
    if remoteGen and remoteGen > (localDesc.generation or 1) then return true end
    if remoteSeq and remoteSeq > (localDesc.configSeq or 0) then return true end
    if remoteEvents and remoteEvents > (localDesc.eventCount or 0) then return true end
    local remoteFingerprint = tonumber(remote.eventFingerprint)
    local localFingerprint = tonumber(localDesc.eventFingerprint)
    if remoteFingerprint and localFingerprint and remoteFingerprint ~= localFingerprint then
        return true
    end
    if remoteArchiveCount and remoteArchiveCount ~= (tonumber(localDesc.archiveCount) or 0) then
        return true
    end
    local localArchiveFingerprint = tonumber(localDesc.archiveFingerprint)
    if remoteArchiveFingerprint and localArchiveFingerprint and remoteArchiveFingerprint ~= localArchiveFingerprint then
        return true
    end
    return false
end
