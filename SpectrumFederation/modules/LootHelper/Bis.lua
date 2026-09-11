-- Item-aware BiS reconstruction. Derived only; logs remain authoritative.
-- luacheck: globals GetItemInfoInstant GetSpecialization GetSpecializationInfo GetInspectSpecialization
-- luacheck: globals UnitGUID UnitExists UnitName IsInRaid GetNumGroupMembers

local addonName, SF = ...

SF.LootHelperBis = SF.LootHelperBis or {}
local Bis = SF.LootHelperBis

Bis.OUTCOME = {
    NOT_BIS = "NOT_BIS",
    ASSIGNED = "ASSIGNED",
    OVERFLOW = "OVERFLOW",
    UNRESOLVED = "UNRESOLVED",
}

Bis.BINDING = {
    PACKABLE = "PACKABLE",
    BOUND = "BOUND",
}

Bis.OVERRIDE_ACTION = {
    ASSIGN = "ASSIGN",
    CLEAR = "CLEAR",
    REPLACE = "REPLACE",
    ASSOCIATE_LEGACY = "ASSOCIATE_LEGACY",
}

Bis.SLOTS = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Bracers",
    "Hands", "Belt", "Pants", "Boots",
    "Ring1", "Ring2", "Trinket1", "Trinket2",
    "Weapon", "OffHand",
}

local RING_INDEX = { Ring1 = 1, Ring2 = 2 }
local TRINKET_INDEX = { Trinket1 = 1, Trinket2 = 2 }
local RING_SLOTS = { "Ring1", "Ring2" }
local TRINKET_SLOTS = { "Trinket1", "Trinket2" }

local EQUIP_TO_SLOT = {
    INVTYPE_HEAD = "Head",
    INVTYPE_NECK = "Neck",
    INVTYPE_SHOULDER = "Shoulder",
    INVTYPE_CLOAK = "Back",
    INVTYPE_CHEST = "Chest",
    INVTYPE_ROBE = "Chest",
    INVTYPE_WRIST = "Bracers",
    INVTYPE_HAND = "Hands",
    INVTYPE_WAIST = "Belt",
    INVTYPE_LEGS = "Pants",
    INVTYPE_FEET = "Boots",
    INVTYPE_FINGER = "ring",
    INVTYPE_TRINKET = "trinket",
    INVTYPE_WEAPON = "weapon",
    INVTYPE_WEAPONMAINHAND = "weapon",
    INVTYPE_2HWEAPON = "weapon",
    INVTYPE_RANGED = "weapon",
    INVTYPE_RANGEDRIGHT = "weapon",
    INVTYPE_WEAPONOFFHAND = "offhand",
    INVTYPE_SHIELD = "offhand",
    INVTYPE_HOLDABLE = "offhand",
}

local VALID_SLOT = {}
for i = 1, #Bis.SLOTS do
    VALID_SLOT[Bis.SLOTS[i]] = true
end

local function EventTypes()
    return SF.LootLogEventTypes or {}
end

local function ArmorActions()
    return SF.LootLogArmorActions or { USED = "USED", AVAILABLE = "AVAILABLE" }
end

local function NormalizeId(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(id) or id
    end
    return id
end

local function SamePlayer(a, b)
    a = NormalizeId(a)
    b = NormalizeId(b)
    if not a or not b then
        return false
    end
    if SF.NameUtil and SF.NameUtil.SamePlayer then
        return SF.NameUtil.SamePlayer(a, b)
    end
    return a == b
end

local function GetLogType(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetEventType then
        return log:GetEventType()
    end
    return log._eventType
end

local function GetLogData(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetEventData then
        return log:GetEventData()
    end
    return log._data
end

local function GetLogId(log)
    if type(log) ~= "table" then
        return nil
    end
    if log.GetID then
        return log:GetID()
    end
    return log._id
end

local function SortedCopy(ids)
    local out = {}
    local seen = {}
    if type(ids) ~= "table" then
        return out
    end
    for _, id in ipairs(ids) do
        local norm = NormalizeId(id)
        if norm and not seen[norm] then
            seen[norm] = true
            out[#out + 1] = norm
        end
    end
    table.sort(out)
    return out
end

local function ScopeKey(members)
    local sorted = SortedCopy(members)
    if #sorted == 0 then
        return ""
    end
    return table.concat(sorted, "\0")
end

local function ListSet(list)
    local set = {}
    for i = 1, #(list or {}) do
        set[list[i]] = true
    end
    return set
end

local function ScopeFullyPresent(scopeMembers, componentSet)
    if type(scopeMembers) ~= "table" or #scopeMembers == 0 then
        return false
    end
    for i = 1, #scopeMembers do
        if not componentSet[scopeMembers[i]] then
            return false
        end
    end
    return true
end

function Bis.AwardRefKey(kind, id)
    if type(kind) ~= "string" or type(id) ~= "string" or id == "" then
        return nil
    end
    return kind .. ":" .. id
end

function Bis.ParseAwardRef(ref)
    if type(ref) ~= "table" then
        return nil
    end
    if type(ref.kind) ~= "string" or type(ref.id) ~= "string" or ref.id == "" then
        return nil
    end
    return { kind = ref.kind, id = ref.id }
end

function Bis.ClassifyItem(itemLinkOrString)
    if itemLinkOrString == nil then
        return nil
    end
    local equipLoc, classId, subClassId
    if GetItemInfoInstant then
        local ok, _, _, _, loc, _, class, sub = pcall(GetItemInfoInstant, itemLinkOrString)
        if ok then
            equipLoc = loc
            classId = class
            subClassId = sub
        end
    end
    if type(equipLoc) ~= "string" or equipLoc == "" then
        return nil
    end
    local mapped = EQUIP_TO_SLOT[equipLoc]
    if not mapped then
        return nil
    end
    local family = mapped
    if mapped ~= "ring" and mapped ~= "trinket" and mapped ~= "weapon" and mapped ~= "offhand" then
        family = "ordinary"
    end
    return {
        equipLoc = equipLoc,
        family = family,
        slot = (family == "ordinary") and mapped or nil,
        itemClass = classId,
        itemSubClass = subClassId,
        isTwoHand = equipLoc == "INVTYPE_2HWEAPON",
        isOffHandLoc = mapped == "offhand",
        isWeaponLoc = mapped == "weapon",
    }
end

function Bis.FamilyForSlot(slot)
    if RING_INDEX[slot] then
        return "ring", RING_INDEX[slot]
    end
    if TRINKET_INDEX[slot] then
        return "trinket", TRINKET_INDEX[slot]
    end
    if slot == "Weapon" or slot == "OffHand" then
        return "weapon", slot
    end
    if VALID_SLOT[slot] then
        return "ordinary", slot
    end
    return nil, nil
end

function Bis.SlotsValid(slots)
    if type(slots) ~= "table" or #slots == 0 then
        return false
    end
    local seen = {}
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) ~= "string" or not VALID_SLOT[slot] or seen[slot] then
            return false
        end
        seen[slot] = true
    end
    return true
end

local function CopySlots(slots)
    local out = {}
    for i = 1, #(slots or {}) do
        out[i] = slots[i]
    end
    return out
end

function Bis.NewState()
    return {
        specs = {},
        awards = {},
        outcomeWinner = {},
        assignments = {},
        activeByAward = {},
        associationByOrigin = {},
        reversedManual = {},
        contributingOrigins = {},
        frozenOverflow = {},
        rank = {},
    }
end

local function AwardKeyFromRef(ref)
    if not ref then
        return nil
    end
    return Bis.AwardRefKey(ref.kind, ref.id)
end

local function IsManualReversed(state, awardRef)
    if not awardRef or awardRef.kind ~= "MANUAL" then
        return false
    end
    return state.reversedManual[awardRef.id] == true
end

local function DeactivateAssignment(state, assignmentId)
    if not assignmentId then
        return
    end
    local asg = state.assignments[assignmentId]
    if not asg or asg.active ~= true then
        return
    end
    asg.active = false
    local key = AwardKeyFromRef(asg.awardRef)
    if key and state.activeByAward[key] == assignmentId then
        state.activeByAward[key] = nil
    end
    if asg.legacyOriginLogId and state.associationByOrigin[asg.legacyOriginLogId] == assignmentId then
        state.associationByOrigin[asg.legacyOriginLogId] = nil
    end
end

function Bis.WeaponAssignSlots(classif, specId, occupancy)
    occupancy = occupancy or {}
    if not classif or not classif.isWeaponLoc and not classif.isOffHandLoc then
        return nil, "UNKNOWN_SLOT"
    end
    specId = tonumber(specId)
    local flags = specId and SF.LootHelperBis.SpecWeapons and SF.LootHelperBis.SpecWeapons.GetFlags(specId)
    if not specId or not flags then
        return nil, specId and "UNKNOWN_COMPAT" or "MISSING_SPEC"
    end
    local weaponFree = occupancy.Weapon ~= true
    local offFree = occupancy.OffHand ~= true

    if classif.isOffHandLoc then
        local loc = classif.equipLoc
        local allowed = false
        if loc == "INVTYPE_SHIELD" then
            allowed = flags.offHandShield == true
        elseif loc == "INVTYPE_HOLDABLE" then
            allowed = flags.offHandHoldable == true
        elseif loc == "INVTYPE_WEAPONOFFHAND" or loc == "INVTYPE_WEAPON" then
            allowed = flags.offHandWeapon == true
        end
        if not allowed then
            return nil, "UNKNOWN_COMPAT"
        end
        if not offFree then
            return {}, nil
        end
        return { "OffHand" }, nil
    end

    if classif.isTwoHand then
        if flags.canDualWield2H then
            if weaponFree then
                return { "Weapon" }, nil
            end
            if offFree then
                return { "OffHand" }, nil
            end
            return {}, nil
        end
        if weaponFree and offFree then
            return { "Weapon", "OffHand" }, nil
        end
        return {}, nil
    end

    -- 1H / MH
    if weaponFree then
        return { "Weapon" }, nil
    end
    if flags.canDualWield1H and offFree then
        return { "OffHand" }, nil
    end
    return {}, nil
end

-- Gear Override may pick Weapon or OffHand for a 2H. Non-dual specs occupy
-- both opportunities with one assignment; dual-2H specs keep the requested slot.
function Bis.NormalizeOverrideSlots(assignedSlots, itemLinkOrString, specId)
    local slots = CopySlots(assignedSlots)
    if not Bis.SlotsValid(slots) then
        return slots
    end
    local classif = Bis.ClassifyItem(itemLinkOrString)
    if not classif or not classif.isTwoHand then
        return slots
    end
    local flags = specId and SF.LootHelperBis.SpecWeapons and SF.LootHelperBis.SpecWeapons.GetFlags(specId)
    if flags and flags.canDualWield2H then
        return slots
    end
    if #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand") then
        return { "Weapon", "OffHand" }
    end
    return slots
end

function Bis.NextPackableSlot(family, occupancy)
    occupancy = occupancy or {}
    local names = family == "ring" and RING_SLOTS or TRINKET_SLOTS
    for i = 1, #names do
        if occupancy[names[i]] ~= true then
            return names[i]
        end
    end
    return nil
end

function Bis.LiveOccupancyFromProjection(result, memberId)
    local occ = {}
    if type(result) ~= "table" or not memberId then
        return occ
    end
    local bis = result.bis
    local slots = bis and bis.slotsByMember and bis.slotsByMember[memberId]
    if type(slots) ~= "table" then
        local armor = result.armor and result.armor[memberId]
        if type(armor) == "table" then
            for slot, used in pairs(armor) do
                if used then
                    occ[slot] = true
                end
            end
        end
        return occ
    end
    for slot, cell in pairs(slots) do
        if type(cell) == "table" and cell.state and cell.state ~= "AVAILABLE" then
            occ[slot] = true
        end
    end
    return occ
end

local function OriginActive(state, originLogId)
    local rec = originLogId and state.contributingOrigins[originLogId]
    return rec and rec.active == true
end

local function RegisterOrigin(state, log, data, kind)
    local id = GetLogId(log)
    if type(id) ~= "string" then
        return
    end
    local member = NormalizeId(data.member)
    local slot = data.slot
    state.contributingOrigins[id] = {
        active = true,
        kind = kind,
        member = member,
        slot = slot,
        identityMembers = data.identityMembers,
        log = log,
        expired = false,
    }
end

local function ClearLocalOrigin(state, memberId, slot)
    for originId, rec in pairs(state.contributingOrigins) do
        if rec.kind == "local" and rec.member == memberId and rec.slot == slot then
            rec.active = false
        end
    end
end

local function MarkIdentityOriginExpired(state, originLogId)
    local rec = state.contributingOrigins[originLogId]
    if rec then
        rec.active = false
        rec.expired = true
    end
end

function Bis.ExpireSplitOrigins(state, isUnified)
    if type(state) ~= "table" or type(isUnified) ~= "function" then
        return
    end
    for originId, rec in pairs(state.contributingOrigins) do
        if rec.kind == "identity" and not rec.expired then
            if not isUnified(rec.identityMembers) then
                rec.active = false
                rec.expired = true
            end
        end
    end
end

local function NewFamilyBoard()
    return { cells = { nil, nil }, overflow = {} }
end

local function AssignmentCausal(a, b)
    local ra = (a and a.rank) or 0
    local rb = (b and b.rank) or 0
    if ra ~= rb then
        return ra < rb
    end
    return tostring(a and a.id or "") < tostring(b and b.id or "")
end

local function PlaceBoundOnBoard(board, assignment, index)
    if index ~= 1 and index ~= 2 then
        board.overflow[#board.overflow + 1] = assignment
        return
    end
    if board.cells[index] == nil then
        board.cells[index] = assignment
        return
    end
    assignment._pending = true
end

local function PackPending(board, pending)
    table.sort(pending, AssignmentCausal)
    for i = 1, #pending do
        local asg = pending[i]
        if board.cells[1] == nil then
            board.cells[1] = asg
        elseif board.cells[2] == nil then
            board.cells[2] = asg
        else
            board.overflow[#board.overflow + 1] = asg
        end
    end
end

local function ProjectScopeFamily(assignments, family)
    local board = NewFamilyBoard()
    local pending = {}
    local names = family == "ring" and RING_SLOTS or TRINKET_SLOTS
    local indexOf = family == "ring" and RING_INDEX or TRINKET_INDEX
    table.sort(assignments, AssignmentCausal)
    for i = 1, #assignments do
        local asg = assignments[i]
        if asg.slotBinding == Bis.BINDING.BOUND then
            local idx
            for s = 1, #asg.assignedSlots do
                local slot = asg.assignedSlots[s]
                if indexOf[slot] then
                    idx = indexOf[slot]
                    break
                end
            end
            if idx and board.cells[idx] == nil then
                board.cells[idx] = asg
            else
                pending[#pending + 1] = asg
            end
        else
            pending[#pending + 1] = asg
        end
    end
    PackPending(board, pending)
    board.slotNames = names
    return board
end

local function MergeFamilyBoards(dst, src)
    local pending = {}
    local srcCells = {}
    if src.cells[1] then
        srcCells[#srcCells + 1] = { index = 1, asg = src.cells[1] }
    end
    if src.cells[2] then
        srcCells[#srcCells + 1] = { index = 2, asg = src.cells[2] }
    end
    table.sort(srcCells, function(a, b)
        return AssignmentCausal(a.asg, b.asg)
    end)
    for i = 1, #srcCells do
        local index = srcCells[i].index
        local asg = srcCells[i].asg
        if dst.cells[index] == nil then
            dst.cells[index] = asg
        else
            pending[#pending + 1] = asg
        end
    end
    for i = 1, #(src.overflow or {}) do
        pending[#pending + 1] = src.overflow[i]
    end
    PackPending(dst, pending)
end

local function ProjectOrdinarySlot(assignments)
    table.sort(assignments, AssignmentCausal)
    local occupant = assignments[1]
    local overflow = {}
    for i = 2, #assignments do
        overflow[#overflow + 1] = assignments[i]
    end
    return occupant, overflow
end

function Bis.ProjectComponent(state, memberIds)
    memberIds = SortedCopy(memberIds)
    local componentSet = ListSet(memberIds)
    local slots = {}
    for i = 1, #Bis.SLOTS do
        slots[Bis.SLOTS[i]] = { state = "AVAILABLE" }
    end
    local pool = {}
    local unassigned = {}
    local mergeOverflow = {}

    local function ownerInComponent(owner)
        return owner and componentSet[owner] == true
    end

    for _, award in pairs(state.awards) do
        if ownerInComponent(award.member) and not award.reversed then
            pool[#pool + 1] = award
        end
    end
    table.sort(pool, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)

    local grouped = {}
    local groupOrder = {}
    for _, asg in pairs(state.assignments) do
        if asg.active and ownerInComponent(asg.awardOwner) then
            local include = true
            if asg.legacyOriginLogId then
                if not OriginActive(state, asg.legacyOriginLogId) then
                    include = false
                else
                    local rec = state.contributingOrigins[asg.legacyOriginLogId]
                    if rec and rec.expired then
                        include = false
                    end
                end
            end
            if include then
                local native = ScopeFullyPresent(asg.assignmentScopeMembers, componentSet)
                local key
                if native then
                    key = ScopeKey(asg.assignmentScopeMembers)
                else
                    key = "__owner:" .. tostring(asg.awardOwner)
                end
                grouped[key] = grouped[key] or { assignments = {}, earliest = asg.rank or 0, degenerate = not native }
                grouped[key].assignments[#grouped[key].assignments + 1] = asg
                if asg.rank and asg.rank < grouped[key].earliest then
                    grouped[key].earliest = asg.rank
                end
            end
        end
    end
    for key, group in pairs(grouped) do
        groupOrder[#groupOrder + 1] = key
        group.key = key
    end
    table.sort(groupOrder, function(a, b)
        local ga, gb = grouped[a], grouped[b]
        if ga.earliest ~= gb.earliest then
            return ga.earliest < gb.earliest
        end
        return tostring(a) < tostring(b)
    end)

    local ringMerged = NewFamilyBoard()
    local trinketMerged = NewFamilyBoard()
    local ordinaryOccupants = {}
    local ordinaryOverflow = {}
    local weaponOccupants = {}
    local weaponOverflow = {}

    for gi = 1, #groupOrder do
        local group = grouped[groupOrder[gi]]
        local byFamily = { ring = {}, trinket = {}, ordinary = {}, weapon = {} }
        for i = 1, #group.assignments do
            local asg = group.assignments[i]
            local family = asg.family
            if family == "ring" then
                byFamily.ring[#byFamily.ring + 1] = asg
            elseif family == "trinket" then
                byFamily.trinket[#byFamily.trinket + 1] = asg
            elseif family == "weapon" then
                byFamily.weapon[#byFamily.weapon + 1] = asg
            else
                byFamily.ordinary[#byFamily.ordinary + 1] = asg
            end
        end
        MergeFamilyBoards(ringMerged, ProjectScopeFamily(byFamily.ring, "ring"))
        MergeFamilyBoards(trinketMerged, ProjectScopeFamily(byFamily.trinket, "trinket"))
        for i = 1, #byFamily.ordinary do
            local asg = byFamily.ordinary[i]
            local slot = asg.assignedSlots[1]
            if slot then
                ordinaryOccupants[slot] = ordinaryOccupants[slot] or {}
                ordinaryOccupants[slot][#ordinaryOccupants[slot] + 1] = asg
            end
        end
        for i = 1, #byFamily.weapon do
            local asg = byFamily.weapon[i]
            weaponOccupants[#weaponOccupants + 1] = asg
        end
    end

    local function applyFamilyBoard(board, names)
        if board.cells[1] then
            local asg = board.cells[1]
            slots[names[1]] = {
                state = asg.source == "OVERRIDE" and "ASSIGNED_OVERRIDE" or "ASSIGNED_AUTO",
                assignmentId = asg.id,
                awardRef = asg.awardRef,
                itemLink = asg.itemLink,
                itemString = asg.itemString,
                source = asg.source,
                legacyOriginLogId = asg.legacyOriginLogId,
            }
        end
        if board.cells[2] then
            local asg = board.cells[2]
            slots[names[2]] = {
                state = asg.source == "OVERRIDE" and "ASSIGNED_OVERRIDE" or "ASSIGNED_AUTO",
                assignmentId = asg.id,
                awardRef = asg.awardRef,
                itemLink = asg.itemLink,
                itemString = asg.itemString,
                source = asg.source,
                legacyOriginLogId = asg.legacyOriginLogId,
            }
        end
        for i = 1, #board.overflow do
            mergeOverflow[#mergeOverflow + 1] = board.overflow[i]
        end
    end
    applyFamilyBoard(ringMerged, RING_SLOTS)
    applyFamilyBoard(trinketMerged, TRINKET_SLOTS)

    for slot, list in pairs(ordinaryOccupants) do
        local occupant, extra = ProjectOrdinarySlot(list)
        if occupant then
            slots[slot] = {
                state = occupant.source == "OVERRIDE" and "ASSIGNED_OVERRIDE" or "ASSIGNED_AUTO",
                assignmentId = occupant.id,
                awardRef = occupant.awardRef,
                itemLink = occupant.itemLink,
                itemString = occupant.itemString,
                source = occupant.source,
                legacyOriginLogId = occupant.legacyOriginLogId,
            }
        end
        for i = 1, #extra do
            mergeOverflow[#mergeOverflow + 1] = extra[i]
        end
    end

    table.sort(weaponOccupants, AssignmentCausal)
    local usedWeapon = {}
    for i = 1, #weaponOccupants do
        local asg = weaponOccupants[i]
        local ok = true
        for s = 1, #asg.assignedSlots do
            if usedWeapon[asg.assignedSlots[s]] then
                ok = false
                break
            end
        end
        if ok then
            for s = 1, #asg.assignedSlots do
                local slot = asg.assignedSlots[s]
                usedWeapon[slot] = true
                slots[slot] = {
                    state = asg.source == "OVERRIDE" and "ASSIGNED_OVERRIDE" or "ASSIGNED_AUTO",
                    assignmentId = asg.id,
                    awardRef = asg.awardRef,
                    itemLink = asg.itemLink,
                    itemString = asg.itemString,
                    source = asg.source,
                }
            end
        else
            mergeOverflow[#mergeOverflow + 1] = asg
        end
    end

    local occupied = {}
    for slot, cell in pairs(slots) do
        if cell.state and cell.state ~= "AVAILABLE" then
            occupied[slot] = true
        end
    end

    return {
        slots = slots,
        pool = pool,
        mergeOverflow = mergeOverflow,
        occupied = occupied,
    }
end

local function CreateAssignment(state, opts)
    local awardRef = opts.awardRef
    local key = AwardKeyFromRef(awardRef)
    if not key then
        return nil
    end
    if state.activeByAward[key] then
        return nil
    end
    if IsManualReversed(state, awardRef) then
        return nil
    end
    local award = state.awards[key]
    if not award or award.reversed then
        return nil
    end
    local slots = CopySlots(opts.assignedSlots)
    if not Bis.SlotsValid(slots) then
        return nil
    end
    local binding = opts.slotBinding
    if binding ~= Bis.BINDING.PACKABLE and binding ~= Bis.BINDING.BOUND then
        return nil
    end
    local family
    for i = 1, #slots do
        local fam = Bis.FamilyForSlot(slots[i])
        if not fam then
            return nil
        end
        family = family or fam
        if fam ~= family and not (family == "weapon" or fam == "weapon") then
            if not ((family == "weapon" and fam == "weapon") or (slots[1] == "Weapon" or slots[1] == "OffHand")) then
                -- mixed families not allowed except Weapon+OffHand
            end
        end
    end
    if #slots == 2 and ((slots[1] == "Weapon" and slots[2] == "OffHand") or (slots[1] == "OffHand" and slots[2] == "Weapon")) then
        family = "weapon"
    elseif RING_INDEX[slots[1]] then
        family = "ring"
    elseif TRINKET_INDEX[slots[1]] then
        family = "trinket"
    elseif slots[1] == "Weapon" or slots[1] == "OffHand" then
        family = "weapon"
    else
        family = "ordinary"
    end
    local asg = {
        id = opts.id,
        awardRef = awardRef,
        awardOwner = award.member,
        assignedSlots = slots,
        slotBinding = binding,
        assignmentScopeMembers = SortedCopy(opts.assignmentScopeMembers),
        family = family,
        itemLink = award.itemLink,
        itemString = award.itemString,
        source = opts.source or "AUTO",
        legacyOriginLogId = opts.legacyOriginLogId,
        legacyOriginKind = opts.legacyOriginKind,
        active = true,
        rank = opts.rank or 0,
    }
    state.assignments[asg.id] = asg
    state.activeByAward[key] = asg.id
    if asg.legacyOriginLogId then
        state.associationByOrigin[asg.legacyOriginLogId] = asg.id
    end
    return asg
end

local function HypotheticalWithout(state, assignmentId)
    local saved = state.assignments[assignmentId]
    local key, origin
    if saved then
        key = AwardKeyFromRef(saved.awardRef)
        origin = saved.legacyOriginLogId
        saved.active = false
        if key then
            state.activeByAward[key] = nil
        end
        if origin then
            state.associationByOrigin[origin] = nil
        end
    end
    return function()
        if saved then
            saved.active = true
            if key then
                state.activeByAward[key] = assignmentId
            end
            if origin then
                state.associationByOrigin[origin] = assignmentId
            end
        end
    end
end

function Bis.IsOutcomeSchemaValid(data)
    if type(data) ~= "table" then
        return false
    end
    local outcome = data.outcome
    if outcome ~= Bis.OUTCOME.NOT_BIS and outcome ~= Bis.OUTCOME.ASSIGNED
        and outcome ~= Bis.OUTCOME.OVERFLOW and outcome ~= Bis.OUTCOME.UNRESOLVED then
        return false
    end
    if type(data.sourceLogId) ~= "string" or data.sourceLogId == "" then
        return false
    end
    if type(data.awardKey) ~= "string" or data.awardKey == "" then
        return false
    end
    if type(data.awardMember) ~= "string" or data.awardMember == "" then
        return false
    end
    if data.qualified ~= true and data.qualified ~= false then
        return false
    end
    if outcome == Bis.OUTCOME.NOT_BIS then
        if data.qualified ~= false then
            return false
        end
    else
        if data.qualified ~= true then
            return false
        end
    end
    if type(data.assignedSlots) ~= "table" then
        return false
    end
    if outcome == Bis.OUTCOME.ASSIGNED then
        if not Bis.SlotsValid(data.assignedSlots) then
            return false
        end
        if data.slotBinding ~= Bis.BINDING.PACKABLE and data.slotBinding ~= Bis.BINDING.BOUND then
            return false
        end
        if type(data.assignmentScopeMembers) ~= "table" or #data.assignmentScopeMembers == 0 then
            return false
        end
    else
        if #data.assignedSlots ~= 0 then
            return false
        end
        if data.slotBinding ~= nil then
            return false
        end
        if data.assignmentScopeMembers ~= nil then
            return false
        end
    end
    return true
end

function Bis.IsOutcomeSourceConsistent(data, rcLog)
    if not Bis.IsOutcomeSchemaValid(data) then
        return false
    end
    if data.sourceLogId ~= data.awardKey then
        return false
    end
    if not rcLog then
        return false
    end
    local rcId = GetLogId(rcLog)
    local rcData = GetLogData(rcLog)
    if rcId ~= data.sourceLogId then
        return false
    end
    if GetLogType(rcLog) ~= (EventTypes().RC_LOOT_COUNCIL) then
        return false
    end
    if not SamePlayer(rcData and rcData.member, data.awardMember) then
        return false
    end
    return true
end

function Bis.ApplyLog(state, log, ctx)
    ctx = ctx or {}
    local eventType = GetLogType(log)
    local data = GetLogData(log)
    local types = EventTypes()
    local actions = ArmorActions()
    local logId = GetLogId(log)
    local rank = ctx.rank or 0
    state.rank[logId] = rank
    if eventType == types.BIS_OUTCOME or eventType == types.BIS_OVERRIDE
        or eventType == types.MANUAL_AWARD or eventType == types.MANUAL_AWARD_REVERSE then
        state.hasItemAwareEvents = true
    end

    local function componentOf(memberId)
        if ctx.GetIdentityMembers then
            return ctx.GetIdentityMembers(memberId)
        end
        return { NormalizeId(memberId) }
    end

    if eventType == types.SPEC_CHANGE and data then
        local memberId = NormalizeId(data.member)
        local specId = tonumber(data.specId)
        if memberId and specId then
            state.specs[memberId] = specId
        end
        return
    end

    if eventType == types.ARMOR_CHANGE and data then
        local memberId = NormalizeId(data.member)
        if data.action == actions.USED then
            if data.scope == "identity" then
                local expired = ctx.IdentityEventExpired and ctx.IdentityEventExpired(log, data)
                RegisterOrigin(state, log, data, "identity")
                if expired then
                    MarkIdentityOriginExpired(state, logId)
                end
            else
                ClearLocalOrigin(state, memberId, data.slot)
                RegisterOrigin(state, log, data, "local")
            end
        elseif data.action == actions.AVAILABLE then
            if data.scope == "identity" then
                -- identity AVAILABLE suppresses that scope's occupancy; origins in that
                -- scope for the slot/family stop contributing when this correction is active.
                local identityMembers = SortedCopy(data.identityMembers)
                local expired = ctx.IdentityEventExpired and ctx.IdentityEventExpired(log, data)
                if not expired then
                    for originId, rec in pairs(state.contributingOrigins) do
                        if rec.kind == "identity" then
                            local sameScope = ScopeKey(rec.identityMembers) == ScopeKey(identityMembers)
                            local famA = select(1, Bis.FamilyForSlot(rec.slot))
                            local famB = select(1, Bis.FamilyForSlot(data.slot))
                            if sameScope and (rec.slot == data.slot or (famA and famA == famB and famA ~= "ordinary" and famA ~= "weapon")) then
                                rec.active = false
                            end
                        end
                    end
                end
            else
                ClearLocalOrigin(state, memberId, data.slot)
            end
        end
        return
    end

    if eventType == types.RC_LOOT_COUNCIL and data then
        local awardKey = data.awardKey
        if type(awardKey) == "string" and awardKey ~= "" then
            local key = Bis.AwardRefKey("RC", awardKey)
            state.awards[key] = {
                kind = "RC",
                id = awardKey,
                member = NormalizeId(data.member),
                itemLink = data.itemLink,
                itemString = data.itemString,
                response = data.response,
                reversed = false,
                log = log,
            }
        end
        return
    end

    if eventType == types.MANUAL_AWARD and data then
        local id = logId
        local key = Bis.AwardRefKey("MANUAL", id)
        state.awards[key] = {
            kind = "MANUAL",
            id = id,
            member = NormalizeId(data.member),
            itemLink = data.itemLink,
            itemString = data.itemString,
            reversed = false,
            log = log,
        }
        return
    end

    if eventType == types.MANUAL_AWARD_REVERSE and data then
        local sourceId = data.sourceLogId
        if type(sourceId) ~= "string" then
            return
        end
        local key = Bis.AwardRefKey("MANUAL", sourceId)
        local award = state.awards[key]
        if not award then
            return
        end
        award.reversed = true
        state.reversedManual[sourceId] = true
        local activeId = state.activeByAward[key]
        if activeId then
            DeactivateAssignment(state, activeId)
        end
        return
    end

    if eventType == types.BIS_OUTCOME and data then
        local rcLog = ctx.FindLog and ctx.FindLog(data.sourceLogId)
        if not Bis.IsOutcomeSourceConsistent(data, rcLog) then
            return
        end
        if state.outcomeWinner[data.awardKey] then
            return
        end
        state.outcomeWinner[data.awardKey] = logId
        local award = state.awards[Bis.AwardRefKey("RC", data.awardKey)]
        if award then
            award.autoOutcome = data.outcome
            award.qualified = data.qualified
            award.specIdUsed = data.specIdUsed
        end
        if data.outcome == Bis.OUTCOME.OVERFLOW or data.outcome == Bis.OUTCOME.UNRESOLVED or data.outcome == Bis.OUTCOME.NOT_BIS then
            if data.outcome == Bis.OUTCOME.OVERFLOW then
                state.frozenOverflow[data.awardKey] = true
            end
            return
        end
        CreateAssignment(state, {
            id = logId,
            awardRef = { kind = "RC", id = data.awardKey },
            assignedSlots = data.assignedSlots,
            slotBinding = data.slotBinding,
            assignmentScopeMembers = data.assignmentScopeMembers,
            source = "AUTO",
            rank = rank,
        })
        return
    end

    if eventType == types.BIS_OVERRIDE and data then
        local action = data.action
        local function awardFromRef(ref)
            ref = Bis.ParseAwardRef(ref)
            if not ref then
                return nil, nil
            end
            return state.awards[AwardKeyFromRef(ref)], ref
        end

        if action == Bis.OVERRIDE_ACTION.CLEAR then
            local target = data.targetAssignmentId
            local asg = target and state.assignments[target]
            if asg and asg.active then
                DeactivateAssignment(state, target)
            end
            return
        end

        if action == Bis.OVERRIDE_ACTION.ASSIGN then
            local award, ref = awardFromRef(data.awardRef)
            if not award or not ref then
                return
            end
            if IsManualReversed(state, ref) then
                return
            end
            if state.activeByAward[AwardKeyFromRef(ref)] then
                return
            end
            local members = componentOf(award.member)
            -- occupancy: requested slots must be available in current projection
            local view = Bis.ProjectComponent(state, members)
            for i = 1, #(data.assignedSlots or {}) do
                local cell = view.slots[data.assignedSlots[i]]
                if cell and cell.state and cell.state ~= "AVAILABLE" then
                    return
                end
            end
            CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = data.assignedSlots,
                slotBinding = data.slotBinding,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                rank = rank,
            })
            return
        end

        if action == Bis.OVERRIDE_ACTION.REPLACE then
            local target = data.targetAssignmentId
            local existing = target and state.assignments[target]
            if not existing or not existing.active then
                return
            end
            local award, ref = awardFromRef(data.awardRef)
            if not award or not ref then
                return
            end
            if IsManualReversed(state, ref) then
                return
            end
            local movingSame = AwardKeyFromRef(ref) == AwardKeyFromRef(existing.awardRef)
            local other = state.activeByAward[AwardKeyFromRef(ref)]
            if other and not movingSame then
                return
            end
            local members = componentOf(award.member)
            local restore = HypotheticalWithout(state, target)
            local view = Bis.ProjectComponent(state, members)
            local ok = Bis.SlotsValid(data.assignedSlots or {})
            if ok then
                for i = 1, #data.assignedSlots do
                    local cell = view.slots[data.assignedSlots[i]]
                    if cell and cell.state and cell.state ~= "AVAILABLE" then
                        ok = false
                        break
                    end
                end
            end
            if not ok or (data.slotBinding ~= Bis.BINDING.PACKABLE and data.slotBinding ~= Bis.BINDING.BOUND) then
                restore()
                return
            end
            restore()
            DeactivateAssignment(state, target)
            CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = data.assignedSlots,
                slotBinding = data.slotBinding,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                rank = rank,
            })
            return
        end

        if action == Bis.OVERRIDE_ACTION.ASSOCIATE_LEGACY then
            local award, ref = awardFromRef(data.awardRef)
            local originId = data.legacyOriginLogId
            if not award or not ref or type(originId) ~= "string" then
                return
            end
            if IsManualReversed(state, ref) then
                return
            end
            if state.activeByAward[AwardKeyFromRef(ref)] then
                return
            end
            if state.associationByOrigin[originId] then
                return
            end
            if not OriginActive(state, originId) then
                return
            end
            local rec = state.contributingOrigins[originId]
            if not rec or rec.expired then
                return
            end
            local members = componentOf(award.member)
            CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = data.assignedSlots or { rec.slot },
                slotBinding = Bis.BINDING.BOUND,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                legacyOriginLogId = originId,
                legacyOriginKind = rec.kind,
                rank = rank,
            })
        end
    end
end

function Bis.BuildMemberSlotMap(state, identityOf)
    local slotsByMember = {}
    local poolByMember = {}
    local processed = {}
    identityOf = identityOf or {}
    local function projectFor(memberId)
        local group = identityOf[memberId] or { memberId }
        local key = ScopeKey(group)
        if processed[key] then
            return processed[key]
        end
        local view = Bis.ProjectComponent(state, group)
        processed[key] = view
        return view
    end
    for memberId, group in pairs(identityOf) do
        local view = projectFor(memberId)
        slotsByMember[memberId] = view.slots
        poolByMember[memberId] = view.pool
    end
    return slotsByMember, poolByMember
end

function Bis.ResolveRecipientSpec(memberId, storedSpecId)
    memberId = NormalizeId(memberId)
    storedSpecId = tonumber(storedSpecId)
    local selfId = SF.NameUtil and SF.NameUtil.GetSelfId and SF.NameUtil.GetSelfId()
    if memberId and selfId and SamePlayer(memberId, selfId) and GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()
        if index then
            local specId = tonumber(GetSpecializationInfo(index))
            if specId and specId > 0 then
                return specId, "live"
            end
        end
    end
    if memberId and GetInspectSpecialization and UnitGUID and UnitExists then
        local units = { "target", "focus", "mouseover" }
        if IsInRaid and IsInRaid() then
            local n = GetNumGroupMembers and GetNumGroupMembers() or 0
            for i = 1, n do
                units[#units + 1] = "raid" .. i
            end
        elseif GetNumGroupMembers then
            local n = GetNumGroupMembers() or 0
            for i = 1, n do
                units[#units + 1] = "party" .. i
            end
        end
        for i = 1, #units do
            local unit = units[i]
            if UnitExists(unit) then
                local name, realm = UnitName(unit)
                local unitId = name
                if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
                    unitId = SF.NameUtil.NormalizeNameRealm(name, realm)
                end
                if unitId and SamePlayer(unitId, memberId) then
                    local specId = tonumber(GetInspectSpecialization(unit)) or 0
                    if specId > 0 then
                        return specId, "inspect"
                    end
                end
            end
        end
    end
    if storedSpecId and storedSpecId > 0 then
        return storedSpecId, "stored"
    end
    return nil, "unknown"
end

function Bis.DecideAutomaticOutcome(opts)
    opts = opts or {}
    local qualified = opts.qualified == true
    local classif = opts.classif
    local specId = tonumber(opts.specId)
    local occupancy = opts.occupancy or {}
    local identityMembers = SortedCopy(opts.identityMembers)
    if #identityMembers == 0 and opts.awardMember then
        identityMembers = { NormalizeId(opts.awardMember) }
    end

    local function unresolved(reason)
        return {
            qualified = true,
            outcome = Bis.OUTCOME.UNRESOLVED,
            assignedSlots = {},
            specIdUsed = specId,
            unresolvedReason = reason,
            frozen = classif,
        }
    end

    if not qualified then
        return {
            qualified = false,
            outcome = Bis.OUTCOME.NOT_BIS,
            assignedSlots = {},
            specIdUsed = specId,
            frozen = classif,
        }
    end
    if not classif then
        return unresolved("UNKNOWN_SLOT")
    end

    if classif.family == "weapon" or classif.isWeaponLoc or classif.isOffHandLoc then
        local slots, reason = Bis.WeaponAssignSlots(classif, specId, occupancy)
        if not slots then
            return unresolved(reason or "UNKNOWN_COMPAT")
        end
        if #slots == 0 then
            return {
                qualified = true,
                outcome = Bis.OUTCOME.OVERFLOW,
                assignedSlots = {},
                specIdUsed = specId,
                frozen = classif,
            }
        end
        return {
            qualified = true,
            outcome = Bis.OUTCOME.ASSIGNED,
            assignedSlots = slots,
            slotBinding = Bis.BINDING.BOUND,
            assignmentScopeMembers = identityMembers,
            specIdUsed = specId,
            frozen = classif,
        }
    end

    if classif.family == "ring" or classif.family == "trinket" then
        local slot = Bis.NextPackableSlot(classif.family, occupancy)
        if not slot then
            return {
                qualified = true,
                outcome = Bis.OUTCOME.OVERFLOW,
                assignedSlots = {},
                specIdUsed = specId,
                frozen = classif,
            }
        end
        return {
            qualified = true,
            outcome = Bis.OUTCOME.ASSIGNED,
            assignedSlots = { slot },
            slotBinding = Bis.BINDING.PACKABLE,
            assignmentScopeMembers = identityMembers,
            specIdUsed = specId,
            frozen = classif,
        }
    end

    local slot = classif.slot
    if type(slot) ~= "string" or not VALID_SLOT[slot] then
        return unresolved("UNKNOWN_SLOT")
    end
    if occupancy[slot] then
        return {
            qualified = true,
            outcome = Bis.OUTCOME.OVERFLOW,
            assignedSlots = {},
            specIdUsed = specId,
            frozen = classif,
        }
    end
    return {
        qualified = true,
        outcome = Bis.OUTCOME.ASSIGNED,
        assignedSlots = { slot },
        slotBinding = Bis.BINDING.BOUND,
        assignmentScopeMembers = identityMembers,
        specIdUsed = specId,
        frozen = classif,
    }
end

function Bis.IsItemAwarePopup(state, bisResponsesConfigured)
    if bisResponsesConfigured then
        return true
    end
    return state and state.hasItemAwareEvents == true
end

function Bis.LegacyOriginsForDisplay(state, memberId, identityOf)
    local group = (identityOf and identityOf[memberId]) or { memberId }
    local set = ListSet(SortedCopy(group))
    local out = {}
    for originId, rec in pairs(state.contributingOrigins) do
        if rec.active and not rec.expired then
            if rec.kind == "local" and set[rec.member] then
                out[#out + 1] = {
                    originLogId = originId,
                    member = rec.member,
                    slot = rec.slot,
                    kind = "local",
                }
            elseif rec.kind == "identity" then
                if ScopeFullyPresent(SortedCopy(rec.identityMembers), set) then
                    out[#out + 1] = {
                        originLogId = originId,
                        member = rec.member,
                        slot = rec.slot,
                        kind = "identity",
                        identityMembers = rec.identityMembers,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.originLogId) < tostring(b.originLogId)
    end)
    return out
end
