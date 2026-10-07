-- Event-driven Raid Consumables reminder, review, and guild bank deposit actions.
-- Accounting stays in the domain. This file only observes WoW and asks the domain to record it.
local _, SF = ...

SF.ConsumablesRuntime = SF.ConsumablesRuntime or {}
local Runtime = SF.ConsumablesRuntime

local MAX_DEPOSIT_PLACES = 6
local MAX_GUILD_BANK_SLOTS = 98
-- Compact Loot Helper scale (roster Equipment is 20; title icons are 18).
local BANNER_MOBILE_SIZE = 22
-- Mobile Banking is a 3s cast; bound pending navigation so a cancelled cast
-- cannot leak into a later manual Guild Bank visit.
local BANNER_BANK_NAV_TTL = 12

local function Debug(level, fmt, ...)
    if not SF.Debug then return end
    local fn = SF.Debug[level]
    if fn then
        fn(SF.Debug, "CONSUMABLES", fmt, ...)
    end
end

local function Warn(text)
    Debug("Warn", "%s", tostring(text))
    if SF.PrintWarning then
        SF:PrintWarning(text)
    end
end

local function Info(text)
    Debug("Info", "%s", tostring(text))
    if SF.PrintInfo then
        SF:PrintInfo(text)
    end
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function TryRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)
end

function Runtime:Profile()
    if SF.GetActiveProfile then
        return SF:GetActiveProfile()
    end
    return nil
end

function Runtime:AccountingProfile()
    local active = self:Profile()
    local sync = SF.LootHelperSync
    local state = sync and sync.state
    if not (state and state.active and type(state.profileId) == "string" and state.profileId ~= "") then
        return active
    end
    local sessionProfile = self:ProfileById(state.profileId)
    if not sessionProfile then
        local activeId = nil
        if type(active) == "table" then
            if active.GetProfileId then
                activeId = active:GetProfileId()
            else
                activeId = active._profileId
            end
        end
        if activeId == state.profileId then
            return active
        end
        return nil
    end
    local activeId = nil
    if type(active) == "table" then
        if active.GetProfileId then
            activeId = active:GetProfileId()
        else
            activeId = active._profileId
        end
    end
    return sessionProfile
end

function Runtime:ProfileById(profileId)
    if type(profileId) ~= "string" or profileId == "" then return nil end
    local db = SF.lootHelperDB
    if type(db) == "table" and type(db.profiles) == "table" and db.profiles[profileId] then
        return db.profiles[profileId]
    end
    local sync = SF.LootHelperSync
    if sync and sync.FindLocalProfileById then
        return sync:FindLocalProfileById(profileId)
    end
    return nil
end

function Runtime:SelfId()
    if SF.NameUtil and SF.NameUtil.GetSelfId then
        return SF.NameUtil.GetSelfId()
    end
    return nil
end

function Runtime:RemindersEnabled()
    local store = SF.SettingsStore
    if store and store.Get then
        local value = store:Get("lootHelper.showRaidSupplyReminders")
        if value == nil then return true end
        return value and true or false
    end
    return true
end

-- Production Loot Helper UI owns the frame and reminder API on the Window child
-- (`SF.LootHelperWindow.Window`), not on the parent namespace table.
function Runtime:LootHelperWindow()
    local lh = SF.LootHelperWindow
    return lh and lh.Window or nil
end

function Runtime:WindowShown()
    local window = self:LootHelperWindow()
    local frame = window and window._frame
    if not (frame and frame.IsShown and frame:IsShown()) then
        return false
    end
    -- Minimized keeps the outer frame shown while hiding Content; treat that as not shown.
    if window.IsMinimized and window:IsMinimized() then
        return false
    end
    return true
end

function Runtime:ItemName(itemId)
    if C_Item and C_Item.GetItemInfo then
        local name = C_Item.GetItemInfo(itemId)
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    if GetItemInfo then
        local name = GetItemInfo(itemId)
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "item " .. tostring(itemId)
end

function Runtime:BindType(itemId)
    if C_Item and C_Item.GetItemInfo then
        local bindType = select(14, C_Item.GetItemInfo(itemId))
        if bindType ~= nil then
            return tonumber(bindType)
        end
    end
    if GetItemInfo then
        return tonumber(select(14, GetItemInfo(itemId)))
    end
    return nil
end

-- Configuration admission for Add Item: item-template BindType only.
-- Instance binding (soulbound stacks / BoE that later bound) is enforced at
-- deposit time by PlaceNextDeposit, which skips each bound source stack.
function Runtime:Transferable(itemId)
    self.pendingItemLoads = self.pendingItemLoads or {}
    local C = SF.Consumables
    itemId = C and C.ItemIdFromText and C.ItemIdFromText(itemId) or tonumber(itemId)
    if not itemId then
        return false, "Enter an item ID or item link."
    end
    local bindType = self:BindType(itemId)
    if bindType == nil then
        if C_Item and C_Item.RequestLoadItemDataByID and not self.pendingItemLoads[itemId] then
            self.pendingItemLoads[itemId] = true
            C_Item.RequestLoadItemDataByID(itemId)
        end
        return nil, "Item data is not ready. Try again."
    end
    local Routing = SF.ConsumablesRouting
    local transferable = Routing and Routing.TransferableBindType and Routing.TransferableBindType(bindType)
    if transferable == nil then
        transferable = not (bindType == 1 or bindType == 4 or bindType == 7 or bindType == 8 or bindType == 9)
    end
    if not transferable then
        return false, "That item is not transferable."
    end
    return true
end

function Runtime:CurrentGuild()
    local clubId = nil
    if C_Club and C_Club.GetGuildClubId then
        clubId = C_Club.GetGuildClubId()
    end
    if clubId == nil or clubId == 0 or clubId == "0" or clubId == "" then
        return nil, nil, "Could not read a stable guild id."
    end
    local name, realm = nil, nil
    if GetGuildInfo then
        local guildName, _, _, guildRealm = GetGuildInfo("player")
        name, realm = guildName, guildRealm
    end
    return {
        guid = tostring(clubId),
        name = type(name) == "string" and name or "",
        realm = type(realm) == "string" and realm or "",
    }
end

function Runtime:ScanBags()
    self.bagCounts = {}
    self.bagStacks = {}
    local container = C_Container
    local Routing = SF.ConsumablesRouting
    if not container or not container.GetContainerNumSlots or not container.GetContainerItemInfo then
        return
    end
    for bag = 0, 5 do
        if not Routing or Routing.IsCarriedBag(bag) then
            local slots = container.GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local info = container.GetContainerItemInfo(bag, slot)
                local itemId = type(info) == "table" and tonumber(info.itemID) or nil
                local count = type(info) == "table" and tonumber(info.stackCount) or nil
                if itemId and count and count > 0 then
                    self.bagCounts[itemId] = (self.bagCounts[itemId] or 0) + count
                    local stacks = self.bagStacks[itemId]
                    if not stacks then
                        stacks = {}
                        self.bagStacks[itemId] = stacks
                    end
                    stacks[#stacks + 1] = { bag = bag, slot = slot, count = count }
                end
            end
        end
    end
end

function Runtime:ProfileOperationPending(profileId)
    if type(profileId) ~= "string" or profileId == "" then return false end
    if type(self.depositIntent) == "table" and self.depositIntent.profileId == profileId then
        return true
    end
    if type(self.depositWork) == "table" and self.depositWork.profileId == profileId then
        return true
    end
    return false
end

function Runtime:DeferProfileDelete(profile)
    if type(profile) ~= "table" then return false end
    local profileId = profile.GetProfileId and profile:GetProfileId() or profile._profileId
    if not self:ProfileOperationPending(profileId) then return false end
    profile._sfConsumablesDeleteAfter = true
    return true
end

function Runtime:CompleteDeferredProfileDeletes()
    local db = SF.lootHelperDB
    if type(db) ~= "table" or type(db.profiles) ~= "table" then return end
    if type(SF.DeleteLootHelperProfile) ~= "function" then return end
    local pending = {}
    for id, profile in pairs(db.profiles) do
        if type(profile) == "table" and profile._sfConsumablesDeleteAfter and not self:ProfileOperationPending(id) then
            pending[#pending + 1] = id
        end
    end
    for i = 1, #pending do
        local id = pending[i]
        local profile = db.profiles[id]
        if type(profile) == "table" then
            profile._sfConsumablesDeleteAfter = nil
        end
        SF:DeleteLootHelperProfile(id)
    end
end

local MOBILE_BANKING_SPELL_ID = 83958

-- Mobile Banking is a guild perk. Prefer "does the player know this spell"
-- (`C_SpellBook.IsSpellKnown` / `IsPlayerSpell`) over "is it listed in the
-- spellbook UI" (`IsSpellInSpellBook`), which can return false for perks the
-- player can still cast.
function Runtime:MobileSpellKnown()
    local spellBank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
    if C_SpellBook and C_SpellBook.IsSpellKnown and spellBank ~= nil then
        return C_SpellBook.IsSpellKnown(MOBILE_BANKING_SPELL_ID, spellBank) and true or false
    end
    if type(IsPlayerSpell) == "function" then
        return IsPlayerSpell(MOBILE_BANKING_SPELL_ID) and true or false
    end
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook and spellBank ~= nil then
        return C_SpellBook.IsSpellInSpellBook(MOBILE_BANKING_SPELL_ID, spellBank) and true or false
    end
    if type(IsSpellKnown) == "function" then
        return IsSpellKnown(MOBILE_BANKING_SPELL_ID) and true or false
    end
    return nil
end

function Runtime:MobileSpell()
    local known = self:MobileSpellKnown()
    if known == false then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(MOBILE_BANKING_SPELL_ID)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
        if not info then return nil end
    end
    if GetSpellInfo then
        local spellName = GetSpellInfo(MOBILE_BANKING_SPELL_ID)
        if type(spellName) == "string" and spellName ~= "" then
            return spellName
        end
        if type(spellName) == "table" and type(spellName.name) == "string" and spellName.name ~= "" then
            return spellName.name
        end
    end
    return nil
end

function Runtime:MobileOnCooldown(spell)
    if not spell or not C_Spell or not C_Spell.GetSpellCooldown then return false end
    local first, second = C_Spell.GetSpellCooldown(spell)
    if type(first) == "table" then
        -- Prefer NeverSecret isActive under SecretWhenCooldownsRestricted.
        if first.isActive ~= nil then
            return first.isActive and true or false
        end
        local duration = tonumber(first.duration)
        return duration ~= nil and duration > 0
    end
    local duration = tonumber(second)
    return duration ~= nil and duration > 0
end

-- Remaining cooldown seconds when start/duration are safely readable.
-- Returns nil when values are unavailable or secret-restricted.
function Runtime:MobileCooldownRemaining(spell)
    if not spell or not C_Spell or not C_Spell.GetSpellCooldown then return nil end
    local first, second = C_Spell.GetSpellCooldown(spell)
    local startTime, duration, modRate
    if type(first) == "table" then
        if first.isActive == false then return 0 end
        startTime = tonumber(first.startTime)
        duration = tonumber(first.duration)
        modRate = tonumber(first.modRate) or 1
    else
        startTime = tonumber(first)
        duration = tonumber(second)
        modRate = 1
    end
    if not startTime or not duration or duration <= 0 then return nil end
    if modRate <= 0 then modRate = 1 end
    local now = (GetTime and GetTime()) or 0
    local remaining = (startTime + duration - now) / modRate
    if remaining < 0 then remaining = 0 end
    return remaining
end

function Runtime:CancelMobileCooldownWatch()
    if self.mobileCooldownTimer then
        if self.mobileCooldownTimer.Cancel then
            self.mobileCooldownTimer:Cancel()
        end
        self.mobileCooldownTimer = nil
    end
    self.mobileCooldownWatchGen = (self.mobileCooldownWatchGen or 0) + 1
end

function Runtime:ScheduleMobileCooldownWatch(spell)
    self:CancelMobileCooldownWatch()
    if not spell or not self:MobileOnCooldown(spell) then return end
    local remaining = self:MobileCooldownRemaining(spell)
    if remaining == nil or remaining <= 0 then return end
    -- Mobile Banking is a 1-hour cooldown; bound runaway values.
    if remaining > 3700 then remaining = 3700 end
    if not (C_Timer and C_Timer.NewTimer) then return end
    local gen = self.mobileCooldownWatchGen or 0
    self.mobileCooldownTimer = C_Timer.NewTimer(remaining + 0.05, function()
        if (self.mobileCooldownWatchGen or 0) ~= gen then return end
        self.mobileCooldownTimer = nil
        if InCombat() then
            self.reviewRefreshPending = true
            return
        end
        self:RefreshReminder()
    end)
end

function Runtime:UpdateMobileCooldownWatch(collected)
    local access = collected and collected.access
    local spell = self:MobileSpell()
    local need = spell
        and access
        and access.reason == "cooldown"
        and self:RemindersEnabled()
        and self:WindowShown()
        and collected.profile
        and self:CarriedRequestedCount(collected.profile) > 0
    if not need then
        self:CancelMobileCooldownWatch()
        return
    end
    self:ScheduleMobileCooldownWatch(spell)
end

function Runtime:MobileSpellIcon()
    if C_Spell and C_Spell.GetSpellTexture then
        local texture = C_Spell.GetSpellTexture(MOBILE_BANKING_SPELL_ID)
        if texture then return texture end
    end
    if type(GetSpellTexture) == "function" then
        local texture = GetSpellTexture(MOBILE_BANKING_SPELL_ID)
        if texture then return texture end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark"
end

function Runtime:MobileCooldownTiming(spell)
    if not spell or not C_Spell or not C_Spell.GetSpellCooldown then return nil, nil end
    local first, second = C_Spell.GetSpellCooldown(spell)
    if type(first) == "table" then
        if first.isActive == false then return 0, 0 end
        local startTime = tonumber(first.startTime)
        local duration = tonumber(first.duration)
        if startTime and duration then return startTime, duration end
        return nil, nil
    end
    local startTime = tonumber(first)
    local duration = tonumber(second)
    if startTime and duration then return startTime, duration end
    return nil, nil
end

function Runtime:BankIsOpen()
    if GuildBankFrame and GuildBankFrame.IsShown and GuildBankFrame:IsShown() then
        return true
    end
    if C_PlayerInteractionManager and C_PlayerInteractionManager.IsInteractingWithNpcOfType and Enum and Enum.PlayerInteractionType then
        return C_PlayerInteractionManager.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.GuildBanker) and true or false
    end
    return false
end

function Runtime:GuildBankSlotCount(tab)
    -- Retail guild-bank tabs are fixed-size; Blizzard UI iterates a constant.
    -- Prefer a live API when a shim/test provides one, otherwise use the cap.
    local slots = MAX_GUILD_BANK_SLOTS
    if type(GetGuildBankNumSlots) == "function" then
        local live = tonumber(GetGuildBankNumSlots(tab))
        if live and live > 0 then
            slots = live
        end
    end
    if slots > MAX_GUILD_BANK_SLOTS then slots = MAX_GUILD_BANK_SLOTS end
    if slots < 0 then slots = 0 end
    return slots
end

function Runtime:TabItemCounts(tab)
    local counts = {}
    if not tab or not GetGuildBankItemLink then return counts end
    local slots = self:GuildBankSlotCount(tab)
    local C = SF.Consumables
    for slot = 1, slots do
        local link = GetGuildBankItemLink(tab, slot)
        local itemId = C and C.ItemIdFromText and C.ItemIdFromText(link) or nil
        if itemId then
            local count = 1
            if GetGuildBankItemInfo then
                local _, stack = GetGuildBankItemInfo(tab, slot)
                count = tonumber(stack) or 1
            end
            counts[itemId] = (counts[itemId] or 0) + count
        end
    end
    return counts
end

function Runtime:SlotItemCount(tab, slot, itemId)
    tab = tonumber(tab)
    slot = tonumber(slot)
    itemId = tonumber(itemId)
    if not tab or not slot or not itemId or not GetGuildBankItemLink then return 0 end
    local link = GetGuildBankItemLink(tab, slot)
    local C = SF.Consumables
    local slotItem = link and C and C.ItemIdFromText and C.ItemIdFromText(link) or nil
    if slotItem ~= itemId then return 0 end
    if not GetGuildBankItemInfo then return 1 end
    local _, stack = GetGuildBankItemInfo(tab, slot)
    return tonumber(stack) or 1
end

function Runtime:ItemStackLimit(itemId)
    itemId = tonumber(itemId)
    if not itemId then return nil end
    if C_Item and type(C_Item.GetItemMaxStackSizeByID) == "function" then
        local maxStack = tonumber(C_Item.GetItemMaxStackSizeByID(itemId))
        if maxStack and maxStack > 1 then
            return math.floor(maxStack)
        end
    end
    if type(GetItemInfo) ~= "function" then return nil end
    local first, _, _, _, _, _, _, stack = GetItemInfo(itemId)
    if type(first) == "table" then
        stack = first.stackCount
    end
    stack = tonumber(stack)
    if stack and stack > 1 then
        return math.floor(stack)
    end
    return nil
end

function Runtime:DepositTargets(tab, itemId, limit)
    local targets = {}
    tab = tonumber(tab)
    itemId = tonumber(itemId)
    limit = tonumber(limit) or MAX_DEPOSIT_PLACES
    if limit < 1 then limit = 1 end
    if limit > MAX_DEPOSIT_PLACES then limit = MAX_DEPOSIT_PLACES end
    if not tab or not itemId or not GetGuildBankItemLink then
        return targets
    end
    local C = SF.Consumables
    local maxStack = self:ItemStackLimit(itemId)
    local slotCount = self:GuildBankSlotCount(tab)
    if maxStack then
        for slot = 1, slotCount do
            if #targets >= limit then break end
            local link = GetGuildBankItemLink(tab, slot)
            local slotItem = link and C and C.ItemIdFromText and C.ItemIdFromText(link) or nil
            if slotItem == itemId and GetGuildBankItemInfo then
                local _, count = GetGuildBankItemInfo(tab, slot)
                count = tonumber(count) or 0
                local room = maxStack - count
                if room > 0 then
                    targets[#targets + 1] = { slot = slot, room = room }
                end
            end
        end
    end
    for slot = 1, slotCount do
        if #targets >= limit then break end
        if not GetGuildBankItemLink(tab, slot) then
            targets[#targets + 1] = { slot = slot, room = maxStack }
        end
    end
    return targets
end

function Runtime:FreeSlots(tab)
    if not tab or not GetGuildBankItemLink then return 0 end
    local slots = self:GuildBankSlotCount(tab)
    local free = 0
    for slot = 1, slots do
        if not GetGuildBankItemLink(tab, slot) then
            free = free + 1
        end
    end
    return free
end

function Runtime:FirstEmptySlot(tab)
    if not tab or not GetGuildBankItemLink then return nil end
    local slots = self:GuildBankSlotCount(tab)
    for slot = 1, slots do
        if not GetGuildBankItemLink(tab, slot) then
            return slot
        end
    end
    return nil
end

function Runtime:ConfiguredBankTabReady(cfg)
    local tab = cfg and tonumber(cfg.bankTab) or nil
    if not tab then return false, nil end
    if type(GetCurrentGuildBankTab) ~= "function" then
        return true, tab
    end
    local current = tonumber(GetCurrentGuildBankTab())
    if current ~= tab then
        return false, current
    end
    return true, current
end

function Runtime:BankAccess(profile)
    local C = SF.Consumables
    local Routing = SF.ConsumablesRouting
    local cfg = C.Ensure(profile)
    local guild = self:CurrentGuild()
    local same = guild and cfg.guild and guild.guid == cfg.guild.guid
    local bankOpen = self:BankIsOpen()
    local canDeposit = false
    local freeSlots = 0
    local tabReady = false
    if bankOpen and cfg.bankTab then
        tabReady = self:ConfiguredBankTabReady(cfg)
    end
    if bankOpen and tabReady and cfg.bankTab and GetGuildBankTabInfo then
        local _, _, _, deposit = GetGuildBankTabInfo(cfg.bankTab)
        canDeposit = deposit and true or false
        freeSlots = self:FreeSlots(cfg.bankTab)
    end
    local mergeRoom = false
    if bankOpen and tabReady and cfg.bankTab and freeSlots <= 0 and type(self.bagCounts) == "table"
        and GetGuildBankItemLink then
        local carried = {}
        local carriedCount = 0
        local ids = C.RequestedItemIds(profile)
        for i = 1, #ids do
            if carriedCount >= C.MAX_REQUESTED_ITEMS then break end
            local itemId = ids[i]
            if (tonumber(self.bagCounts[itemId]) or 0) > 0 then
                carried[itemId] = true
                carriedCount = carriedCount + 1
            end
        end
        if carriedCount > 0 then
            local slotCount = self:GuildBankSlotCount(cfg.bankTab)
            for slot = 1, slotCount do
                local link = GetGuildBankItemLink(cfg.bankTab, slot)
                local slotItem = link and C.ItemIdFromText and C.ItemIdFromText(link) or nil
                if slotItem and carried[slotItem] and GetGuildBankItemInfo then
                    local maxStack = self:ItemStackLimit(slotItem)
                    if maxStack then
                        local _, count = GetGuildBankItemInfo(cfg.bankTab, slot)
                        if maxStack - (tonumber(count) or 0) > 0 then
                            mergeRoom = true
                            break
                        end
                    end
                end
            end
        end
    end
    local spell = self:MobileSpell()
    return Routing.GuildBankAccess({
        configured = cfg.guild ~= nil and cfg.bankTab ~= nil,
        sameGuild = same and true or false,
        bankOpen = bankOpen,
        wrongTab = bankOpen and cfg.bankTab ~= nil and not tabReady or false,
        canDeposit = canDeposit,
        freeSlots = freeSlots,
        mergeRoom = mergeRoom,
        mobileKnown = spell ~= nil,
        mobileCooldown = spell ~= nil and self:MobileOnCooldown(spell) or false,
    })
end

function Runtime:Collect()
    local C = SF.Consumables
    local Routing = SF.ConsumablesRouting
    local profile = self:AccountingProfile()
    if not C or not Routing or not profile then return nil end
    self:ScanBags()
    local access = self:BankAccess(profile)
    local usable = Routing.GuildBankUsable(access)
    local carried = {}
    local ids = C.RequestedItemIds(profile)
    local Workflow = SF.ConsumablesWorkflow
    self.qtyOverrides = self.qtyOverrides or {}
    for i = 1, #ids do
        local itemId = ids[i]
        local have = self.bagCounts[itemId] or 0
        if have > 0 then
            local qty = have
            local edited = self.qtyOverrides[itemId]
            if edited and Workflow and Workflow.ClampDonationQuantity then
                qty = Workflow.ClampDonationQuantity(edited, have)
            end
            if qty > 0 then
                carried[#carried + 1] = {
                    itemId = itemId,
                    quantity = qty,
                    name = self:ItemName(itemId),
                }
            end
        end
    end
    local plan = C.BuildDonationPlan(profile, carried, {
        guildBankUsable = usable,
    })
    return {
        profile = profile,
        access = access,
        usable = usable,
        plan = plan,
    }
end

function Runtime:CarriedRequestedCount(profile)
    local C = SF.Consumables
    if not C or not profile or type(self.bagCounts) ~= "table" then return 0 end
    local ids = C.RequestedItemIds(profile)
    local total = 0
    for i = 1, #ids do
        total = total + (tonumber(self.bagCounts[ids[i]]) or 0)
    end
    return total
end

function Runtime:ReminderState()
    local reviewShown = self.review and self.review.IsShown and self.review:IsShown()
    if not self:WindowShown() and not reviewShown then
        self:LogReminderDecision(nil, false, "window_hidden")
        return false
    end
    local Routing = SF.ConsumablesRouting
    local collected = self:Collect()
    if not collected then
        self:LogReminderDecision(nil, false, "no_profile")
        return false
    end
    local carriedCount = self:CarriedRequestedCount(collected.profile)
    local carries = carriedCount > 0
    local path = Routing.HasReminderPath(collected.access)
    local visible = Routing.ReminderVisible({
        remindersEnabled = self:RemindersEnabled(),
        windowAllowed = self:WindowShown(),
        carriesRequested = carries,
        hasReminderPath = path,
    })
    self:LogReminderDecision(collected, visible, nil, carriedCount)
    return visible, collected
end

function Runtime:LogReminderDecision(collected, visible, earlyReason, carriedCount)
    local access = collected and collected.access or nil
    local profile = collected and collected.profile or nil
    local profileId = nil
    if type(profile) == "table" then
        if profile.GetProfileId then
            profileId = profile:GetProfileId()
        else
            profileId = profile._profileId
        end
    end
    local cfg = profile and SF.Consumables and SF.Consumables.Ensure and SF.Consumables.Ensure(profile) or nil
    local spell = self:MobileSpell()
    local fingerprint = table.concat({
        tostring(profileId or ""),
        tostring(self:RemindersEnabled()),
        tostring(self:WindowShown()),
        tostring(carriedCount or 0),
        tostring(cfg and cfg.guild and cfg.guild.guid or ""),
        tostring(cfg and cfg.bankTab or ""),
        tostring(access and access.action or ""),
        tostring(access and access.reason or ""),
        tostring(access and access.enabled or false),
        tostring(spell ~= nil),
        tostring(spell ~= nil and self:MobileOnCooldown(spell) or false),
        tostring(visible and true or false),
        tostring(earlyReason or ""),
    }, "|")
    if fingerprint == self._reminderDebugFingerprint then
        return
    end
    self._reminderDebugFingerprint = fingerprint
    Debug("Info",
        "reminder decision profile=%s enabled=%s window=%s carried=%s guildTab=%s access=%s/%s mobile=%s cooldown=%s visible=%s%s",
        tostring(profileId or ""),
        tostring(self:RemindersEnabled()),
        tostring(self:WindowShown()),
        tostring(carriedCount or 0),
        tostring(cfg and cfg.bankTab or ""),
        tostring(access and access.action or "none"),
        tostring(access and (access.reason or (access.enabled and "ok" or "disabled")) or earlyReason or "n/a"),
        tostring(spell ~= nil),
        tostring(spell ~= nil and self:MobileOnCooldown(spell) or false),
        tostring(visible and true or false),
        earlyReason and (" early=" .. earlyReason) or "")
end

function Runtime:RefreshReminder()
    self:WatchWindow()
    local visible, collected = self:ReminderState()
    self.reminderShown = visible and true or false
    self.lastAccess = collected and collected.access or nil
    local access = self.lastAccess
    local spell = self:MobileSpell()
    local mobileState = nil
    if visible and spell and access and (access.action == "mobile" or access.action == "cooldown") then
        local onCooldown = access.action == "cooldown" or self:MobileOnCooldown(spell)
        local startTime, duration = nil, nil
        if onCooldown then
            startTime, duration = self:MobileCooldownTiming(spell)
        end
        mobileState = {
            visible = true,
            spell = spell,
            spellId = MOBILE_BANKING_SPELL_ID,
            onCooldown = onCooldown and true or false,
            cooldownStart = startTime,
            cooldownDuration = duration,
        }
    end
    local window = self:LootHelperWindow()
    if window and window.SetSupplyReminder then
        window:SetSupplyReminder(visible, mobileState)
    end
    self:SyncBannerMobileButton(mobileState)
    self:UpdateMobileCooldownWatch(collected)
end

function Runtime:WatchWindow()
    local window = self:LootHelperWindow()
    local frame = window and window._frame
    if not frame or frame.__sfConsumablesHook then return end
    frame.__sfConsumablesHook = true
    frame:HookScript("OnShow", function()
        self:RefreshReminder()
    end)
    frame:HookScript("OnHide", function()
        self.reminderShown = false
        self:CancelMobileCooldownWatch()
        self:SyncBannerMobileButton(nil)
    end)
    frame:HookScript("OnSizeChanged", function()
        if InCombat() then
            self.bannerMobilePending = true
            return
        end
        if self.bannerMobileHolder and self.bannerMobileHolder.IsShown and self.bannerMobileHolder:IsShown() then
            self:PlaceBannerMobileHolder()
        end
    end)
    local title = frame.Title
    if title and title.HookScript then
        title:HookScript("OnDragStop", function()
            if InCombat() then
                self.bannerMobilePending = true
                return
            end
            self:PlaceBannerMobileHolder()
        end)
    end
end

function Runtime:BannerMobileAnchor()
    local window = self:LootHelperWindow()
    local reminder = window and window._frame and window._frame.Content and window._frame.Content.SupplyReminder
    return reminder and reminder.MobileAnchor or nil
end

function Runtime:PlaceBannerMobileHolder()
    local holder = self.bannerMobileHolder
    local anchor = self:BannerMobileAnchor()
    if not holder or not anchor or InCombat() then return end
    local left = anchor.GetLeft and anchor:GetLeft()
    local bottom = anchor.GetBottom and anchor:GetBottom()
    if not left or not bottom then return end
    if holder.ClearAllPoints then holder:ClearAllPoints() end
    -- Screen coordinates only. Anchoring to the Loot Helper window would protect it in combat.
    holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
end

function Runtime:CancelBannerBankNavigation(reason)
    if self.bannerBankNavTimer then
        if self.bannerBankNavTimer.Cancel then
            self.bannerBankNavTimer:Cancel()
        end
        self.bannerBankNavTimer = nil
    end
    self.bannerBankNavGen = (self.bannerBankNavGen or 0) + 1
    if self.bannerBankNav then
        Debug("Info", "banner bank navigation cleared reason=%s", tostring(reason or "cancel"))
    end
    self.bannerBankNav = nil
end

function Runtime:BannerBankNavigationIdentity(profile)
    local C = SF.Consumables
    if not C or not profile then return nil end
    local cfg = C.Ensure(profile)
    if not (cfg and cfg.guild and cfg.guild.guid and cfg.bankTab) then return nil end
    local profileId = nil
    if profile.GetProfileId then
        profileId = profile:GetProfileId()
    else
        profileId = profile._profileId
    end
    if type(profileId) ~= "string" or profileId == "" then return nil end
    return {
        profileId = profileId,
        guildGuid = tostring(cfg.guild.guid),
        bankTab = tonumber(cfg.bankTab),
        configSeq = tonumber(cfg.configSeq) or 0,
    }
end

function Runtime:BeginBannerBankNavigation()
    local profile = self:AccountingProfile()
    local identity = self:BannerBankNavigationIdentity(profile)
    if not identity then
        self:CancelBannerBankNavigation("no_identity")
        return
    end
    self:CancelBannerBankNavigation("replace")
    local gen = self.bannerBankNavGen or 0
    self.bannerBankNav = identity
    Debug("Info",
        "banner bank navigation pending profile=%s guild=%s tab=%s configSeq=%s",
        tostring(identity.profileId),
        tostring(identity.guildGuid),
        tostring(identity.bankTab),
        tostring(identity.configSeq))
    if C_Timer and C_Timer.NewTimer then
        self.bannerBankNavTimer = C_Timer.NewTimer(BANNER_BANK_NAV_TTL, function()
            if (self.bannerBankNavGen or 0) ~= gen then return end
            self.bannerBankNavTimer = nil
            self:CancelBannerBankNavigation("expired")
        end)
    end
end

function Runtime:ConfiguredTabViewable(tab)
    tab = tonumber(tab)
    if not tab or type(GetGuildBankTabInfo) ~= "function" then return false end
    local name, _, isViewable = GetGuildBankTabInfo(tab)
    if type(name) ~= "string" or name == "" then return false end
    if isViewable == false then return false end
    return true
end

function Runtime:SelectConfiguredBankTab(tab)
    tab = tonumber(tab)
    if not tab or type(SetCurrentGuildBankTab) ~= "function" then return false end
    if not self:ConfiguredTabViewable(tab) then return false end
    SetCurrentGuildBankTab(tab)
    if type(QueryGuildBankTab) == "function" then
        QueryGuildBankTab(tab)
    end
    if type(GuildBankFrame_UpdateTabs) == "function" then
        pcall(GuildBankFrame_UpdateTabs)
    end
    if type(GuildBankFrame_Update) == "function" then
        pcall(GuildBankFrame_Update)
    end
    return true
end

-- Consume a banner-initiated navigation intent once for this Guild Bank opening.
-- Returns true only when the configured tab was selected. Always clears pending
-- state so duplicate open events and later manual visits cannot reuse it.
function Runtime:ConsumeBannerBankNavigation()
    local pending = self.bannerBankNav
    if not pending then return false end
    self:CancelBannerBankNavigation("consume")
    local profile = self:AccountingProfile()
    local identity = self:BannerBankNavigationIdentity(profile)
    if not identity then
        Debug("Warn", "banner bank navigation aborted: configuration no longer valid")
        return false
    end
    if identity.profileId ~= pending.profileId
        or identity.guildGuid ~= pending.guildGuid
        or identity.bankTab ~= pending.bankTab
        or identity.configSeq ~= pending.configSeq then
        Debug("Warn", "banner bank navigation aborted: destination identity changed")
        return false
    end
    local guild = self:CurrentGuild()
    if not (guild and guild.guid and guild.guid == pending.guildGuid) then
        Debug("Warn", "banner bank navigation aborted: guild mismatch")
        return false
    end
    if not self:SelectConfiguredBankTab(pending.bankTab) then
        Debug("Warn", "banner bank navigation aborted: tab %s not selectable", tostring(pending.bankTab))
        return false
    end
    Debug("Info", "banner bank navigation selected tab=%s", tostring(pending.bankTab))
    return true
end

function Runtime:EnsureBannerMobileButton()
    if self.bannerMobileButton then return self.bannerMobileButton end
    if InCombat() then
        self.bannerMobilePending = true
        return nil
    end
    self.bannerMobilePending = nil
    local holder = self.bannerMobileHolder
    if not holder then
        holder = CreateFrame("Frame", "SpectrumFederationRaidSuppliesBannerMobile", UIParent)
        holder:SetSize(BANNER_MOBILE_SIZE, BANNER_MOBILE_SIZE)
        if holder.SetFrameStrata then holder:SetFrameStrata("DIALOG") end
        holder:Hide()
        self.bannerMobileHolder = holder
    end
    -- Detached SecureActionButton only. Do not protect the movable Loot Helper window.
    local button = CreateFrame("Button", nil, holder, "SecureActionButtonTemplate")
    button:SetSize(BANNER_MOBILE_SIZE, BANNER_MOBILE_SIZE)
    if button.SetAllPoints then button:SetAllPoints(holder) end
    if button.RegisterForClicks then
        button:RegisterForClicks("AnyUp", "AnyDown")
    end
    local icon = button:CreateTexture(nil, "ARTWORK")
    if icon.SetAllPoints then icon:SetAllPoints(button) end
    button.Icon = icon
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    if highlight.SetAllPoints then highlight:SetAllPoints(button) end
    if highlight.SetColorTexture then
        highlight:SetColorTexture(1, 1, 1, 0.15)
    end
    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    if cooldown.SetAllPoints then cooldown:SetAllPoints(button) end
    button.Cooldown = cooldown
    button:SetScript("PreClick", function()
        if button.sfOnCooldown then return end
        self:BeginBannerBankNavigation()
    end)
    button:SetScript("OnEnter", function(selfBtn)
        if not GameTooltip then return end
        GameTooltip:SetOwner(selfBtn, "ANCHOR_RIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(MOBILE_BANKING_SPELL_ID)
        else
            GameTooltip:SetText(selfBtn.sfSpellName or "Mobile Banking")
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    button:Hide()
    self.bannerMobileButton = button
    return button
end

function Runtime:SyncBannerMobileButton(mobileState)
    local show = mobileState and mobileState.visible and mobileState.spell ~= nil
    -- SecureActionButton show/hide/attributes are protected; defer the whole sync in combat.
    if InCombat() then
        self.bannerMobilePending = true
        return
    end
    if not show then
        if self.bannerMobileHolder then self.bannerMobileHolder:Hide() end
        if self.bannerMobileButton then self.bannerMobileButton:Hide() end
        self.bannerMobilePending = nil
        return
    end
    if not self:EnsureBannerMobileButton() then
        return
    end
    self.bannerMobilePending = nil
    self:PlaceBannerMobileHolder()
    local button = self.bannerMobileButton
    local holder = self.bannerMobileHolder
    if holder then holder:Show() end
    button:SetShown(true)
    button.sfSpellName = mobileState.spell
    button:SetAttribute("type", "spell")
    button:SetAttribute("spell", mobileState.spell)
    if button.Icon then
        if button.Icon.SetTexture then
            button.Icon:SetTexture(self:MobileSpellIcon())
        end
        if button.Icon.SetDesaturated then
            button.Icon:SetDesaturated(mobileState.onCooldown and true or false)
        end
    end
    local cooldown = button.Cooldown
    if cooldown then
        if mobileState.onCooldown
            and type(mobileState.cooldownStart) == "number"
            and type(mobileState.cooldownDuration) == "number"
            and mobileState.cooldownDuration > 0
            and cooldown.SetCooldown then
            cooldown:SetCooldown(mobileState.cooldownStart, mobileState.cooldownDuration)
        elseif cooldown.Clear then
            cooldown:Clear()
        elseif cooldown.SetCooldown then
            cooldown:SetCooldown(0, 0)
        end
    end
    button.sfOnCooldown = mobileState.onCooldown and true or false
    if mobileState.onCooldown then
        button:Disable()
    else
        button:Enable()
    end
end

function Runtime:EnsureReview()
    if self.review then return self.review end
    local frame = CreateFrame("Frame", "SpectrumFederationRaidSupplies", UIParent, "BackdropTemplate")
    frame:SetSize(480, 380)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(selfFrame)
        if InCombat() then return end
        selfFrame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        if InCombat() then
            self.mobileButtonPending = true
            return
        end
        self:PlaceMobileHolder()
    end)
    frame:SetScript("OnHide", function()
        self:SyncMobileButton()
    end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText("Raid supplies")
    -- No X/close control: visibility follows Guild Bank + configured-tab lifecycle.
    local status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -42)
    status:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -42)
    status:SetJustifyH("LEFT")
    status:SetText("")
    frame.Status = status
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -64)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 48)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(420, 1)
    scroll:SetScrollChild(child)
    frame.Child = child
    frame.Rows = {}
    self.review = frame
    self:EnsureMobileButton()
    return frame
end

function Runtime:PlaceMobileHolder()
    local frame = self.review
    local holder = frame and frame.MobileHolder
    if not frame or not holder or InCombat() then return end
    local left = frame.GetLeft and frame:GetLeft()
    local bottom = frame.GetBottom and frame:GetBottom()
    if not left or not bottom then return end
    if holder.ClearAllPoints then holder:ClearAllPoints() end
    -- Screen coordinates only. Anchoring to the review would protect it in combat.
    holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left + 16, bottom + 14)
end

function Runtime:EnsureMobileButton()
    local frame = self.review
    if not frame then return nil end
    if frame.Mobile then return frame.Mobile end
    if InCombat() then
        self.mobileButtonPending = true
        return nil
    end
    self.mobileButtonPending = nil
    local holder = self.mobileHolder
    if not holder then
        holder = CreateFrame("Frame", "SpectrumFederationRaidSuppliesMobile", UIParent)
        holder:SetSize(160, 22)
        if holder.SetFrameStrata then holder:SetFrameStrata("DIALOG") end
        holder:Hide()
        self.mobileHolder = holder
    end
    local mobile = CreateFrame("Button", nil, holder, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    mobile:SetSize(160, 22)
    if mobile.SetAllPoints then mobile:SetAllPoints(holder) end
    mobile:SetText("Mobile Banking")
    mobile:Hide()
    frame.Mobile = mobile
    frame.MobileHolder = holder
    self:PlaceMobileHolder()
    return mobile
end

function Runtime:SyncMobileButton()
    local frame = self.review
    if not frame then return end
    if InCombat() then
        self.mobileButtonPending = true
        return
    end
    if not frame.Mobile and not self:EnsureMobileButton() then
        return
    end
    self.mobileButtonPending = nil
    self:PlaceMobileHolder()
    local button = frame.Mobile
    local holder = frame.MobileHolder
    local spell = self:MobileSpell()
    local access = self.lastAccess
    local reviewShown = frame.IsShown and frame:IsShown()
    local show = reviewShown and access and access.action == "mobile" and spell ~= nil
    if holder then
        if show then holder:Show() else holder:Hide() end
    end
    button:SetShown(show and true or false)
    if not show then return end
    button:SetAttribute("type", "spell")
    button:SetAttribute("spell", spell)
    if self:MobileOnCooldown(spell) then
        button:Disable()
        button:SetText("On cooldown")
    else
        button:Enable()
        button:SetText("Mobile Banking")
    end
end

local function StatusText(access)
    if not access or not access.visible then
        if access and access.reason == "wrong_guild" then
            return "Guild bank actions are hidden for this guild."
        end
        return ""
    end
    if access.reason == "no_permission" then
        return "You cannot deposit to the configured guild bank tab."
    end
    if access.reason == "wrong_tab" then
        return "Open the configured guild bank tab to deposit."
    end
    if access.reason == "tab_full" then
        return "The configured guild bank tab is full."
    end
    if access.reason == "cooldown" then
        return "Mobile Banking is on cooldown."
    end
    if access.reason == "bank_closed" then
        return "Open the configured guild bank to deposit."
    end
    if access.action == "deposit" and access.enabled then
        return "The configured guild bank tab can take deposits."
    end
    return ""
end

function Runtime:ClearRows()
    local frame = self.review
    if not frame then return end
    for i = 1, #frame.Rows do
        frame.Rows[i]:Hide()
    end
end

function Runtime:AcquireRow(index)
    local frame = self.review
    local row = frame.Rows[index]
    if row then
        row:Show()
        return row
    end
    row = CreateFrame("Frame", nil, frame.Child)
    row:SetSize(400, 24)
    local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", row, "LEFT", 0, 0)
    text:SetWidth(230)
    text:SetJustifyH("LEFT")
    row.Text = text
    local edit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    edit:SetSize(40, 20)
    edit:SetPoint("LEFT", text, "RIGHT", 8, 0)
    edit:SetAutoFocus(false)
    edit:SetNumeric(true)
    row.Edit = edit
    local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    button:SetSize(90, 20)
    button:SetPoint("LEFT", edit, "RIGHT", 8, 0)
    row.Button = button
    frame.Rows[index] = row
    return row
end

function Runtime:ShowReview()
    local frame = self:EnsureReview()
    frame:Show()
    self:RebuildReview()
end

function Runtime:RebuildReview()
    local frame = self:EnsureReview()
    if not frame:IsShown() then return end
    local collected = self:Collect()
    self:ClearRows()
    if not collected then return end
    self.lastAccess = collected.access
    frame.Status:SetText(StatusText(collected.access))
    local y = 0
    local index = 0
    local groups = {}
    local planGroups = collected.plan.groups or {}
    for g = 1, #planGroups do
        local group = planGroups[g]
        if type(group) == "table" and type(group.lines) == "table" and #group.lines > 0 then
            groups[#groups + 1] = group
        end
    end
    local maxRows = 512
    local itemCap = SF.Consumables and tonumber(SF.Consumables.MAX_REQUESTED_ITEMS) or nil
    if itemCap and itemCap >= 1 then
        maxRows = itemCap * 2
    end
    local stop = false
    for g = 1, #groups do
        if index >= maxRows then break end
        local group = groups[g]
        index = index + 1
        local header = self:AcquireRow(index)
        header:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 0, -y)
        header.Text:SetText(tostring(group.key))
        header.Edit:Hide()
        header.Button:Hide()
        y = y + 22
        for i = 1, #group.lines do
            if index >= maxRows then
                stop = true
                break
            end
            local line = group.lines[i]
            index = index + 1
            local row = self:AcquireRow(index)
            row:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 8, -y)
            row.Text:SetText(string.format("%s x%d", line.name or self:ItemName(line.itemId), line.quantity))
            row.Edit:Show()
            row.Edit:SetText(tostring(line.quantity))
            row.Edit:SetScript("OnEnterPressed", function(edit)
                local Workflow = SF.ConsumablesWorkflow
                local have = (self.bagCounts and self.bagCounts[line.itemId]) or line.quantity
                local qty = tonumber(edit:GetText()) or line.quantity
                if Workflow and Workflow.ClampDonationQuantity then
                    qty = Workflow.ClampDonationQuantity(qty, have)
                end
                self.qtyOverrides[line.itemId] = qty
                edit:ClearFocus()
                self:RebuildReview()
            end)
            local button = row.Button
            button:Show()
            button:SetText("Deposit")
            if collected.access and collected.access.action == "deposit" and collected.access.enabled then
                button:Enable()
            else
                button:Disable()
            end
            button:SetScript("OnClick", function()
                local Workflow = SF.ConsumablesWorkflow
                local have = (self.bagCounts and self.bagCounts[line.itemId]) or line.quantity
                local qty = tonumber(row.Edit:GetText()) or line.quantity
                if Workflow and Workflow.ClampDonationQuantity then
                    qty = Workflow.ClampDonationQuantity(qty, have)
                end
                self.qtyOverrides[line.itemId] = qty
                local depositLine = {
                    itemId = line.itemId,
                    quantity = qty,
                    name = line.name,
                    generation = line.generation,
                    quality = line.quality,
                    guildBank = line.guildBank,
                }
                self:BeginDeposit(depositLine, collected)
            end)
            y = y + 26
        end
        if stop then break end
    end
    if index == 0 then
        index = 1
        local empty = self:AcquireRow(index)
        empty:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 0, 0)
        empty.Text:SetText("No raid supplies to deposit.")
        empty.Edit:Hide()
        empty.Button:Hide()
        y = 24
    end
    frame.Child:SetHeight(math.max(1, y))
    self:SyncMobileButton()
end

function Runtime:Commit(profile, token, events)
    local sync = SF.LootHelperSync
    local ok, err
    if sync and sync.CommitConsumablesEvents then
        ok, err = sync:CommitConsumablesEvents(profile, token, events)
    else
        ok, err = SF.Consumables.CommitEvents(profile, token, events)
    end
    if not ok and err then
        Warn(err)
    end
    return ok, err
end

function Runtime:NextToken(kind)
    self.tokenSeq = (self.tokenSeq or 0) + 1
    local who = self:SelfId()
    if type(who) ~= "string" or who == "" then
        who = "player"
    end
    return string.format("%s-%s-%s-%d", kind, who, tostring(GetTime and GetTime() or self.tokenSeq), self.tokenSeq)
end

function Runtime:CancelDepositWork()
    local hadWork = self.depositWork ~= nil
    self.depositContinueGen = (self.depositContinueGen or 0) + 1
    if hadWork then
        self:FinalizeDepositWork()
        -- Cancellation stops future cursor work, but still settles any slot
        -- increases already observed under the captured transaction context.
        if self.depositIntent and (tonumber(self.depositIntent.bestActual) or 0) > 0 then
            self:FinishDeposit(true)
        end
    end
    if hadWork then
        self:CompleteDeferredProfileDeletes()
    end
end

function Runtime:ScheduleDepositContinue(delay)
    self.depositContinueGen = (self.depositContinueGen or 0) + 1
    local gen = self.depositContinueGen
    delay = tonumber(delay) or 0
    if delay < 0 then delay = 0 end
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, function()
            if self.depositContinueGen ~= gen then return end
            self:PlaceNextDeposit()
        end)
        return
    end
    self:PlaceNextDeposit()
end

function Runtime:DepositConfigStillValid(work)
    if type(work) ~= "table" then return false end
    local C = SF.Consumables
    local profile = work.profile
    if type(profile) ~= "table" then
        profile = self:ProfileById(work.profileId)
    end
    if not profile or not C then return false end
    local cfg = C.Ensure(profile)
    if (tonumber(cfg.configSeq) or 0) ~= (tonumber(work.configSeq) or 0) then
        return false
    end
    if tonumber(cfg.bankTab) ~= tonumber(work.tab) then
        return false
    end
    local itemId = work.line and tonumber(work.line.itemId) or tonumber(work.itemId)
    if work.requested == true and itemId and not C.IsRequested(profile, itemId) then
        return false
    end
    return true
end

function Runtime:FinalizeDepositWork()
    local work = self.depositWork
    self.depositWork = nil
    if type(work) ~= "table" or (tonumber(work.placed) or 0) <= 0 then
        Warn("Could not deposit into the configured guild bank tab.")
        self:CompleteDeferredProfileDeletes()
        return
    end
    local line = work.line
    self.depositIntent = {
        itemId = line.itemId,
        tab = work.tab,
        observedTab = work.observedTab or work.tab,
        guildGuid = work.guildGuid,
        generation = work.generation,
        configSeq = work.configSeq,
        requested = work.requested == true,
        intended = work.intended - (tonumber(work.remaining) or 0),
        beforeTab = work.beforeTab,
        beforeBags = work.beforeBags,
        places = work.places,
        bestActual = tonumber(work.bestActual) or 0,
        token = self:NextToken("deposit"),
        profileId = work.profileId,
        profile = work.profile,
    }
    self:ObserveDepositIntent(self.depositIntent)
    if self.depositTimer and self.depositTimer.Cancel then
        self.depositTimer:Cancel()
    end
    if C_Timer and C_Timer.NewTimer then
        self.depositTimer = C_Timer.NewTimer(1.5, function()
            self.depositTimer = nil
            self:FinishDeposit(true)
        end)
    end
end

function Runtime:ObserveDepositIntent(intent)
    if type(intent) ~= "table" then return 0 end
    local guild = self:CurrentGuild()
    if not (guild and intent.guildGuid and guild.guid == intent.guildGuid) then
        return tonumber(intent.bestActual) or 0
    end
    local placedSlots = intent.places
    if type(placedSlots) ~= "table" then return tonumber(intent.bestActual) or 0 end
    local actual = 0
    for i = 1, #placedSlots do
        local row = placedSlots[i]
        if type(row) == "table" then
            local after = self:SlotItemCount(intent.tab, row.slot, intent.itemId)
            local increase = after - (tonumber(row.before) or 0)
            if increase > (tonumber(row.observedIncrease) or 0) then
                row.observedIncrease = increase
                row.after = (tonumber(row.before) or 0) + increase
            end
            actual = actual + math.max(0, tonumber(row.observedIncrease) or 0)
        end
    end
    intent.bestObservedSlots = math.min(actual, tonumber(intent.intended) or actual)
    return intent.bestObservedSlots
end

function Runtime:VerifyDepositIntent(intent)
    if type(intent) ~= "table" then return 0, nil end
    self:ScanBags()
    self:ObserveDepositIntent(intent)
    local Workflow = SF.ConsumablesWorkflow
    if not Workflow then return 0, nil end
    local guild = self:CurrentGuild()
    local afterTab = (self:TabItemCounts(intent.tab)[intent.itemId]) or 0
    local afterBags = (self.bagCounts and self.bagCounts[intent.itemId]) or 0
    return Workflow.InterpretDeposit({
        guildOk = guild and intent.guildGuid and guild.guid == intent.guildGuid,
        configuredTab = intent.tab,
        observedTab = intent.observedTab or intent.tab,
        intendedQty = intent.intended,
        beforeTab = intent.beforeTab,
        afterTab = afterTab,
        beforeBags = intent.beforeBags,
        afterBags = afterBags,
        placedSlots = intent.places,
    })
end

local MAX_DEPOSIT_LOCK_WAITS = 20

function Runtime:PlaceNextDeposit()
    local work = self.depositWork
    if type(work) ~= "table" then return end
    if not self:DepositConfigStillValid(work) then
        -- Stop future movement, then settle confirmed placements against the
        -- immutable profile/guild/tab/generation captured at start.
        self.depositContinueGen = (self.depositContinueGen or 0) + 1
        self:FinalizeDepositWork()
        Warn("Raid supplies configuration changed during the deposit.")
        if self.depositIntent and (tonumber(self.depositIntent.bestActual) or 0) > 0 then
            self:FinishDeposit(true)
        end
        return
    end
    local container = C_Container
    if not container or not PickupGuildBankItem then
        self:FinalizeDepositWork()
        return
    end
    local remaining = tonumber(work.remaining) or 0
    local placed = tonumber(work.placed) or 0
    local stacks = work.stacks
    local targets = work.targets
    if remaining <= 0 or placed >= MAX_DEPOSIT_PLACES or type(stacks) ~= "table" or type(targets) ~= "table" then
        self:FinalizeDepositWork()
        return
    end
    local stackIndex = tonumber(work.stackIndex) or 1
    local stackLeft = tonumber(work.stackLeft)
    while stackIndex <= #stacks do
        local stack = stacks[stackIndex]
        if stackLeft == nil then
            stackLeft = tonumber(stack and stack.count) or 0
        end
        if stackLeft > 0 and remaining > 0 and placed < MAX_DEPOSIT_PLACES then
            local take = math.min(remaining, stackLeft)
            local target = targets[placed + 1]
            if not target or take <= 0 then
                break
            end
            if type(target.room) == "number" and take > target.room then
                take = target.room
            end
            if take <= 0 then
                break
            end
            -- One place per frame: Retail can lock the source slot until the
            -- server confirms. Residual targets continue on the next tick.
            local info = container.GetContainerItemInfo and container.GetContainerItemInfo(stack.bag, stack.slot)
            if type(info) == "table" and info.isLocked then
                work.lockWaits = (tonumber(work.lockWaits) or 0) + 1
                if work.lockWaits > MAX_DEPOSIT_LOCK_WAITS then
                    self:FinalizeDepositWork()
                    return
                end
                self:ScheduleDepositContinue(0.1)
                return
            end
            work.lockWaits = 0
            -- Continuations (and any later place) can race other bank activity or
            -- a tab change. Recheck before touching the bag stack so a failed
            -- target cannot swap a foreign bank item onto the cursor.
            do
                local ready = self:ConfiguredBankTabReady({ bankTab = work.tab })
                local link = GetGuildBankItemLink and GetGuildBankItemLink(work.tab, target.slot)
                local C = SF.Consumables
                local slotItem = link and C and C.ItemIdFromText and C.ItemIdFromText(link) or nil
                local itemId = tonumber(work.line.itemId)
                local maxStack = self:ItemStackLimit(itemId)
                local current = self:SlotItemCount(work.tab, target.slot, itemId)
                local empty = link == nil
                local sameRoom = slotItem == itemId and maxStack and (maxStack - current) >= take
                if not ready or (not empty and not sameRoom) then
                    self:FinalizeDepositWork()
                    return
                end
                if type(target.room) == "number" and not empty then
                    local liveRoom = maxStack - current
                    if liveRoom < take then
                        take = liveRoom
                    end
                    if take <= 0 then
                        self:FinalizeDepositWork()
                        return
                    end
                end
            end
            -- Skip soulbound stacks (or BoE that later bound) without advancing
            -- remaining or touching the cursor.
            local skipBound = false
            if C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
                local loc = ItemLocation:CreateFromBagAndSlot(stack.bag, stack.slot)
                if loc and C_Item.IsBound(loc) then
                    skipBound = true
                end
            end
            if skipBound then
                stackIndex = stackIndex + 1
                stackLeft = nil
                work.stackIndex = stackIndex
                work.stackLeft = nil
            else
                -- Recheck on every continuation immediately before source pickup.
                -- Never clear or move a cursor payload supplied by the player.
                if not self:DepositCursorEmpty() then
                    Warn("Put down the cursor item before depositing raid supplies.")
                    self:CancelDepositWork()
                    return
                end
                if take < stackLeft and container.SplitContainerItem then
                    container.SplitContainerItem(stack.bag, stack.slot, take)
                elseif container.PickupContainerItem then
                    container.PickupContainerItem(stack.bag, stack.slot)
                end
                if self:CursorItemId() ~= tonumber(work.line.itemId) then
                    -- Nothing on the cursor: picking the bank slot would withdraw it.
                    self:FinalizeDepositWork()
                    return
                end
                work.places[#work.places + 1] = {
                    slot = target.slot,
                    before = self:SlotItemCount(work.tab, target.slot, work.line.itemId),
                }
                PickupGuildBankItem(work.tab, target.slot)
                remaining = remaining - take
                stackLeft = stackLeft - take
                placed = placed + 1
                work.remaining = remaining
                work.placed = placed
                work.stackIndex = stackIndex
                work.stackLeft = stackLeft
                if remaining > 0 and placed < MAX_DEPOSIT_PLACES and (stackLeft > 0 or stackIndex < #stacks) then
                    self:ScheduleDepositContinue(0)
                    return
                end
                self:FinalizeDepositWork()
                return
            end
        else
            stackIndex = stackIndex + 1
            stackLeft = nil
            work.stackIndex = stackIndex
            work.stackLeft = nil
        end
    end
    self:FinalizeDepositWork()
end

function Runtime:BeginDeposit(line, collected)
    local C = SF.Consumables
    local Routing = SF.ConsumablesRouting
    local profile = collected and collected.profile
    local current = self:AccountingProfile()
    local profileId = profile and (profile.GetProfileId and profile:GetProfileId() or profile._profileId)
    local currentId = current and (current.GetProfileId and current:GetProfileId() or current._profileId)
    if not profileId or profileId ~= currentId then
        Warn("Raid supplies profile changed. Review the donation again.")
        self:RebuildReview()
        return
    end
    if not self:DepositCursorEmpty() then
        Warn("Put down the cursor item before depositing raid supplies.")
        return
    end
    -- Recompute live bank access at click time; the review model can be stale.
    local access = self:BankAccess(profile)
    local usable = Routing and Routing.GuildBankUsable(access) or false
    if not usable then
        if access and access.reason == "wrong_tab" then
            Warn("Open the configured guild bank tab to deposit.")
        elseif access and access.reason == "no_permission" then
            Warn("You cannot deposit to the configured guild bank tab.")
        elseif access and access.reason == "tab_full" then
            Warn("The configured guild bank tab is full.")
        elseif access and access.reason == "wrong_guild" then
            Warn("Open the configured guild bank to deposit.")
        else
            Warn("No Guild Bank donation path is available.")
        end
        return
    end
    local have = (self.bagCounts and self.bagCounts[line.itemId]) or 0
    local ok, err = C.RevalidateDonation(profile, line, {
        guildBankUsable = usable,
    }, have)
    if not ok then
        Warn(err or "Review the donation again.")
        return
    end
    if InCombat() then
        Warn("Leave combat before moving raid supplies.")
        return
    end
    local cfg = C.Ensure(profile)
    local tab = cfg.bankTab
    local container = C_Container
    if not tab or not container or not PickupGuildBankItem then
        Warn("The configured guild bank tab is not available.")
        return
    end
    local tabReady, observedTab = self:ConfiguredBankTabReady(cfg)
    if not tabReady then
        Warn("Open the configured guild bank tab to deposit.")
        return
    end
    if self.depositIntent or self.depositWork then
        Warn("A deposit is already in progress.")
        return
    end
    local beforeTab = (self:TabItemCounts(tab)[line.itemId]) or 0
    local beforeBags = have
    local stacks = (self.bagStacks and self.bagStacks[line.itemId]) or {}
    local targets = self:DepositTargets(tab, line.itemId, MAX_DEPOSIT_PLACES)
    self:CancelDepositWork()
    self.depositWork = {
        line = line,
        profile = profile,
        profileId = profileId,
        tab = tab,
        observedTab = observedTab or tab,
        guildGuid = cfg.guild and cfg.guild.guid or nil,
        generation = cfg.generation,
        configSeq = tonumber(cfg.configSeq) or 0,
        requested = C.IsRequested(profile, line.itemId) == true,
        intended = line.quantity,
        remaining = line.quantity,
        beforeTab = beforeTab,
        beforeBags = beforeBags,
        places = {},
        placed = 0,
        stacks = stacks,
        stackIndex = 1,
        stackLeft = nil,
        targets = targets,
        lockWaits = 0,
    }
    self:PlaceNextDeposit()
end

function Runtime:FinishDeposit(fromTimer)
    local intent = self.depositIntent
    if not intent then return end
    local profile = self:ProfileById(intent.profileId)
    local C = SF.Consumables
    local Workflow = SF.ConsumablesWorkflow
    if not profile or not C or not Workflow then
        self.depositIntent = nil
        if self.depositTimer and self.depositTimer.Cancel then
            self.depositTimer:Cancel()
            self.depositTimer = nil
        end
        Debug("Warn", "Skipped deposit commit because profile %s is gone", tostring(intent.profileId))
        self:CompleteDeferredProfileDeletes()
        return
    end
    local actual, reason = self:VerifyDepositIntent(intent)
    if reason == "wrong_guild" or reason == "wrong_tab" then
        self.depositIntent = nil
        if self.depositTimer and self.depositTimer.Cancel then
            self.depositTimer:Cancel()
            self.depositTimer = nil
        end
        Warn("That deposit was not in the configured guild bank tab.")
        self:CompleteDeferredProfileDeletes()
        return
    end
    if actual > (intent.bestActual or 0) then
        intent.bestActual = actual
    end
    local action = Workflow.DepositDisposition(intent.bestActual, intent.intended, fromTimer)
    if action == "wait" then
        return
    end
    self.depositIntent = nil
    if self.depositTimer and self.depositTimer.Cancel then
        self.depositTimer:Cancel()
        self.depositTimer = nil
    end
    if action == "drop" then
        self:CompleteDeferredProfileDeletes()
        return
    end
    actual = intent.bestActual or actual
    local events = Workflow.DepositEvents({
        generation = intent.generation,
        itemId = intent.itemId,
        donor = self:SelfId(),
        requested = intent.requested == true,
        timestamp = C.Now and C.Now() or nil,
    }, actual)
    local committed = self:Commit(profile, intent.token, events)
    if committed and actual < intent.intended then
        Info(string.format("Deposited %d. The rest is still in your bags.", actual))
    end
    self:CompleteDeferredProfileDeletes()
end

function Runtime:DepositCursorEmpty()
    -- A nil item ID is not proof of emptiness: spell/money payloads and item
    -- payloads with unresolved IDs must not reach the item-moving APIs either.
    return type(GetCursorInfo) == "function" and GetCursorInfo() == nil
end

function Runtime:CursorItemId()
    if type(GetCursorInfo) ~= "function" then return nil end
    local kind, itemId, link = GetCursorInfo()
    if kind ~= "item" then return nil end
    local C = SF.Consumables
    return tonumber(itemId) or (C and C.ItemIdFromText(link))
end

function Runtime:HideReviewForBankLifecycle()
    if self.review and self.review.IsShown and self.review:IsShown() then
        self.review:Hide()
    end
end

function Runtime:IsConfiguredBankTabActive()
    local C = SF.Consumables
    local profile = self:AccountingProfile()
    if not C or not profile then return false end
    local cfg = C.Ensure(profile)
    return self:ConfiguredBankTabReady(cfg) and true or false
end

-- Keep the standalone Raid Supplies window aligned with Guild Bank open/close
-- and the configured deposit tab. Leaving the configured tab is lifecycle hide,
-- not user dismissal, so auto-review may run again when that tab returns.
function Runtime:SyncReviewWithGuildBank()
    if not self.bankOpen then
        self:HideReviewForBankLifecycle()
        return
    end
    if not self:IsConfiguredBankTabActive() then
        self:HideReviewForBankLifecycle()
        self.autoReviewedThisOpen = false
        return
    end
    self:MaybeAutoReview()
    if self.review and self.review.IsShown and self.review:IsShown() then
        self:RebuildReview()
    end
end

function Runtime:OnBankOpened()
    local first = not self.bankOpen
    self.bankOpen = true
    if first then
        self.autoReviewedThisOpen = false
        -- Banner-initiated tab selection must run before SyncReviewWithGuildBank
        -- so BankAccess can see the configured tab as usable when appropriate.
        self:ConsumeBannerBankNavigation()
    elseif self.bannerBankNav then
        -- Duplicate open signal while already open: never select twice.
        self:CancelBannerBankNavigation("duplicate_open")
    end
    self:RefreshReminder()
    self:SyncReviewWithGuildBank()
end

function Runtime:OnBankClosed()
    self.autoReviewedThisOpen = false
    if self.bannerBankNav then
        self:CancelBannerBankNavigation("bank_closed")
    end
    if self.depositWork then
        self:CancelDepositWork()
    elseif self.depositIntent then
        self:ObserveDepositIntent(self.depositIntent)
        if (tonumber(self.depositIntent.bestActual) or 0) > 0 then
            self:FinishDeposit(true)
        end
    end
    self.bankOpen = false
    self:HideReviewForBankLifecycle()
    self:RefreshReminder()
end

function Runtime:MaybeAutoReview()
    if self.autoReviewedThisOpen then return end
    if not self:RemindersEnabled() then
        self.autoReviewedThisOpen = true
        return
    end
    local Routing = SF.ConsumablesRouting
    if not SF.Consumables or not Routing then return end
    local collected = self:Collect()
    if not collected then return end
    local carries = false
    for i = 1, #collected.plan.lines do
        if collected.plan.lines[i].quantity > 0 then carries = true end
    end
    if not carries then return end
    if not Routing.HasActionablePath(collected.usable) then return end
    self.autoReviewedThisOpen = true
    self:ShowReview()
end

function Runtime:OnProfileChanged(profile)
    local id = nil
    if type(profile) == "table" then
        if profile.GetProfileId then
            id = profile:GetProfileId()
        else
            id = profile._profileId
        end
    end
    if id ~= nil and id == self._seenProfileId then
        self:RefreshReminder()
        return
    end
    self._seenProfileId = id
    self:CancelBannerBankNavigation("profile_changed")
    if self.review then
        self.review:Hide()
    end
    self.qtyOverrides = {}
    self:RefreshReminder()
end

function Runtime:OnEvent(event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        if self.mobileButtonPending then
            self:SyncMobileButton()
        end
        if self.reviewRefreshPending then
            self.reviewRefreshPending = nil
            self:RefreshReminder()
            if self.bankOpen then
                self:SyncReviewWithGuildBank()
            elseif self.review and self.review:IsShown() then
                self:RebuildReview()
            end
        elseif self.bannerMobilePending or self.reminderShown then
            self:RefreshReminder()
        end
        return
    end
    if event == "BAG_UPDATE_DELAYED" or event == "GROUP_ROSTER_UPDATE" then
        if event == "BAG_UPDATE_DELAYED" and self.depositWork then
            local work = self.depositWork
            local attempted = (tonumber(work.intended) or 0) - (tonumber(work.remaining) or 0)
            local verified = self:VerifyDepositIntent({
                guildGuid = work.guildGuid, tab = work.tab, observedTab = work.observedTab,
                itemId = work.line and work.line.itemId, places = work.places,
                intended = attempted, beforeTab = work.beforeTab, beforeBags = work.beforeBags,
            })
            if verified > (tonumber(work.bestActual) or 0) then work.bestActual = verified end
        elseif event == "BAG_UPDATE_DELAYED" and self.depositIntent then
            self:FinishDeposit(false)
        end
        if InCombat() then
            self.reviewRefreshPending = true
            return
        end
        self:RefreshReminder()
        if self.bankOpen then
            self:SyncReviewWithGuildBank()
        elseif self.review and self.review:IsShown() then
            self:RebuildReview()
        end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        -- Does not fire when a cooldown ends; use it to (re)arm the one-shot expiry watch.
        local spellId = tonumber(arg1)
        if spellId ~= nil and spellId ~= MOBILE_BANKING_SPELL_ID then
            return
        end
        if InCombat() then
            self.reviewRefreshPending = true
            return
        end
        self:RefreshReminder()
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemId = tonumber(arg1)
        if itemId then
            self.pendingItemLoads[itemId] = nil
        end
    elseif event == "GUILDBANKFRAME_OPENED" then
        self:OnBankOpened()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self:OnBankClosed()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.GuildBanker then
            self:OnBankOpened()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.GuildBanker then
            self:OnBankClosed()
        end
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        if self.depositWork then
            -- Capture confirmed slot increases even while more cursor work is
            -- pending; cancellation must not erase those observations.
            local work = self.depositWork
            local shadow = {
                guildGuid = work.guildGuid, tab = work.tab, observedTab = work.observedTab,
                itemId = work.line and work.line.itemId, places = work.places,
                intended = (tonumber(work.intended) or 0) - (tonumber(work.remaining) or 0),
                beforeTab = work.beforeTab, beforeBags = work.beforeBags,
            }
            local verified = self:VerifyDepositIntent(shadow)
            if verified > (tonumber(work.bestActual) or 0) then work.bestActual = verified end
        elseif self.depositIntent then
            self:FinishDeposit(false)
        end
        -- Always resync after deposit bookkeeping. Tab changes during an
        -- in-flight deposit or confirmation intent still take this event, and
        -- skipping lifecycle sync can leave the review visible on the wrong tab.
        if InCombat() then
            self.reviewRefreshPending = true
            return
        end
        self:RefreshReminder()
        if self.bankOpen then
            self:SyncReviewWithGuildBank()
        elseif self.review and self.review:IsShown() then
            self:RebuildReview()
        end
    end
end

function Runtime:Init()
    if self.frame then return end
    self.qtyOverrides = {}
    self.pendingItemLoads = {}
    self.bagCounts = {}
    self.bagStacks = {}
    self.bannerBankNav = nil
    local frame = CreateFrame("Frame")
    self.frame = frame
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
    TryRegister(frame, "BAG_UPDATE_DELAYED")
    TryRegister(frame, "GROUP_ROSTER_UPDATE")
    TryRegister(frame, "SPELL_UPDATE_COOLDOWN")
    TryRegister(frame, "ITEM_DATA_LOAD_RESULT")
    TryRegister(frame, "GUILDBANKFRAME_OPENED")
    TryRegister(frame, "GUILDBANKFRAME_CLOSED")
    TryRegister(frame, "GUILDBANKBAGSLOTS_CHANGED")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    TryRegister(frame, "PLAYER_REGEN_ENABLED")
    if SF.Consumables and SF.Consumables.RegisterUIListener then
        local reviewUiQueued = false
        SF.Consumables.RegisterUIListener(function()
            if InCombat() then
                self.reviewRefreshPending = true
                return
            end
            if reviewUiQueued then return end
            reviewUiQueued = true
            local function run()
                reviewUiQueued = false
                if InCombat() then
                    self.reviewRefreshPending = true
                    return
                end
                self:RefreshReminder()
                if self.bankOpen then
                    self:SyncReviewWithGuildBank()
                elseif self.review and self.review.IsShown and self.review:IsShown() then
                    self:RebuildReview()
                end
            end
            if C_Timer and C_Timer.After then
                C_Timer.After(0, run)
            else
                run()
            end
        end)
    end
    if SF.SettingsStore and SF.SettingsStore.RegisterCallback then
        SF.SettingsStore:RegisterCallback("lootHelper.showRaidSupplyReminders", function()
            self:RefreshReminder()
        end)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            self:WatchWindow()
            self:RefreshReminder()
        end)
    end
    self:CompleteDeferredProfileDeletes()
    Debug("Info", "Raid Consumables runtime initialized")
end
