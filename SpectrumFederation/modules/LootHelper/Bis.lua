-- Item-aware BiS reconstruction. Derived only; logs remain authoritative.
-- luacheck: globals GetItemInfoInstant
-- luacheck: globals UnitGUID UnitExists UnitName IsInRaid GetNumGroupMembers strtrim

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

-- Legal assignedSlots shapes: one named slot, or exactly Weapon+OffHand for a
-- normal two-hand assignment. Mixed families such as Head+Ring1 are rejected.
function Bis.IsLegalSlotShape(slots)
    if not Bis.SlotsValid(slots) then
        return false
    end
    if #slots == 1 then
        return true
    end
    if #slots ~= 2 then
        return false
    end
    local a, b = slots[1], slots[2]
    return (a == "Weapon" and b == "OffHand") or (a == "OffHand" and b == "Weapon")
end

local function CopySlots(slots)
    local out = {}
    for i = 1, #(slots or {}) do
        out[i] = slots[i]
    end
    return out
end

local function SortedWeaponPair(slots)
    if type(slots) ~= "table" then
        return nil
    end
    local hasWeapon, hasOff = false, false
    for i = 1, #slots do
        if slots[i] == "Weapon" then
            hasWeapon = true
        elseif slots[i] == "OffHand" then
            hasOff = true
        end
    end
    if hasWeapon and hasOff and #slots == 2 then
        return { "Weapon", "OffHand" }
    end
    return CopySlots(slots)
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
        occupancyOrigins = {},
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

-- Inverse of DeactivateAssignment for the same assignment object. REPLACE
-- must restore every mapping DeactivateAssignment cleared when creation fails.
local function RestoreDeactivatedAssignment(state, assignmentId)
    if not assignmentId then
        return
    end
    local asg = state.assignments[assignmentId]
    if not asg or asg.active == true then
        return
    end
    asg.active = true
    local key = AwardKeyFromRef(asg.awardRef)
    if key then
        state.activeByAward[key] = assignmentId
    end
    if asg.legacyOriginLogId then
        state.associationByOrigin[asg.legacyOriginLogId] = assignmentId
    end
end

local function WeaponProficiencyOk(classif, specId)
    specId = tonumber(specId)
    local SpecWeapons = SF.LootHelperBis.SpecWeapons
    if not specId then
        return false, "MISSING_SPEC"
    end
    if not (SpecWeapons and SpecWeapons.IsItemAllowedForSpec) then
        return false, "UNKNOWN_COMPAT"
    end
    if not SpecWeapons.IsItemAllowedForSpec(specId, classif) then
        return false, "UNKNOWN_COMPAT"
    end
    return true, nil
end

local function IsRangedWeaponLoc(classif)
    local SpecWeapons = SF.LootHelperBis.SpecWeapons
    return classif and SpecWeapons and SpecWeapons.IsRangedEquipLoc
        and SpecWeapons.IsRangedEquipLoc(classif.equipLoc)
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
    local okProf, profErr = WeaponProficiencyOk(classif, specId)
    if not okProf then
        return nil, profErr
    end
    local weaponFree = occupancy.Weapon ~= true
    local offFree = occupancy.OffHand ~= true

    if IsRangedWeaponLoc(classif) then
        if not weaponFree then
            return {}, nil
        end
        return { "Weapon" }, nil
    end

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
        if not flags.canTwoHand and not flags.canDualWield2H then
            return nil, "UNKNOWN_COMPAT"
        end
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
-- Unknown spec or unverified weapon compatibility fails closed (slots=nil, err).
function Bis.ResolveOverrideSlots(assignedSlots, itemLinkOrClassif, specId)
    local slots = CopySlots(assignedSlots)
    if not Bis.IsLegalSlotShape(slots) then
        return nil, "INVALID_SLOTS"
    end
    local classif = itemLinkOrClassif
    if type(classif) ~= "table" or not classif.family then
        classif = Bis.ClassifyItem(itemLinkOrClassif)
    end
    if not classif then
        return nil, "UNKNOWN_SLOT"
    end
    local ok, err = Bis.ItemFitsSlots(classif, slots, specId)
    if not ok then
        return nil, err or "UNKNOWN_COMPAT"
    end
    if classif.isTwoHand then
        local flags = tonumber(specId) and SF.LootHelperBis.SpecWeapons and SF.LootHelperBis.SpecWeapons.GetFlags(specId)
        if not flags then
            return nil, specId and "UNKNOWN_COMPAT" or "MISSING_SPEC"
        end
        if flags.canDualWield2H then
            if #slots == 2 then
                return nil, "UNKNOWN_COMPAT"
            end
            return slots, nil
        end
        if #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand") then
            return { "Weapon", "OffHand" }, nil
        end
        return SortedWeaponPair(slots), nil
    end
    return slots, nil
end

function Bis.NormalizeOverrideSlots(assignedSlots, itemLinkOrString, specId)
    local slots, err = Bis.ResolveOverrideSlots(assignedSlots, itemLinkOrString, specId)
    if not slots then
        return nil, err
    end
    return slots, nil
end

function Bis.ItemFitsSlots(classif, slots, specId)
    if type(classif) ~= "table" then
        return false, "UNKNOWN_SLOT"
    end
    if not Bis.IsLegalSlotShape(slots) then
        return false, "INVALID_SLOTS"
    end
    local family = classif.family
    if family == "ordinary" then
        if #slots ~= 1 or slots[1] ~= classif.slot then
            return false, "INCOMPATIBLE_SLOT"
        end
        return true, nil
    end
    if family == "ring" then
        if #slots ~= 1 or not RING_INDEX[slots[1]] then
            return false, "INCOMPATIBLE_SLOT"
        end
        return true, nil
    end
    if family == "trinket" then
        if #slots ~= 1 or not TRINKET_INDEX[slots[1]] then
            return false, "INCOMPATIBLE_SLOT"
        end
        return true, nil
    end
    if family == "weapon" or classif.isWeaponLoc or classif.isOffHandLoc then
        specId = tonumber(specId)
        local flags = specId and SF.LootHelperBis.SpecWeapons and SF.LootHelperBis.SpecWeapons.GetFlags(specId)
        if not specId or not flags then
            return false, specId and "UNKNOWN_COMPAT" or "MISSING_SPEC"
        end
        local okProf, profErr = WeaponProficiencyOk(classif, specId)
        if not okProf then
            return false, profErr
        end
        if IsRangedWeaponLoc(classif) then
            if #slots == 1 and slots[1] == "Weapon" then
                return true, nil
            end
            return false, "INCOMPATIBLE_SLOT"
        end
        if classif.isOffHandLoc then
            if #slots ~= 1 or slots[1] ~= "OffHand" then
                return false, "INCOMPATIBLE_SLOT"
            end
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
                return false, "UNKNOWN_COMPAT"
            end
            return true, nil
        end
        if classif.isTwoHand then
            if not flags.canTwoHand and not flags.canDualWield2H then
                return false, "UNKNOWN_COMPAT"
            end
            if flags.canDualWield2H then
                if #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand") then
                    return true, nil
                end
                return false, "INCOMPATIBLE_SLOT"
            end
            local pair = SortedWeaponPair(slots)
            if pair and #pair == 2 then
                return true, nil
            end
            if #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand") then
                return true, nil
            end
            return false, "INCOMPATIBLE_SLOT"
        end
        -- 1H / MH / ranged occupying Weapon, or OffHand when the spec dual-wields 1H
        if #slots ~= 1 then
            return false, "INCOMPATIBLE_SLOT"
        end
        if slots[1] == "Weapon" then
            return true, nil
        end
        if slots[1] == "OffHand" and flags.canDualWield1H then
            return true, nil
        end
        return false, "INCOMPATIBLE_SLOT"
    end
    return false, "UNKNOWN_SLOT"
end

function Bis.ItemFitsSlot(classif, slot, specId)
    if type(slot) ~= "string" then
        return false, "INCOMPATIBLE_SLOT"
    end
    local dummy = { slot }
    if classif and classif.isTwoHand then
        dummy = { slot }
    end
    return Bis.ItemFitsSlots(classif, dummy, specId)
end

function Bis.CompatibleSlotsForItem(classif, specId)
    if type(classif) ~= "table" then
        return nil, "UNKNOWN_SLOT"
    end
    if classif.family == "ordinary" and classif.slot then
        return { classif.slot }, nil
    end
    if classif.family == "ring" then
        return { "Ring1", "Ring2" }, nil
    end
    if classif.family == "trinket" then
        return { "Trinket1", "Trinket2" }, nil
    end
    if classif.family == "weapon" or classif.isWeaponLoc or classif.isOffHandLoc then
        specId = tonumber(specId)
        local flags = specId and SF.LootHelperBis.SpecWeapons and SF.LootHelperBis.SpecWeapons.GetFlags(specId)
        if not specId or not flags then
            return nil, specId and "UNKNOWN_COMPAT" or "MISSING_SPEC"
        end
        local out = {}
        for _, slot in ipairs({ "Weapon", "OffHand" }) do
            if Bis.ItemFitsSlot(classif, slot, specId) then
                out[#out + 1] = slot
            end
        end
        if #out == 0 then
            return nil, "UNKNOWN_COMPAT"
        end
        return out, nil
    end
    return nil, "UNKNOWN_SLOT"
end

-- Canonicalize manual award input: numeric item ID, item:... token, or hyperlink.
function Bis.NormalizeAwardItemInput(text)
    if type(text) ~= "string" then
        return nil, nil, nil, "Enter an item ID or item link."
    end
    local trimmed = strtrim(text)
    if trimmed == "" then
        return nil, nil, nil, "Enter an item ID or item link."
    end
    local itemString
    local itemLink
    if SF.LootLog and SF.LootLog.ExtractItemHyperlink then
        itemLink = SF.LootLog.ExtractItemHyperlink(trimmed)
    end
    if type(itemLink) == "string" and itemLink:find("|Hitem:", 1, true) then
        itemString = SF.LootLog.ExtractItemString(itemLink)
    elseif trimmed:match("^item:[%-%d:]+$") then
        itemString = trimmed
        itemLink = "|H" .. trimmed .. "|h[Item]|h"
    elseif trimmed:match("^%d+$") then
        local itemId = tonumber(trimmed)
        if not itemId or itemId < 1 or itemId ~= math.floor(itemId) then
            return nil, nil, nil, "Enter a valid item ID or item link."
        end
        itemString = "item:" .. tostring(itemId)
        itemLink = "|H" .. itemString .. "|h[Item]|h"
    else
        return nil, nil, nil, "Enter a valid item ID or item link."
    end
    if type(itemString) ~= "string" or itemString == "" then
        return nil, nil, nil, "Enter a valid item ID or item link."
    end
    local itemId = tonumber(itemString:match("^item:(%d+)"))
    if not itemId then
        return nil, nil, nil, "Enter a valid item ID or item link."
    end
    if GetItemInfoInstant then
        local ok, instantId = pcall(GetItemInfoInstant, itemId)
        if not ok or instantId == nil then
            return nil, nil, nil, "That item ID is not recognized."
        end
    end
    return itemLink, itemString, itemId, nil
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
    local rec = originLogId and state.occupancyOrigins and state.occupancyOrigins[originLogId]
    return rec ~= nil
end

local function ExpireInactiveLegacyAssociations(state)
    if type(state) ~= "table" or type(state.assignments) ~= "table" then
        return
    end
    local expired = {}
    for id, asg in pairs(state.assignments) do
        if asg.active and asg.legacyOriginLogId and not OriginActive(state, asg.legacyOriginLogId) then
            expired[#expired + 1] = id
        end
    end
    for i = 1, #expired do
        DeactivateAssignment(state, expired[i])
    end
end

function Bis.SetOccupancyOrigins(state, origins)
    if type(state) ~= "table" then
        return
    end
    local map = {}
    if type(origins) == "table" then
        for originId, rec in pairs(origins) do
            if type(originId) == "string" and type(rec) == "table" then
                map[originId] = rec
            end
        end
    end
    state.occupancyOrigins = map
    ExpireInactiveLegacyAssociations(state)
end

function Bis.GetOccupancyOrigin(state, originLogId)
    if type(state) ~= "table" or type(originLogId) ~= "string" then
        return nil
    end
    return state.occupancyOrigins and state.occupancyOrigins[originLogId] or nil
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
                include = OriginActive(state, asg.legacyOriginLogId)
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
    if not Bis.IsLegalSlotShape(slots) then
        return nil
    end
    local binding = opts.slotBinding
    if binding ~= Bis.BINDING.PACKABLE and binding ~= Bis.BINDING.BOUND then
        return nil
    end
    local family
    if #slots == 2 then
        family = "weapon"
    else
        family = select(1, Bis.FamilyForSlot(slots[1]))
    end
    if not family then
        return nil
    end
    if #slots == 2 then
        slots = { "Weapon", "OffHand" }
    end
    local classif
    if opts.replayFrozen then
        classif = opts.frozenClassif
        if not classif then
            return nil
        end
        if not Bis.FrozenSlotsInternallyConsistent(classif, slots) then
            return nil
        end
    else
        classif = Bis.ClassifyItem(award.itemLink or award.itemString)
        if not classif then
            return nil
        end
        local specId = opts.specId or (award.member and state.specs[award.member])
        if not Bis.ItemFitsSlots(classif, slots, specId) then
            return nil
        end
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
        if not Bis.IsLegalSlotShape(data.assignedSlots) then
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

function Bis.ClassifFromFrozenOutcome(data)
    if type(data) ~= "table" then
        return nil
    end
    local equipLoc = data.equipLoc
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
    if type(data.itemFamily) == "string" and data.itemFamily ~= "" and data.itemFamily ~= family then
        return nil
    end
    local isTwoHand = equipLoc == "INVTYPE_2HWEAPON"
    if data.isTwoHand ~= nil and (data.isTwoHand == true) ~= isTwoHand then
        return nil
    end
    return {
        equipLoc = equipLoc,
        family = family,
        slot = (family == "ordinary") and mapped or nil,
        itemClass = data.itemClass,
        itemSubClass = data.itemSubClass,
        isTwoHand = isTwoHand,
        isOffHandLoc = mapped == "offhand",
        isWeaponLoc = mapped == "weapon",
    }
end

-- Internal consistency of a frozen AUTO assignment. Does not consult live
-- SpecWeapons tables or GetItemInfoInstant.
function Bis.FrozenSlotsInternallyConsistent(classif, slots)
    if type(classif) ~= "table" or not Bis.IsLegalSlotShape(slots) then
        return false
    end
    local family = classif.family
    if family == "ordinary" then
        return #slots == 1 and slots[1] == classif.slot
    end
    if family == "ring" then
        return #slots == 1 and RING_INDEX[slots[1]] ~= nil
    end
    if family == "trinket" then
        return #slots == 1 and TRINKET_INDEX[slots[1]] ~= nil
    end
    if family == "weapon" or classif.isWeaponLoc or classif.isOffHandLoc then
        if IsRangedWeaponLoc(classif) then
            return #slots == 1 and slots[1] == "Weapon"
        end
        if classif.isOffHandLoc then
            return #slots == 1 and slots[1] == "OffHand"
        end
        if classif.isTwoHand then
            if #slots == 2 then
                return true
            end
            return #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand")
        end
        return #slots == 1 and (slots[1] == "Weapon" or slots[1] == "OffHand")
    end
    return false
end

local function ItemIdFromString(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local extracted = SF.LootLog and SF.LootLog.ExtractItemString and SF.LootLog.ExtractItemString(value)
    local s = extracted or value
    return s:match("item:(%d+)")
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
    local rcItem = rcData and (rcData.itemString or rcData.itemLink)
    local outcomeItem = data.itemString or data.itemLink
    local rcItemString = type(rcItem) == "string" and SF.LootLog and SF.LootLog.ExtractItemString
        and SF.LootLog.ExtractItemString(rcItem) or rcItem
    local outItemString = type(outcomeItem) == "string" and SF.LootLog and SF.LootLog.ExtractItemString
        and SF.LootLog.ExtractItemString(outcomeItem) or outcomeItem
    if type(rcItemString) == "string" and rcItemString ~= ""
        and type(outItemString) == "string" and outItemString ~= ""
        and rcItemString ~= outItemString then
        return false
    end
    local rcIdNum = ItemIdFromString(rcItem)
    local outIdNum = ItemIdFromString(outcomeItem)
    if rcIdNum and outIdNum and rcIdNum ~= outIdNum then
        return false
    end
    if data.outcome == Bis.OUTCOME.ASSIGNED then
        if rcIdNum and not outIdNum then
            return false
        end
        local rcLoc = rcData and rcData.equipLoc
        if type(rcLoc) == "string" and rcLoc ~= "" then
            if data.equipLoc ~= rcLoc then
                return false
            end
        end
        if not Bis.ClassifFromFrozenOutcome(data) then
            return false
        end
    end
    return true
end

function Bis.ApplyLog(state, log, ctx)
    ctx = ctx or {}
    local eventType = GetLogType(log)
    local data = GetLogData(log)
    local types = EventTypes()
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
        local SpecWeapons = SF.LootHelperBis.SpecWeapons
        if not (memberId and specId and SpecWeapons and SpecWeapons.IsKnownSpec and SpecWeapons.IsKnownSpec(specId)) then
            return
        end
        if ctx.MemberClass then
            local classToken = ctx.MemberClass(memberId)
            if type(classToken) ~= "string" or classToken == "" then
                return
            end
            if not SpecWeapons.IsSpecValidForClass(specId, classToken) then
                return
            end
        end
        state.specs[memberId] = specId
        return
    end

    if eventType == types.ARMOR_CHANGE then
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
        if data.outcome == Bis.OUTCOME.OVERFLOW or data.outcome == Bis.OUTCOME.UNRESOLVED or data.outcome == Bis.OUTCOME.NOT_BIS then
            state.outcomeWinner[data.awardKey] = logId
            local award = state.awards[Bis.AwardRefKey("RC", data.awardKey)]
            if award then
                award.autoOutcome = data.outcome
                award.qualified = data.qualified
                award.specIdUsed = data.specIdUsed
            end
            if data.outcome == Bis.OUTCOME.OVERFLOW then
                state.frozenOverflow[data.awardKey] = true
            end
            return
        end
        local slots = CopySlots(data.assignedSlots)
        if #slots == 2 then
            slots = { "Weapon", "OffHand" }
        end
        local members = componentOf(data.awardMember)
        local view = Bis.ProjectComponent(state, members)
        for i = 1, #slots do
            local slot = slots[i]
            local cell = view.slots[slot]
            if cell and cell.state and cell.state ~= "AVAILABLE" then
                return
            end
            if ctx.SlotOccupied and ctx.SlotOccupied(data.awardMember, slot) then
                return
            end
        end
        local asg = CreateAssignment(state, {
            id = logId,
            awardRef = { kind = "RC", id = data.awardKey },
            assignedSlots = data.assignedSlots,
            slotBinding = data.slotBinding,
            assignmentScopeMembers = data.assignmentScopeMembers,
            source = "AUTO",
            specId = data.specIdUsed,
            rank = rank,
            replayFrozen = true,
            frozenClassif = Bis.ClassifFromFrozenOutcome(data),
        })
        if not asg then
            return
        end
        state.outcomeWinner[data.awardKey] = logId
        local award = state.awards[Bis.AwardRefKey("RC", data.awardKey)]
        if award then
            award.autoOutcome = data.outcome
            award.qualified = data.qualified
            award.specIdUsed = data.specIdUsed
        end
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
            if type(data.sourceLogId) == "string" and data.sourceLogId ~= ref.id then
                return
            end
            if IsManualReversed(state, ref) then
                return
            end
            if state.activeByAward[AwardKeyFromRef(ref)] then
                return
            end
            if not Bis.IsLegalSlotShape(data.assignedSlots or {}) then
                return
            end
            local members = componentOf(award.member)
            local specId = award.member and state.specs[award.member]
            local classif = Bis.ClassifyItem(award.itemLink or award.itemString)
            local slots = data.assignedSlots
            if classif then
                slots = select(1, Bis.ResolveOverrideSlots(data.assignedSlots, classif, specId))
                if not slots then
                    return
                end
            end
            local view = Bis.ProjectComponent(state, members)
            for i = 1, #slots do
                local cell = view.slots[slots[i]]
                if cell and cell.state and cell.state ~= "AVAILABLE" then
                    return
                end
                if ctx.SlotOccupied and ctx.SlotOccupied(award.member, slots[i]) then
                    return
                end
            end
            CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = slots,
                slotBinding = data.slotBinding,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                specId = specId,
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
            if type(data.sourceLogId) == "string" and data.sourceLogId ~= ref.id then
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
            local specId = award.member and state.specs[award.member]
            local classif = Bis.ClassifyItem(award.itemLink or award.itemString)
            local slots = data.assignedSlots
            if classif then
                slots = select(1, Bis.ResolveOverrideSlots(data.assignedSlots, classif, specId))
                if not slots then
                    return
                end
            elseif not Bis.IsLegalSlotShape(data.assignedSlots or {}) then
                return
            end
            local members = componentOf(award.member)
            local restore = HypotheticalWithout(state, target)
            local view = Bis.ProjectComponent(state, members)
            local ok = true
            for i = 1, #slots do
                local cell = view.slots[slots[i]]
                if cell and cell.state and cell.state ~= "AVAILABLE" then
                    ok = false
                    break
                end
                if ctx.SlotOccupied and ctx.SlotOccupied(award.member, slots[i]) then
                    ok = false
                    break
                end
            end
            if not ok or (data.slotBinding ~= Bis.BINDING.PACKABLE and data.slotBinding ~= Bis.BINDING.BOUND) then
                restore()
                return
            end
            restore()
            DeactivateAssignment(state, target)
            local created = CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = slots,
                slotBinding = data.slotBinding,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                specId = specId,
                rank = rank,
            })
            if not created then
                RestoreDeactivatedAssignment(state, target)
            end
            return
        end

        if action == Bis.OVERRIDE_ACTION.ASSOCIATE_LEGACY then
            local award, ref = awardFromRef(data.awardRef)
            local originId = data.legacyOriginLogId
            if not award or not ref or type(originId) ~= "string" then
                return
            end
            if type(data.sourceLogId) == "string" and data.sourceLogId ~= ref.id then
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
            local rec = ctx.GetContributingOrigin and ctx.GetContributingOrigin(originId)
            if not rec then
                rec = Bis.GetOccupancyOrigin(state, originId)
            end
            if not rec then
                return
            end
            if rec.isOverflow then
                return
            end
            local displayed = rec.displayedSlot
            local originSlot = (type(displayed) == "string" and displayed ~= "") and displayed or rec.slot
            local members = componentOf(award.member)
            local slots = data.assignedSlots
            if type(slots) ~= "table" or #slots == 0 then
                slots = originSlot and { originSlot } or nil
            end
            if not slots then
                return
            end
            if originSlot then
                if #slots ~= 1 or slots[1] ~= originSlot then
                    return
                end
            end
            local specId = award.member and state.specs[award.member]
            local classif = Bis.ClassifyItem(award.itemLink or award.itemString)
            if classif then
                slots = select(1, Bis.ResolveOverrideSlots(slots, classif, specId))
                if not slots then
                    return
                end
            elseif not Bis.IsLegalSlotShape(slots) then
                return
            end
            if originSlot then
                local bound = false
                for i = 1, #slots do
                    if slots[i] == originSlot then
                        bound = true
                        break
                    end
                end
                if not bound then
                    return
                end
            end
            CreateAssignment(state, {
                id = logId,
                awardRef = ref,
                assignedSlots = slots,
                slotBinding = Bis.BINDING.BOUND,
                assignmentScopeMembers = data.assignmentScopeMembers or members,
                source = "OVERRIDE",
                specId = specId,
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
    -- Automatic outcomes use the stored SPEC_CHANGE spec only. Live player
    -- spec and inspect spec can differ across admins for the same award.
    storedSpecId = tonumber(storedSpecId)
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
    local origins = state and state.occupancyOrigins
    if type(origins) ~= "table" then
        return out
    end
    for originId, rec in pairs(origins) do
        if type(rec) == "table" then
            local include = false
            if rec.kind == "local" and rec.member and set[rec.member] then
                include = true
            elseif rec.kind == "identity" then
                if ScopeFullyPresent(SortedCopy(rec.identityMembers), set) then
                    include = true
                end
            elseif rec.member and set[rec.member] then
                include = true
            end
            if include and rec.isOverflow ~= true then
                out[#out + 1] = {
                    originLogId = rec.originLogId or originId,
                    member = rec.member,
                    slot = rec.slot,
                    displayedSlot = rec.displayedSlot or rec.slot,
                    kind = rec.kind,
                    identityMembers = rec.identityMembers,
                    packed = rec.packed == true,
                    active = true,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.originLogId) < tostring(b.originLogId)
    end)
    return out
end

-- displayedSlot is authoritative when present. Original slot is only a
-- fallback for origins that never received a projected display slot.
function Bis.LegacyOriginForDisplayedSlot(origins, slot)
    if type(origins) ~= "table" or type(slot) ~= "string" then
        return nil
    end
    local fallback
    for i = 1, #origins do
        local rec = origins[i]
        if type(rec) == "table" and rec.isOverflow ~= true then
            local displayed = rec.displayedSlot
            if type(displayed) == "string" and displayed ~= "" then
                if displayed == slot then
                    return rec
                end
            elseif rec.slot == slot and not fallback then
                fallback = rec
            end
        end
    end
    return fallback
end
