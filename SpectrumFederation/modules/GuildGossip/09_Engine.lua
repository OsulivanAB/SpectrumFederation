-- Guild Gossip engine: discovery, C1 exchange, receive dispatch, lifecycle.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

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
        -- New announcement invalidates prior "already covered" marks.
        peer.covered = {}
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

    local submittedFinal = false
    local releasedEarly = false
    local function releaseAdmission()
        if releasedEarly or submittedFinal then
            return
        end
        releasedEarly = true
        e.streamBusy[sk] = nil
        onGossipSubmitted(bytes)
    end
    local callback = function(_, sent, textlen, sendResult)
        -- ChatThrottleLib/AceComm callback: sent reaches textlen on final fragment.
        if type(sent) == "number" and type(textlen) == "number" and sent >= textlen then
            if not submittedFinal and not releasedEarly then
                submittedFinal = true
                e.streamBusy[sk] = nil
                onGossipSubmitted(bytes)
                if opts.onFinalSubmitted then
                    opts.onFinalSubmitted(true, sendResult)
                end
            end
        end
    end

    local providerId = opts.providerId or (type(payload) == "table" and payload.providerId) or nil
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
    })
    if not ok then
        e.streamBusy[sk] = nil
        e.admittedOutBytes = math.max(0, (e.admittedOutBytes or 0) - bytes)
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

local function bookmarkKey(peerName, providerId, scopeId, bucketId)
    return table.concat({
        peerKey(peerName),
        tostring(providerId),
        tostring(scopeId),
        tostring(bucketId),
    }, "|")
end

local function getBookmark(entry, peerName, scopeId, bucketId)
    local key = bookmarkKey(peerName, entry.id, scopeId, bucketId)
    return entry.bookmarks[key], key
end

local function setBookmark(entry, peerName, scopeId, bucketId, bm)
    local key = bookmarkKey(peerName, entry.id, scopeId, bucketId)
    entry.bookmarks[key] = bm
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

local function providerScope(entry)
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

local function providerEligible(entry, peerName, scopeId)
    return entry
        and entry.enabled
        and entry.ready
        and scopeId ~= nil
        and providerScope(entry) == scopeId
        and GG.ProviderIsPeerEligible(entry, peerName, { scopeId = scopeId })
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
            pull.awaitingSince = GG._Now()
            pull.usableProgressAt = pull.awaitingSince
        end
    end
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
    GG.ClearAllPartials()
    local comm = SF.LootHelperComm
    if comm and comm.CancelAllQueuedGossip then
        comm:CancelAllQueuedGossip()
    end
    GG._DInfo("Gossip runtime invalidated (%s)", tostring(reason))
end

GG.OnGuildInvalidated = function(reason)
    GG.InvalidateRuntime(reason)
end

GG.OnGuildReady = function()
    if GG.HasActiveProvider() then
        GG.MarkWorkPending()
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
    if GG.CancelQueuedGossipForProvider then
        GG.CancelQueuedGossipForProvider(providerId)
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

    local view = GG.CaptureViewSummaries(
        providerEntry.index,
        providerEntry.eligibilityGen,
        scopeId,
        providerEntry.id,
        providerEntry.schema
    )
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
        onFinalSubmitted = function(success)
            if e.outPull == pull then
                pull.awaitingSince = GG._Now()
                pull.finalSubmitted = success and true or false
            end
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
                if not (peer.covered and peer.covered[entry.id]) then
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

local function enqueueReceive(sender, msgType, payloadStr, enc, bytes)
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
    enqueueReceive(sender, msgType, payloadStr, enc, #text)
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
        return
    end
    if not providerEligible(providerEntry, sender, scopeId) then
        return
    end

    if payload.op == "request" then
        -- Serve a pull: reply with our view summaries.
        if e.inPull then
            -- Stop-and-wait: one served pull at a time. Tell requester to rotate.
            GG.SendGossip(GG.MSG.ACK, {
                viewId = payload.viewId,
                busy = true,
                providerId = payload.providerId,
            }, "WHISPER", sender, { ignoreStreamBusy = true })
            return
        end
        local view = GG.CaptureViewSummaries(
            providerEntry.index,
            providerEntry.eligibilityGen,
            scopeId,
            providerEntry.id,
            providerEntry.schema
        )
        local reply = {
            op = "offer",
            viewId = payload.viewId,
            sourceViewId = view.viewId,
            providerId = providerEntry.id,
            schema = providerEntry.schema,
            scopeId = scopeId,
            eligibilityGen = providerEntry.eligibilityGen,
            epoch = view.epoch,
            packedBuckets = view.packedBuckets,
            mode = GG.GetSchedMode(),
            engineGen = e.generation,
        }
        local peer = touchPeer(sender, {})
        if peer then
            peer.activeExchange = true
        end
        e.inPull = {
            peer = sender,
            providerId = providerEntry.id,
            viewId = payload.viewId,
            sourceViewId = view.viewId,
            scopeId = scopeId,
            epoch = view.epoch,
            buckets = view.buckets,
            phase = "serving",
            engineGen = e.generation,
            usableProgressAt = GG._Now(),
            pauseExcluded = 0,
            finalSubmitted = false,
        }
        GG.SendGossip(GG.MSG.VIEW, reply, "WHISPER", sender, {
            providerId = providerEntry.id,
            onFinalSubmitted = function(success)
                noteInPullSubmission(e.inPull, success)
            end,
        })
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

local function handleManifest(sender, payload)
    local e = GG._engine
    if payload.op == "request" then
        local pull = e.inPull
        if not pull or pull.peer ~= sender or pull.viewId ~= payload.viewId
            or type(payload.requestId) ~= "string" then
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId) then
            return
        end
        pull.usableProgressAt = GG._Now()
        local limits = GG.GetStepLimits(payload.mode or GG.GetSchedMode())
        local endSeq = 0
        local bucketId = tonumber(payload.bucketId) or 0
        if pull.buckets and pull.buckets[bucketId] then
            endSeq = pull.buckets[bucketId].lastSeq or 0
        end
        -- Capture was fixed at serve time; use captured end marker.
        local entries = GG.IndexSeekManifest(
            entry.index,
            bucketId,
            payload.afterSeq or 0,
            endSeq,
            limits.manifestEntries
        )
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
            done = (#entries == 0) or ((entries[#entries].seq or 0) >= endSeq),
            engineGen = e.generation,
        }
        -- A manifest must also be sendable as one bounded gossip envelope.
        while #response.entries > 0 and not GG.BuildWireMessage(GG.MSG.MANIFEST, response) do
            table.remove(response.entries)
            response.done = false
        end
        GG.SendGossip(GG.MSG.MANIFEST, response, "WHISPER", sender, {
            providerId = pull.providerId,
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
        pull.manifest = payload
        pull.phase = "need_bodies"
        pull.neededBodies = {}
        pull.bodyOffset = 0
        pull.bodySubpage = 0
        pull.expectedRequestId = nil
        pull.expectedSubpage = nil
        pull.outstanding = nil
        pull.usableProgressAt = GG._Now()
        for _, ent in ipairs(payload.entries) do
            local have = GG.IndexGetEntry(entry.index, ent.id)
            if not have or have.versionFp ~= ent.versionFp then
                pull.neededBodies[#pull.neededBodies + 1] = ent
            end
        end
        GG.MarkWorkPending()
    end
end

local function handleBody(sender, payload)
    local e = GG._engine
    if payload.op == "request" then
        local pull = e.inPull
        if not pull or pull.peer ~= sender or pull.viewId ~= payload.viewId
            or type(payload.requestId) ~= "string" or type(payload.ids) ~= "table"
            or #payload.ids > GG.BODIES_PER_MESSAGE.NORMAL then
            return
        end
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId)
            or not entry.api or type(entry.api.GetRecordBody) ~= "function" then
            return
        end
        pull.usableProgressAt = GG._Now()
        local records = {}
        local skippedIds = {}
        local more = false
        for _, rid in ipairs(payload.ids) do
            local ok, body = pcall(entry.api.GetRecordBody, rid)
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
        local expectedFp = pull.expectedFingerprints or {}
        local function isExpected(id)
            for key, value in pairs(expected) do
                if tostring(key) == tostring(id) or tostring(value) == tostring(id) then
                    return true
                end
            end
            return false
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
        local entry = GG.GetProvider(pull.providerId)
        if not providerEligible(entry, sender, pull.scopeId) then
            closeOutPull("provider_ineligible")
            return
        end
        pull.bodyPage = payload
        pull.bodyApplyCursor = 0
        pull.pendingBodyCount = #payload.records + #(payload.skippedIds or {})
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

local function hasValidRecords(records)
    if type(records) ~= "table" then
        return false
    end
    for _, record in ipairs(records) do
        if type(record) ~= "table" or record.id == nil or record.versionFp == nil then
            return false
        end
    end
    return true
end

local function validPayloadForMessage(msgType, payload)
    if type(payload) ~= "table" then
        return false
    end
    if not boundedValue(payload, 1, { nodes = 1 }, {}) then
        return false
    end
    if msgType == GG.MSG.MANIFEST and payload.op == "page" then
        return hasValidEntries(payload.entries)
    end
    if msgType == GG.MSG.BODY and payload.op == "page" then
        return hasValidRecords(payload.records)
    end
    return true
end

local function dispatchOne(item, limits)
    local msgType = item.msgType
    local payload, err = GG.DecodePayload(item.payloadStr, item.enc)
    if err or not validPayloadForMessage(msgType, payload) then
        GG._DVerbose("Drop malformed gossip %s from %s", tostring(msgType), tostring(item.sender))
        return
    end
    if msgType == GG.MSG.DISC then
        handleDisc(item.sender, payload)
    elseif msgType == GG.MSG.VIEW then
        handleView(item.sender, payload)
    elseif msgType == GG.MSG.MANIFEST then
        handleManifest(item.sender, payload)
    elseif msgType == GG.MSG.BODY then
        handleBody(item.sender, payload)
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
        onFinalSubmitted = function(success)
            if GG._engine.outPull == pull then
                pull.finalSubmitted = success and true or false
                pull.awaitingSince = GG._Now()
            end
        end,
    })
end

local function recordUnresolved(providerId, recordId, result, now)
    local e = GG._engine
    local key = tostring(providerId) .. "|" .. tostring(recordId)
    e.unresolved[key] = {
        at = now,
        providerId = providerId,
        recordId = recordId,
        result = result,
    }
    local oldestKey, oldestAt, count = nil, nil, 0
    for unresolvedKey, item in pairs(e.unresolved) do
        count = count + 1
        if not oldestAt or (item.at or 0) < oldestAt then
            oldestKey, oldestAt = unresolvedKey, item.at or 0
        end
    end
    if count > GG.MAX_UNRESOLVED and oldestKey then
        e.unresolved[oldestKey] = nil
    end
end

local function hasUnresolvedForProvider(providerId)
    for _, item in pairs(GG._engine.unresolved) do
        if item.providerId == providerId then
            return true
        end
    end
    return false
end

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

    if pull.finalSubmitted and pull.awaitingSince and pull.outstanding
        and now >= (pull.usableProgressAt or pull.awaitingSince)
        and (now - (pull.usableProgressAt or pull.awaitingSince)) > GG.VIEW_IDLE_TIMEOUT_SEC then
        pull.retries = (pull.retries or 0) + 1
        if pull.retries > GG.PAGE_RETRY_MAX then
            closeOutPull("exhausted")
            return false
        end
        local backoff = GG.PAGE_RETRY_BACKOFF[pull.retries] or 15
        pull.usableProgressAt = now + backoff
        resendOutstanding(pull)
        return true
    end

    local entry = GG.GetProvider(pull.providerId)
    if not providerEligible(entry, pull.peer, pull.scopeId) then
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
                if bm and bm.epoch == pull.remoteView.epoch and bm.scopeId == pull.scopeId then
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
            -- All buckets covered for this finite pass.
            GG.SendGossip(GG.MSG.ACK, {
                viewId = pull.viewId,
                done = true,
                providerId = pull.providerId,
            }, "WHISPER", pull.peer)
            local p = e.peers[peerKey(pull.peer)]
            if p and not hasUnresolvedForProvider(pull.providerId) then
                p.covered = p.covered or {}
                p.covered[pull.providerId] = true
            end
            closeOutPull("complete")
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
        local ok = resendOutstanding(pull)
        if ok then
            pull.phase = "wait_manifest"
        else
            pull.outstanding = nil
        end
        return true
    end

    if pull.phase == "need_bodies" then
        if not pull.neededBodies or #pull.neededBodies == 0 then
            -- Advance enumeration cursor for this manifest page.
            local page = pull.manifest
            if page and page.entries and #page.entries > 0 then
                pull.afterSeq = page.entries[#page.entries].seq or pull.afterSeq
            end
            setBookmark(entry, pull.peer, pull.scopeId, pull.activeBucket, {
                epoch = pull.remoteView and pull.remoteView.epoch,
                scopeId = pull.scopeId,
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
        local ids, expectedFingerprints = {}, {}
        local maxBodies = limits.bodies
        for i = (pull.bodyOffset or 0) + 1, math.min(#pull.neededBodies, (pull.bodyOffset or 0) + maxBodies) do
            local needed = pull.neededBodies[i]
            ids[#ids + 1] = needed.id
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
            engineGen = e.generation,
        }
        pull.pendingBodyCount = #ids
        pull.expectedRequestId = requestId
        pull.expectedSubpage = pull.bodySubpage
        pull.expectedIds = ids
        pull.expectedFingerprints = expectedFingerprints
        pull.outstanding = { msgType = GG.MSG.BODY, payload = payload }
        local ok = resendOutstanding(pull)
        if ok then
            pull.phase = "wait_bodies"
        else
            pull.outstanding = nil
        end
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
            -- Re-check eligibility immediately before the provider side effect.
            if not providerEligible(entry, pull.peer, pull.scopeId) then
                closeOutPull("provider_ineligible")
                return false
            end
            local result = GG.ApplyRecordToProvider(entry, rec, ctx)
            if result == GG.DELIVERY.PENDING or result == GG.DELIVERY.REJECTED then
                recordUnresolved(pull.providerId, rec.id, result, now)
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
            recordUnresolved(pull.providerId, recordId, GG.DELIVERY.REJECTED, now)
        end
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
            end
            setBookmark(entry, pull.peer, pull.scopeId, pull.activeBucket, {
                epoch = pull.remoteView and pull.remoteView.epoch,
                scopeId = pull.scopeId,
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
    local pull = GG._engine.inPull
    if not pull then
        return false
    end
    if pull.engineGen ~= GG._engine.generation then
        closeInPull("stale_gen")
        return true
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
        return
    end

    local stepStartedAt = debugprofilestop and debugprofilestop() or nil
    local indexRemaining = limits.indexEntries or 0
    e.stepStats = { indexExamined = 0, receivedApps = 0, cpuMs = 0 }
    -- Index maintenance uses one aggregate entry budget across providers.
    for _, entry in ipairs(GG.ListActiveProviders()) do
        if indexRemaining <= 0 then
            break
        end
        local indexLimits = {}
        for key, value in pairs(limits) do
            indexLimits[key] = value
        end
        indexLimits.indexEntries = indexRemaining
        GG.EnsureProviderIndex(entry, indexLimits)
        local examined = math.max(0, tonumber(entry.lastIndexExamined) or 0)
        e.stepStats.indexExamined = e.stepStats.indexExamined + examined
        indexRemaining = math.max(0, indexRemaining - examined)
        if stepStartedAt and (debugprofilestop() - stepStartedAt) >= (limits.cpuMs or math.huge) then
            break
        end
    end

    -- Drain receive queue under app budget.
    local apps = 0
    while #(e.recvQueue) > 0 and apps < limits.apps do
        local item = table.remove(e.recvQueue, 1)
        e.recvBytes = math.max(0, (e.recvBytes or 0) - (item.bytes or 0))
        dispatchOne(item, limits)
        apps = apps + 1
    end
    e.stepStats.receivedApps = apps

    GG.ConsumeChangeDebounce(now)
    expirePeers(now)
    expireUnresolved(now)
    GG.ExpireStalePartials(now)

    if not e.outPull then
        local peer, entry = selectPullPeer()
        if peer and entry then
            startOutPull(peer, entry)
        end
    end

    advanceOutPull(limits, now)
    advanceInPull(now)
    if stepStartedAt then
        e.stepStats.cpuMs = debugprofilestop() - stepStartedAt
    end

    -- Idle detection: no pulls, empty recv, no debounce, discovery-only.
    local sched = GG._sched
    if not e.outPull and not e.inPull and #(e.recvQueue) == 0
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
        if LibStub then
            local AceComm = LibStub("AceComm-3.0", true)
            if AceComm then
                GG.InstallReceiveGuard(AceComm)
            end
        end
        return
    end
    e.inited = true
    opts = opts or {}

    GG.InitGuildAdapter()

    if LibStub then
        local AceComm = LibStub("AceComm-3.0", true)
        if AceComm then
            GG.InstallReceiveGuard(AceComm)
        end
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
    GG.ShutdownGuildAdapter()
    GG._engine.inited = false
end
