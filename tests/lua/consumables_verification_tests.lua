-- Behavioral tests for Consumables verification/sync/accounting (Issue #366 PR2).
-- Run: lua5.1 tests/lua/consumables_verification_tests.lua

local failures = 0
local passes = 0

local function fail(message)
    failures = failures + 1
    io.stderr:write("FAIL: " .. tostring(message) .. "\n")
end

local function pass(message)
    passes = passes + 1
    io.stdout:write("ok: " .. tostring(message) .. "\n")
end

local function assertTrue(cond, message)
    if cond then pass(message) else fail(message) end
end

local function assertFalse(cond, message)
    if cond then fail(message) else pass(message) end
end

local function assertEq(actual, expected, message)
    if actual == expected then
        pass(message)
    else
        fail(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

local world
local function resetWorld()
    world = {
        self = "Observer-Realm",
        now = 1000000,
    }
end
resetWorld()

time = function() return world.now end
GetTime = function() return 100 end

local SF = {
    Debug = {
        Info = function() end,
        Warn = function() end,
        Error = function() end,
        Verbose = function() end,
    },
    NameUtil = {
        GetSelfId = function() return world.self end,
        NormalizeNameRealm = function(name) return name end,
        SamePlayer = function(a, b) return a == b end,
    },
    LocaleText = function(_, default) return default end,
}

local function load(path)
    local chunk = assert(loadfile(path))
    chunk("SpectrumFederation", SF)
end

load("SpectrumFederation/locale/enUS.lua")
load("SpectrumFederation/modules/LootHelper/Consumables.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesSync.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesWorkflow.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesObservation.lua")
load("SpectrumFederation/modules/LootHelper/ConsumablesVerification.lua")

local C = SF.Consumables
local S = SF.ConsumablesSync
local O = SF.ConsumablesObservation
local V = SF.ConsumablesVerification
local W = SF.ConsumablesWorkflow

local clock = 1000000
C._clock = function() return clock end
O._clock = function() return clock end
V._clock = function() return clock end

local flask = 212283
local admin = "Admin-Realm"
local donor = "Donor-Realm"
local w1 = "WitnessOne-Realm"
local w2 = "WitnessTwo-Realm"
local w3 = "WitnessThree-Realm"
local w1alt = "WitnessOneAlt-Realm"
local GUILD = { guid = "club-1", name = "Spectrum", realm = "Realm" }

local function makeProfile(id, admins)
    local p = {
        _profileId = id or "profile-verify",
        _owner = admin,
        _adminUsers = admins or { admin },
        _linked = {},
    }
    function p:GetProfileId() return self._profileId end
    function p:IsAdminMemberId(memberId)
        for i = 1, #self._adminUsers do
            if self._adminUsers[i] == memberId then return true end
        end
        return false
    end
    function p:AreSameIdentity(a, b)
        if a == b then return true end
        local group = self._linked[a] or self._linked[b]
        if type(group) ~= "table" then return false end
        local hasA, hasB = false, false
        for i = 1, #group do
            if group[i] == a then hasA = true end
            if group[i] == b then hasB = true end
        end
        return hasA and hasB
    end
    C.Ensure(p)
    assert(C.SetGuild(p, admin, GUILD, 2))
    assert(C.AddRequestedItem(p, admin, flask))
    return p
end

local function evidence(overrides)
    local e = {
        localId = "co:test:1",
        coreSignature = O.CoreSignature("deposit", donor, flask, 20),
        type = "deposit",
        donor = donor,
        itemId = flask,
        quantity = 20,
        guildGuid = "club-1",
        bankTab = 2,
        generation = 1,
        approxTxnTime = clock - 60,
        ageHours = 0.1,
        occurrenceIndex = 1,
        neighborsOlder = { "deposit|Other-Realm|1|1" },
        neighborsNewer = {},
        observedBy = w1,
        firstSeen = clock - 60,
        status = "pending",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    if not overrides or not overrides.coreSignature then
        e.coreSignature = O.CoreSignature(e.type, e.donor, e.itemId, e.quantity)
    end
    return e
end

-- ---------------------------------------------------------------------------
-- Admin trust
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("admin-trust")
    local db = {}
    local store = O.EnsureProfileStore(db, "admin-trust")
    local scope = O.EnsureScope(store, "club-1", 2)
    local stats = V.IngestReport(p, "admin-trust", admin, { evidence({ observedBy = admin }) }, {
        isAdmin = true,
        scope = scope,
        obsStore = store,
    })
    assertEq(stats.verified, 1, "admin report is immediately verified")
    local clusters = V.ListVerifiedClusters("admin-trust")
    assertEq(#clusters, 1, "one verified cluster exists")
    local ok = V.CommitVerifiedCluster(p, clusters[1], admin)
    assertTrue(ok, "admin-trusted cluster commits")
    assertEq(C.ContributionTotal(p, donor, flask), 20, "admin-trusted donation counts for donor")
    assertTrue(C.HasTxnId(p, clusters[1].txnId), "txnId is indexed for exactly-once accounting")
    local ok2 = V.CommitVerifiedCluster(p, clusters[1], admin)
    assertTrue(ok2, "recommitting the same txn is idempotent")
    assertEq(C.ContributionTotal(p, donor, flask), 20, "duplicate commit does not double-count")
end

-- ---------------------------------------------------------------------------
-- Three-witness verification + linked-identity dedupe
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("three-witness")
    p._linked[w1] = { w1, w1alt }
    p._linked[w1alt] = { w1, w1alt }
    local db = {}
    local store = O.EnsureProfileStore(db, "three-witness")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence()
    local s1 = V.IngestReport(p, "three-witness", w1, { ev }, { scope = scope, obsStore = store })
    assertEq(s1.verified, 0, "one witness stays pending")
    local sAlt = V.IngestReport(p, "three-witness", w1alt, { ev }, { scope = scope, obsStore = store })
    assertEq(sAlt.verified, 0, "linked alt does not count as a second witness")
    local s2 = V.IngestReport(p, "three-witness", w2, { ev }, { scope = scope, obsStore = store })
    assertEq(s2.verified, 0, "two independent witnesses stay pending")
    local s3 = V.IngestReport(p, "three-witness", w3, { ev }, { scope = scope, obsStore = store })
    assertEq(s3.verified, 1, "three independent witnesses verify")
    local clusters = V.ListVerifiedClusters("three-witness")
    assertEq(clusters[1].verification, V.VERIFICATION.WITNESSES, "verification method is witnesses")
    assertTrue(V.CommitVerifiedCluster(p, clusters[1], w3), "witness-verified cluster commits")
    assertEq(C.ContributionTotal(p, donor, flask), 20, "witness-verified donation counts")
end

-- ---------------------------------------------------------------------------
-- Rejection persistence vs later witnesses + correction
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("reject-race")
    local db = {}
    local store = O.EnsureProfileStore(db, "reject-race")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 7, coreSignature = O.CoreSignature("deposit", donor, flask, 7) })
    V.IngestReport(p, "reject-race", w1, { ev }, { scope = scope, obsStore = store })
    local ok, status = V.ApplyDecision(p, "reject-race", admin, {
        action = "reject",
        evidence = ev,
    }, { isAdmin = true, scope = scope, obsStore = store })
    assertTrue(ok and status == "rejected", "admin rejection applies")
    assertTrue(V.IsRejected(scope, ev), "rejection is recorded on scope")
    local after = V.IngestReport(p, "reject-race", w2, { ev }, { scope = scope, obsStore = store })
    assertEq(after.verified, 0, "rejected evidence does not verify from later witnesses")
    assertEq(after.rejected, 1, "later matching reports are suppressed")
    local ok2, status2, cluster = V.ApplyDecision(p, "reject-race", admin, {
        action = "correct",
        evidence = ev,
    }, { isAdmin = true, scope = scope, obsStore = store })
    assertTrue(ok2 and status2 == "verified", "admin correction verifies")
    assertFalse(V.IsRejected(scope, ev), "correction clears rejection")
    assertTrue(V.CommitVerifiedCluster(p, cluster, admin), "corrected cluster commits")
    assertEq(C.ContributionTotal(p, donor, flask), 7, "corrected donation counts once")
end

-- ---------------------------------------------------------------------------
-- Donor ≠ writer sync authorization
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("donor-writer")
    local event = {
        id = "ce:donor-writer:Admin-Realm:1",
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = flask,
        quantity = 11,
        source = "guildbank",
        generation = 1,
        timestamp = clock,
        txnId = "ctx:donor-writer:1",
        verification = "admin_trust",
    }
    assertTrue(select(1, S.ApplyRemoteEvent(p, event, admin)), "admin can write donation for another donor")
    assertEq(C.ContributionTotal(p, donor, flask), 11, "synced donation preserves donor identity")
    assertFalse(select(1, S.ApplyRemoteEvent(p, {
        id = "ce:donor-writer:Donor-Realm:2",
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = flask,
        quantity = 3,
        source = "guildbank",
        generation = 1,
        txnId = "ctx:donor-writer:2",
    }, donor)), "non-admin cannot insert canonical donation")
end

-- ---------------------------------------------------------------------------
-- goldValueCopper schema preservation (unset by default)
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("gold-schema")
    local event = {
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = flask,
        quantity = 2,
        source = "guildbank",
        generation = 1,
        timestamp = clock,
        txnId = "ctx:gold-schema:1",
        goldValueCopper = 12345,
    }
    assertTrue(select(1, C.CommitEvents(p, admin .. ":ctx:gold-schema:1", { event }, { writer = admin })),
        "donation with goldValueCopper commits")
    local stored = p._consumableEvents[#p._consumableEvents]
    assertEq(stored.goldValueCopper, 12345, "goldValueCopper is preserved through commit/copy")
    local snap = C.ExportSnapshot(p)
    local exported = nil
    for i = 1, #(snap.events or {}) do
        if snap.events[i].txnId == "ctx:gold-schema:1" then
            exported = snap.events[i]
        end
    end
    assertTrue(exported ~= nil, "snapshot exports goldValueCopper donation")
    assertEq(exported.goldValueCopper, 12345, "ExportSnapshot/CopyEvent preserves goldValueCopper")
    local bare = {
        type = C.EVENT.DONATION,
        actor = donor,
        itemId = flask,
        quantity = 1,
        source = "guildbank",
        generation = 1,
        txnId = "ctx:gold-schema:2",
    }
    assertTrue(select(1, C.CommitEvents(p, admin .. ":ctx:gold-schema:2", { bare }, { writer = admin })))
    local storedBare = nil
    for i = 1, #p._consumableEvents do
        if p._consumableEvents[i].txnId == "ctx:gold-schema:2" then
            storedBare = p._consumableEvents[i]
        end
    end
    assertTrue(storedBare ~= nil, "unset goldValueCopper donation was stored")
    assertTrue(storedBare.goldValueCopper == nil, "unset goldValueCopper stays nil, not 0")
end

-- ---------------------------------------------------------------------------
-- Migration discards legacy donations once; preserves config
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("migrate")
    assertTrue(select(1, C.CommitEvents(p, "legacy-deposit", W.DepositEvents({
        generation = 1, itemId = flask, donor = donor, requested = true, timestamp = clock,
    }, 9), { writer = donor })), "legacy-style local commit works")
    assertTrue(C.ContributionTotal(p, donor, flask) >= 9, "pre-migration donation present")
    -- Simulate unreleased legacy profile lacking the observation schema marker.
    p._consumables.obsAccountingSchema = nil
    C.InvalidateEventIndex(p)
    local cfg = C.Ensure(p)
    assertEq(tonumber(cfg.obsAccountingSchema), C.OBS_ACCOUNTING_SCHEMA, "migration sets schema marker")
    assertEq(C.ContributionTotal(p, donor, flask), 0, "legacy donations are discarded")
    assertTrue(C.IsRequested(p, flask), "requested items are preserved")
    assertEq(cfg.guild.guid, "club-1", "guild config is preserved")
    assertEq(cfg.bankTab, 2, "bank tab is preserved")
    -- Second Ensure must not wipe new verified donations.
    assertTrue(select(1, C.CommitEvents(p, admin .. ":ctx:migrate:1", { {
        type = C.EVENT.DONATION, actor = donor, itemId = flask, quantity = 4,
        source = "guildbank", generation = 1, txnId = "ctx:migrate:1",
    } }, { writer = admin })))
    C.Ensure(p)
    assertEq(C.ContributionTotal(p, donor, flask), 4, "post-migration donations survive subsequent Ensure")
end

-- ---------------------------------------------------------------------------
-- Eligibility cutover after baseline
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("cutover")
    local db = {}
    local store = O.EnsureProfileStore(db, "cutover")
    C.NoteObservationBaseline(p)
    local newItem = 190000
    assertTrue(C.AddRequestedItem(p, admin, newItem), "add item after baseline")
    local eligibility = C.EligibilitySnapshot(p)
    assertTrue(eligibility.baselineEstablished, "baseline established")
    assertTrue(tonumber(eligibility.items[tostring(newItem)]) ~= nil, "new item has cutover timestamp")
    local oldEvidence = {
        type = "deposit",
        donor = donor,
        itemId = newItem,
        quantity = 5,
        guildGuid = "club-1",
        bankTab = 2,
        generation = 1,
        approxTxnTime = clock - 3600,
        coreSignature = O.CoreSignature("deposit", donor, newItem, 5),
        observedBy = w1,
        occurrenceIndex = 1,
        neighborsOlder = {},
        neighborsNewer = {},
    }
    assertFalse(O.IsEvidenceEligible(oldEvidence, eligibility), "pre-cutover deposit is ineligible")
    oldEvidence.approxTxnTime = clock + 10
    assertTrue(O.IsEvidenceEligible(oldEvidence, eligibility), "post-cutover deposit is eligible")
end

-- ---------------------------------------------------------------------------
-- Deposit assistant no longer produces accounting events from FinishDeposit path
-- (Workflow helper may still build events for tests; Runtime must not commit them.)
-- ---------------------------------------------------------------------------
do
    local runtimePath = "SpectrumFederation/modules/LootHelper/ConsumablesRuntime.lua"
    local fh = assert(io.open(runtimePath, "r"))
    local body = fh:read("*a")
    fh:close()
    assertTrue(body:find("DepositEvents(", 1, true) == nil,
        "runtime FinishDeposit path does not call DepositEvents")
    assertTrue(body:find("Contribution credit waits for Guild Bank verification", 1, true) ~= nil,
        "runtime tells the user credit waits for verification")
end

-- ---------------------------------------------------------------------------
-- Format helpers for pending/verified UI
-- ---------------------------------------------------------------------------
do
    local text = C.FormatObservation(evidence({ status = "pending" }), "Sunglass Vials")
    assertTrue(text:find("Pending verification", 1, true) ~= nil, "pending format includes status")
    local verified = C.FormatObservation(evidence({ status = "verified" }), "Sunglass Vials")
    assertTrue(verified:find("Verified", 1, true) ~= nil, "verified format includes status")
end

-- ---------------------------------------------------------------------------
-- Account evidence: observedBy vs submittedBy separation
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("submitter-split")
    local db = {}
    local store = O.EnsureProfileStore(db, "submitter-split")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ observedBy = admin, quantity = 3 })
    -- Non-admin submits evidence originally observed by an admin character: no admin trust.
    local stats = V.IngestReport(p, "submitter-split", w1, { ev }, {
        isAdmin = false,
        scope = scope,
        obsStore = store,
    })
    assertEq(stats.verified, 0, "historical admin observedBy does not grant trust to non-admin submitter")
    -- Admin submitter trusts even when observedBy was someone else.
    local stats2 = V.IngestReport(p, "submitter-split", admin, { ev }, {
        isAdmin = true,
        scope = scope,
        obsStore = store,
    })
    assertEq(stats2.verified, 1, "authenticated admin submitter grants trust")
end

assertTrue(type(V.IngestReport) == "function", "verification API present")
assertTrue(type(V.ApplyDecision) == "function", "decision API present")
assertEq(V.WITNESS_THRESHOLD, 3, "witness threshold is the v1 constant")

-- ---------------------------------------------------------------------------
-- Evidence-stable txnId + rematch of verified clusters (no double credit)
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("stable-txn")
    local db = {}
    local store = O.EnsureProfileStore(db, "stable-txn")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 15 })
    local s1 = V.IngestReport(p, "stable-txn", admin, { ev }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(s1.verified, 1, "first admin report verifies")
    local clusters = V.ListVerifiedClusters("stable-txn")
    local txnId = clusters[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, clusters[1], admin), "first commit succeeds")
    local s2 = V.IngestReport(p, "stable-txn", admin, { ev }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(s2.verified, 0, "rematched verified report does not re-verify")
    assertEq(#V.ListVerifiedClusters("stable-txn"), 1, "still one verified cluster")
    assertEq(V.ListVerifiedClusters("stable-txn")[1].txnId, txnId, "txnId stays registry-stable")
    assertEq(C.ContributionTotal(p, donor, flask), 15, "no double credit after rematch")
    assertTrue(C.FindRegistryTxn(p, txnId) ~= nil, "canonical registry retains verified txn")
    assertTrue(V.TxnIdFromEvidence("stable-txn", ev) == nil,
        "Blizzard evidence no longer mints permanent txnIds")
    -- Cross-observer: reconstructed time may differ; registry rematch reuses the ID.
    local shiftedTime = evidence({
        quantity = 15,
        approxTxnTime = (ev.approxTxnTime or clock) + 1800,
        neighborsOlder = ev.neighborsOlder,
        neighborsNewer = ev.neighborsNewer,
        occurrenceIndex = 99,
    })
    local how, entry = V.ReconcileAgainstRegistry(p, shiftedTime)
    assertEq(how, "verified", "shifted-time rematch hits registry")
    assertEq(entry.txnId, txnId, "registry rematch reuses Spectrum-owned txnId")
    local emptyCtx = evidence({ quantity = 15, neighborsOlder = {}, neighborsNewer = {} })
    assertTrue(V.HasStrongIdentityContext(emptyCtx) == false,
        "empty neighbor context is weak identity evidence")
end

-- ---------------------------------------------------------------------------
-- Ambiguous observations are never auto-trusted
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("no-ambiguous-trust")
    local db = {}
    local store = O.EnsureProfileStore(db, "no-ambiguous-trust")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ status = "ambiguous", quantity = 8 })
    scope.observations[1] = ev
    local stats = V.ProcessLocalAfterReconcile(p, "no-ambiguous-trust", store, scope, {
        selfId = admin, asAdmin = true, deferToCoordinator = false,
    })
    assertEq(stats.trusted, 0, "ambiguous local observations are not admin-trusted")
    local report = V.IngestReport(p, "no-ambiguous-trust", admin, { ev }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(report.verified, 0, "ambiguous admin reports stay pending for review")
end

-- ---------------------------------------------------------------------------
-- Coordinator scope filter: wrong guild/tab/item/eligibility are skipped
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("scope-filter")
    C.NoteObservationBaseline(p)
    local newItem = 190001
    assertTrue(C.AddRequestedItem(p, admin, newItem))
    local eligibility = C.EligibilitySnapshot(p)
    local badGuild = evidence({ guildGuid = "other-club", quantity = 2 })
    local badTab = evidence({ bankTab = 7, quantity = 2 })
    local preCutover = evidence({
        itemId = newItem, quantity = 2,
        approxTxnTime = clock - 3600,
        coreSignature = O.CoreSignature("deposit", donor, newItem, 2),
    })
    local stats = V.IngestReport(p, "scope-filter", w1, { badGuild, badTab, preCutover }, {
        isAdmin = false,
        guildGuid = "club-1",
        bankTab = 2,
        eligibility = eligibility,
        isRequested = function(itemId) return C.IsRequested(p, itemId) end,
    })
    assertEq(stats.skipped, 3, "out-of-scope reports are skipped")
    assertEq(stats.accepted, 0, "no out-of-scope report is accepted")
end

-- ---------------------------------------------------------------------------
-- Eligibility travels with config snapshots
-- ---------------------------------------------------------------------------
do
    local src = makeProfile("elig-export")
    C.NoteObservationBaseline(src)
    local newItem = 190002
    assertTrue(C.AddRequestedItem(src, admin, newItem))
    local snap = C.ExportSnapshot(src, { omitEvents = true })
    assertTrue(type(snap.eligibility) == "table", "ExportSnapshot includes eligibility")
    assertTrue(tonumber(snap.eligibility.items[tostring(newItem)]) ~= nil, "exported item cutover present")
    local dest = makeProfile("elig-import")
    assertTrue(select(1, C.ReplaceConfig(dest, snap)), "ReplaceConfig accepts eligibility payload")
    local imported = C.EligibilitySnapshot(dest)
    assertTrue(imported.baselineEstablished, "imported baselineEstablished")
    assertEq(tonumber(imported.items[tostring(newItem)]), tonumber(snap.eligibility.items[tostring(newItem)]),
        "imported item cutover matches")
end

-- ---------------------------------------------------------------------------
-- Rejection after commit is refused; distinct deposits stay distinct
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("reject-committed")
    local db = {}
    local store = O.EnsureProfileStore(db, "reject-committed")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 6 })
    V.IngestReport(p, "reject-committed", admin, { ev }, { isAdmin = true, scope = scope, obsStore = store })
    local cluster = V.ListVerifiedClusters("reject-committed")[1]
    assertTrue(V.CommitVerifiedCluster(p, cluster, admin), "commit before reject race")
    cluster._committed = true
    local ok, status = V.ApplyDecision(p, "reject-committed", admin, {
        action = "reject", clusterId = cluster.clusterId, evidence = ev,
    }, { isAdmin = true, scope = scope, obsStore = store })
    assertFalse(ok, "reject after commit is refused")
    assertEq(status, "committed", "reject-after-commit status is committed")
    assertEq(C.ContributionTotal(p, donor, flask), 6, "committed donation remains credited")

    local rej1 = V.RejectionRecord(evidence({
        quantity = 4, occurrenceIndex = 1,
        neighborsOlder = { "a" }, neighborsNewer = { "b" },
        approxTxnTime = clock - 30,
        coreSignature = O.CoreSignature("deposit", donor, flask, 4),
    }), admin, clock, "rejected")
    local ev2 = evidence({
        quantity = 4, occurrenceIndex = 2,
        neighborsOlder = { "c" }, neighborsNewer = { "d" },
        approxTxnTime = clock - 20,
        coreSignature = O.CoreSignature("deposit", donor, flask, 4),
    })
    assertFalse(V.RejectionMatches(rej1, ev2), "distinct occurrence indexes do not share one rejection")
end

-- ---------------------------------------------------------------------------
-- Quantity cap matches canonical event limit
-- ---------------------------------------------------------------------------
do
    local tooBig = evidence({ quantity = S.MAX_EVENT_QUANTITY + 1 })
    assertFalse(select(1, V.ValidateObservationPayload(tooBig)), "quantity above MAX_EVENT_QUANTITY is rejected")
    local okQty = evidence({ quantity = S.MAX_EVENT_QUANTITY })
    assertTrue(select(1, V.ValidateObservationPayload(okQty)), "quantity at MAX_EVENT_QUANTITY is accepted")
end

-- ---------------------------------------------------------------------------
-- CollectUnresolvedForSubmit paginates by submitted keys (no offset starve)
-- ---------------------------------------------------------------------------
do
    local db = {}
    local store = O.EnsureProfileStore(db, "paginate")
    local scope = O.EnsureScope(store, "club-1", 2)
    for i = 1, V.MAX_OBS_BATCH + 5 do
        scope.observations[i] = evidence({
            localId = "co:paginate:" .. i,
            quantity = 1,
            occurrenceIndex = i,
            neighborsOlder = { "n-" .. i },
            coreSignature = O.CoreSignature("deposit", donor, flask, 1) .. ":" .. i,
            approxTxnTime = clock - i,
        })
    end
    local batch1, more1, rem1 = V.CollectUnresolvedForSubmit(store, "club-1", 2, {
        profileId = "paginate",
    })
    assertEq(#batch1, V.MAX_OBS_BATCH, "first page is MAX_OBS_BATCH")
    assertEq(rem1, V.MAX_OBS_BATCH + 5, "total unresolved count includes later rows")
    assertTrue(more1, "hasMore when later rows remain")
    V.MarkObservationsSubmitted(store, batch1, "paginate")
    -- Simulate first page becoming verified (shrinking unresolved set).
    for i = 1, V.MAX_OBS_BATCH do
        scope.observations[i].status = "verified"
    end
    local batch2, more2, rem2 = V.CollectUnresolvedForSubmit(store, "club-1", 2, {
        profileId = "paginate",
    })
    assertEq(#batch2, 5, "second page drains remaining observations after shrink")
    assertEq(rem2, 5, "remaining count is the unsubmitted unresolved rows")
    assertFalse(more2, "no more after final page")
    assertTrue(batch2[1].coreSignature ~= batch1[1].coreSignature, "later rows are not starved")
end

-- ---------------------------------------------------------------------------
-- Review summary exposes rejected rows for correction
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("review-rejected")
    local db = {}
    local store = O.EnsureProfileStore(db, "review-rejected")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 9 })
    V.IngestReport(p, "review-rejected", w1, { ev }, { scope = scope, obsStore = store })
    assertTrue(select(1, V.ApplyDecision(p, "review-rejected", admin, {
        action = "reject", evidence = ev,
    }, { isAdmin = true, scope = scope, obsStore = store })))
    local summary = V.ReviewSummary("review-rejected", { profile = p })
    local found = false
    for i = 1, #summary do
        if summary[i].status == "rejected" then found = true end
    end
    assertTrue(found, "review summary includes rejected rows for correction")
end

-- ---------------------------------------------------------------------------
-- Durable rejections sync via ExportSnapshot / ReplaceConfig
-- ---------------------------------------------------------------------------
do
    local src = makeProfile("durable-rej")
    local ev = evidence({ quantity = 12 })
    assertTrue(C.RecordDurableRejection(src, ev, admin, "rejected"), "durable rejection recorded")
    local snap = C.ExportSnapshot(src, { omitEvents = true })
    assertTrue(type(snap.rejections) == "table" and #snap.rejections >= 1, "snapshot exports rejections")
    local dest = makeProfile("durable-rej-dest")
    assertTrue(select(1, C.ReplaceConfig(dest, snap)), "ReplaceConfig merges rejections")
    assertTrue(V.IsRejected({ rejections = C.DurableRejections(dest) }, ev), "imported durable rejection matches")
end

-- ---------------------------------------------------------------------------
-- Defer local admin trust while a coordinator session owns verification
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("defer-session")
    local db = {}
    local store = O.EnsureProfileStore(db, "defer-session")
    local scope = O.EnsureScope(store, "club-1", 2)
    scope.observations[1] = evidence({ quantity = 3, status = "pending" })
    local stats = V.ProcessLocalAfterReconcile(p, "defer-session", store, scope, {
        selfId = admin, asAdmin = true, deferToCoordinator = true,
    })
    assertEq(stats.trusted, 0, "session-active path defers local admin trust")
    assertEq(stats.deferred, 1, "deferred count tracks unresolved rows")
end

-- ---------------------------------------------------------------------------
-- Two offline admins with different reconstructed times credit once
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("two-admin-offline")
    local dbA, dbB = {}, {}
    local storeA = O.EnsureProfileStore(dbA, "two-admin-offline")
    local storeB = O.EnsureProfileStore(dbB, "two-admin-offline")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local sharedNeighbors = { "shared-older" }
    local obsA = evidence({
        quantity = 14, occurrenceIndex = 3,
        approxTxnTime = clock - 120, neighborsOlder = sharedNeighbors,
        status = "pending",
    })
    local obsB = evidence({
        quantity = 14, occurrenceIndex = 1,
        approxTxnTime = clock - 120 + 1800, neighborsOlder = sharedNeighbors,
        status = "pending",
    })
    scopeA.observations[1] = obsA
    scopeB.observations[1] = obsB
    local sA = V.ProcessLocalAfterReconcile(p, "two-admin-offline", storeA, scopeA, {
        selfId = admin, asAdmin = true, deferToCoordinator = false,
    })
    assertEq(sA.trusted, 1, "first offline admin commits")
    assertEq(C.ContributionTotal(p, donor, flask), 14, "first offline credit applied")
    local sB = V.ProcessLocalAfterReconcile(p, "two-admin-offline", storeB, scopeB, {
        selfId = "AdminTwo-Realm", asAdmin = true, deferToCoordinator = false,
    })
    assertEq(sB.trusted, 1, "second offline admin converges")
    assertEq(C.ContributionTotal(p, donor, flask), 14, "second offline admin does not double-credit")
    local match = V.FindEquivalentLedgerDonation(p, "two-admin-offline", obsB)
    assertTrue(match and V.ValidTxnId(match.txnId), "second observer rematches via registry/ledger")
    assertEq(#C.TxnRegistry(p), 1, "one canonical registry entry for both observers")
end

-- ---------------------------------------------------------------------------
-- Distinct identical deposits within 3h remain separately creditable
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("distinct-identical")
    local db = {}
    local store = O.EnsureProfileStore(db, "distinct-identical")
    local scope = O.EnsureScope(store, "club-1", 2)
    local first = evidence({
        quantity = 20, occurrenceIndex = 1,
        neighborsOlder = { "old-a" }, neighborsNewer = { "new-a" },
        approxTxnTime = clock - 60,
    })
    local second = evidence({
        quantity = 20, occurrenceIndex = 2,
        neighborsOlder = { "old-b" }, neighborsNewer = { "new-b" },
        approxTxnTime = clock - 30,
    })
    local s1 = V.IngestReport(p, "distinct-identical", admin, { first }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(s1.verified, 1, "first identical deposit verifies")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("distinct-identical")[1], admin))
    V.ClearSessionClusters()
    local s2 = V.IngestReport(p, "distinct-identical", admin, { second }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(s2.verified, 1, "second identical deposit verifies as its own txn")
    local clusters = V.ListVerifiedClusters("distinct-identical")
    assertEq(#clusters, 1, "fresh session has one new verified cluster")
    assertFalse(clusters[1]._committed == true, "second deposit is not absorbed as already committed")
    assertTrue(V.CommitVerifiedCluster(p, clusters[1], admin), "second distinct deposit commits")
    assertEq(C.ContributionTotal(p, donor, flask), 40, "both identical deposits credit")
    assertTrue(V.FindEquivalentLedgerDonation(p, "distinct-identical", second) ~= nil,
        "strict ledger match finds the second deposit by occurrence")
    assertTrue(V.FindEquivalentLedgerDonation(p, "distinct-identical", first) ~= nil,
        "strict ledger match still finds the first deposit")
end

-- ---------------------------------------------------------------------------
-- Coordinator Clear replaces follower eligibility (convergence)
-- ---------------------------------------------------------------------------
do
    local coord = makeProfile("elig-clear-coord")
    C.NoteObservationBaseline(coord)
    local item = 190003
    assertTrue(C.AddRequestedItem(coord, admin, item))
    local follower = makeProfile("elig-clear-follower")
    assertTrue(select(1, C.ReplaceConfig(follower, C.ExportSnapshot(coord, { omitEvents = true }))),
        "follower adopts coordinator config")
    assertTrue(C.EligibilitySnapshot(follower).baselineEstablished, "follower has baseline")
    assertTrue(select(1, C.Clear(coord, admin)), "coordinator clears")
    local clearedSnap = C.ExportSnapshot(coord, { omitEvents = true })
    assertTrue(clearedSnap.eligibility.baselineEstablished, "clear keeps baseline floor")
    assertTrue(tonumber(clearedSnap.eligibility.tabEligibleFrom) ~= nil, "clear sets tabEligibleFrom floor")
    assertTrue(select(1, C.ReplaceConfig(follower, clearedSnap)), "follower receives clear snapshot")
    local fpCoord = C.Descriptor(coord).configFingerprint
    local fpFollow = C.Descriptor(follower).configFingerprint
    assertEq(fpFollow, fpCoord, "fingerprints converge after clear")
    -- Reconfigure same guild/tab/item: old history stays ineligible.
    assertTrue(C.SetGuild(coord, admin, GUILD, 2))
    assertTrue(C.AddRequestedItem(coord, admin, flask))
    local elig = C.EligibilitySnapshot(coord)
    local oldRow = {
        type = "deposit", donor = donor, itemId = flask, quantity = 5,
        guildGuid = "club-1", bankTab = 2, generation = 1,
        approxTxnTime = (elig.tabEligibleFrom or clock) - 3600,
        coreSignature = O.CoreSignature("deposit", donor, flask, 5),
        occurrenceIndex = 1, neighborsOlder = {}, neighborsNewer = {},
    }
    assertFalse(O.IsEvidenceEligible(oldRow, elig), "pre-clear history is ineligible after reconfigure")
    oldRow.approxTxnTime = (elig.tabEligibleFrom or clock) + 10
    assertTrue(O.IsEvidenceEligible(oldRow, elig), "post-clear donation remains eligible")
end

-- ---------------------------------------------------------------------------
-- Durable rejection correction survives authoritative ReplaceConfig
-- ---------------------------------------------------------------------------
do
    local coord = makeProfile("rej-correct-coord")
    local follower = makeProfile("rej-correct-follower")
    local ev = evidence({ quantity = 12, occurrenceIndex = 4 })
    assertTrue(C.RecordDurableRejection(coord, ev, admin, "rejected"))
    local snap1 = C.ExportSnapshot(coord, { omitEvents = true })
    assertTrue(select(1, C.ReplaceConfig(follower, snap1)), "follower receives rejection")
    assertTrue(V.IsRejected({ rejections = C.DurableRejections(follower) }, ev),
        "follower durable rejection present")
    assertTrue(C.ClearDurableRejection(coord, ev), "coordinator corrects rejection")
    local snap2 = C.ExportSnapshot(coord, { omitEvents = true })
    assertTrue((tonumber(snap2.rejectionSeq) or 0) > (tonumber(snap1.rejectionSeq) or 0),
        "correction bumps rejectionSeq")
    assertTrue(select(1, C.ReplaceConfig(follower, snap2)), "follower receives correction snapshot")
    assertFalse(V.IsRejected({ rejections = C.DurableRejections(follower) }, ev),
        "follower durable rejection removed after authoritative correction")
end

-- ---------------------------------------------------------------------------
-- AllowRemoteOp still admits a full observation page (one credit per report)
-- ---------------------------------------------------------------------------
do
    local bucket = {}
    local now = 1000
    assertTrue(S.AllowRemoteOp(bucket, "Reporter-Realm", now), "first report admitted")
    -- A full page must not require 32 credits.
    assertTrue(S.AllowRemoteOp(bucket, "Reporter-Realm", now), "second report in window admitted")
    local count = 2
    while S.AllowRemoteOp(bucket, "Reporter-Realm", now) do
        count = count + 1
        if count > S.MAX_REMOTE_OPS + 5 then break end
    end
    assertEq(count, S.MAX_REMOTE_OPS, "window still bounds reports, not observations")
end

-- ---------------------------------------------------------------------------
-- Rejection updates advance admitted configSeq / descriptor catch-up
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("rej-watermark")
    local before = C.Descriptor(p)
    local ev = evidence({ quantity = 7 })
    assertTrue(C.RecordDurableRejection(p, ev, admin, "rejected"))
    local after = C.Descriptor(p)
    assertTrue((tonumber(after.configSeq) or 0) > (tonumber(before.configSeq) or 0),
        "rejection bumps configSeq for ApplyRemoteConfig admission")
    assertTrue((tonumber(after.rejectionSeq) or 0) > (tonumber(before.rejectionSeq) or 0),
        "rejection bumps rejectionSeq")
    assertTrue(after.configFingerprint ~= before.configFingerprint,
        "rejection changes config fingerprint")
    assertTrue(S.CoordinatorConfigDiffers(before, after),
        "catch-up sees rejectionSeq/config difference")
end

-- ---------------------------------------------------------------------------
-- Scope change (Clear) replaces follower durable rejections
-- ---------------------------------------------------------------------------
do
    local coord = makeProfile("rej-scope-coord")
    local follower = makeProfile("rej-scope-follower")
    local ev = evidence({ quantity = 11, occurrenceIndex = 2 })
    assertTrue(C.RecordDurableRejection(follower, ev, admin, "rejected"))
    -- Inflate follower rejectionSeq above a fresh clear snapshot.
    for _ = 1, 3 do
        C.RecordDurableRejection(follower, evidence({
            quantity = 11 + _,
            coreSignature = O.CoreSignature("deposit", donor, flask, 11 + _),
            neighborsOlder = { "x" .. _ },
        }), admin, "rejected")
    end
    assertTrue(select(1, C.Clear(coord, admin)), "coordinator clears")
    local snap = C.ExportSnapshot(coord, { omitEvents = true })
    assertTrue(select(1, C.ReplaceConfig(follower, snap)), "follower accepts clear snapshot")
    assertFalse(V.IsRejected({ rejections = C.DurableRejections(follower) }, ev),
        "scope change replaces stale durable rejections")
end

-- ---------------------------------------------------------------------------
-- Cross-generation identical deposit is not absorbed from archive
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("cross-gen")
    local db = {}
    local store = O.EnsureProfileStore(db, "cross-gen")
    local scope = O.EnsureScope(store, "club-1", 2)
    local first = evidence({
        quantity = 20, occurrenceIndex = 1, generation = 1,
        neighborsOlder = { "old-a" }, neighborsNewer = { "new-a" },
    })
    V.IngestReport(p, "cross-gen", admin, { first }, { isAdmin = true, scope = scope, obsStore = store })
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("cross-gen")[1], admin))
    assertEq(C.ContributionTotal(p, donor, flask), 20, "first generation deposit credited")
    assertTrue(select(1, C.Clear(p, admin)), "clear advances generation")
    assertTrue(C.SetGuild(p, admin, GUILD, 2))
    assertTrue(C.AddRequestedItem(p, admin, flask))
    local gen = tonumber(C.Ensure(p).generation) or 2
    V.ClearSessionClusters()
    local second = evidence({
        quantity = 20, occurrenceIndex = 1, generation = gen,
        neighborsOlder = { "old-a" }, neighborsNewer = { "new-a" },
        approxTxnTime = clock - 10,
    })
    local stats = V.IngestReport(p, "cross-gen", admin, { second }, {
        isAdmin = true, scope = scope, obsStore = store,
    })
    assertEq(stats.verified, 1, "post-clear identical deposit verifies anew")
    local cluster = V.ListVerifiedClusters("cross-gen")[1]
    assertFalse(cluster._committed == true, "post-clear deposit is not archive-absorbed")
    assertTrue(V.CommitVerifiedCluster(p, cluster, admin), "post-clear deposit commits")
    -- Clear shelves prior-generation totals; current generation must still credit 20.
    assertEq(C.ContributionTotal(p, donor, flask), 20, "new generation credits the post-clear deposit")
    local matched = V.FindEquivalentLedgerDonation(p, "cross-gen", second)
    assertTrue(matched ~= nil, "ledger match finds the new-generation donation")
    assertEq(tonumber(matched.generation), tonumber(second.generation),
        "matched ledger donation is the new generation, not the archive")
end

-- ---------------------------------------------------------------------------
-- Offline admin trust honors durable profile rejections
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("offline-durable-rej")
    local ev = evidence({ quantity = 13, neighborsOlder = { "n1" } })
    assertTrue(C.RecordDurableRejection(p, ev, admin, "rejected"))
    local db = {}
    local store = O.EnsureProfileStore(db, "offline-durable-rej")
    local scope = O.EnsureScope(store, "club-1", 2)
    scope.observations[1] = evidence({
        quantity = 13, neighborsOlder = { "n1" }, status = "pending",
    })
    local stats = V.ProcessLocalAfterReconcile(p, "offline-durable-rej", store, scope, {
        selfId = admin, asAdmin = true, deferToCoordinator = false,
    })
    assertEq(stats.trusted, 0, "durable rejection blocks offline admin trust")
    assertEq(stats.suppressed, 1, "durable rejection suppresses the observation")
    assertEq(scope.observations[1].status, "rejected", "observation marked rejected")
    assertEq(C.ContributionTotal(p, donor, flask), 0, "rejected deposit is not credited")
end

-- ---------------------------------------------------------------------------
-- Uncertain empty-window offline rows defer instead of minting colliding IDs
-- ---------------------------------------------------------------------------
do
    local p = makeProfile("uncertain-offline")
    local db = {}
    local store = O.EnsureProfileStore(db, "uncertain-offline")
    local scope = O.EnsureScope(store, "club-1", 2)
    scope.observations[1] = evidence({
        quantity = 5, occurrenceIndex = 1,
        neighborsOlder = {}, neighborsNewer = {},
        status = "pending",
    })
    local stats = V.ProcessLocalAfterReconcile(p, "uncertain-offline", store, scope, {
        selfId = admin, asAdmin = true, deferToCoordinator = false,
    })
    assertEq(stats.trusted, 0, "empty-context offline trust is deferred")
    assertEq(stats.deferred, 1, "uncertain identity waits for review")
    assertEq(C.ContributionTotal(p, donor, flask), 0, "no credit without stable identity")
end

-- ---------------------------------------------------------------------------
-- Staggered witnesses across session resets still reach threshold
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("staggered-witness")
    local db = {}
    local store = O.EnsureProfileStore(db, "staggered-witness")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 16 })
    local s1 = V.IngestReport(p, "staggered-witness", w1, { ev }, {
        scope = scope, obsStore = store,
        recordPendingWitness = function(evidence, submittedBy, witnessMap)
            C.UpsertPendingWitness(p, evidence, submittedBy, witnessMap)
        end,
    })
    assertEq(s1.verified, 0, "first session witness stays pending")
    assertTrue(#C.PendingWitnesses(p) >= 1, "witness aggregate persisted")
    V.ClearSessionClusters()
    local s2 = V.IngestReport(p, "staggered-witness", w2, { ev }, {
        scope = scope, obsStore = store,
        recordPendingWitness = function(evidence, submittedBy, witnessMap)
            C.UpsertPendingWitness(p, evidence, submittedBy, witnessMap)
        end,
    })
    assertEq(s2.verified, 0, "second session still pending after hydrate")
    V.ClearSessionClusters()
    local s3 = V.IngestReport(p, "staggered-witness", w3, { ev }, {
        scope = scope, obsStore = store,
        recordPendingWitness = function(evidence, submittedBy, witnessMap)
            C.UpsertPendingWitness(p, evidence, submittedBy, witnessMap)
        end,
        clearPendingWitness = function(evidence)
            C.ClearPendingWitness(p, evidence)
        end,
    })
    assertEq(s3.verified, 1, "third staggered session verifies from durable witnesses")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("staggered-witness")[1], w3))
    assertEq(C.ContributionTotal(p, donor, flask), 16, "staggered witnesses credit once")
end

-- ---------------------------------------------------------------------------
-- ReviewSummary exposes durable rejections after session reset
-- ---------------------------------------------------------------------------
do
    V.ClearSessionClusters()
    local p = makeProfile("durable-review")
    local ev = evidence({ quantity = 18, neighborsOlder = { "r1" } })
    assertTrue(C.RecordDurableRejection(p, ev, admin, "rejected"))
    V.ClearSessionClusters()
    local summary = V.ReviewSummary("durable-review", { profile = p })
    local found = false
    for i = 1, #summary do
        if summary[i].status == "rejected" and summary[i].quantity == 18 then
            found = true
            assertTrue(select(1, V.ApplyDecision(p, "durable-review", admin, {
                action = "correct", evidence = summary[i].evidence or ev,
            }, {
                isAdmin = true,
                clearDurableRejection = function(evidence)
                    C.ClearDurableRejection(p, evidence)
                end,
            })), "durable rejection can be corrected after session reset")
        end
    end
    assertTrue(found, "review summary includes durable rejection after session reset")
    assertFalse(V.IsRejected({ rejections = C.DurableRejections(p) }, ev),
        "correction clears durable rejection")
end

-- ---------------------------------------------------------------------------
-- Eligibility boundary-spanning deposits become ambiguous
-- ---------------------------------------------------------------------------
do
    local cutover = clock - 100
    local eligibility = {
        items = {},
        tabEligibleFrom = cutover,
        baselineEstablished = true,
    }
    local spanning = evidence({
        approxTxnTime = cutover + 10,
        ageHours = 0,
        neighborsOlder = { "b1" },
    })
    assertTrue(O.EvidenceSpansEligibilityBoundary(spanning, eligibility),
        "age-zero deposit near cutover spans boundary")
    assertTrue(O.IsEvidenceEligible(spanning, eligibility),
        "boundary-spanning rows remain visible/eligible for review")
    local spanningHour = evidence({
        approxTxnTime = cutover + 10,
        ageHours = 1,
        neighborsOlder = { "b1h" },
    })
    assertTrue(O.EvidenceSpansEligibilityBoundary(spanningHour, eligibility),
        "whole-hour age=1 near cutover also spans boundary")
    local safe = evidence({
        approxTxnTime = cutover + 7200,
        ageHours = 2,
        neighborsOlder = { "b2" },
    })
    assertFalse(O.EvidenceSpansEligibilityBoundary(safe, eligibility),
        "well-after-cutover deposits are not ambiguous by boundary")
end

-- ---------------------------------------------------------------------------
-- Canonical transaction registry regressions (Issue #366 remaining work)
-- ---------------------------------------------------------------------------

-- 1. Same transaction, different relative timestamps across clients
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-shift-time")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-shift-time")
    local scope = O.EnsureScope(store, "club-1", 2)
    local base = evidence({
        quantity = 11,
        approxTxnTime = clock - 120,
        neighborsOlder = { "anchor-older" },
        neighborsNewer = { "anchor-newer" },
    })
    assertEq(V.IngestReport(p, "reg-shift-time", admin, { base }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#1 first admin verifies")
    local txnId = V.ListVerifiedClusters("reg-shift-time")[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-shift-time")[1], admin))
    V.ClearSessionClusters()
    local shifted = evidence({
        quantity = 11,
        approxTxnTime = clock - 120 + 2400,
        occurrenceIndex = 7,
        neighborsOlder = { "anchor-older" },
        neighborsNewer = { "anchor-newer" },
    })
    local stats = V.IngestReport(p, "reg-shift-time", w1, { shifted }, {
        isAdmin = false, scope = scope, obsStore = store,
    })
    assertEq(stats.verified, 0, "registry#1 rematch does not re-verify")
    local how, entry = V.ReconcileAgainstRegistry(p, shifted)
    assertEq(how, "verified", "registry#1 shifted time rematches")
    assertEq(entry.txnId, txnId, "registry#1 reuses Spectrum txnId")
    assertEq(C.ContributionTotal(p, donor, flask), 11, "registry#1 no double credit")
end

-- 2. Same transaction, different surrounding Guild Bank records
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-neighbors")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-neighbors")
    local scope = O.EnsureScope(store, "club-1", 2)
    local first = evidence({
        quantity = 12,
        neighborsOlder = { "n-a", "n-b" },
        neighborsNewer = { "n-c" },
        approxTxnTime = clock - 90,
    })
    assertEq(V.IngestReport(p, "reg-neighbors", admin, { first }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#2 verifies")
    local txnId = V.ListVerifiedClusters("reg-neighbors")[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-neighbors")[1], admin))
    local altNeighbors = evidence({
        quantity = 12,
        neighborsOlder = { "n-b", "n-x" },
        neighborsNewer = { "n-c", "n-y" },
        approxTxnTime = clock - 80,
        occurrenceIndex = 1,
    })
    local how, entry = V.ReconcileAgainstRegistry(p, altNeighbors)
    assertEq(how, "verified", "registry#2 partial neighbor overlap rematches")
    assertEq(entry.txnId, txnId, "registry#2 keeps canonical id with different surround")
end

-- 3. Two distinct identical-item deposits stay separate
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-twin-deposits")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-twin-deposits")
    local scope = O.EnsureScope(store, "club-1", 2)
    local a = evidence({
        quantity = 20, occurrenceIndex = 1,
        neighborsOlder = { "twin-old-1" }, neighborsNewer = { "twin-new-1" },
        approxTxnTime = clock - 200,
    })
    local b = evidence({
        quantity = 20, occurrenceIndex = 2,
        neighborsOlder = { "twin-old-2" }, neighborsNewer = { "twin-new-2" },
        approxTxnTime = clock - 40,
    })
    assertEq(V.IngestReport(p, "reg-twin-deposits", admin, { a }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#3 first deposit verifies")
    local idA = V.ListVerifiedClusters("reg-twin-deposits")[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-twin-deposits")[1], admin))
    V.ClearSessionClusters()
    assertEq(V.IngestReport(p, "reg-twin-deposits", admin, { b }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#3 second deposit verifies separately")
    local idB = V.ListVerifiedClusters("reg-twin-deposits")[1].txnId
    assertTrue(idA ~= idB, "registry#3 distinct Spectrum IDs")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-twin-deposits")[1], admin))
    assertEq(C.ContributionTotal(p, donor, flask), 40, "registry#3 both deposits credit")
    assertEq(#C.TxnRegistry(p), 2, "registry#3 two registry rows")
end

-- 4. Two deposits with identical surrounding patterns remain separate when far apart
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-same-pattern")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-same-pattern")
    local scope = O.EnsureScope(store, "club-1", 2)
    local pattern = { "pat-older" }
    local newer = { "pat-newer" }
    local early = evidence({
        quantity = 9, occurrenceIndex = 1,
        neighborsOlder = pattern, neighborsNewer = newer,
        approxTxnTime = clock - (4 * 3600),
        ageHours = 4,
    })
    local late = evidence({
        quantity = 9, occurrenceIndex = 1,
        neighborsOlder = pattern, neighborsNewer = newer,
        approxTxnTime = clock - 30,
        ageHours = 0,
    })
    assertEq(V.IngestReport(p, "reg-same-pattern", admin, { early }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#4 early pattern verifies")
    local idEarly = V.ListVerifiedClusters("reg-same-pattern")[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-same-pattern")[1], admin))
    V.ClearSessionClusters()
    local how = select(1, V.ReconcileAgainstRegistry(p, late))
    assertEq(how, "none", "registry#4 late identical pattern does not auto-merge (>3h)")
    assertEq(V.IngestReport(p, "reg-same-pattern", admin, { late }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#4 late deposit verifies as new txn")
    local idLate = V.ListVerifiedClusters("reg-same-pattern")[1].txnId
    assertTrue(idEarly ~= idLate, "registry#4 distinct IDs for same pattern later")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-same-pattern")[1], admin))
    assertEq(C.ContributionTotal(p, donor, flask), 18, "registry#4 both pattern deposits credit")
end

-- 5. Visible history disappears; later matching-looking deposit is not auto-merged
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-disappear")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-disappear")
    local scope = O.EnsureScope(store, "club-1", 2)
    local first = evidence({
        quantity = 7, occurrenceIndex = 1,
        neighborsOlder = {}, neighborsNewer = {},
        approxTxnTime = clock - (4 * 3600),
        ageHours = 4,
        firstSeen = clock - (4 * 3600),
        lastSeen = clock - (4 * 3600),
    })
    assertEq(V.IngestReport(p, "reg-disappear", admin, { first }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#5 first verifies")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-disappear")[1], admin))
    local later = evidence({
        quantity = 7, occurrenceIndex = 1,
        neighborsOlder = {}, neighborsNewer = {},
        approxTxnTime = clock - 10,
        ageHours = 0,
        firstSeen = clock - 10,
        lastSeen = clock - 10,
        observedAt = clock,
    })
    local how = select(1, V.ReconcileAgainstRegistry(p, later))
    assertEq(how, "none", "registry#5 later empty-context lookalike is not auto-matched")
    V.ClearSessionClusters()
    assertEq(V.IngestReport(p, "reg-disappear", admin, { later }, {
        isAdmin = true, scope = scope, obsStore = store, historyComplete = true,
    }).verified, 1, "registry#5 later deposit verifies as new when distinct")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-disappear")[1], admin))
    assertEq(C.ContributionTotal(p, donor, flask), 14, "registry#5 two credits when distinct")
end

-- 6. Verified transaction survives reload / new raid session via profile sync payload
do
    V.ClearSessionClusters()
    local tuesday = makeProfile("reg-reload")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-reload")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({ quantity = 13, neighborsOlder = { "reload-n" } })
    assertEq(V.IngestReport(tuesday, "reg-reload", admin, { ev }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "registry#6 verifies before reload")
    local txnId = V.ListVerifiedClusters("reg-reload")[1].txnId
    assertTrue(V.CommitVerifiedCluster(tuesday, V.ListVerifiedClusters("reg-reload")[1], admin))
    local snap = C.ExportSnapshot(tuesday)
    assertTrue(type(snap.txnRegistry) == "table" and #snap.txnRegistry >= 1,
        "registry#6 snapshot includes txnRegistry")
    assertTrue(tonumber(snap.txnAllocSeq) and snap.txnAllocSeq >= 1,
        "registry#6 snapshot includes txnAllocSeq")
    V.ClearSessionClusters()
    local thursday = makeProfile("reg-reload-restored")
    assertTrue(select(1, C.MergeSnapshot(thursday, snap, { consumablesFromCoordinator = true })),
        "registry#6 merge restores registry+ledger across session")
    assertTrue(C.FindRegistryTxn(thursday, txnId) ~= nil, "registry#6 txn survives reload")
    assertEq(C.ContributionTotal(thursday, donor, flask), 13, "registry#6 credit survives reload")
    local how, entry = V.ReconcileAgainstRegistry(thursday, ev)
    assertEq(how, "verified", "registry#6 rematch after reload")
    assertEq(entry.txnId, txnId, "registry#6 same Spectrum id after reload")
end

-- 7. Coordinator A Tuesday → Coordinator B Thursday
do
    V.ClearSessionClusters()
    local coordA = makeProfile("reg-handoff", { admin, "CoordB-Realm" })
    local dbA = {}
    local storeA = O.EnsureProfileStore(dbA, "reg-handoff")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local tuesdayEv = evidence({
        quantity = 16, neighborsOlder = { "tue-n" }, approxTxnTime = clock - 100,
    })
    assertEq(V.IngestReport(coordA, "reg-handoff", admin, { tuesdayEv }, {
        isAdmin = true, scope = scopeA, obsStore = storeA,
    }).verified, 1, "registry#7 Coord A verifies Tuesday")
    local txnId = V.ListVerifiedClusters("reg-handoff")[1].txnId
    assertTrue(V.CommitVerifiedCluster(coordA, V.ListVerifiedClusters("reg-handoff")[1], admin))
    local snap = C.ExportSnapshot(coordA)
    V.ClearSessionClusters()
    local coordB = makeProfile("reg-handoff-b", { admin, "CoordB-Realm" })
    assertTrue(select(1, C.MergeSnapshot(coordB, snap, { consumablesFromCoordinator = true })),
        "registry#7 Coord B receives Tuesday registry+ledger")
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "reg-handoff-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local reobserve = evidence({
        quantity = 16, neighborsOlder = { "tue-n" },
        approxTxnTime = clock - 100 + 900,
        occurrenceIndex = 4,
    })
    local stats = V.IngestReport(coordB, "reg-handoff-b", "CoordB-Realm", { reobserve }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    })
    assertEq(stats.verified, 0, "registry#7 Coord B does not re-verify Tuesday txn")
    assertEq(C.ContributionTotal(coordB, donor, flask), 16, "registry#7 Tuesday credit intact")
    local how, entry = V.ReconcileAgainstRegistry(coordB, reobserve)
    assertEq(how, "verified", "registry#7 Coord B rematches registry")
    assertEq(entry.txnId, txnId, "registry#7 Coord B reuses Tuesday Spectrum id")
    local fresh = evidence({
        quantity = 5, neighborsOlder = { "thu-n" },
        approxTxnTime = clock - 20, occurrenceIndex = 1,
        coreSignature = O.CoreSignature("deposit", donor, flask, 5),
    })
    assertEq(V.IngestReport(coordB, "reg-handoff-b", "CoordB-Realm", { fresh }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    }).verified, 1, "registry#7 Thursday new deposit still verifies")
    local newId = nil
    local verified = V.ListVerifiedClusters("reg-handoff-b")
    for i = 1, #verified do
        if verified[i].txnId ~= txnId then newId = verified[i].txnId end
    end
    assertTrue(newId ~= nil and newId ~= txnId, "registry#7 new Thursday id is distinct")
end

-- 8. New coordinator with incomplete history holds uncertain credit
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-incomplete")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-incomplete")
    local scope = O.EnsureScope(store, "club-1", 2)
    -- Simulate remote coordinator ahead on events/registry watermarks.
    p._consumablesCatchUpRemote = {
        generation = 1,
        configSeq = 5,
        eventCount = 3,
        eventFingerprint = 999,
        txnAllocSeq = 3,
        archiveCount = 0,
        archiveFingerprint = 0,
    }
    assertTrue(S.NeedsCatchUp(C.Descriptor(p), p._consumablesCatchUpRemote),
        "registry#8 catch-up required")
    local uncertain = evidence({
        quantity = 4, neighborsOlder = { "inc-n" }, approxTxnTime = clock - 50,
    })
    local stats = V.IngestReport(p, "reg-incomplete", admin, { uncertain }, {
        isAdmin = true, scope = scope, obsStore = store, historyComplete = false,
    })
    assertEq(stats.verified, 0, "registry#8 incomplete history does not verify")
    assertEq(stats.pending, 1, "registry#8 holds pending for review")
    assertEq(C.ContributionTotal(p, donor, flask), 0, "registry#8 no speculative credit")
end

-- 8b. Incomplete new coordinator must recover peer history before overlapping credit
do
    V.ClearSessionClusters()
    local coordA = makeProfile("reg-handoff-recover", { admin, "CoordB-Realm" })
    local dbA = {}
    local storeA = O.EnsureProfileStore(dbA, "reg-handoff-recover")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local tuesdayEv = evidence({
        quantity = 17, neighborsOlder = { "tue-recover" }, approxTxnTime = clock - 200,
    })
    assertEq(V.IngestReport(coordA, "reg-handoff-recover", admin, { tuesdayEv }, {
        isAdmin = true, scope = scopeA, obsStore = storeA,
    }).verified, 1, "handoff-recover A verifies Tuesday")
    local txnId = V.ListVerifiedClusters("reg-handoff-recover")[1].txnId
    assertTrue(V.CommitVerifiedCluster(coordA, V.ListVerifiedClusters("reg-handoff-recover")[1], admin))
    local richSnap = C.ExportSnapshot(coordA)
    assertTrue(S.PeerHistoryAhead(C.Descriptor(makeProfile("empty-desc")), C.Descriptor(coordA)),
        "handoff-recover peer-ahead helper sees richer history")

    -- B starts Thursday with no Tuesday registry.
    V.ClearSessionClusters()
    local coordB = makeProfile("reg-handoff-recover-b", { admin, "CoordB-Realm" })
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "reg-handoff-recover-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local incompleteSnap = C.ExportSnapshot(coordB)
    assertEq(#(C.TxnRegistry(coordB) or {}), 0, "handoff-recover B starts empty")

    -- A's richer history must survive B's incomplete authoritative snapshot.
    assertTrue(select(1, C.MergeSnapshot(coordA, incompleteSnap, { consumablesFromCoordinator = true })),
        "handoff-recover incomplete B snapshot applies without error")
    assertTrue(C.FindRegistryTxn(coordA, txnId) ~= nil,
        "handoff-recover A keeps Tuesday registry after incomplete B overwrite attempt")
    assertEq(C.ContributionTotal(coordA, donor, flask), 17,
        "handoff-recover A keeps Tuesday ledger credit")
    assertTrue(type(coordA._consumablesUnsent) == "table" and #coordA._consumablesUnsent >= 1,
        "handoff-recover A requeues canonical credit for coordinator recovery")

    -- B holds overlapping observations until peer history is absorbed.
    local reobserve = evidence({
        quantity = 17, neighborsOlder = { "tue-recover" },
        approxTxnTime = clock - 200 + 600, occurrenceIndex = 3,
    })
    local held = V.IngestReport(coordB, "reg-handoff-recover-b", "CoordB-Realm", { reobserve }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = false,
    })
    assertEq(held.verified, 0, "handoff-recover B holds until history recovered")
    assertEq(C.ContributionTotal(coordB, donor, flask), 0, "handoff-recover B no duplicate yet")

    -- A supplies missing history; B converges on original Spectrum txnId.
    assertTrue(select(1, C.MergeSnapshot(coordB, richSnap, { consumablesFromCoordinator = true })),
        "handoff-recover B absorbs A's Tuesday snapshot")
    assertTrue(C.FindRegistryTxn(coordB, txnId) ~= nil, "handoff-recover B has Tuesday txnId")
    assertEq(C.ContributionTotal(coordB, donor, flask), 17, "handoff-recover B credits Tuesday once")
    V.ClearSessionClusters()
    local after = V.IngestReport(coordB, "reg-handoff-recover-b", "CoordB-Realm", { reobserve }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    })
    assertEq(after.verified, 0, "handoff-recover rematch does not re-verify")
    local how, entry = V.ReconcileAgainstRegistry(coordB, reobserve)
    assertEq(how, "verified", "handoff-recover rematch hits registry")
    assertEq(entry.txnId, txnId, "handoff-recover reuses original canonical id")
    assertEq(C.ContributionTotal(coordB, donor, flask), 17, "handoff-recover no duplicate credit")

    local thursday = evidence({
        quantity = 3, neighborsOlder = { "thu-recover" },
        approxTxnTime = clock - 15, occurrenceIndex = 1,
        coreSignature = O.CoreSignature("deposit", donor, flask, 3),
    })
    V.ClearSessionClusters()
    assertEq(V.IngestReport(coordB, "reg-handoff-recover-b", "CoordB-Realm", { thursday }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    }).verified, 1, "handoff-recover new Thursday deposit still verifies")
    local thuCluster = V.ListVerifiedClusters("reg-handoff-recover-b")[1]
    assertTrue(thuCluster and thuCluster.txnId ~= txnId, "handoff-recover Thursday gets a distinct txnId")
    assertTrue(V.CommitVerifiedCluster(coordB, thuCluster, "CoordB-Realm"))
    assertEq(C.ContributionTotal(coordB, donor, flask), 20, "handoff-recover Thursday credits normally")
end

-- 9. Three independent witnesses converge without combining separate deposits
do
    V.ClearSessionClusters()
    local p = makeProfile("reg-witnesses")
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-witnesses")
    local scope = O.EnsureScope(store, "club-1", 2)
    local depA = evidence({
        quantity = 8, occurrenceIndex = 1,
        neighborsOlder = { "w-a1" }, neighborsNewer = { "w-a2" },
        approxTxnTime = clock - 300,
    })
    local depB = evidence({
        quantity = 8, occurrenceIndex = 2,
        neighborsOlder = { "w-b1" }, neighborsNewer = { "w-b2" },
        approxTxnTime = clock - 60,
    })
    assertEq(V.IngestReport(p, "reg-witnesses", w1, { depA }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "registry#9 depA witness1 pending")
    assertEq(V.IngestReport(p, "reg-witnesses", w2, { depA }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "registry#9 depA witness2 pending")
    local s3 = V.IngestReport(p, "reg-witnesses", w3, { depA }, {
        isAdmin = false, scope = scope, obsStore = store,
    })
    assertEq(s3.verified, 1, "registry#9 depA third witness verifies")
    local idA = V.ListVerifiedClusters("reg-witnesses")[1].txnId
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-witnesses")[1], w3))
    V.ClearSessionClusters()
    assertEq(V.IngestReport(p, "reg-witnesses", w1, { depB }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "registry#9 depB witness1 pending")
    assertEq(V.IngestReport(p, "reg-witnesses", w2, { depB }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "registry#9 depB witness2 pending")
    local sB = V.IngestReport(p, "reg-witnesses", w3, { depB }, {
        isAdmin = false, scope = scope, obsStore = store,
    })
    assertEq(sB.verified, 1, "registry#9 depB verifies independently")
    local idB = V.ListVerifiedClusters("reg-witnesses")[1].txnId
    assertTrue(idA ~= idB, "registry#9 witness paths do not merge distinct deposits")
    assertTrue(V.CommitVerifiedCluster(p, V.ListVerifiedClusters("reg-witnesses")[1], w3))
    assertEq(C.ContributionTotal(p, donor, flask), 16, "registry#9 both witness-verified deposits credit")
end

-- 10. Admin rejection/correction survives registry sync and coordinator change
do
    V.ClearSessionClusters()
    local coordA = makeProfile("reg-reject-sync", { admin, "CoordB-Realm" })
    local db = {}
    local store = O.EnsureProfileStore(db, "reg-reject-sync")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({
        quantity = 6, neighborsOlder = { "rej-n" }, approxTxnTime = clock - 70,
    })
    assertEq(V.IngestReport(coordA, "reg-reject-sync", w1, { ev }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "registry#10 pending before reject")
    local clusters = V.EnsureClusterStore("reg-reject-sync").clusters
    local clusterId = clusters[1] and clusters[1].clusterId
    assertTrue(select(1, V.ApplyDecision(coordA, "reg-reject-sync", admin, {
        action = "reject", clusterId = clusterId, reason = "duplicate bank scan",
    }, {
        isAdmin = true,
        recordDurableRejection = function(evidence, decidedBy, reason)
            C.RecordDurableRejection(coordA, evidence, decidedBy, reason)
        end,
    })), "registry#10 admin rejects")
    local rejEntry = nil
    for i = 1, #C.TxnRegistry(coordA) do
        if C.TxnRegistry(coordA)[i].status == "rejected" then
            rejEntry = C.TxnRegistry(coordA)[i]
        end
    end
    assertTrue(rejEntry ~= nil, "registry#10 rejection recorded in txnRegistry")
    local snap = C.ExportSnapshot(coordA, { omitEvents = true })
    V.ClearSessionClusters()
    local coordB = makeProfile("reg-reject-sync-b", { admin, "CoordB-Realm" })
    assertTrue(select(1, C.ReplaceConfig(coordB, snap)), "registry#10 Coord B receives rejection snapshot")
    assertTrue(V.IsRejected({ rejections = C.DurableRejections(coordB) }, ev),
        "registry#10 durable rejection present on Coord B")
    local how = select(1, V.ReconcileAgainstRegistry(coordB, ev))
    assertEq(how, "rejected", "registry#10 registry rejection survives sync")
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "reg-reject-sync-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local stats = V.IngestReport(coordB, "reg-reject-sync-b", w2, { ev }, {
        isAdmin = false, scope = scopeB, obsStore = storeB,
        durableRejections = C.DurableRejections(coordB),
    })
    assertEq(stats.rejected, 1, "registry#10 re-report stays rejected after handoff")
    assertEq(C.ContributionTotal(coordB, donor, flask), 0, "registry#10 no credit after rejection sync")
    assertTrue(select(1, V.ApplyDecision(coordB, "reg-reject-sync-b", "CoordB-Realm", {
        action = "correct", evidence = ev,
    }, {
        isAdmin = true,
        clearDurableRejection = function(evidence)
            C.ClearDurableRejection(coordB, evidence)
        end,
    })), "registry#10 Coord B can correct after sync")
    local howAfter = select(1, V.ReconcileAgainstRegistry(coordB, ev))
    assertEq(howAfter, "verified", "registry#10 correction flips registry status")
end

-- 11. Writer-offline peer recovery: authorized non-writer peer supplies stamped history
do
    V.ClearSessionClusters()
    local writer = admin
    local peerAdmin = "PeerAdmin-Realm"
    local coordB = "CoordB-Realm"
    local coordA = makeProfile("peer-recover-a", { writer, peerAdmin, coordB })
    local dbA = {}
    local storeA = O.EnsureProfileStore(dbA, "peer-recover-a")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local tuesdayEv = evidence({
        quantity = 19, neighborsOlder = { "peer-tue" }, approxTxnTime = clock - 400,
    })
    assertEq(V.IngestReport(coordA, "peer-recover-a", writer, { tuesdayEv }, {
        isAdmin = true, scope = scopeA, obsStore = storeA,
    }).verified, 1, "peer-recover writer verifies Tuesday")
    local txnId = V.ListVerifiedClusters("peer-recover-a")[1].txnId
    assertTrue(V.CommitVerifiedCluster(coordA, V.ListVerifiedClusters("peer-recover-a")[1], writer))
    -- Simulate coordinator-stamped provenance a synchronized peer would hold.
    for i = 1, #(coordA._consumableEvents or {}) do
        local event = coordA._consumableEvents[i]
        if type(event) == "table" and event.txnId == txnId then
            C.StampOrder(coordA, event)
            C.NoteStoredWriter(coordA, event, writer)
        end
    end
    local peerCopy = makeProfile("peer-recover-holder", { writer, peerAdmin, coordB })
    assertTrue(select(1, C.MergeSnapshot(peerCopy, C.ExportSnapshot(coordA), { consumablesFromCoordinator = true })),
        "peer-recover authorized peer holds synchronized Tuesday history")
    assertTrue(C.FindRegistryTxn(peerCopy, txnId) ~= nil, "peer-recover peer has original txnId")
    assertEq(C.ContributionTotal(peerCopy, donor, flask), 19, "peer-recover peer has Tuesday credit")

    -- New coordinator B has empty history; original writer is offline.
    V.ClearSessionClusters()
    local late = makeProfile("peer-recover-b", { writer, peerAdmin, coordB })
    assertEq(#(C.TxnRegistry(late) or {}), 0, "peer-recover B starts without Tuesday registry")
    local peerSnap = C.ExportSnapshot(peerCopy)
    -- Peer path: stamped RelayWriter events + registry union (writer offline).
    assertTrue(select(1, C.MergeSnapshot(late, peerSnap, { consumablesFromCoordinator = false })),
        "peer-recover B absorbs history from non-writer authorized peer")
    assertTrue(C.FindRegistryTxn(late, txnId) ~= nil, "peer-recover B recovered original txnId")
    local recovered = C.FindRegistryTxn(late, txnId)
    assertEq(recovered.status, "verified", "peer-recover recovered status stays verified")
    assertTrue(recovered.committed == true, "peer-recover recovered committed provenance")
    assertEq(C.ContributionTotal(late, donor, flask), 19, "peer-recover B credits Tuesday once")

    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "peer-recover-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local reobserve = evidence({
        quantity = 19, neighborsOlder = { "peer-tue" },
        approxTxnTime = clock - 400 + 800, occurrenceIndex = 2,
    })
    local after = V.IngestReport(late, "peer-recover-b", coordB, { reobserve }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    })
    assertEq(after.verified, 0, "peer-recover rematch does not re-verify")
    assertEq(C.ContributionTotal(late, donor, flask), 19, "peer-recover no duplicate credit after rematch")
    local how, entry = V.ReconcileAgainstRegistry(late, reobserve)
    assertEq(how, "verified", "peer-recover rematch hits recovered registry")
    assertEq(entry.txnId, txnId, "peer-recover reuses original Spectrum id")
end

-- 12. Older rejection cannot overwrite a newer authorized correction/approval
do
    V.ClearSessionClusters()
    local p = makeProfile("decision-order", { admin, "CoordB-Realm" })
    local db = {}
    local store = O.EnsureProfileStore(db, "decision-order")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({
        quantity = 11, neighborsOlder = { "dec-n" }, approxTxnTime = clock - 90,
    })
    assertEq(V.IngestReport(p, "decision-order", w1, { ev }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "decision-order pending before reject")
    local clusterId = V.EnsureClusterStore("decision-order").clusters[1].clusterId
    clock = clock + 10
    assertTrue(select(1, V.ApplyDecision(p, "decision-order", admin, {
        action = "reject", clusterId = clusterId, reason = "false positive",
    }, {
        isAdmin = true,
        recordDurableRejection = function(evidence, decidedBy, reason)
            C.RecordDurableRejection(p, evidence, decidedBy, reason)
        end,
    })), "decision-order rejects first")
    local rejected = nil
    for i = 1, #C.TxnRegistry(p) do
        if C.TxnRegistry(p)[i].status == "rejected" then
            rejected = C.TxnRegistry(p)[i]
        end
    end
    assertTrue(rejected ~= nil, "decision-order rejection row exists")
    local rejectAt = tonumber(rejected.decidedAt)
    local rejectSnap = C.ExportSnapshot(p, { omitEvents = true })

    clock = clock + 50
    assertTrue(select(1, V.ApplyDecision(p, "decision-order", "CoordB-Realm", {
        action = "correct", clusterId = clusterId, evidence = ev,
    }, {
        isAdmin = true,
        clearDurableRejection = function(evidence)
            C.ClearDurableRejection(p, evidence)
        end,
    })), "decision-order corrects later")
    local corrected = C.FindRegistryTxn(p, rejected.txnId)
    assertTrue(corrected ~= nil and corrected.status == "verified",
        "decision-order local correction is verified")
    assertTrue(tonumber(corrected.decidedAt) > (rejectAt or 0),
        "decision-order correction decidedAt is newer")

    -- Stale rejection snapshot must not win over newer correction.
    local peer = makeProfile("decision-order-peer", { admin, "CoordB-Realm" })
    assertTrue(select(1, C.ReplaceConfig(peer, C.ExportSnapshot(p, { omitEvents = true }))),
        "decision-order peer starts with correction")
    assertTrue(select(1, C.ReplaceConfig(peer, rejectSnap)),
        "decision-order older rejection snapshot merges")
    local afterStale = C.FindRegistryTxn(peer, rejected.txnId)
    assertEq(afterStale.status, "verified",
        "decision-order older rejection does not overwrite newer correction")

    -- Reverse merge order converges to the same verified decision.
    local peer2 = makeProfile("decision-order-peer2", { admin, "CoordB-Realm" })
    assertTrue(select(1, C.ReplaceConfig(peer2, rejectSnap)), "decision-order peer2 starts rejected")
    assertTrue(select(1, C.ReplaceConfig(peer2, C.ExportSnapshot(p, { omitEvents = true }))),
        "decision-order peer2 then merges correction")
    local afterFresh = C.FindRegistryTxn(peer2, rejected.txnId)
    assertEq(afterFresh.status, "verified",
        "decision-order newer correction wins regardless of merge order")
    assertEq(afterStale.status, afterFresh.status,
        "decision-order repeated sync converges on the same status")
    assertEq(tonumber(afterStale.decidedAt), tonumber(afterFresh.decidedAt),
        "decision-order repeated sync converges on the same decidedAt")
end

-- 13b. Same-signature deposits stay separate in durable pending witnesses
do
    V.ClearSessionClusters()
    local p = makeProfile("witness-separate")
    local depA = evidence({
        quantity = 9, occurrenceIndex = 1,
        neighborsOlder = { "sep-a1" }, neighborsNewer = { "sep-a2" },
        approxTxnTime = clock - 500,
    })
    local depB = evidence({
        quantity = 9, occurrenceIndex = 2,
        neighborsOlder = { "sep-b1" }, neighborsNewer = { "sep-b2" },
        approxTxnTime = clock - 40,
    })
    assertTrue(C.UpsertPendingWitness(p, depA, w1, { [w1] = clock }))
    assertTrue(C.UpsertPendingWitness(p, depB, w2, { [w2] = clock }))
    local pending = C.PendingWitnesses(p)
    assertEq(#pending, 2, "witness-separate keeps two same-signature aggregates")
    assertTrue(C.UpsertPendingWitness(p, depA, w3, { [w1] = clock, [w3] = clock }))
    pending = C.PendingWitnesses(p)
    assertEq(#pending, 2, "witness-separate third witness joins only matching aggregate")
    local aCount, bCount = 0, 0
    for i = 1, #pending do
        local n = 0
        for _ in pairs(pending[i].witnesses or {}) do n = n + 1 end
        if pending[i].evidence.occurrenceIndex == 1 then aCount = n end
        if pending[i].evidence.occurrenceIndex == 2 then bCount = n end
    end
    assertEq(aCount, 2, "witness-separate deposit A has two witnesses")
    assertEq(bCount, 1, "witness-separate deposit B stays at one witness")
end

-- 13c. Peer recovery must not wipe local pending witnesses or durable rejections
do
    V.ClearSessionClusters()
    local coord = makeProfile("peer-preserve-decisions", { admin, "PeerAdmin-Realm" })
    local ev = evidence({
        quantity = 4, neighborsOlder = { "pres-n" }, approxTxnTime = clock - 80,
    })
    assertTrue(C.UpsertPendingWitness(coord, ev, w1, { [w1] = clock }))
    assertTrue(C.UpsertPendingWitness(coord, ev, w2, { [w1] = clock, [w2] = clock }))
    assertEq(#C.PendingWitnesses(coord), 1, "peer-preserve starts with one aggregate")
    assertTrue(C.RecordDurableRejection(coord, ev, admin, "not a real deposit"))
    local localRejSeq = tonumber(coord._consumables.rejectionSeq) or 0
    local peer = makeProfile("peer-preserve-stale", { admin, "PeerAdmin-Realm" })
    -- Stale peer: empty witnesses/rejections but equal/higher rejectionSeq.
    peer._consumables.rejectionSeq = localRejSeq + 1
    peer._consumables.pendingWitnesses = {}
    peer._consumables.rejections = {}
    local stale = C.ExportSnapshot(peer)
    assertTrue(select(1, C.MergeSnapshot(coord, stale, { consumablesFromCoordinator = false })),
        "peer-preserve peer merge applies")
    assertEq(#C.PendingWitnesses(coord), 1,
        "peer-preserve forceReplace=false keeps local pending witnesses")
    local wcount = 0
    for _ in pairs(C.PendingWitnesses(coord)[1].witnesses or {}) do wcount = wcount + 1 end
    assertEq(wcount, 2, "peer-preserve keeps authenticated witness maps")
    assertTrue(V.IsRejected({ rejections = C.DurableRejections(coord) }, ev),
        "peer-preserve durable rejection survives peer recovery")
end

-- 13c1. Peer-asserted forged witnesses must not pad coordinator quorum
do
    V.ClearSessionClusters()
    local coord = makeProfile("peer-forge-quorum", { admin, "PeerAdmin-Realm" })
    local ev = evidence({
        quantity = 7, neighborsOlder = { "forge-n" }, approxTxnTime = clock - 70,
    })
    -- One authenticated local witness only; peer will try to invent the rest.
    assertTrue(C.UpsertPendingWitness(coord, ev, w1, { [w1] = clock }))
    assertEq(#C.PendingWitnesses(coord), 1, "peer-forge starts with one aggregate")
    local forgedPeer = makeProfile("peer-forge-source", { admin, "PeerAdmin-Realm" })
    forgedPeer._consumables.pendingWitnesses = {
        {
            evidence = {
                coreSignature = ev.coreSignature,
                approxTxnTime = ev.approxTxnTime,
                donor = ev.donor,
                itemId = ev.itemId,
                quantity = ev.quantity,
                guildGuid = ev.guildGuid,
                bankTab = ev.bankTab,
                generation = ev.generation,
                occurrenceIndex = ev.occurrenceIndex,
                neighborsOlder = ev.neighborsOlder,
                neighborsNewer = ev.neighborsNewer,
                type = "deposit",
            },
            witnesses = {
                [w1] = clock,
                ["ForgedTwo-Realm"] = clock,
                ["ForgedThree-Realm"] = clock,
            },
            updatedAt = clock,
        },
    }
    assertTrue(select(1, C.MergeSnapshot(coord, C.ExportSnapshot(forgedPeer), {
        consumablesFromCoordinator = false,
    })), "peer-forge peer merge applies")
    local wcount, sawForged = 0, false
    for name in pairs(C.PendingWitnesses(coord)[1].witnesses or {}) do
        wcount = wcount + 1
        if name == "ForgedTwo-Realm" or name == "ForgedThree-Realm" then
            sawForged = true
        end
    end
    assertEq(wcount, 1, "peer-forge does not import peer witness identities")
    assertFalse(sawForged, "peer-forge forged names stay out of durable maps")
    V.ClearSessionClusters()
    V.HydrateClustersFromDurable(coord, "peer-forge-quorum")
    local afterForge = V.IngestReport(coord, "peer-forge-quorum", w2, { ev }, {
        isAdmin = false,
        scope = O.EnsureScope(O.EnsureProfileStore({}, "peer-forge-quorum"), "club-1", 2),
        obsStore = O.EnsureProfileStore({}, "peer-forge-quorum"),
        historyComplete = true,
    })
    assertEq(afterForge.verified, 0,
        "peer-forge forged peer witnesses cannot pad three-witness quorum")
    assertEq(afterForge.pending, 1, "peer-forge stays pending with two real witnesses")
    assertEq(C.ContributionTotal(coord, donor, flask), 0,
        "peer-forge no auto-credit from peer-asserted quorum")
    local cluster = V.EnsureClusterStore("peer-forge-quorum").clusters[1]
    local realCount = 0
    for name in pairs((cluster and cluster.witnesses) or {}) do
        if name == w1 or name == w2 then realCount = realCount + 1 end
    end
    assertEq(realCount, 2, "peer-forge cluster holds only authenticated witnesses")
end

-- 13c2. Ambiguous cluster match must not adopt a recovered registry/ledger ID
do
    V.ClearSessionClusters()
    local p = makeProfile("ambig-adopt", { admin })
    local db = {}
    local store = O.EnsureProfileStore(db, "ambig-adopt")
    local scope = O.EnsureScope(store, "club-1", 2)
    local depA = evidence({
        quantity = 5, occurrenceIndex = 1,
        neighborsOlder = { "ambig-a" }, neighborsNewer = {},
        approxTxnTime = clock - 120,
    })
    local depB = evidence({
        quantity = 5, occurrenceIndex = 2,
        neighborsOlder = { "ambig-b" }, neighborsNewer = {},
        approxTxnTime = clock - 120,
    })
    assertEq(V.IngestReport(p, "ambig-adopt", w1, { depA }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "ambig-adopt seeds cluster A")
    assertEq(V.IngestReport(p, "ambig-adopt", w2, { depB }, {
        isAdmin = false, scope = scope, obsStore = store,
    }).pending, 1, "ambig-adopt seeds cluster B")
    assertEq(#V.EnsureClusterStore("ambig-adopt").clusters, 2, "ambig-adopt has two pending clusters")
    -- One recovered registry identity that matches the shared core signature.
    local txnId = "ctx:ambig-adopt:Admin-Realm:1:cafe"
    assertTrue(C.RegisterCanonicalTxn(p, {
        txnId = txnId, status = "verified", committed = true,
        donor = donor, itemId = flask, quantity = 5,
        coreSignature = depA.coreSignature,
        approxTxnTime = clock - 120,
        guildGuid = "club-1", bankTab = 2, generation = 1,
        decidedBy = admin, decidedAt = clock - 50,
        neighborsOlder = { "ambig-a" },
    }, { bumpSeq = false }))
    local report = evidence({
        quantity = 5,
        occurrenceIndex = false,
        neighborsOlder = { "ambig-a", "ambig-b" },
        neighborsNewer = {},
        approxTxnTime = clock - 120,
    })
    report.occurrenceIndex = nil
    local stats = V.IngestReport(p, "ambig-adopt", w3, { report }, {
        isAdmin = false, scope = scope, obsStore = store, historyComplete = true,
    })
    assertEq(stats.verified, 0, "ambig-adopt competing match does not auto-verify")
    local clusters = V.EnsureClusterStore("ambig-adopt").clusters
    local ambiguousCount, withTxn = 0, 0
    for i = 1, #clusters do
        if clusters[i].status == "ambiguous" then ambiguousCount = ambiguousCount + 1 end
        if V.ValidTxnId(clusters[i].txnId) then withTxn = withTxn + 1 end
    end
    assertTrue(ambiguousCount >= 1, "ambig-adopt keeps ambiguity for review")
    assertEq(withTxn, 0, "ambig-adopt does not attach recovered txnId to ambiguous cluster")
    assertEq(C.ContributionTotal(p, donor, flask), 0,
        "ambig-adopt no ledger credit from ambiguous adoption")
end

-- 13d. Pending cluster without txnId adopts recovered registry identity (no double credit)
do
    V.ClearSessionClusters()
    local tuesday = makeProfile("pending-adopt", { admin, "CoordB-Realm" })
    local db = {}
    local store = O.EnsureProfileStore(db, "pending-adopt")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({
        quantity = 14, neighborsOlder = { "adopt-n" }, approxTxnTime = clock - 300,
    })
    assertEq(V.IngestReport(tuesday, "pending-adopt", admin, { ev }, {
        isAdmin = true, scope = scope, obsStore = store,
    }).verified, 1, "pending-adopt Tuesday verifies")
    local txnId = V.ListVerifiedClusters("pending-adopt")[1].txnId
    assertTrue(V.CommitVerifiedCluster(tuesday, V.ListVerifiedClusters("pending-adopt")[1], admin))
    local rich = C.ExportSnapshot(tuesday)

    V.ClearSessionClusters()
    local late = makeProfile("pending-adopt-b", { admin, "CoordB-Realm" })
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "pending-adopt-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local held = V.IngestReport(late, "pending-adopt-b", w1, { ev }, {
        isAdmin = false, scope = scopeB, obsStore = storeB, historyComplete = false,
    })
    assertEq(held.pending, 1, "pending-adopt B holds pending cluster before recovery")
    local pendingCluster = V.EnsureClusterStore("pending-adopt-b").clusters[1]
    assertTrue(pendingCluster and not V.ValidTxnId(pendingCluster.txnId),
        "pending-adopt held cluster has no txnId yet")
    assertTrue(select(1, C.MergeSnapshot(late, rich, { consumablesFromCoordinator = true })),
        "pending-adopt recovers Tuesday registry+ledger")
    assertEq(C.ContributionTotal(late, donor, flask), 14, "pending-adopt credit once after recovery")
    local after = V.IngestReport(late, "pending-adopt-b", admin, { ev }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    })
    assertEq(after.verified, 0, "pending-adopt admin rematch does not re-verify")
    assertEq(C.ContributionTotal(late, donor, flask), 14, "pending-adopt no duplicate credit")
    local how, entry = V.ReconcileAgainstRegistry(late, ev)
    assertEq(how, "verified", "pending-adopt rematch hits registry")
    assertEq(entry.txnId, txnId, "pending-adopt reuses original txnId")
end

-- 13e. Config fingerprint ignores merge order and local txnAllocSeq drift
do
    local a = makeProfile("fp-order-a")
    local b = makeProfile("fp-order-b")
    C.RegisterCanonicalTxn(a, {
        txnId = "ctx:fp:a:1:1", status = "verified", committed = true,
        donor = donor, itemId = flask, quantity = 1, decidedBy = admin, decidedAt = clock,
    }, { bumpSeq = false })
    C.RegisterCanonicalTxn(a, {
        txnId = "ctx:fp:a:2:2", status = "rejected", committed = false,
        donor = donor, itemId = flask, quantity = 2, decidedBy = admin, decidedAt = clock,
    }, { bumpSeq = false })
    C.RegisterCanonicalTxn(b, {
        txnId = "ctx:fp:a:2:2", status = "rejected", committed = false,
        donor = donor, itemId = flask, quantity = 2, decidedBy = admin, decidedAt = clock,
    }, { bumpSeq = false })
    C.RegisterCanonicalTxn(b, {
        txnId = "ctx:fp:a:1:1", status = "verified", committed = true,
        donor = donor, itemId = flask, quantity = 1, decidedBy = admin, decidedAt = clock,
    }, { bumpSeq = false })
    a._consumables.txnAllocSeq = 1
    b._consumables.txnAllocSeq = 99
    local da, db = C.Descriptor(a), C.Descriptor(b)
    assertEq(da.configFingerprint, db.configFingerprint,
        "fp-order registry merge order does not change config fingerprint")
    assertFalse(S.CoordinatorConfigDiffers(da, db),
        "fp-order unequal txnAllocSeq alone is not config drift")
end

-- 13. Untrusted fabricated peer snapshot events cannot mint verified credits
do
    V.ClearSessionClusters()
    local victim = makeProfile("untrusted-inject", { admin })
    local fakeTxn = "ctx:untrusted-inject:Evil-Realm:1:deadbeef"
    -- Registry-only fabrication (no stamped ledger event) must not register.
    local registryOnly = {
        generation = 1,
        configSeq = 1,
        ledgerSeq = 1,
        eventSeq = 1,
        txnAllocSeq = 1,
        txnRegistry = {
            {
                txnId = fakeTxn,
                status = "verified",
                committed = true,
                donor = donor,
                itemId = flask,
                quantity = 99,
                coreSignature = O.CoreSignature("deposit", donor, flask, 99),
                approxTxnTime = clock - 10,
                decidedBy = "Evil-Realm",
                decidedAt = clock,
                verification = "witnesses",
            },
        },
        events = {},
    }
    assertTrue(select(1, C.MergeSnapshot(victim, registryOnly, { consumablesFromCoordinator = false })),
        "untrusted-inject peer merge does not error")
    assertEq(C.ContributionTotal(victim, donor, flask), 0,
        "untrusted-inject registry-only fabrication does not credit the ledger")
    assertTrue(C.FindRegistryTxn(victim, fakeTxn) == nil,
        "untrusted-inject fabricated registry row without ledger is not accepted")
    -- Event missing Spectrum txnId is rejected even with a RelayWriter binding.
    local noTxn = {
        generation = 1,
        configSeq = 1,
        events = {
            {
                id = "ce:remote:Evil-Realm:2",
                type = C.EVENT.DONATION,
                source = "guildbank",
                actor = donor,
                itemId = flask,
                quantity = 7,
                generation = 1,
                timestamp = clock,
                order = 1,
                writer = "Evil-Realm",
            },
        },
    }
    assertTrue(select(1, C.MergeSnapshot(victim, noTxn, { consumablesFromCoordinator = false })),
        "untrusted-inject no-txnId peer merge applies")
    assertEq(C.ContributionTotal(victim, donor, flask), 0,
        "untrusted-inject donation without txnId does not credit")
    -- Explicit forged relay claiming an admin writer but id owned by attacker.
    local forged = {
        id = "ce:remote:Evil-Realm:9",
        type = C.EVENT.DONATION,
        source = "guildbank",
        actor = donor,
        itemId = flask,
        quantity = 5,
        generation = 1,
        timestamp = clock,
        txnId = "ctx:untrusted-inject:Evil-Realm:9:cafe",
        order = 2,
        writer = admin,
    }
    assertFalse(select(1, S.ApplyRemoteEvent(victim, forged, nil, { coordinatorRelay = true })),
        "untrusted-inject forged admin-writer claim is rejected when id is not admin-owned")
    assertEq(C.ContributionTotal(victim, donor, flask), 0,
        "untrusted-inject forged relay leaves ledger empty")
end

-- 14. Three-witness credits survive writer-offline peer recovery
do
    V.ClearSessionClusters()
    local coordA = makeProfile("witness-peer-a", { admin, "CoordB-Realm" })
    local db = {}
    local store = O.EnsureProfileStore(db, "witness-peer-a")
    local scope = O.EnsureScope(store, "club-1", 2)
    local ev = evidence({
        quantity = 8, neighborsOlder = { "wit-peer" }, approxTxnTime = clock - 180,
    })
    assertEq(V.IngestReport(coordA, "witness-peer-a", w1, { ev }, {
        isAdmin = false, scope = scope, obsStore = store, historyComplete = true,
    }).pending, 1, "witness-peer seeds with first witness")
    assertEq(V.IngestReport(coordA, "witness-peer-a", w2, { ev }, {
        isAdmin = false, scope = scope, obsStore = store, historyComplete = true,
    }).pending, 1, "witness-peer second witness still pending")
    assertEq(V.IngestReport(coordA, "witness-peer-a", w3, { ev }, {
        isAdmin = false, scope = scope, obsStore = store, historyComplete = true,
    }).verified, 1, "witness-peer third witness verifies")
    local cluster = V.ListVerifiedClusters("witness-peer-a")[1]
    assertTrue(cluster and cluster.verification == V.VERIFICATION.WITNESSES,
        "witness-peer verification mode is witnesses")
    -- Commit under the last witness writer (pre-stamp-admin behavior) to prove
    -- peer recovery admits ValidTxnId RelayWriter donations, not only admins.
    assertTrue(V.CommitVerifiedCluster(coordA, cluster, w3), "witness-peer commits under witness writer")
    local txnId = cluster.txnId
    assertEq(C.ContributionTotal(coordA, donor, flask), 8, "witness-peer A has credit")
    assertTrue(C.FindRegistryTxn(coordA, txnId) ~= nil, "witness-peer A has registry row")
    local peer = makeProfile("witness-peer-holder", { admin, "CoordB-Realm" })
    assertTrue(select(1, C.MergeSnapshot(peer, C.ExportSnapshot(coordA), {
        consumablesFromCoordinator = true,
    })), "witness-peer holder absorbs coordinator snapshot")
    assertEq(C.ContributionTotal(peer, donor, flask), 8, "witness-peer holder has credit")
    local late = makeProfile("witness-peer-late", { admin, "CoordB-Realm" })
    assertEq(C.ContributionTotal(late, donor, flask), 0, "witness-peer late starts empty")
    assertTrue(select(1, C.MergeSnapshot(late, C.ExportSnapshot(peer), {
        consumablesFromCoordinator = false,
    })), "witness-peer late recovers via peer path")
    assertEq(C.ContributionTotal(late, donor, flask), 8,
        "witness-peer late recovers three-witness ledger credit")
    assertTrue(C.FindRegistryTxn(late, txnId) ~= nil,
        "witness-peer late recovers original registry txnId")
    assertTrue(C.HasTxnId(late, txnId), "witness-peer late HasTxnId for recovered credit")
end

-- 15. Manual approve during history hold cannot mint a duplicate credit
do
    V.ClearSessionClusters()
    local coordA = makeProfile("approve-hold-a", { admin, "CoordB-Realm" })
    local dbA = {}
    local storeA = O.EnsureProfileStore(dbA, "approve-hold-a")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local tuesday = evidence({
        quantity = 17, neighborsOlder = { "apr-hold" }, approxTxnTime = clock - 400,
    })
    assertEq(V.IngestReport(coordA, "approve-hold-a", admin, { tuesday }, {
        isAdmin = true, scope = scopeA, obsStore = storeA, historyComplete = true,
    }).verified, 1, "approve-hold A verifies Tuesday")
    local txnA = V.ListVerifiedClusters("approve-hold-a")[1].txnId
    assertTrue(V.CommitVerifiedCluster(coordA, V.ListVerifiedClusters("approve-hold-a")[1], admin))
    local rich = C.ExportSnapshot(coordA)

    V.ClearSessionClusters()
    local coordB = makeProfile("approve-hold-b", { admin, "CoordB-Realm" })
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "approve-hold-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local held = V.IngestReport(coordB, "approve-hold-b", "CoordB-Realm", { tuesday }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = false,
    })
    assertEq(held.verified, 0, "approve-hold B holds auto-verify")
    assertEq(held.pending, 1, "approve-hold B keeps pending cluster")
    local pending = V.EnsureClusterStore("approve-hold-b").clusters[1]
    assertTrue(pending and not V.ValidTxnId(pending.txnId), "approve-hold pending has no txnId")
    local ok, status = V.ApplyDecision(coordB, "approve-hold-b", "CoordB-Realm", {
        action = "approve", clusterId = pending.clusterId,
    }, {
        isAdmin = true, scope = scopeB, historyComplete = false,
    })
    assertFalse(ok, "approve-hold manual approve refused while history incomplete")
    assertEq(status, "history_incomplete", "approve-hold reports history_incomplete")
    assertEq(C.ContributionTotal(coordB, donor, flask), 0, "approve-hold no credit from blocked approve")
    assertTrue(select(1, C.MergeSnapshot(coordB, rich, { consumablesFromCoordinator = true })),
        "approve-hold B absorbs original Tuesday history")
    assertEq(C.ContributionTotal(coordB, donor, flask), 17, "approve-hold credits once after absorb")
    assertTrue(C.FindRegistryTxn(coordB, txnA) ~= nil, "approve-hold keeps original txnId")
    -- After absorb, approve may adopt recovered identity (no second mint).
    V.ClearSessionClusters()
    local rematch = V.IngestReport(coordB, "approve-hold-b", "CoordB-Realm", { tuesday }, {
        isAdmin = true, scope = scopeB, obsStore = storeB, historyComplete = true,
    })
    assertEq(rematch.verified, 0, "approve-hold rematch does not re-verify")
    assertEq(C.ContributionTotal(coordB, donor, flask), 17, "approve-hold no duplicate after rematch")
end

-- 16. Pre-advertisement window: production gate holds until baseline/peer history
do
    V.ClearSessionClusters()
    local coordA = makeProfile("pre-adv-a", { admin, "CoordB-Realm" })
    local dbA = {}
    local storeA = O.EnsureProfileStore(dbA, "pre-adv-a")
    local scopeA = O.EnsureScope(storeA, "club-1", 2)
    local tuesday = evidence({
        quantity = 11, neighborsOlder = { "pre-adv" }, approxTxnTime = clock - 500,
    })
    assertEq(V.IngestReport(coordA, "pre-adv-a", admin, { tuesday }, {
        isAdmin = true, scope = scopeA, obsStore = storeA, historyComplete = true,
    }).verified, 1, "pre-adv A verifies Tuesday")
    local txnA = V.ListVerifiedClusters("pre-adv-a")[1].txnId
    assertTrue(V.CommitVerifiedCluster(coordA, V.ListVerifiedClusters("pre-adv-a")[1], admin))
    local rich = C.ExportSnapshot(coordA)

    V.ClearSessionClusters()
    local coordB = makeProfile("pre-adv-b", { admin, "CoordB-Realm" })
    -- Simulate newly elected coordinator before any HAVE_PROFILE: baseline unconfirmed.
    coordB._consumablesHistoryBaselineAt = clock - 10
    coordB._consumablesHistoryUnconfirmedAt = clock - 10
    local dbB = {}
    local storeB = O.EnsureProfileStore(dbB, "pre-adv-b")
    local scopeB = O.EnsureScope(storeB, "club-1", 2)
    local held = V.IngestReport(coordB, "pre-adv-b", "CoordB-Realm", { tuesday }, {
        isAdmin = true, scope = scopeB, obsStore = storeB,
        historyComplete = false,
        historyBaselineAt = coordB._consumablesHistoryBaselineAt,
    })
    assertEq(held.verified, 0, "pre-adv B does not mint before peer advertisement")
    assertEq(C.ContributionTotal(coordB, donor, flask), 0, "pre-adv B no premature credit")
    -- Clearly-new deposit at/after baseline may still verify.
    local fresh = evidence({
        quantity = 2, neighborsOlder = { "pre-adv-new" },
        approxTxnTime = clock, occurrenceIndex = 1,
        coreSignature = O.CoreSignature("deposit", donor, flask, 2),
    })
    assertEq(V.IngestReport(coordB, "pre-adv-b", "CoordB-Realm", { fresh }, {
        isAdmin = true, scope = scopeB, obsStore = storeB,
        historyComplete = false,
        historyBaselineAt = coordB._consumablesHistoryBaselineAt,
    }).verified, 1, "pre-adv clearly-new deposit still verifies during baseline")
    local freshCluster = V.ListVerifiedClusters("pre-adv-b")[1]
    assertTrue(V.CommitVerifiedCluster(coordB, freshCluster, "CoordB-Realm"))
    assertEq(C.ContributionTotal(coordB, donor, flask), 2, "pre-adv clearly-new credits once")
    -- Later absorb of Tuesday history converges without duplicating Tuesday.
    assertTrue(select(1, C.MergeSnapshot(coordB, rich, { consumablesFromCoordinator = false })),
        "pre-adv B absorbs Tuesday from peer")
    assertTrue(C.FindRegistryTxn(coordB, txnA) ~= nil, "pre-adv recovered Tuesday txnId")
    assertEq(C.ContributionTotal(coordB, donor, flask), 13,
        "pre-adv Tuesday + clearly-new credits without duplicate Tuesday")
end

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))

