-- Guild Gossip engine: discovery, C1 exchange, receive dispatch, lifecycle.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip
local providerScope, providerEligible
local isKnownUnresolvedRevision, clearUnresolvedRevision, recordUnresolved
local hasUnresolvedForProvider, reopenUnresolvedEnumeration
local hasValidBodyIdArray, transportSenderAuthorized

GG._engine = GG._engine or {
    inited = false,
    peers = {}, -- [name] = peer
    peerOrder = {},
    discoveryTimer = nil,
    nextDiscoveryAt = nil,
    outPull = nil, -- active initiated pull
    inPull = nil, -- active served pull
    recvQueue = {}, -- { {sender, msgType, payload, bytes, at} }
    recvBytes = 0,
    streamBusy = {}, -- [dist|target] = true while multipart submit in flight
    admittedOutBytes = 0,
    generation = 0,
    requestSeq = 0,
    lastNackAt = {},
    peerCooldownUntil = {},
    unresolved = {}, -- bounded unresolved bookkeeping
    -- [peer|provider|scope] = until: suspend exchanges after pending/rejected
    unresolvedBackoffUntil = {},
    pendingOutCapture = nil, -- budgeted local VIEW summary construction
}

local function peerKey(name)
    return string.lower(tostring(name or ""))
end

local function streamKey(distribution, target)
    return tostring(distribution) .. "|" .. tostring(target or "")
end

function GG.GetEngineStats()
    local e = GG._engine
    return {
        peerCount = #(e.peerOrder or {}),
        recvQueue = #(e.recvQueue or {}),
        recvBytes = e.recvBytes or 0,
        admittedOutBytes = e.admittedOutBytes or 0,
        hasOutPull = e.outPull ~= nil,
        hasInPull = e.inPull ~= nil,
        generation = e.generation or 0,
    }
end

---------------------------------------------------------------------------
-- Peer working set
---------------------------------------------------------------------------

local function providerAnnouncementFingerprint(cap)
    if type(cap) ~= "table" then
        return ""
    end
    -- revision (provider-owned) and changeGen (engine-owned) are independent
    -- identity fields; neither may suppress the other.
    return table.concat({
        tostring(cap.id or ""),
        tostring(cap.schema or ""),
        tostring(cap.revision or ""),
        tostring(cap.changeGen or ""),
        tostring(cap.dataFingerprint or cap.fingerprint or ""),
        tostring(cap.eligibilityGen or ""),
    }, "\0")
end

-- Iterate every registered provider (enabled or not) so peer eviction and
-- scoped invalidation cannot leave bookmarks behind on disabled entries.
local function eachRegisteredProvider(fn)
    local reg = GG._providers and GG._providers.byId
    if not reg then
        return
    end
    for _, entry in pairs(reg) do
        if entry then
            fn(entry)
        end
    end
end

-- Clear bookmarks using structured bookmark metadata (never parse composite keys:
-- supported scopes such as name:<guild>|<realm> contain '|').
local function clearBookmarksForScope(peerName, providerId, scopeId)
    local normalized = peerName and peerKey(peerName) or nil
    local scopeStr = scopeId ~= nil and tostring(scopeId) or nil
    eachRegisteredProvider(function(entry)
        if providerId and entry.id ~= providerId then
            return
        end
        if not normalized and not scopeStr then
            entry.bookmarks = {}
            return
        end
        for key, bm in pairs(entry.bookmarks or {}) do
            if type(bm) == "table" and bm.peerKey ~= nil then
                local bmScope = bm.scopeId ~= nil and tostring(bm.scopeId) or nil
                if (not normalized or bm.peerKey == normalized)
                    and (not scopeStr or bmScope == scopeStr) then
                    entry.bookmarks[key] = nil
                end
            end
        end
    end)
end

local function clearUnresolvedForScope(peerName, providerId, scopeId)
    local normalized = peerName and peerKey(peerName) or nil
    local unresolved = GG._engine.unresolved or {}
    for key, item in pairs(unresolved) do
        if (not normalized or item.peerKey == normalized)
            and (not providerId or item.providerId == providerId)
            and (not scopeId or item.scopeId == scopeId) then
            unresolved[key] = nil
        end
    end
end

local function clearPeerOwnedRuntime(peerName)
    local normalized = peerName and peerKey(peerName) or nil
    if not normalized then
        return
    end
    local e = GG._engine
    clearBookmarksForScope(peerName, nil, nil)
    clearUnresolvedForScope(peerName, nil, nil)
    if e.peerCooldownUntil then
        e.peerCooldownUntil[normalized] = nil
    end
    if e.unresolvedBackoffUntil then
        local prefix = normalized .. "|"
        for key in pairs(e.unresolvedBackoffUntil) do
            if type(key) == "string" and string.sub(key, 1, #prefix) == prefix then
                e.unresolvedBackoffUntil[key] = nil
            end
        end
    end
    if e.lastNackAt then
        e.lastNackAt[normalized] = nil
    end
    if e.pendingOutCapture and e.pendingOutCapture.peer
        and peerKey(e.pendingOutCapture.peer) == normalized then
        e.pendingOutCapture = nil
    end
    local peer = e.peers[normalized]
    if peer then
        peer.covered = {}
        peer.scopeIncompat = nil
        peer.capFingerprints = nil
        peer.caps = nil
    end
end

-- Full peer/provider/scope wipe (bookmarks + obligations). Prefer narrower
-- helpers when only bookmarks or a single revision must change.
local function clearPeerProviderState(peerName, providerId, scopeId)
    clearBookmarksForScope(peerName, providerId, scopeId)
    clearUnresolvedForScope(peerName, providerId, scopeId)
end

local function touchPeer(name, info)
    local e = GG._engine
    local norm = GG.NormalizePlayer(name)
    if not norm then
        return nil
    end
    local key = peerKey(norm)
    local peer = e.peers[key]
    local now = GG._Now()
    if not peer then
        if #e.peerOrder >= GG.MAX_PEERS then
            -- Rotate inactive peers; never evict an active exchange peer.
            local evictIdx = nil
            for i, pk in ipairs(e.peerOrder) do
                local p = e.peers[pk]
                if p and not p.activeExchange then
                    evictIdx = i
                    break
                end
            end
            if not evictIdx then
                return nil
            end
            local ek = e.peerOrder[evictIdx]
            local evicted = e.peers[ek]
            if evicted then
                -- Same scoped cleanup as expirePeers so capacity eviction cannot
                -- retain bookmarks/unresolved/cooldowns outside the peer bound.
                clearPeerOwnedRuntime(evicted.name)
            end
            e.peers[ek] = nil
            table.remove(e.peerOrder, evictIdx)
        end
        peer = { name = norm, key = key }
        e.peers[key] = peer
        e.peerOrder[#e.peerOrder + 1] = key
    end
    peer.lastSeen = now
    if info and info.caps then
        peer.caps = info.caps
        peer.capFingerprints = peer.capFingerprints or {}
        peer.covered = peer.covered or {}
        -- Discovery is deliberately rotated. Only an advertised provider whose
        -- bounded change identity differs reopens coverage; omission says
        -- nothing about providers absent from this packet. Retain fingerprints
        -- only for locally registered providers so cumulative bogus IDs cannot
        -- grow the map without bound.
        for _, cap in ipairs(info.caps.providers or {}) do
            if type(cap) == "table" and cap.id then
                local id = tostring(cap.id)
                if GG.GetProvider(id) then
                    local fingerprint = providerAnnouncementFingerprint(cap)
                    if peer.capFingerprints[id] and peer.capFingerprints[id] ~= fingerprint then
                        peer.covered[id] = nil
                        -- Remote revision/eligibility change clears scoped VIEW
                        -- incompatibility so a now-compatible peer can recover.
                        if peer.scopeIncompat then
                            peer.scopeIncompat[id] = nil
                        end
                        clearPeerProviderState(norm, id, nil)
                        -- Active fixed-end pulls keep their captured view; mark
                        -- follow-up so completion cannot claim coverage on the
                        -- stale announcement identity.
                        local out = e.outPull
                        if out and out.providerId == id
                            and out.peer and peerKey(out.peer) == key then
                            out.needsFollowUp = true
                            if GG._sched then
                                GG._sched.dirtyFollowUp = true
                            end
                            GG.MarkWorkPending()
                        end
                    end
                    peer.capFingerprints[id] = fingerprint
                end
            end
        end
        for id in pairs(peer.capFingerprints) do
            if not GG.GetProvider(id) then
                peer.capFingerprints[id] = nil
                if peer.covered then
                    peer.covered[id] = nil
                end
            end
        end
    end
    peer.proto = info and info.proto or peer.proto
    peer.covered = peer.covered or {}
    return peer
end

local function expirePeers(now)
    local e = GG._engine
    now = now or GG._Now()
    local keep = {}
    for _, key in ipairs(e.peerOrder) do
        local p = e.peers[key]
        if p then
            local active = p.activeExchange
            local fresh = not p.lastSeen or (now - p.lastSeen) < GG.PEER_EXPIRE_SEC
            if active or fresh then
                keep[#keep + 1] = key
            else
                clearPeerOwnedRuntime(p.name)
                e.peers[key] = nil
            end
        end
    end
    e.peerOrder = keep
end

---------------------------------------------------------------------------
-- Send path (via LootHelperComm traffic class)
---------------------------------------------------------------------------

local function onGossipSubmitted(bytes)
    local e = GG._engine
    e.admittedOutBytes = math.max(0, (e.admittedOutBytes or 0) - (bytes or 0))
end

function GG.SendGossip(msgType, payload, distribution, target, opts)
    opts = opts or {}
    local Comm = SF.LootHelperComm
    if not Comm or not Comm._ready then
        return false, "comm_not_ready"
    end
    if not GG.HasActiveProvider() and not opts.allowWithoutProvider then
        return false, "no_provider"
    end
    if not GG.IsGuildReady() and not opts.allowWithoutProvider then
        return false, "guild_not_ready"
    end
    if distribution == "WHISPER" and target and not opts.allowWithoutProvider then
        if not GG.IsGuildMember(target) then
            return false, "target_not_member"
        end
    end

    local envelope, err = GG.BuildWireMessage(msgType, payload)
    if not envelope then
        return false, err
    end
    if distribution == "GUILD" and #envelope > GG.MAX_DISCOVERY_BYTES then
        return false, "discovery_too_large"
    end

    local e = GG._engine
    local bytes = #envelope
    if (e.admittedOutBytes or 0) + bytes > GG.MAX_ADMITTED_OUT_BYTES then
        return false, "admitted_out_cap"
    end

    local sk = streamKey(distribution, target)
    if e.streamBusy[sk] and not opts.ignoreStreamBusy then
        return false, "stream_busy"
    end

    -- Multipart threshold ~255; mark stream busy until final fragment callback.
    local isMulti = bytes > 250
    if isMulti then
        e.streamBusy[sk] = true
    end
    e.admittedOutBytes = (e.admittedOutBytes or 0) + bytes

    local terminal = false
    local function finish(success, sendResult)
        if terminal then
            return
        end
        terminal = true
        e.streamBusy[sk] = nil
        onGossipSubmitted(bytes)
        -- A served VIEW offer may be waiting for this stream to drain.
        local pull = GG._engine.inPull
        if pull and pull.offerRetryPending and streamKey("WHISPER", pull.peer) == sk then
            GG.MarkWorkPending()
        end
        if opts.onFinalSubmitted then
            opts.onFinalSubmitted(success == true, sendResult)
        end
    end
    local function releaseAdmission(reason)
        finish(false, reason or "cancelled")
    end
    local callback = function(_, sent, textlen, sendResult)
        -- ChatThrottleLib/AceComm callback: sent reaches textlen on final fragment.
        if type(sent) == "number" and type(textlen) == "number" and sent >= textlen then
            finish(sendResult ~= false, sendResult)
        end
    end

    local providerId = opts.providerId or (type(payload) == "table" and payload.providerId) or nil
    local scopeId = opts.scopeId or (type(payload) == "table" and payload.scopeId) or nil
    if providerId and not scopeId and providerScope then
        scopeId = providerScope(GG.GetProvider(providerId))
    end
    local sendGeneration = e.generation
    local gossipValid = opts.gossipValid or function()
        if sendGeneration ~= GG._engine.generation or not GG.IsGuildReady() then
            return false
        end
        if not providerId then
            return GG.HasActiveProvider()
        end
        return providerEligible and providerEligible(GG.GetProvider(providerId), target, scopeId)
    end
    local ok = Comm:Send("GOSSIP", msgType, payload, distribution, target, GG.ACE_PRIO, {
        enc = (payload == nil or (type(payload) == "table" and next(payload) == nil)) and GG.ENC_NONE or GG.ENC_B64CBOR,
        queue = true,
        trafficClass = GG.TRAFFIC_CLASS,
        gossipEnvelope = envelope, -- Comm may use prebuilt envelope
        callback = callback,
        proto = GG.PROTO_CURRENT,
        gossip = true,
        gossipProviderId = providerId,
        gossipGeneration = e.generation,
        gossipCancel = releaseAdmission,
        gossipValid = gossipValid,
    })
    if not ok then
        finish(false, "queue_rejected")
        return false, "queue_rejected"
    end
    -- Single-part: AceComm still invokes callback; if Comm bypasses callback on
    -- immediate failure we already rolled back. For single-part success without
    -- callback in tests, release on next pump via safety.
    if not isMulti then
        -- Defer release to callback; tests may invoke callback manually.
    end
    return true, nil
end

---------------------------------------------------------------------------
-- Discovery
---------------------------------------------------------------------------

function GG.StopDiscovery()
    local e = GG._engine
    if e.discoveryTimer and e.discoveryTimer.Cancel then
        pcall(function()
            e.discoveryTimer:Cancel()
        end)
    end
    e.discoveryTimer = nil
    e.nextDiscoveryAt = nil
end

function GG.ScheduleDiscovery(initial)
    GG.StopDiscovery()
    if not GG.HasActiveProvider() then
        return
    end
    local lo, hi
    if initial then
        lo, hi = GG.DISCOVERY_INITIAL_JITTER[1], GG.DISCOVERY_INITIAL_JITTER[2]
    else
        lo, hi = GG.DISCOVERY_INTERVAL[1], GG.DISCOVERY_INTERVAL[2]
    end
    local delay = GG.RandomInRange(lo, hi)
    local e = GG._engine
    e.nextDiscoveryAt = GG._Now() + delay
    if C_Timer and C_Timer.NewTimer then
        e.discoveryTimer = C_Timer.NewTimer(delay, function()
            e.discoveryTimer = nil
            GG.SendDiscovery()
            GG.ScheduleDiscovery(false)
        end)
    end
    GG.MarkWorkPending()
end

function GG.SendDiscovery()
    if not GG.HasActiveProvider() then
        return false
    end
    if not GG.IsGuildReady() then
        return false
    end
    -- Discovery uses an independent timer; when the work ticker is idle,
    -- _sched.paused may be stale. Refresh live combat/loading inputs and
    -- preserve resume jitter / pause-clock accounting before broadcasting.
    if GG.UpdatePauseState then
        GG.UpdatePauseState(GG._Now())
    end
    if GG.IsSchedPaused() then
        return false
    end
    local payload = GG.BuildDiscoveryCaps()
    -- Keep discovery tiny: trim provider list if needed.
    while true do
        local ok, err = GG.SendGossip(GG.MSG.DISC, payload, "GUILD", nil, { ignoreStreamBusy = true })
        if ok then
            GG._DVerbose("Discovery sent providers=%d", #(payload.providers or {}))
            return true
        end
        if err == "discovery_too_large" and payload.providers and #payload.providers > 1 then
            table.remove(payload.providers)
        else
            GG._DVerbose("Discovery deferred (%s)", tostring(err))
            return false
        end
    end
end

local function compatibleProviders(remoteCaps)
    local matched = {}
    if type(remoteCaps) ~= "table" or type(remoteCaps.providers) ~= "table" then
        return matched
    end
    local remoteProto = tonumber(remoteCaps.proto)
    if remoteProto and (remoteProto < GG.PROTO_MIN or remoteProto > GG.PROTO_MAX) then
        return matched
    end
    -- Reject peers that advertise only compressed encodings.
    if type(remoteCaps.enc) == "table" then
        local hasUncompressed = false
        for _, enc in ipairs(remoteCaps.enc) do
            if enc == GG.ENC_B64CBOR then
                hasUncompressed = true
            end
        end
        if #remoteCaps.enc > 0 and not hasUncompressed then
            return matched
        end
    end
    for _, rp in ipairs(remoteCaps.providers) do
        if type(rp) == "table" and rp.id then
            local localP = GG.GetProvider(rp.id)
            if localP and localP.enabled and localP.ready and tonumber(rp.schema) == tonumber(localP.schema) then
                matched[#matched + 1] = localP
            end
        end
    end
    return matched
end

---------------------------------------------------------------------------
-- C1 pull state machines
---------------------------------------------------------------------------

-- Opaque storage key: length-prefixed fields so '|' inside scope/id cannot
-- create ambiguous encodings. Matching uses structured bookmark metadata.
local function lengthPrefixedKey(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = tostring(select(i, ...) or "")
        parts[#parts + 1] = string.format("%d:%s", #value, value)
    end
    return table.concat(parts, "\0")
end

local function bookmarkKey(peerName, providerId, scopeId, bucketId)
    return lengthPrefixedKey(peerKey(peerName), providerId, scopeId, bucketId)
end

local function getBookmark(entry, peerName, scopeId, bucketId)
    local key = bookmarkKey(peerName, entry.id, scopeId, bucketId)
    return entry.bookmarks[key], key
end

local function setBookmark(entry, peerName, scopeId, bucketId, bm)
    local key = bookmarkKey(peerName, entry.id, scopeId, bucketId)
    bm = bm or {}
    bm.peerKey = peerKey(peerName)
    bm.providerId = entry.id
    bm.scopeId = scopeId
    bm.bucketId = tonumber(bucketId)
    entry.bookmarks[key] = bm
end

local function unresolvedBackoffKey(peerName, providerId, scopeId)
    -- Prefix-matched on eviction via peerKey.."|"; provider/scope may contain '|'.
    return peerKey(peerName) .. "|" .. tostring(providerId or "") .. "\0" .. tostring(scopeId or "")
end

local function closeOutPull(reason)
    local e = GG._engine
    local pull = e.outPull
    if not pull then
        return
    end
    if pull.peer and e.peers[peerKey(pull.peer)] then
        e.peers[peerKey(pull.peer)].activeExchange = nil
    end
    e.outPull = nil
    GG._DVerbose("Out pull closed (%s)", tostring(reason))
    if reason == "exhausted" and pull.peer then
        e.peerCooldownUntil[peerKey(pull.peer)] = GG._Now() + GG.POST_EXHAUSTION_COOLDOWN_SEC
    elseif reason == "unresolved" and pull.peer and pull.providerId then
        -- Keep coverage incomplete; suppress this scoped obligation until a
        -- meaningful notification or the bounded backoff deadline.
        e.unresolvedBackoffUntil = e.unresolvedBackoffUntil or {}
        e.unresolvedBackoffUntil[unresolvedBackoffKey(pull.peer, pull.providerId, pull.scopeId)] =
            GG._Now() + (GG.UNRESOLVED_BACKOFF_SEC or GG.POST_EXHAUSTION_COOLDOWN_SEC)
    end
end

local function closeInPull(reason)
    local e = GG._engine
    local pull = e.inPull
    if not pull then
        return
    end
    if pull.peer and e.peers[peerKey(pull.peer)] then
        e.peers[peerKey(pull.peer)].activeExchange = nil
    end
    e.inPull = nil
    GG._DVerbose("In pull closed (%s)", tostring(reason))
end

local function scheduleOutPullRetry(pull, reason)
    if GG._engine.outPull ~= pull or not pull.outstanding then
        return
    end
    pull.retries = (pull.retries or 0) + 1
    if pull.retries > GG.PAGE_RETRY_MAX then
        closeOutPull("exhausted")
        return
    end
    local backoff = GG.PAGE_RETRY_BACKOFF[pull.retries] or GG.PAGE_RETRY_BACKOFF[#GG.PAGE_RETRY_BACKOFF]
    pull.finalSubmitted = false
    pull.awaitingSince = nil
    pull.retryAt = GG._Now() + backoff
    pull.usableProgressAt = pull.retryAt
    GG.MarkWorkPending()
    GG._DVerbose("Out pull retry scheduled (%s) in %ss", tostring(reason), tostring(backoff))
end

local function noteOutPullSubmission(pull, success, sendResult)
    if GG._engine.outPull ~= pull then
        return
    end
    if success then
        pull.finalSubmitted = true
        pull.retryAt = nil
        pull.awaitingSince = GG._Now()
        pull.usableProgressAt = pull.awaitingSince
    else
        scheduleOutPullRetry(pull, sendResult or "final_submission_failed")
    end
end

providerScope = function(entry)
    if not entry or not entry.api then
        return nil
    end
    if type(entry.api.GetScopeId) == "function" then
        local ok, scopeId = pcall(entry.api.GetScopeId)
        if ok then
            return scopeId
        end
        return nil
    end
    return GG.GetGuildScopeId()
end

providerEligible = function(entry, peerName, scopeId)
    return entry
        and entry.enabled
        and entry.ready
        and scopeId ~= nil
        and providerScope(entry) == scopeId
        and GG.ProviderIsPeerEligible(entry, peerName, { scopeId = scopeId })
end

local function recordExportable(entry, peerName, scopeId, recordId, indexEntry)
    if not providerEligible(entry, peerName, scopeId) then
        return false
    end
    local api = entry.api
    if type(api.IsRecordExportable) == "function" then
        local ctx = {
            peer = peerName,
            scopeId = scopeId,
            eligibilityGen = entry.eligibilityGen,
            indexEntry = indexEntry,
        }
        local ok, allowed = pcall(api.IsRecordExportable, peerName, recordId, ctx)
        return ok and allowed == true
    end
    return true
end

local function indexReadyForView(entry)
    local index = entry and entry.index
    return index
        and index.buildComplete == true
        and not index.dirty
        and not entry._listCursor
end

local function providerNeedsIndexWork(entry)
    if not entry or not entry.enabled or not entry.ready or not entry.index then
        return false
    end
    -- Terminal index failure: stop polling; recovery is NotifyProviderChanged / re-register.
    if entry.indexFailed then
        return false
    end
    if entry._listCursor then
        return true
    end
    return entry.index.dirty == true or entry.index.buildComplete ~= true
end

local function viewExportFilter(entry, peerName, scopeId)
    if not entry or not entry.api or type(entry.api.IsRecordExportable) ~= "function" then
        return nil
    end
    return function(recordId, indexEntry)
        return recordExportable(entry, peerName, scopeId, recordId, indexEntry)
    end
end

local function nextRequestId(pull, kind)
    local e = GG._engine
    e.requestSeq = (e.requestSeq or 0) + 1
    return table.concat({
        tostring(pull.viewId),
        tostring(kind),
        tostring(e.generation),
        tostring(e.requestSeq),
    }, ":")
end

local function noteInPullSubmission(pull, success)
    if GG._engine.inPull == pull then
        pull.finalSubmitted = success and true or false
        if pull.finalSubmitted then
            pull.offerRetryPending = nil
            pull.awaitingSince = GG._Now()
            pull.usableProgressAt = pull.awaitingSince
        else
            -- An unsent offer/page cannot retain the stop-and-wait lease.
            closeInPull("submission_failed")
        end
    end
end

-- Serving budgets are owned by the local scheduler step. A remote mode may only
-- reduce throughput; it must never raise the server above its current limits.
local function resolveServeLimits(stepLimits, remoteMode)
    local localLimits = stepLimits or GG.GetStepLimits()
    local remoteLimits = remoteMode and GG.GetStepLimits(remoteMode) or localLimits
    return {
        mode = localLimits.mode,
        bodies = math.min(localLimits.bodies or 1, remoteLimits.bodies or 1),
        manifestEntries = math.min(localLimits.manifestEntries or 1, remoteLimits.manifestEntries or 1),
        apps = localLimits.apps,
        cpuMs = localLimits.cpuMs,
        indexEntries = localLimits.indexEntries,
    }
end

local function consumeStepExportBudget(kind, amount)
    local budget = GG._engine.stepExportBudget
    if not budget then
        return amount
    end
    local key = kind == "manifest" and "manifestEntries" or "bodies"
    local remaining = tonumber(budget[key]) or 0
    local take = math.max(0, math.min(amount, remaining))
    budget[key] = math.max(0, remaining - take)
    return take
end

local function trySendServedOffer(pull)
    if not pull or not pull.offerPayload or GG._engine.inPull ~= pull then
        return false
    end
    local ok, err = GG.SendGossip(GG.MSG.VIEW, pull.offerPayload, "WHISPER", pull.peer, {
        providerId = pull.providerId,
        scopeId = pull.scopeId,
        onFinalSubmitted = function(success)
            noteInPullSubmission(pull, success)
        end,
    })
    if ok then
        pull.offerRetryPending = nil
        return true
    end
    if err == "stream_busy" then
        -- Preserve the correlated served view and retry when the stream drains.
        pull.offerRetryPending = true
        pull.finalSubmitted = false
        GG.MarkWorkPending()
        return false
    end
    closeInPull("offer_admission_failed")
    return false
end

function GG.OnGossipPauseChanged(paused, now)
    now = now or GG._Now()
    local e = GG._engine
    for _, pull in ipairs({ e.outPull, e.inPull }) do
        if pull then
            if paused then
                pull.pauseStartedAt = pull.pauseStartedAt or now
            elseif pull.pauseStartedAt then
                local elapsed = math.max(0, now - pull.pauseStartedAt)
                pull.pauseExcluded = (pull.pauseExcluded or 0) + elapsed
                pull.usableProgressAt = (pull.usableProgressAt or now) + elapsed
                if pull.awaitingSince then
                    pull.awaitingSince = pull.awaitingSince + elapsed
                end
                pull.pauseStartedAt = nil
            end
        end
    end
end

-- Comm owns its shared queue; this indirection keeps engine cancellation scoped.
GG.CancelQueuedGossipForProvider = GG.CancelQueuedGossipForProvider or function(providerId)
    local comm = SF.LootHelperComm
    if comm and comm.CancelQueuedGossipForProvider then
        return comm:CancelQueuedGossipForProvider(providerId)
    end
    return false
end

function GG.InvalidateRuntime(reason)
    local e = GG._engine
    e.generation = (e.generation or 0) + 1
    closeOutPull(reason or "invalidated")
    closeInPull(reason or "invalidated")
    e.recvQueue = {}
    e.recvBytes = 0
    e.pendingOutCapture = nil
    e.unresolvedBackoffUntil = {}
    GG.ClearAllPartials()
    local comm = SF.LootHelperComm
    if comm and comm.CancelAllQueuedGossip then
        comm:CancelAllQueuedGossip()
    end
    GG._DInfo("Gossip runtime invalidated (%s)", tostring(reason))
end

local function clearEngineOwnedRuntimeState()
    local e = GG._engine
    e.peers = {}
    e.peerOrder = {}
    e.unresolved = {}
    e.peerCooldownUntil = {}
    e.lastNackAt = {}
    e.unresolvedBackoffUntil = {}
    e.pendingOutCapture = nil
    e.recvQueue = {}
    e.recvBytes = 0
    e.streamBusy = {}
    e.admittedOutBytes = 0
    if GG._providers and GG._providers.byId then
        for _, entry in pairs(GG._providers.byId) do
            if entry then
                entry.bookmarks = {}
            end
        end
    end
end

GG.OnGuildInvalidated = function(reason)
    GG.StopDiscovery()
    GG.InvalidateRuntime(reason)
    -- Verified guild-scope change invalidates scope-dependent peer coverage
    -- and announcement identity. Transient readiness loss (roster/identity
    -- gaps, leave) must not erase useful progress or durable provider storage.
    if reason == "scope_changed" then
        local e = GG._engine
        for _, key in ipairs(e.peerOrder or {}) do
            local p = e.peers[key]
            if p then
                clearPeerOwnedRuntime(p.name)
            end
        end
        -- Bookmarks/unresolved already cleared per-peer; drop leftover peer
        -- announcement maps so a same-fingerprint peer in the new guild is
        -- not treated as already covered.
        for _, p in pairs(e.peers or {}) do
            if p then
                p.covered = {}
                p.scopeIncompat = nil
                p.capFingerprints = nil
                p.caps = nil
            end
        end
    end
    -- Suspend the work ticker until readiness returns; preserve unfinished
    -- obligations via generation bump / closed pulls above.
    if GG._StopScheduler then
        GG._StopScheduler()
    end
end

GG.OnGuildReady = function()
    if GG.HasActiveProvider() then
        GG.MarkWorkPending()
        GG._EnsureScheduler()
        GG.ScheduleDiscovery(true)
    end
end

GG.OnProviderRemoved = function(providerId)
    local e = GG._engine
    local entry = GG.GetProvider(providerId)
    if entry and GG.InvalidateProviderBookmarks then
        GG.InvalidateProviderBookmarks(entry)
    end
    if e.outPull and e.outPull.providerId == providerId then
        closeOutPull("provider_removed")
    end
    if e.inPull and e.inPull.providerId == providerId then
        closeInPull("provider_removed")
    end
    if e.pendingOutCapture and e.pendingOutCapture.providerId == providerId then
        e.pendingOutCapture = nil
    end
    if GG.CancelQueuedGossipForProvider then
        GG.CancelQueuedGossipForProvider(providerId)
    end
    clearPeerProviderState(nil, providerId, nil)
    for key, item in pairs(e.unresolved or {}) do
        if item.providerId == providerId then
            e.unresolved[key] = nil
        end
    end
    for _, peer in pairs(e.peers or {}) do
        if peer.capFingerprints then
            peer.capFingerprints[providerId] = nil
        end
        if peer.covered then
            peer.covered[providerId] = nil
        end
    end
end

local function startOutPull(peer, providerEntry)
    local e = GG._engine
    if e.outPull then
        return false
    end
    if not GG.IsGuildReady() then
        return false
    end
    local scopeId = providerScope(providerEntry)
    if not providerEligible(providerEntry, peer.name, scopeId) then
        return false
    end
    local cooldown = e.peerCooldownUntil[peer.key]
    if cooldown and GG._Now() < cooldown then
        return false
    end
    local backoffUntil = e.unresolvedBackoffUntil
        and e.unresolvedBackoffUntil[unresolvedBackoffKey(peer.name, providerEntry.id, scopeId)]
    if backoffUntil and GG._Now() < backoffUntil then
        return false
    end
    -- Never publish a cold/dirty partial index as a usable view.
    if not indexReadyForView(providerEntry) then
        GG.MarkWorkPending()
        return false
    end

    local limits = e.stepLimits or GG.GetStepLimits()
    local metaBudget = math.max(0, tonumber(e.stepMetaRemaining) or tonumber(limits.indexEntries) or 0)
    if metaBudget <= 0 and viewExportFilter(providerEntry, peer.name, scopeId) then
        GG.MarkWorkPending()
        return false
    end
    local captureLimits = {}
    for key, value in pairs(limits) do
        captureLimits[key] = value
    end
    captureLimits.indexEntries = metaBudget > 0 and metaBudget or (limits.indexEntries or 1)
    local filter = viewExportFilter(providerEntry, peer.name, scopeId)
    local resume = nil
    if e.pendingOutCapture
        and e.pendingOutCapture.peerKey == peer.key
        and e.pendingOutCapture.providerId == providerEntry.id
        and e.pendingOutCapture.scopeId == scopeId
        and e.pendingOutCapture.eligibilityGen == providerEntry.eligibilityGen
        and e.pendingOutCapture.epoch == providerEntry.index.epoch then
        resume = e.pendingOutCapture.state
    end
    local view, pending, examined = GG.CaptureViewSummaries(
        providerEntry.index,
        providerEntry.eligibilityGen,
        scopeId,
        providerEntry.id,
        providerEntry.schema,
        filter,
        captureLimits,
        resume
    )
    examined = math.max(0, tonumber(examined) or 0)
    if e.stepStats then
        e.stepStats.indexExamined = (e.stepStats.indexExamined or 0) + examined
    end
    e.stepMetaRemaining = math.max(0, (tonumber(e.stepMetaRemaining) or metaBudget) - examined)
    if e.stepLimits then
        e.stepLimits.indexEntries = e.stepMetaRemaining
    end
    if pending then
        e.pendingOutCapture = {
            peerKey = peer.key,
            providerId = providerEntry.id,
            scopeId = scopeId,
            eligibilityGen = providerEntry.eligibilityGen,
            epoch = providerEntry.index.epoch,
            state = pending,
        }
        GG.MarkWorkPending()
        return false
    end
    e.pendingOutCapture = nil
    if not view then
        return false
    end
    local payload = {
        op = "request",
        viewId = view.viewId,
        providerId = providerEntry.id,
        schema = providerEntry.schema,
        scopeId = scopeId,
        eligibilityGen = providerEntry.eligibilityGen,
        epoch = view.epoch,
        packedBuckets = view.packedBuckets,
        mode = GG.GetSchedMode(),
        engineGen = e.generation,
    }
    local pull = {
        peer = peer.name,
        providerId = providerEntry.id,
        viewId = view.viewId,
        scopeId = scopeId,
        eligibilityGen = providerEntry.eligibilityGen,
        localEpoch = view.epoch,
        localBuckets = view.buckets,
        localPacked = view.packedBuckets,
        -- Announcement identity observed when this fixed-end pull started.
        -- Coverage completion requires the peer still advertise the same fp.
        remoteAnnouncementFp = peer.capFingerprints and peer.capFingerprints[providerEntry.id] or nil,
        remoteView = nil,
        bucketCursor = 0,
        afterSeq = 0,
        phase = "wait_view",
        retries = 0,
        usableProgressAt = GG._Now(),
        finalSubmitted = false,
        pauseExcluded = 0,
        mode = GG.GetSchedMode(),
        neededBodies = nil,
        bodyOffset = 0,
        outstanding = { msgType = GG.MSG.VIEW, payload = payload },
        engineGen = e.generation,
    }
    peer.activeExchange = true
    e.outPull = pull
    local ok = GG.SendGossip(GG.MSG.VIEW, payload, "WHISPER", peer.name, {
        providerId = providerEntry.id,
        scopeId = scopeId,
        onFinalSubmitted = function(success)
            noteOutPullSubmission(pull, success)
        end,
    })
    if not ok then
        closeOutPull("view_queue_rejected")
        return false
    end
    GG.MarkWorkPending()
    return true
end

local function selectPullPeer()
    local e = GG._engine
    expirePeers()
    local now = GG._Now()
    -- Rotate peerOrder fairly so a busy peer does not starve others.
    if #e.peerOrder > 1 then
        local first = table.remove(e.peerOrder, 1)
        e.peerOrder[#e.peerOrder + 1] = first
    end
    for _, key in ipairs(e.peerOrder) do
        local peer = e.peers[key]
        local cool = e.peerCooldownUntil[key]
        if peer and not peer.activeExchange and not (cool and now < cool) then
            local matched = compatibleProviders(peer.caps)
            -- Prefer a provider not already covered for this peer.
            for _, entry in ipairs(matched) do
                local scopeId = providerScope(entry)
                local ub = e.unresolvedBackoffUntil
                    and e.unresolvedBackoffUntil[unresolvedBackoffKey(peer.name, entry.id, scopeId)]
                local scopeBlocked = peer.scopeIncompat and peer.scopeIncompat[entry.id]
                -- Cached mismatch records the request's local scope. When the
                -- authoritative GetScopeId changes, drop the block without a
                -- periodic retry (NotifyProviderChanged / remote fingerprint
                -- recovery remain the other clear paths).
                if scopeBlocked and scopeBlocked.localScope ~= nil
                    and tostring(scopeBlocked.localScope) ~= tostring(scopeId) then
                    peer.scopeIncompat[entry.id] = nil
                    scopeBlocked = nil
                end
                if providerEligible(entry, peer.name, scopeId)
                    and not (peer.covered and peer.covered[entry.id])
                    and not scopeBlocked
                    and not (ub and now < ub)
                    and indexReadyForView(entry) then
                    return peer, entry
                end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Receive admission + dispatch
---------------------------------------------------------------------------

local function enqueueReceive(sender, msgType, payloadStr, enc, bytes, distribution)
    local e = GG._engine
    bytes = tonumber(bytes) or 0
    if #(e.recvQueue) >= GG.MAX_RECV_QUEUE_MESSAGES then
        GG._DVerbose("Recv queue full; drop %s from %s", tostring(msgType), tostring(sender))
        return false
    end
    if (e.recvBytes or 0) + bytes > GG.MAX_RECV_QUEUE_BYTES then
        GG._DVerbose("Recv byte cap; drop %s from %s", tostring(msgType), tostring(sender))
        return false
    end
    e.recvQueue[#e.recvQueue + 1] = {
        sender = sender,
        msgType = msgType,
        payloadStr = payloadStr,
        enc = enc,
        distribution = distribution,
        bytes = bytes,
        at = GG._Now(),
    }
    e.recvBytes = (e.recvBytes or 0) + bytes
    GG.MarkWorkPending()
    return true
end

function GG.OnGossipCommReceived(prefix, text, distribution, sender)
    if prefix ~= GG.PREFIX then
        return
    end
    -- Inert while stopped: Shutdown clears inited and the Comm sink.
    if not GG._engine or not GG._engine.inited then
        return
    end
    if not GG.HasActiveProvider() then
        return
    end
    sender = GG.NormalizePlayer(sender)
    if not sender then
        return
    end
    if GG.SamePlayer(sender, GG.SelfId()) then
        return
    end
    -- Early encoded size check.
    if type(text) ~= "string" or #text > GG.MAX_ENCODED_ENVELOPE then
        GG._DVerbose("Drop oversized gossip from %s", tostring(sender))
        return
    end

    local ok, msgType, proto, enc, payloadStr, parseErr = GG.ParseEnvelope(text)
    if not ok then
        GG._DVerbose("Bad gossip envelope from %s (%s)", tostring(sender), tostring(parseErr))
        return
    end

    if (msgType == GG.MSG.DISC and distribution ~= "GUILD")
        or (msgType ~= GG.MSG.DISC and distribution ~= "WHISPER") then
        return
    end

    -- Cheap channel + membership admission before proto feedback or decode.
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then
        return
    end
    if not GG.IsGuildMember(sender) then
        GG._DVerbose("Drop gossip from non-member %s", tostring(sender))
        return
    end

    local protoOk, code = GG.ValidateGossipProto(proto)
    if not protoOk then
        -- Quiet fail; optional throttled gossip NACK (never via raid path).
        if distribution == "WHISPER" then
            local e = GG._engine
            local now = GG._Now()
            local lk = peerKey(sender)
            if not e.lastNackAt[lk] or (now - e.lastNackAt[lk]) > 60 then
                e.lastNackAt[lk] = now
                GG.SendGossip(GG.MSG.NACK, {
                    seenProto = proto,
                    supportedMin = GG.PROTO_MIN,
                    supportedMax = GG.PROTO_MAX,
                    code = code,
                }, "WHISPER", sender, { allowWithoutProvider = true, ignoreStreamBusy = true })
            end
        end
        GG._DVerbose("Unsupported gossip proto from %s proto=%s", tostring(sender), tostring(proto))
        return
    end

    if enc == "B64CBORZ" or (SF.SyncProtocol and enc == SF.SyncProtocol.ENC_B64CBORZ) then
        GG._DVerbose("Rejected compressed gossip from %s", tostring(sender))
        return
    end

    -- Payload decoding is intentionally deferred until the bounded dispatcher.
    enqueueReceive(sender, msgType, payloadStr, enc, #text, distribution)
end

local function handleDisc(sender, payload)
    local caps = payload
    if type(caps) ~= "table" then
        return
    end
    local matched = compatibleProviders(caps)
    if #matched == 0 then
        -- Still track peer briefly? Prefer only compatible peers in working set.
        return
    end
    touchPeer(sender, { caps = caps, proto = caps.proto })
    GG.MarkWorkPending()
end

local function handleView(sender, payload)
    local e = GG._engine
    if type(payload) ~= "table" then
        return
    end
    local providerEntry = GG.GetProvider(payload.providerId)
    if not providerEntry or not providerEntry.enabled then
        return
    end
    if tonumber(payload.schema) ~= tonumber(providerEntry.schema) then
        return
    end
    local scopeId = providerScope(providerEntry)
    if not scopeId or payload.scopeId ~= scopeId then
        -- Bound scoped incompatibility so a mismatched provider cannot starve
        -- another compatible provider for this peer after peer-wide cooldown.
        if payload.op == "request" and payload.providerId then
            GG.SendGossip(GG.MSG.ACK, {
                viewId = payload.viewId,
                providerId = payload.providerId,
                scopeMismatch = true,
            }, "WHISPER", sender, { ignoreStreamBusy = true })
        end
        return
    end
    if not providerEligible(providerEntry, sender, scopeId) then
        return
    end

    if payload.op == "request" then
        -- Serve a pull: reply with our view summaries.
        if e.inPull then
            local existing = e.inPull
            if existing.peer == sender and existing.viewId == payload.viewId
                and existing.providerId == payload.providerId and existing.scopeId == scopeId then
                if existing.offerPayload then
                    trySendServedOffer(existing)
                    return
                end
                if existing.phase == "capturing" then
                    -- Idempotent duplicate while capture is in progress: stay
                    -- attached and preserve continuation. Do not treat the
                    -- retry as usable progress (lease must not renew).
                    return
                end
            end
            -- Stop-and-wait: one served pull at a time. Tell requester to rotate.
            GG.SendGossip(GG.MSG.ACK, {
                viewId = payload.viewId,
                busy = true,
                providerId = payload.providerId,
            }, "WHISPER", sender, { ignoreStreamBusy = true })
            return
        end
        -- Never serve a cold/dirty partial index as a permanently coverable view.
        if not indexReadyForView(providerEntry) then
            GG.SendGossip(GG.MSG.ACK, {
                viewId = payload.viewId,
                busy = true,
                providerId = payload.providerId,
            }, "WHISPER", sender, { ignoreStreamBusy = true })
            GG.MarkWorkPending()
            return
        end
        local peer = touchPeer(sender, {})
        if peer then
            peer.activeExchange = true
        end
        e.inPull = {
            peer = sender,
            providerId = providerEntry.id,
            viewId = payload.viewId,
            scopeId = scopeId,
            eligibilityGen = providerEntry.eligibilityGen,
            epoch = providerEntry.index.epoch,
            phase = "capturing",
            captureState = nil,
            engineGen = e.generation,
            usableProgressAt = GG._Now(),
            pauseExcluded = 0,
            finalSubmitted = false,
        }
        GG.MarkWorkPending()
        return
    end

    if payload.op == "offer" then
        local pull = e.outPull
        if not pull or pull.phase ~= "wait_view" or pull.viewId ~= payload.viewId
            or pull.peer ~= sender or pull.providerId ~= payload.providerId
            or pull.scopeId ~= payload.scopeId then
            return
        end
        if pull.engineGen ~= e.generation then
            return
        end
        payload.buckets = GG.UnpackBucketSummaries(payload.packedBuckets or payload.buckets)
        pull.remoteView = payload
        pull.phase = "compare"
        pull.usableProgressAt = GG._Now()
        pull.bucketCursor = 0
        pull.afterSeq = 0
        GG.MarkWorkPending()
    end
end

-- Returns "defer" when the shared step export budget is exhausted so the
-- caller can put the admitted request back on the receive queue.
local function handleManifest(sender, payload, stepLimits)
    local e = GG._engine
    if payload.op == "request" then
        local pull = e.inPull
        if not pull or pull.peer ~= sender or pull.viewId ~= payload.viewId
            or type(payload.requestId) ~= "string" then
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId)
            or pull.epoch ~= (entry and entry.index and entry.index.epoch)
            or pull.eligibilityGen ~= (entry and entry.eligibilityGen) then
            closeInPull("stale_provider_view")
            return
        end
        local limits = resolveServeLimits(stepLimits or e.stepLimits, payload.mode)
        local manifestBudget = consumeStepExportBudget("manifest", limits.manifestEntries or 1)
        if manifestBudget <= 0 then
            -- Shared step export budget exhausted; retain the admitted request
            -- without renewing the served-view lease.
            GG.MarkWorkPending()
            return "defer"
        end
        local metaRemaining = tonumber(e.stepMetaRemaining)
        if metaRemaining ~= nil and metaRemaining <= 0 then
            -- Shared examine budget exhausted; do not force another examination
            -- or renew the lease merely because the request was requeued.
            GG.MarkWorkPending()
            return "defer"
        end
        local endSeq = 0
        local bucketId = tonumber(payload.bucketId) or 0
        if pull.buckets and pull.buckets[bucketId] then
            endSeq = pull.buckets[bucketId].lastSeq or 0
        end
        -- Capture was fixed at serve time; use captured end marker.
        local examineBudget = math.max(1, metaRemaining or manifestBudget)
        local entries, seekMeta = GG.IndexSeekManifest(
            entry.index,
            bucketId,
            payload.afterSeq or 0,
            endSeq,
            manifestBudget,
            function(recordId, indexEntry)
                return recordExportable(entry, sender, pull.scopeId, recordId, indexEntry)
            end,
            examineBudget
        )
        local examined = math.max(0, tonumber(seekMeta and seekMeta.examined) or 0)
        if e.stepStats then
            e.stepStats.indexExamined = (e.stepStats.indexExamined or 0) + examined
        end
        e.stepMetaRemaining = math.max(0, (tonumber(e.stepMetaRemaining) or examineBudget) - examined)
        local response = {
            op = "page",
            viewId = pull.viewId,
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            requestId = payload.requestId,
            subpage = tonumber(payload.subpage) or 1,
            bucketId = bucketId,
            afterSeq = payload.afterSeq or 0,
            endSeq = endSeq,
            entries = entries,
            -- Scan continuation for empty/filtered budget slices.
            scanAfter = seekMeta and seekMeta.lastExaminedSeq or nil,
            done = seekMeta and seekMeta.done == true,
            engineGen = e.generation,
        }
        -- A manifest must also be sendable as one bounded gossip envelope.
        while #response.entries > 0 and not GG.BuildWireMessage(GG.MSG.MANIFEST, response) do
            table.remove(response.entries)
            response.done = false
        end
        if #response.entries == 0 and #entries > 0 then
            -- The descriptor itself cannot fit. Do not advance past it or
            -- pretend this bucket is covered; give the requester a correlated
            -- terminal outcome so it can cool down without a tight retry loop.
            response.limit = true
            response.error = "manifest_descriptor_too_large"
            response.done = false
        end
        -- Lease renews only after validated export work is submitted.
        GG.SendGossip(GG.MSG.MANIFEST, response, "WHISPER", sender, {
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            onFinalSubmitted = function(success)
                noteInPullSubmission(pull, success)
            end,
        })
        return
    end

    if payload.op == "page" then
        local pull = e.outPull
        if not pull or pull.phase ~= "wait_manifest" or pull.peer ~= sender
            or pull.viewId ~= payload.viewId or pull.providerId ~= payload.providerId
            or pull.scopeId ~= payload.scopeId
            or payload.requestId ~= pull.expectedRequestId
            or tonumber(payload.subpage) ~= tonumber(pull.expectedSubpage)
            or tonumber(payload.bucketId) ~= tonumber(pull.activeBucket)
            or tonumber(payload.afterSeq) ~= tonumber(pull.afterSeq) then
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId) then
            closeOutPull("provider_ineligible")
            return
        end
        if payload.limit then
            e.peerCooldownUntil[peerKey(sender)] = GG._Now() + GG.POST_EXHAUSTION_COOLDOWN_SEC
            closeOutPull("provider_limit")
            return
        end
        -- Nonterminal pages must prove monotonic bounded progress before any
        -- request/lease mutation. Empty filtered pages may advance via scanAfter.
        local entries = type(payload.entries) == "table" and payload.entries or {}
        local entryCount = #entries
        local pullAfter = tonumber(pull.afterSeq) or 0
        local endSeq = tonumber(payload.endSeq)
        if endSeq == nil then
            endSeq = tonumber(pull.remoteEndSeq) or 0
        end
        local scanAfter = tonumber(payload.scanAfter)
        local terminal = payload.done == true
        local hasEntries = entryCount > 0
        local scanProgress = scanAfter ~= nil and scanAfter > pullAfter
        if scanAfter ~= nil then
            if scanAfter < pullAfter or (endSeq > 0 and scanAfter > endSeq) then
                -- Backward or out-of-range scan: drop without renewing the lease.
                return
            end
        end
        if not terminal and not hasEntries and not scanProgress then
            -- Unchanged/absent progress on a nonterminal page: ignore.
            return
        end
        pull.manifest = payload
        pull.phase = "need_bodies"
        pull.neededBodies = {}
        pull.bodyOffset = 0
        pull.bodySubpage = 0
        pull.expectedRequestId = nil
        pull.expectedSubpage = nil
        pull.outstanding = nil
        pull.usableProgressAt = GG._Now()
        for _, ent in ipairs(entries) do
            local have = GG.IndexGetEntry(entry.index, ent.id)
            if (not have or have.versionFp ~= ent.versionFp)
                and not isKnownUnresolvedRevision(
                    pull.providerId, pull.peer, pull.scopeId, ent.id, ent.versionFp) then
                pull.neededBodies[#pull.neededBodies + 1] = ent
            end
        end
        GG.MarkWorkPending()
    end
end

-- Returns "defer" when the shared step export budget is exhausted so the
-- caller can put the admitted request back on the receive queue.
local function handleBody(sender, payload, stepLimits)
    local e = GG._engine
    if payload.op == "request" then
        local pull = e.inPull
        if not pull or pull.peer ~= sender or pull.viewId ~= payload.viewId
            or type(payload.requestId) ~= "string"
            or not hasValidBodyIdArray(payload.ids) then
            return
        end
        if not transportSenderAuthorized(sender) then
            closeInPull("sender_unauthorized")
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId)
            or pull.epoch ~= (entry and entry.index and entry.index.epoch)
            or pull.eligibilityGen ~= (entry and entry.eligibilityGen)
            or not entry.api or type(entry.api.GetRecordBody) ~= "function" then
            closeInPull("stale_provider_view")
            return
        end
        local records = {}
        local skippedIds = {}
        local limits = resolveServeLimits(stepLimits or e.stepLimits, payload.mode)
        local cpuLimit = tonumber(limits.cpuMs)
        local stepStartedAt = e.stepStartedAt
        -- Pre-exhausted CPU: defer without renewing the lease or sending an
        -- empty unusable page that would force a response timeout.
        if stepStartedAt and debugprofilestop and cpuLimit
            and (debugprofilestop() - stepStartedAt) >= cpuLimit then
            GG.MarkWorkPending()
            return "defer"
        end
        local maxBodies = consumeStepExportBudget("bodies", math.min(#payload.ids, limits.bodies or 1))
        if maxBodies <= 0 then
            -- Shared step export budget exhausted; retain the admitted request.
            GG.MarkWorkPending()
            return "defer"
        end
        local more = #payload.ids > maxBodies
        local lookups = 0
        local cpuCut = false
        for requestIndex, rid in ipairs(payload.ids) do
            if requestIndex > maxBodies then
                more = true
                break
            end
            if stepStartedAt and debugprofilestop and cpuLimit
                and (debugprofilestop() - stepStartedAt) >= cpuLimit then
                more = true
                cpuCut = true
                break
            end
            if not transportSenderAuthorized(sender) then
                closeInPull("sender_unauthorized")
                return
            end
            local exportCtx = {
                peer = sender,
                scopeId = pull.scopeId,
                eligibilityGen = entry.eligibilityGen,
            }
            local ok, body = false, nil
            if recordExportable(entry, sender, pull.scopeId, rid, GG.IndexGetEntry(entry.index, rid)) then
                ok, body = pcall(entry.api.GetRecordBody, rid, exportCtx)
                lookups = lookups + 1
            end
            if ok and type(body) == "table" then
                local rawOk, raw = false, nil
                if C_EncodingUtil and C_EncodingUtil.SerializeCBOR then
                    rawOk, raw = pcall(C_EncodingUtil.SerializeCBOR, body)
                end
                if not rawOk or type(raw) ~= "string" or #raw > GG.MAX_RECORD_CBOR then
                    skippedIds[#skippedIds + 1] = rid
                else
                    local candidate = {
                        op = "page", viewId = pull.viewId, providerId = pull.providerId,
                        scopeId = pull.scopeId, requestId = payload.requestId,
                        subpage = tonumber(payload.subpage) or 1, records = {},
                        skippedIds = skippedIds, more = false, engineGen = e.generation,
                    }
                    for i, record in ipairs(records) do
                        candidate.records[i] = record
                    end
                    candidate.records[#candidate.records + 1] = body
                    if GG.BuildWireMessage(GG.MSG.BODY, candidate) then
                        records[#records + 1] = body
                    elseif #records == 0 then
                        -- It fits the record cap but not a gossip envelope: never retry forever.
                        skippedIds[#skippedIds + 1] = rid
                    else
                        more = true
                        break
                    end
                end
            else
                skippedIds[#skippedIds + 1] = rid
            end
        end
        if e.stepStats then
            e.stepStats.exportLookups = (e.stepStats.exportLookups or 0) + lookups
        end
        local settled = #records + #skippedIds
        if settled == 0 then
            -- No ID settled (CPU cut before first / envelope failure). Defer
            -- rather than send an empty more=true page the requester rejects.
            if cpuCut then
                GG.MarkWorkPending()
                return "defer"
            end
            -- Pathological: cannot settle even one ID; cool down without lease renew.
            e.peerCooldownUntil[peerKey(sender)] = GG._Now() + GG.POST_EXHAUSTION_COOLDOWN_SEC
            closeInPull("body_unsettled")
            return
        end
        pull.usableProgressAt = GG._Now()
        -- Unprocessed trailing IDs are preserved via more=true; they are not skipped.
        GG.SendGossip(GG.MSG.BODY, {
            op = "page",
            viewId = pull.viewId,
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            requestId = payload.requestId,
            subpage = tonumber(payload.subpage) or 1,
            records = records,
            skippedIds = skippedIds,
            more = more,
            engineGen = e.generation,
        }, "WHISPER", sender, {
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            onFinalSubmitted = function(success)
                noteInPullSubmission(pull, success)
            end,
        })
        return
    end

    if payload.op == "page" then
        local pull = e.outPull
        if not pull or pull.phase ~= "wait_bodies" or pull.peer ~= sender
            or pull.viewId ~= payload.viewId or pull.providerId ~= payload.providerId
            or pull.scopeId ~= payload.scopeId
            or payload.requestId ~= pull.expectedRequestId
            or tonumber(payload.subpage) ~= tonumber(pull.expectedSubpage) then
            return
        end
        local expected = pull.expectedIds or {}
        local expectedOrder = pull.expectedOrder or {}
        local expectedFp = pull.expectedFingerprints or {}
        local function isExpected(id)
            return expected[tostring(id)] == true
        end
        local seen = {}
        for _, record in ipairs(payload.records) do
            if not isExpected(record.id)
                or seen[tostring(record.id)]
                or (expectedFp[tostring(record.id)] and expectedFp[tostring(record.id)] ~= record.versionFp) then
                return
            end
            seen[tostring(record.id)] = true
        end
        if payload.skippedIds ~= nil and type(payload.skippedIds) ~= "table" then
            return
        end
        for _, recordId in ipairs(payload.skippedIds or {}) do
            if not isExpected(recordId) or seen[tostring(recordId)] then
                return
            end
            seen[tostring(recordId)] = true
        end
        local settled = #payload.records + #(payload.skippedIds or {})
        if settled == 0 then
            return
        end
        -- A partial page may settle only the leading portion of the current
        -- request. Otherwise a reordered/omitted response could advance the
        -- cursor over records which were never delivered.
        for i = 1, settled do
            local expectedId = expectedOrder[i]
            if not expectedId or not seen[tostring(expectedId)] then
                return
            end
        end
        if payload.more ~= true and settled ~= #expectedOrder then
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId)
            or pull.localEpoch ~= (entry and entry.index and entry.index.epoch) then
            closeOutPull("provider_ineligible")
            return
        end
        pull.bodyPage = payload
        pull.bodyApplyCursor = 0
        pull.pendingBodyCount = settled
        pull.bodyMore = payload.more == true
        pull.expectedRequestId = nil
        pull.expectedSubpage = nil
        pull.outstanding = nil
        pull.phase = "apply_bodies"
        pull.usableProgressAt = GG._Now()
        GG.MarkWorkPending()
    end
end

local function handleAck(sender, payload)
    local e = GG._engine
    if type(payload) ~= "table" then
        return
    end
    if payload.scopeMismatch and payload.providerId then
        -- Correlate to the active request/view; stale ACKs must not poison selection.
        local pull = e.outPull
        if not pull or pull.peer ~= sender
            or pull.providerId ~= payload.providerId
            or pull.viewId ~= payload.viewId then
            return
        end
        local peer = e.peers[peerKey(sender)] or touchPeer(sender, {})
        if peer then
            local pid = tostring(payload.providerId)
            peer.scopeIncompat = peer.scopeIncompat or {}
            peer.scopeIncompat[pid] = {
                fingerprint = peer.capFingerprints and peer.capFingerprints[pid] or nil,
                localScope = pull.scopeId,
                at = GG._Now(),
            }
        end
        closeOutPull("scope_mismatch")
        GG.MarkWorkPending()
        return
    end
    if payload.busy then
        local pull = e.outPull
        if pull and pull.peer == sender and pull.viewId == payload.viewId then
            e.peerCooldownUntil[peerKey(sender)] = GG._Now() + 2
            closeOutPull("peer_busy")
            GG.MarkWorkPending()
        end
        return
    end
    local pull = e.inPull
    if pull and pull.peer == sender and pull.viewId == payload.viewId then
        if payload.done then
            closeInPull("acked_done")
        end
    end
end

local function boundedValue(value, depth, state, seen)
    if type(value) ~= "table" then
        return true
    end
    if depth > GG.MAX_CBOR_DEPTH or seen[value] then
        return false
    end
    seen[value] = true
    for _, child in pairs(value) do
        state.nodes = state.nodes + 1
        if state.nodes > GG.MAX_CBOR_NODES or not boundedValue(child, depth + 1, state, seen) then
            return false
        end
    end
    seen[value] = nil
    return true
end

local function hasValidEntries(entries)
    if type(entries) ~= "table" then
        return false
    end
    for _, entry in ipairs(entries) do
        if type(entry) ~= "table" or entry.id == nil or entry.versionFp == nil then
            return false
        end
    end
    return true
end

local function recordRawWithinCap(record)
    if type(record) ~= "table" then
        return false
    end
    if not (C_EncodingUtil and C_EncodingUtil.SerializeCBOR) then
        return false
    end
    local ok, raw = pcall(C_EncodingUtil.SerializeCBOR, record)
    if not ok or type(raw) ~= "string" then
        return false
    end
    return #raw <= GG.MAX_RECORD_CBOR
end

local function hasValidRecords(records)
    if type(records) ~= "table" then
        return false
    end
    for _, record in ipairs(records) do
        if type(record) ~= "table" or record.id == nil or record.versionFp == nil then
            return false
        end
        -- Enforce the advertised 2 KiB raw record cap before provider mutation.
        if not recordRawWithinCap(record) then
            return false
        end
    end
    return true
end

-- Non-empty dense BODY id arrays only. Empty/sparse/map-shaped tables are
-- invalid work (drop), not temporary budget exhaustion (defer).
hasValidBodyIdArray = function(ids)
    if type(ids) ~= "table" then
        return false
    end
    local n = #ids
    if n < 1 or n > GG.BODIES_PER_MESSAGE.NORMAL then
        return false
    end
    local count = 0
    for key, value in pairs(ids) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key > n or key ~= math.floor(key) then
            return false
        end
        if value == nil or (type(value) ~= "string" and type(value) ~= "number") then
            return false
        end
    end
    return count == n
end

local function validPayloadForMessage(msgType, payload, distribution)
    if type(payload) ~= "table" then
        return false
    end
    if not boundedValue(payload, 1, { nodes = 1 }, {}) then
        return false
    end
    if msgType == GG.MSG.DISC then
        return distribution == "GUILD" and type(payload.providers) == "table"
            and #payload.providers <= GG.MAX_PEERS
    end
    if msgType == GG.MSG.VIEW then
        return distribution == "WHISPER"
            and (payload.op == "request" or payload.op == "offer")
            and type(payload.viewId) == "string" and type(payload.providerId) == "string"
            and type(payload.scopeId) == "string"
    end
    if msgType == GG.MSG.MANIFEST then
        if distribution ~= "WHISPER" or (payload.op ~= "request" and payload.op ~= "page") then
            return false
        end
        return type(payload.viewId) == "string" and type(payload.providerId) == "string"
            and type(payload.scopeId) == "string" and type(payload.requestId) == "string"
            and (payload.op ~= "page" or hasValidEntries(payload.entries))
    end
    if msgType == GG.MSG.BODY then
        if distribution ~= "WHISPER" or (payload.op ~= "request" and payload.op ~= "page") then
            return false
        end
        if type(payload.viewId) ~= "string" or type(payload.providerId) ~= "string"
            or type(payload.scopeId) ~= "string" or type(payload.requestId) ~= "string" then
            return false
        end
        if payload.op == "request" then
            return hasValidBodyIdArray(payload.ids)
        end
        return hasValidRecords(payload.records)
            and #payload.records <= GG.BODIES_PER_MESSAGE.NORMAL
            and (payload.skippedIds == nil or type(payload.skippedIds) == "table")
    end
    return distribution == "WHISPER" and (msgType == GG.MSG.ACK or msgType == GG.MSG.NACK)
end

transportSenderAuthorized = function(sender)
    return GG.IsGuildReady() and GG.IsGuildMember(sender) == true
end

-- Returns "defer" when export work must wait for a later step budget.
local function dispatchOne(item, limits)
    local msgType = item.msgType
    -- Revalidate guild readiness/membership at dispatch so deferred/queued work
    -- cannot outlive roster authorization that admitted the encoded envelope.
    if not transportSenderAuthorized(item.sender) then
        GG._DVerbose("Drop gossip from unauthorized sender %s", tostring(item.sender))
        return
    end
    local payload, err = GG.DecodePayload(item.payloadStr, item.enc)
    if err or not validPayloadForMessage(msgType, payload, item.distribution) then
        GG._DVerbose("Drop malformed gossip %s from %s", tostring(msgType), tostring(item.sender))
        return
    end
    if msgType == GG.MSG.DISC then
        handleDisc(item.sender, payload)
    elseif msgType == GG.MSG.VIEW then
        handleView(item.sender, payload)
    elseif msgType == GG.MSG.MANIFEST then
        return handleManifest(item.sender, payload, limits)
    elseif msgType == GG.MSG.BODY then
        return handleBody(item.sender, payload, limits)
    elseif msgType == GG.MSG.ACK then
        handleAck(item.sender, payload)
    elseif msgType == GG.MSG.NACK then
        GG._DVerbose("Gossip NACK from %s", tostring(item.sender))
    end
end

---------------------------------------------------------------------------
-- Processor step
---------------------------------------------------------------------------

local function resendOutstanding(pull)
    local outstanding = pull and pull.outstanding
    if not outstanding then
        return false
    end
    local entry = GG.GetProvider(pull.providerId)
    if not providerEligible(entry, pull.peer, pull.scopeId) then
        closeOutPull("provider_ineligible")
        return false
    end
    pull.finalSubmitted = false
    return GG.SendGossip(outstanding.msgType, outstanding.payload, "WHISPER", pull.peer, {
        providerId = pull.providerId,
        scopeId = pull.scopeId,
        onFinalSubmitted = function(success, sendResult)
            noteOutPullSubmission(pull, success, sendResult)
        end,
    })
end

-- Reopen bookmarks/coverage for a scoped peer/provider without deleting sibling
-- unresolved revisions. Expiry and cap eviction call this, then remove only the
-- selected obligation key.
local function reopenCoverageForUnresolved(item)
    if not item then
        return
    end
    clearBookmarksForScope(item.peer, item.providerId, item.scopeId)
    local peer = item.peerKey and GG._engine.peers[item.peerKey]
    if peer and peer.covered then
        peer.covered[item.providerId] = nil
    end
end

local function invalidateUnresolvedCoverage(item)
    reopenCoverageForUnresolved(item)
end

-- Revision-scoped unresolved obligations. Keys are length-prefixed so scopes
-- containing '|' cannot collide; matching always uses item metadata fields.
local function unresolvedRevisionKey(providerId, peerName, scopeId, recordId, versionFp)
    return lengthPrefixedKey(providerId, peerKey(peerName), scopeId, recordId, versionFp or "")
end

isKnownUnresolvedRevision = function(providerId, peerName, scopeId, recordId, versionFp)
    if versionFp == nil then
        return false
    end
    local key = unresolvedRevisionKey(providerId, peerName, scopeId, recordId, versionFp)
    return GG._engine.unresolved[key] ~= nil
end

clearUnresolvedRevision = function(providerId, peerName, scopeId, recordId, versionFp)
    if versionFp == nil then
        return
    end
    local key = unresolvedRevisionKey(providerId, peerName, scopeId, recordId, versionFp)
    GG._engine.unresolved[key] = nil
end

recordUnresolved = function(providerId, recordId, result, now, peerName, scopeId, versionFp)
    local e = GG._engine
    local peer = peerKey(peerName)
    versionFp = versionFp ~= nil and tostring(versionFp) or ""
    local key = unresolvedRevisionKey(providerId, peerName, scopeId, recordId, versionFp)
    local existing = e.unresolved[key]
    if existing and existing.result == result and tostring(existing.versionFp or "") == versionFp then
        -- Identical outcome: preserve original age so TTL/eviction can fire.
        return
    end
    -- A new fingerprint supersedes older revisions of the same record id.
    for unresolvedKey, item in pairs(e.unresolved) do
        if item.providerId == providerId
            and item.peerKey == peer
            and item.scopeId == scopeId
            and tostring(item.recordId) == tostring(recordId)
            and tostring(item.versionFp or "") ~= versionFp then
            e.unresolved[unresolvedKey] = nil
        end
    end
    e.unresolved[key] = {
        at = now,
        providerId = providerId,
        recordId = recordId,
        versionFp = versionFp,
        result = result,
        peer = peerName,
        peerKey = peer,
        scopeId = scopeId,
    }
    local oldestKey, oldestAt, count = nil, nil, 0
    for unresolvedKey, item in pairs(e.unresolved) do
        count = count + 1
        if not oldestAt or (item.at or 0) < oldestAt then
            oldestKey, oldestAt = unresolvedKey, item.at or 0
        end
    end
    if count > GG.MAX_UNRESOLVED and oldestKey then
        -- Cap eviction reopens bookmarks/coverage for recovery of the selected
        -- revision only; sibling obligations remain so coverage stays honest.
        local evicted = e.unresolved[oldestKey]
        invalidateUnresolvedCoverage(evicted)
        e.unresolved[oldestKey] = nil
    end
end

hasUnresolvedForProvider = function(providerId, peerName, scopeId)
    for _, item in pairs(GG._engine.unresolved) do
        if item.providerId == providerId
            and (not peerName or item.peerKey == peerKey(peerName))
            and (not scopeId or item.scopeId == scopeId) then
            return true
        end
    end
    return false
end

reopenUnresolvedEnumeration = function(providerId)
    local e = GG._engine
    local snapshot = {}
    for key, item in pairs(e.unresolved or {}) do
        if not providerId or item.providerId == providerId then
            snapshot[#snapshot + 1] = { key = key, item = item }
            e.unresolved[key] = nil
        end
    end
    local touched = {}
    for _, row in ipairs(snapshot) do
        local item = row.item
        local ck = lengthPrefixedKey(item.peerKey or "", item.providerId or "", item.scopeId or "")
        if not touched[ck] then
            touched[ck] = true
            -- Bookmarks only: obligations for this provider were already removed.
            clearBookmarksForScope(item.peer, item.providerId, item.scopeId)
            local peer = item.peerKey and e.peers[item.peerKey]
            if peer and peer.covered then
                peer.covered[item.providerId] = nil
            end
        end
    end
end
GG.ReopenUnresolvedEnumeration = reopenUnresolvedEnumeration

local function advanceOutPull(limits, now)
    local e = GG._engine
    local pull = e.outPull
    if not pull then
        return false
    end
    if pull.engineGen ~= e.generation then
        closeOutPull("stale_gen")
        return false
    end

    if pull.retryAt then
        if now < pull.retryAt then
            return false
        end
        pull.retryAt = nil
        resendOutstanding(pull)
        return true
    end

    if not pull.finalSubmitted and pull.outstanding
        and now >= (pull.usableProgressAt or now)
        and (now - (pull.usableProgressAt or now)) >= GG.PAGE_RETRY_BACKOFF[1] then
        -- Queue admission is not final-fragment submission. If a lower layer
        -- neither invokes its callback nor cancels the item, retain the exact
        -- correlated obligation and recover on the first bounded backoff.
        scheduleOutPullRetry(pull, "submission_unconfirmed")
        return true
    end

    if pull.finalSubmitted and pull.awaitingSince and pull.outstanding
        and now >= (pull.usableProgressAt or pull.awaitingSince)
        and (now - (pull.usableProgressAt or pull.awaitingSince)) > GG.VIEW_IDLE_TIMEOUT_SEC then
        scheduleOutPullRetry(pull, "response_timeout")
        return true
    end

    local entry = GG.GetProvider(pull.providerId)
    if not providerEligible(entry, pull.peer, pull.scopeId)
        or pull.localEpoch ~= (entry and entry.index and entry.index.epoch) then
        closeOutPull("provider_gone")
        return false
    end

    if pull.phase == "compare" and pull.remoteView then
        -- Find next differing bucket.
        while pull.bucketCursor < GG.BUCKET_COUNT do
            local b = pull.bucketCursor
            local lb = pull.localBuckets and pull.localBuckets[b]
            local rb = pull.remoteView.buckets and pull.remoteView.buckets[b]
            pull.bucketCursor = b + 1
            if GG.BucketsDiffer(lb, rb) and rb and (rb.lastSeq or 0) > 0 then
                local bm = select(1, getBookmark(entry, pull.peer, pull.scopeId, b))
                local after = 0
                local remoteElig = pull.remoteView.eligibilityGen
                if bm and bm.epoch == pull.remoteView.epoch and bm.scopeId == pull.scopeId
                    and bm.eligibilityGen ~= nil and bm.eligibilityGen == remoteElig then
                    after = bm.afterSeq or 0
                end
                pull.activeBucket = b
                pull.afterSeq = after
                pull.remoteEndSeq = rb.lastSeq or 0
                pull.phase = "request_manifest"
                break
            end
        end
        if pull.phase == "compare" then
            -- Finite enumeration finished; coverage requires no unresolved obligations
            -- and an unchanged remote announcement identity for this pull.
            GG.SendGossip(GG.MSG.ACK, {
                viewId = pull.viewId,
                done = true,
                providerId = pull.providerId,
            }, "WHISPER", pull.peer)
            local stillUnresolved = hasUnresolvedForProvider(
                pull.providerId, pull.peer, pull.scopeId)
            local p = e.peers[peerKey(pull.peer)]
            local currentFp = p and p.capFingerprints and p.capFingerprints[pull.providerId]
            local announcementStale = pull.remoteAnnouncementFp
                and currentFp
                and currentFp ~= pull.remoteAnnouncementFp
            if announcementStale or pull.needsFollowUp then
                if GG._sched then
                    GG._sched.dirtyFollowUp = true
                end
            end
            if p and not stillUnresolved and not announcementStale and not pull.needsFollowUp then
                p.covered = p.covered or {}
                p.covered[pull.providerId] = true
                closeOutPull("complete")
            elseif stillUnresolved then
                -- Incomplete coverage + bounded backoff; do not hot-loop unchanged obligations.
                closeOutPull("unresolved")
            else
                -- Stale announcement mid-pull: release without claiming coverage.
                closeOutPull("stale_announcement")
            end
            if GG.HasDirtyFollowUp() then
                GG.ClearDirtyFollowUp()
                -- Local/remote appends invalidate coverage so a follow-up can run.
                for _, peer in pairs(e.peers) do
                    peer.covered = {}
                end
                GG.NotifyMeaningfulChange()
            end
            return true
        end
    end

    if pull.phase == "request_manifest" then
        local requestId = nextRequestId(pull, "manifest")
        local payload = {
            op = "request",
            viewId = pull.viewId,
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            requestId = requestId,
            subpage = 1,
            bucketId = pull.activeBucket,
            afterSeq = pull.afterSeq,
            mode = limits.mode,
            engineGen = e.generation,
        }
        pull.expectedRequestId = requestId
        pull.expectedSubpage = 1
        pull.expectedIds = nil
        pull.outstanding = { msgType = GG.MSG.MANIFEST, payload = payload }
        pull.phase = "wait_manifest"
        resendOutstanding(pull)
        return true
    end

    if pull.phase == "need_bodies" then
        if not pull.neededBodies or #pull.neededBodies == 0 then
            -- Advance enumeration cursor for this manifest page. Empty filtered
            -- slices use scanAfter so the requester does not retry the same range.
            local page = pull.manifest
            if page and page.entries and #page.entries > 0 then
                pull.afterSeq = page.entries[#page.entries].seq or pull.afterSeq
            elseif page and page.scanAfter
                and (tonumber(page.scanAfter) or 0) > (tonumber(pull.afterSeq) or 0) then
                pull.afterSeq = tonumber(page.scanAfter)
            end
            setBookmark(entry, pull.peer, pull.scopeId, pull.activeBucket, {
                epoch = pull.remoteView and pull.remoteView.epoch,
                scopeId = pull.scopeId,
                eligibilityGen = pull.remoteView and pull.remoteView.eligibilityGen,
                afterSeq = pull.afterSeq,
            })
            GG.SendGossip(GG.MSG.ACK, {
                viewId = pull.viewId,
                providerId = pull.providerId,
                bucketId = pull.activeBucket,
                afterSeq = pull.afterSeq,
            }, "WHISPER", pull.peer)
            if page and page.done then
                pull.phase = "compare"
                pull.manifest = nil
            else
                pull.phase = "request_manifest"
                pull.manifest = nil
            end
            return true
        end
        local ids, expectedIds, expectedFingerprints = {}, {}, {}
        local maxBodies = limits.bodies
        for i = (pull.bodyOffset or 0) + 1, math.min(#pull.neededBodies, (pull.bodyOffset or 0) + maxBodies) do
            local needed = pull.neededBodies[i]
            ids[#ids + 1] = needed.id
            expectedIds[tostring(needed.id)] = true
            expectedFingerprints[tostring(needed.id)] = needed.versionFp
        end
        if #ids == 0 then
            closeOutPull("body_cursor_invalid")
            return false
        end
        pull.bodySubpage = (pull.bodySubpage or 0) + 1
        local requestId = nextRequestId(pull, "body")
        local payload = {
            op = "request",
            viewId = pull.viewId,
            providerId = pull.providerId,
            scopeId = pull.scopeId,
            requestId = requestId,
            subpage = pull.bodySubpage,
            ids = ids,
            mode = limits.mode,
            engineGen = e.generation,
        }
        pull.pendingBodyCount = #ids
        pull.expectedRequestId = requestId
        pull.expectedSubpage = pull.bodySubpage
        pull.expectedIds = expectedIds
        pull.expectedOrder = ids
        pull.expectedFingerprints = expectedFingerprints
        pull.outstanding = { msgType = GG.MSG.BODY, payload = payload }
        pull.phase = "wait_bodies"
        resendOutstanding(pull)
        return true
    end

    if pull.phase == "apply_bodies" and pull.bodyPage then
        local apps = 0
        local ctx = {
            sender = pull.peer,
            scopeId = pull.scopeId,
            providerId = pull.providerId,
            viewId = pull.viewId,
            distribution = "WHISPER",
        }
        local records = pull.bodyPage.records or {}
        local cursor = tonumber(pull.bodyApplyCursor) or 0
        while cursor < #records and apps < limits.apps do
            local rec = records[cursor + 1]
            -- Guild transport boundary must still hold before delayed application;
            -- provider eligibility is an additional restriction, never a substitute.
            if not transportSenderAuthorized(pull.peer) then
                closeOutPull("peer_unauthorized")
                return false
            end
            -- Re-check eligibility immediately before the provider side effect.
            if not providerEligible(entry, pull.peer, pull.scopeId)
                or pull.localEpoch ~= (entry and entry.index and entry.index.epoch) then
                closeOutPull("provider_ineligible")
                return false
            end
            local result = GG.ApplyRecordToProvider(entry, rec, ctx)
            -- Applying an accepted replacement can intentionally rebuild the
            -- local provider index. The next record still revalidates against
            -- the epoch produced by this provider-owned side effect.
            if result == GG.DELIVERY.ACCEPTED or result == GG.DELIVERY.DUPLICATE then
                pull.localEpoch = entry.index and entry.index.epoch or pull.localEpoch
                local vfp = rec.versionFp
                    or (pull.expectedFingerprints and pull.expectedFingerprints[tostring(rec.id)])
                clearUnresolvedRevision(pull.providerId, pull.peer, pull.scopeId, rec.id, vfp)
            elseif result == GG.DELIVERY.PENDING or result == GG.DELIVERY.REJECTED then
                local vfp = rec.versionFp
                    or (pull.expectedFingerprints and pull.expectedFingerprints[tostring(rec.id)])
                recordUnresolved(
                    pull.providerId, rec.id, result, now, pull.peer, pull.scopeId, vfp)
            end
            cursor = cursor + 1
            apps = apps + 1
            pull.bodyApplyCursor = cursor
        end
        if cursor < #records then
            -- SLOW mode may make one application at a time; retain this page.
            pull.usableProgressAt = now
            return true
        end
        local skipped = pull.bodyPage.skippedIds or {}
        for _, recordId in ipairs(skipped) do
            -- Skipped bodies have no body payload; use correlated manifest fingerprint.
            local vfp = pull.expectedFingerprints
                and pull.expectedFingerprints[tostring(recordId)]
            recordUnresolved(
                pull.providerId, recordId, GG.DELIVERY.REJECTED, now, pull.peer, pull.scopeId, vfp)
        end
        -- Enumeration advances past unresolved revisions; obligations remain and
        -- block peer.covered until recovery. Neither PENDING nor REJECTED may
        -- indefinitely block unrelated later pages/buckets.
        local appliedCount = pull.pendingBodyCount or (#records + #skipped)
        pull.bodyOffset = (pull.bodyOffset or 0) + appliedCount
        pull.bodyPage = nil
        pull.bodyApplyCursor = 0
        pull.pendingBodyCount = nil
        if pull.bodyMore then
            pull.bodyMore = nil
            pull.phase = "need_bodies"
            pull.usableProgressAt = now
            return true
        end
        if pull.bodyOffset >= #(pull.neededBodies or {}) then
            -- Finished body subpages for this manifest.
            local page = pull.manifest
            if page and page.entries and #page.entries > 0 then
                pull.afterSeq = page.entries[#page.entries].seq or pull.afterSeq
            elseif page and page.scanAfter
                and (tonumber(page.scanAfter) or 0) > (tonumber(pull.afterSeq) or 0) then
                pull.afterSeq = tonumber(page.scanAfter)
            end
            setBookmark(entry, pull.peer, pull.scopeId, pull.activeBucket, {
                epoch = pull.remoteView and pull.remoteView.epoch,
                scopeId = pull.scopeId,
                eligibilityGen = pull.remoteView and pull.remoteView.eligibilityGen,
                afterSeq = pull.afterSeq,
            })
            pull.neededBodies = nil
            pull.bodyOffset = 0
            if page and page.done then
                pull.phase = "compare"
            else
                pull.phase = "request_manifest"
            end
            pull.manifest = nil
            GG.SendGossip(GG.MSG.ACK, {
                viewId = pull.viewId,
                providerId = pull.providerId,
                bucketId = pull.activeBucket,
                afterSeq = pull.afterSeq,
            }, "WHISPER", pull.peer)
        else
            pull.phase = "need_bodies"
        end
        pull.usableProgressAt = now
        return true
    end

    return false
end

local function advanceInPull(now)
    local e = GG._engine
    local pull = e.inPull
    if not pull then
        return false
    end
    if pull.engineGen ~= e.generation then
        closeInPull("stale_gen")
        return true
    end
    if pull.phase == "capturing" then
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, pull.peer, pull.scopeId)
            or not indexReadyForView(entry)
            or pull.epoch ~= (entry and entry.index and entry.index.epoch)
            or pull.eligibilityGen ~= (entry and entry.eligibilityGen) then
            closeInPull("capture_invalidated")
            return true
        end
        local limits = e.stepLimits or GG.GetStepLimits()
        local metaBudget = math.max(0, tonumber(e.stepMetaRemaining) or tonumber(limits.indexEntries) or 0)
        if metaBudget <= 0 and viewExportFilter(entry, pull.peer, pull.scopeId) then
            GG.MarkWorkPending()
            return true
        end
        local captureLimits = {}
        for key, value in pairs(limits) do
            captureLimits[key] = value
        end
        captureLimits.indexEntries = metaBudget > 0 and metaBudget or (limits.indexEntries or 1)
        local filter = viewExportFilter(entry, pull.peer, pull.scopeId)
        local view, pending, examined = GG.CaptureViewSummaries(
            entry.index,
            entry.eligibilityGen,
            pull.scopeId,
            entry.id,
            entry.schema,
            filter,
            captureLimits,
            pull.captureState
        )
        examined = math.max(0, tonumber(examined) or 0)
        if e.stepStats then
            e.stepStats.indexExamined = (e.stepStats.indexExamined or 0) + examined
        end
        e.stepMetaRemaining = math.max(0, (tonumber(e.stepMetaRemaining) or metaBudget) - examined)
        if e.stepLimits then
            e.stepLimits.indexEntries = e.stepMetaRemaining
        end
        if pending then
            pull.captureState = pending
            pull.usableProgressAt = now
            GG.MarkWorkPending()
            return true
        end
        if not view then
            closeInPull("capture_failed")
            return true
        end
        local reply = {
            op = "offer",
            viewId = pull.viewId,
            sourceViewId = view.viewId,
            providerId = entry.id,
            schema = entry.schema,
            scopeId = pull.scopeId,
            eligibilityGen = entry.eligibilityGen,
            epoch = view.epoch,
            packedBuckets = view.packedBuckets,
            mode = GG.GetSchedMode(),
            engineGen = e.generation,
        }
        pull.sourceViewId = view.viewId
        pull.epoch = view.epoch
        pull.buckets = view.buckets
        pull.offerPayload = reply
        pull.captureState = nil
        pull.phase = "serving"
        trySendServedOffer(pull)
        return true
    end
    if pull.offerRetryPending and pull.offerPayload then
        local sk = streamKey("WHISPER", pull.peer)
        if not e.streamBusy[sk] then
            trySendServedOffer(pull)
            return true
        end
        GG.MarkWorkPending()
        return false
    end
    if pull.finalSubmitted and now >= (pull.usableProgressAt or now)
        and (now - (pull.usableProgressAt or now)) > GG.SERVED_VIEW_IDLE_TIMEOUT_SEC then
        closeInPull("served_view_idle")
        return true
    end
    return false
end

local function expireUnresolved(now)
    local unresolved = GG._engine.unresolved
    for key, item in pairs(unresolved) do
        if not item.at or (now - item.at) > GG.UNRESOLVED_TTL_SEC then
            invalidateUnresolvedCoverage(item)
            unresolved[key] = nil
        end
    end
end

function GG.OnSchedulerStep(limits, now)
    local e = GG._engine
    if not GG.HasActiveProvider() then
        return
    end
    if not GG.IsGuildReady() then
        -- Suspend the work ticker while readiness is absent; OnGuildReady restarts.
        GG.StopDiscovery()
        if GG.ExpireStalePartials then
            GG.ExpireStalePartials(now)
        end
        if GG._StopScheduler then
            GG._StopScheduler()
        end
        return
    end

    local stepStartedAt = debugprofilestop and debugprofilestop() or nil
    e.stepStartedAt = stepStartedAt
    local indexRemaining = limits.indexEntries or 0
    e.indexWorkPending = false
    e.stepLimits = limits
    e.stepMetaRemaining = indexRemaining
    e.stepExportBudget = {
        bodies = limits.bodies or 0,
        manifestEntries = limits.manifestEntries or 0,
    }
    e.stepStats = { indexExamined = 0, receivedApps = 0, cpuMs = 0, exportLookups = 0 }
    -- Index maintenance uses one aggregate entry budget across providers.
    local activeProviders = GG.ListActiveProviders()
    for _, entry in ipairs(activeProviders) do
        if indexRemaining <= 0 then
            break
        end
        local indexLimits = {}
        for key, value in pairs(limits) do
            indexLimits[key] = value
        end
        indexLimits.indexEntries = indexRemaining
        local moreIndex = GG.EnsureProviderIndex(entry, indexLimits)
        if moreIndex or providerNeedsIndexWork(entry) then
            e.indexWorkPending = true
        end
        local examined = math.max(0, tonumber(entry.lastIndexExamined) or 0)
        e.stepStats.indexExamined = e.stepStats.indexExamined + examined
        indexRemaining = math.max(0, indexRemaining - examined)
        e.stepMetaRemaining = indexRemaining
        if stepStartedAt and (debugprofilestop() - stepStartedAt) >= (limits.cpuMs or math.huge) then
            break
        end
    end
    -- Providers skipped by exact budget/CPU exhaustion still keep the scheduler awake.
    if not e.indexWorkPending then
        for _, entry in ipairs(activeProviders) do
            if providerNeedsIndexWork(entry) then
                e.indexWorkPending = true
                break
            end
        end
    end
    -- Share remaining metadata budget with capture / manifest scans this step.
    e.stepLimits = {}
    for key, value in pairs(limits) do
        e.stepLimits[key] = value
    end
    e.stepLimits.indexEntries = indexRemaining

    -- Drain receive queue under app + shared export budgets.
    local apps = 0
    while #(e.recvQueue) > 0 and apps < limits.apps do
        local item = table.remove(e.recvQueue, 1)
        e.recvBytes = math.max(0, (e.recvBytes or 0) - (item.bytes or 0))
        local status = dispatchOne(item, limits)
        if status == "defer" then
            -- Put the admitted request back; do not burn further app slots.
            table.insert(e.recvQueue, 1, item)
            e.recvBytes = (e.recvBytes or 0) + (item.bytes or 0)
            GG.MarkWorkPending()
            break
        end
        apps = apps + 1
    end
    e.stepStats.receivedApps = apps

    GG.ConsumeChangeDebounce(now)
    expirePeers(now)
    expireUnresolved(now)
    GG.ExpireStalePartials(now)

    if not e.outPull then
        local started = false
        if e.pendingOutCapture then
            local pc = e.pendingOutCapture
            local peer = e.peers[pc.peerKey]
            local entry = GG.GetProvider(pc.providerId)
            local scopeId = entry and providerScope(entry)
            local stillValid = peer and entry and not peer.activeExchange
                and indexReadyForView(entry)
                and scopeId ~= nil
                and scopeId == pc.scopeId
                and entry.eligibilityGen == pc.eligibilityGen
                and entry.index and entry.index.epoch == pc.epoch
                and providerEligible(entry, peer.name, scopeId)
            if stillValid then
                started = startOutPull(peer, entry) and true or false
            else
                e.pendingOutCapture = nil
            end
        end
        if not started and not e.outPull and not e.pendingOutCapture then
            local peer, entry = selectPullPeer()
            if peer and entry then
                startOutPull(peer, entry)
            end
        end
    end

    advanceOutPull(e.stepLimits or limits, now)
    advanceInPull(now)
    if stepStartedAt then
        e.stepStats.cpuMs = debugprofilestop() - stepStartedAt
    end

    -- Idle detection: no pulls, empty recv, no debounce, discovery-only.
    local sched = GG._sched
    if not e.outPull and not e.inPull and #(e.recvQueue) == 0
        and not e.indexWorkPending
        and not e.pendingOutCapture
        and not (sched and sched.changeDebounceAt)
    then
        -- Keep discovery while providers active; clear continuous work flag.
        if not e.discoveryTimer and not e.nextDiscoveryAt then
            GG.ScheduleDiscovery(false)
        end
        if GG.ClearWorkPendingIfIdle then
            GG.ClearWorkPendingIfIdle()
        end
        -- Stop the 0.1s step ticker; discovery uses its own NewTimer.
        if GG._StopScheduler then
            local keepDiscovery = e.discoveryTimer
            local keepNext = e.nextDiscoveryAt
            GG._StopScheduler()
            e.discoveryTimer = keepDiscovery
            e.nextDiscoveryAt = keepNext
        end
    end
end

---------------------------------------------------------------------------
-- Init / shutdown
---------------------------------------------------------------------------

function GG.Init(opts)
    local e = GG._engine
    if e.inited then
        -- Re-bind receive guard to current AceComm.
        if GG.EnsureReceiveGuard then
            GG.EnsureReceiveGuard()
        elseif LibStub then
            local AceComm = LibStub("AceComm-3.0", true)
            if AceComm then
                GG.InstallReceiveGuard(AceComm)
            end
        end
        if GG.InitReceiveGuardLifecycle then
            GG.InitReceiveGuardLifecycle()
        end
        return
    end
    e.inited = true
    opts = opts or {}
    if GG.InitEpochIncarnation then
        GG.InitEpochIncarnation()
    end

    GG.InitGuildAdapter()

    if GG.EnsureReceiveGuard then
        GG.EnsureReceiveGuard()
    elseif LibStub then
        local AceComm = LibStub("AceComm-3.0", true)
        if AceComm then
            GG.InstallReceiveGuard(AceComm)
        end
    end
    if GG.InitReceiveGuardLifecycle then
        GG.InitReceiveGuardLifecycle()
    end

    local Comm = SF.LootHelperComm
    if Comm and Comm.Init then
        -- Ensure Comm is ready (safe if Loot Helper already initialized it).
        Comm:Init()
    end
    if Comm and Comm.RegisterGossipHandler then
        Comm:RegisterGossipHandler(function(prefix, text, distribution, sender)
            GG.OnGossipCommReceived(prefix, text, distribution, sender)
        end)
    end

    GG._DInfo("Guild Gossip engine initialized")
end

function GG.Shutdown()
    GG.StopDiscovery()
    GG._StopScheduler()
    GG.InvalidateRuntime("shutdown")
    clearEngineOwnedRuntimeState()
    GG.ShutdownGuildAdapter()
    local Comm = SF.LootHelperComm
    if Comm and Comm.ClearGossipHandler then
        Comm:ClearGossipHandler()
    elseif Comm then
        Comm._gossipHandler = false
    end
    local guard = GG._recvGuard
    if guard and guard.lifecycleFrame then
        -- Retain the named frame for reuse; only deactivate events/scripts.
        if guard.lifecycleFrame.UnregisterAllEvents then
            guard.lifecycleFrame:UnregisterAllEvents()
        end
        if guard.lifecycleFrame.SetScript then
            guard.lifecycleFrame:SetScript("OnEvent", nil)
        end
    end
    GG._engine.inited = false
end
