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
    assertEq(V.ListVerifiedClusters("stable-txn")[1].txnId, txnId, "txnId stays evidence-stable")
    assertEq(C.ContributionTotal(p, donor, flask), 15, "no double credit after rematch")
    local idA = V.TxnIdFromEvidence("stable-txn", ev)
    local idB = V.TxnIdFromEvidence("stable-txn", ev)
    assertEq(idA, idB, "TxnIdFromEvidence is deterministic")
    assertEq(idA, txnId, "committed txnId matches evidence-derived identity")
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
-- CollectUnresolvedForSubmit paginates beyond MAX_OBS_BATCH
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
            coreSignature = O.CoreSignature("deposit", donor, flask, 1) .. ":" .. i,
            approxTxnTime = clock - i,
        })
    end
    local batch1, next1, total = V.CollectUnresolvedForSubmit(store, "club-1", 2, { offset = 0 })
    assertEq(#batch1, V.MAX_OBS_BATCH, "first page is MAX_OBS_BATCH")
    assertEq(total, V.MAX_OBS_BATCH + 5, "total unresolved count includes later rows")
    assertTrue(next1 > 0, "next offset advances when more remain")
    local batch2, next2 = V.CollectUnresolvedForSubmit(store, "club-1", 2, { offset = next1 })
    assertEq(#batch2, 5, "second page drains remaining observations")
    assertEq(next2, 0, "offset wraps to 0 after the final page")
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

if failures > 0 then
    io.stderr:write(string.format("%d failed, %d passed\n", failures, passes))
    os.exit(1)
end
io.stdout:write(string.format("%d passed, 0 failed\n", passes))
