-- Event-driven Raid Consumables reminder, review, trade, and guild bank actions.
-- Accounting stays in the domain. This file only observes WoW and asks the domain to record it.
local _, SF = ...

SF.ConsumablesRuntime = SF.ConsumablesRuntime or {}
local Runtime = SF.ConsumablesRuntime

local MAX_TRADE_SLOTS = 6
local MAX_DEPOSIT_PLACES = 6
local REMINDER_TEXT = "Raid supplies available"

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

function Runtime:UnitId(unit)
    if not unit or not UnitExists or not UnitExists(unit) then return nil end
    local name, realm = UnitFullName(unit)
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        return SF.NameUtil.NormalizeNameRealm(name, realm)
    end
    return name
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

function Runtime:WindowShown()
    local window = SF.LootHelperWindow
    local frame = window and window._frame
    return frame and frame.IsShown and frame:IsShown() and true or false
end

function Runtime:ItemName(itemId)
    if C_Item and C_Item.GetItemInfo then
        local info = C_Item.GetItemInfo(itemId)
        if type(info) == "table" and type(info.itemName or info.name) == "string" then
            return info.itemName or info.name
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
        local info = C_Item.GetItemInfo(itemId)
        if type(info) == "table" and info.bindType ~= nil then
            return tonumber(info.bindType)
        end
    end
    if GetItemInfo then
        return tonumber(select(14, GetItemInfo(itemId)))
    end
    return nil
end

function Runtime:Transferable(itemId)
    self.pendingItemLoads = self.pendingItemLoads or {}
    local C = SF.Consumables
    itemId = C and C.ItemIdFromText and C.ItemIdFromText(itemId) or tonumber(itemId)
    if not itemId then
        return false, "Enter an item ID or item link."
    end
    self:ScanBags()
    local stacks = self.bagStacks and self.bagStacks[itemId]
    if stacks and stacks[1] and C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
        local loc = ItemLocation:CreateFromBagAndSlot(stacks[1].bag, stacks[1].slot)
        if loc and C_Item.IsBound(loc) then
            return false, "That item is not transferable."
        end
    end
    local bindType = self:BindType(itemId)
    if bindType == nil then
        if C_Item and C_Item.RequestLoadItemDataByID and not self.pendingItemLoads[itemId] then
            self.pendingItemLoads[itemId] = true
            C_Item.RequestLoadItemDataByID(itemId)
        end
        return nil, "Item data is not ready. Try again."
    end
    if bindType == 1 or bindType == 4 then
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

function Runtime:GroupMap()
    local map = {}
    local function add(unit)
        local id = self:UnitId(unit)
        if id then map[id] = unit end
    end
    if IsInRaid and IsInRaid() then
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        for i = 1, n do
            add("raid" .. i)
        end
    elseif IsInGroup and IsInGroup() then
        add("player")
        local n = GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
        for i = 1, n do
            add("party" .. i)
        end
    end
    return map
end

function Runtime:IsCompatible(name)
    local selfId = self:SelfId()
    local isSelf = name ~= nil and (name == selfId or (SF.NameUtil and SF.NameUtil.SamePlayer and SF.NameUtil.SamePlayer(name, selfId)))
    if isSelf then return true end
    local sync = SF.LootHelperSync
    if not sync or not sync.GetPeer then return false end
    local peer = sync:GetPeer(name)
    local Routing = SF.ConsumablesRouting
    if Routing and Routing.PeerCompatible then
        return Routing.PeerCompatible(peer, false)
    end
    return type(peer) == "table" and peer.consumablesCapable == true
end

function Runtime:IsInRange(unit)
    if not unit then return false end
    if not CheckInteractDistance then return true end
    return CheckInteractDistance(unit, 2) and true or false
end

function Runtime:RecipientInRange(name)
    local group = self.groupMap or self:GroupMap()
    return self:IsInRange(group[name])
end

function Runtime:MobileSpell()
    local name = "Mobile Banking"
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(name)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
        if not info then return nil end
    end
    if GetSpellInfo then
        local spellName = GetSpellInfo(name)
        if type(spellName) == "string" and spellName ~= "" then
            return spellName
        end
    end
    return nil
end

function Runtime:MobileOnCooldown(spell)
    if not spell or not C_Spell or not C_Spell.GetSpellCooldown then return false end
    local first, second = C_Spell.GetSpellCooldown(spell)
    local duration = nil
    if type(first) == "table" then
        duration = first.duration
    else
        duration = second
    end
    return (tonumber(duration) or 0) > 0
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

function Runtime:TabItemCounts(tab)
    local counts = {}
    if not tab or not GetGuildBankNumSlots or not GetGuildBankItemLink then return counts end
    local slots = GetGuildBankNumSlots(tab) or 0
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

function Runtime:FreeSlots(tab)
    if not tab or not GetGuildBankNumSlots or not GetGuildBankItemLink then return 0 end
    local slots = GetGuildBankNumSlots(tab) or 0
    local free = 0
    for slot = 1, slots do
        if not GetGuildBankItemLink(tab, slot) then
            free = free + 1
        end
    end
    return free
end

function Runtime:FirstEmptySlot(tab)
    if not tab or not GetGuildBankNumSlots or not GetGuildBankItemLink then return nil end
    local slots = GetGuildBankNumSlots(tab) or 0
    for slot = 1, slots do
        if not GetGuildBankItemLink(tab, slot) then
            return slot
        end
    end
    return nil
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
    if bankOpen and cfg.bankTab and GetGuildBankTabInfo then
        local _, _, _, deposit = GetGuildBankTabInfo(cfg.bankTab)
        canDeposit = deposit and true or false
        freeSlots = self:FreeSlots(cfg.bankTab)
    end
    local spell = self:MobileSpell()
    return Routing.GuildBankAccess({
        configured = cfg.guild ~= nil and cfg.bankTab ~= nil,
        sameGuild = same and true or false,
        bankOpen = bankOpen,
        canDeposit = canDeposit,
        freeSlots = freeSlots,
        mobileKnown = spell ~= nil,
        mobileCooldown = spell ~= nil and self:MobileOnCooldown(spell) or false,
    })
end

function Runtime:Collect()
    local C = SF.Consumables
    local Routing = SF.ConsumablesRouting
    local profile = self:Profile()
    if not C or not Routing or not profile then return nil end
    self:ScanBags()
    local group = self:GroupMap()
    self.groupMap = group
    local inGroup, compatible, inRange = {}, {}, {}
    for name, unit in pairs(group) do
        inGroup[name] = true
        compatible[name] = self:IsCompatible(name)
        inRange[name] = self:IsInRange(unit)
    end
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
        inGroup = inGroup,
        compatible = compatible,
        inRange = inRange,
        guildBankUsable = usable,
    })
    return {
        profile = profile,
        access = access,
        usable = usable,
        plan = plan,
        inGroup = inGroup,
        compatible = compatible,
        inRange = inRange,
    }
end

function Runtime:ReminderState()
    local Routing = SF.ConsumablesRouting
    local C = SF.Consumables
    local collected = self:Collect()
    if not collected then return false end
    local profile = collected.profile
    local carries = false
    for i = 1, #collected.plan.lines do
        if collected.plan.lines[i].quantity > 0 then
            carries = true
        end
    end
    local path = Routing.HasActionablePath(collected.plan.lines, collected.usable)
    local visible = Routing.ReminderVisible({
        isCrafter = C.IsCrafter(profile, self:SelfId()),
        remindersEnabled = self:RemindersEnabled(),
        windowAllowed = self:WindowShown(),
        dismissed = self.dismissed and true or false,
        carriesRequested = carries,
        hasActionablePath = path,
    })
    return visible
end

function Runtime:RefreshReminder()
    self:WatchWindow()
    local visible = self:ReminderState()
    self.reminderShown = visible and true or false
    local window = SF.LootHelperWindow
    if window and window.SetSupplyReminder then
        window:SetSupplyReminder(visible, function()
            self:ShowReview()
        end, function()
            self.dismissed = true
            self:RefreshReminder()
        end)
    end
    self:SyncRangeTicker()
end

function Runtime:WatchWindow()
    local window = SF.LootHelperWindow
    local frame = window and window._frame
    if not frame or frame.__sfConsumablesHook then return end
    frame.__sfConsumablesHook = true
    frame:HookScript("OnShow", function()
        self:RefreshReminder()
    end)
    frame:HookScript("OnHide", function()
        self.reminderShown = false
        self:SyncRangeTicker()
    end)
end

function Runtime:ShouldPoll()
    local Routing = SF.ConsumablesRouting
    if not Routing then return false end
    local selected = nil
    local outOfRange = false
    for i = 1, #(self.reviewButtons or {}) do
        local button = self.reviewButtons[i]
        if button.recipient and button.IsShown and button:IsShown() then
            selected = button.recipient
            if not self:RecipientInRange(button.recipient) then
                outOfRange = true
            end
        end
    end
    return Routing.ShouldPollRange({
        selectedRecipient = outOfRange and selected or nil,
        inRange = not outOfRange,
        reminderVisible = self.reminderShown and true or false,
        reviewVisible = self.review and self.review:IsShown() and true or false,
    })
end

function Runtime:SyncRangeTicker()
    local want = self:ShouldPoll()
    if want and not self.rangeTicker and C_Timer and C_Timer.NewTicker then
        self.rangeTicker = C_Timer.NewTicker(0.5, function()
            self:OnRangeTick()
        end)
    elseif (not want) and self.rangeTicker then
        self.rangeTicker:Cancel()
        self.rangeTicker = nil
    end
end

function Runtime:OnRangeTick()
    self:UpdateTradeButtons()
    if not self:ShouldPoll() then
        self:SyncRangeTicker()
    end
end

function Runtime:UpdateTradeButtons()
    for i = 1, #(self.reviewButtons or {}) do
        local button = self.reviewButtons[i]
        if button.recipient and button.Enable and button.Disable then
            if self:RecipientInRange(button.recipient) then
                button:Enable()
            else
                button:Disable()
            end
        end
    end
    self:SyncMobileButton()
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
    frame:SetScript("OnDragStart", function(selfFrame) selfFrame:StartMoving() end)
    frame:SetScript("OnDragStop", function(selfFrame) selfFrame:StopMovingOrSizing() end)
    frame:SetScript("OnHide", function()
        self:SyncRangeTicker()
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
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
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
    local mobile = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    mobile:SetSize(160, 22)
    mobile:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 14)
    mobile:SetText("Mobile Banking")
    mobile:Hide()
    frame.Mobile = mobile
    self.review = frame
    self.reviewButtons = {}
    return frame
end

function Runtime:SyncMobileButton()
    local frame = self.review
    if not frame or not frame.Mobile then return end
    if InCombat() then
        self.mobileButtonPending = true
        return
    end
    self.mobileButtonPending = nil
    local button = frame.Mobile
    local spell = self:MobileSpell()
    local access = self.lastAccess
    local show = access and access.action == "mobile" and spell ~= nil
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
    self.reviewButtons = {}
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
    local groups = collected.plan.groups or {}
    for g = 1, #groups do
        local group = groups[g]
        index = index + 1
        local header = self:AcquireRow(index)
        header:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 0, -y)
        header.Text:SetText(tostring(group.key))
        header.Edit:Hide()
        header.Button:Hide()
        y = y + 22
        for i = 1, #group.lines do
            if index >= 40 then break end
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
            button.recipient = nil
            if line.recipient then
                button.recipient = line.recipient
                button:SetText("Trade")
                local Routing = SF.ConsumablesRouting
                local action = Routing.TradeAction(line.recipient, collected.inRange[line.recipient])
                if action.enabled then button:Enable() else button:Disable() end
                button:SetScript("OnClick", function()
                    self:BeginTrade(line, collected)
                end)
                self.reviewButtons[#self.reviewButtons + 1] = button
            else
                button:SetText("Deposit")
                if collected.access and collected.access.action == "deposit" and collected.access.enabled then
                    button:Enable()
                else
                    button:Disable()
                end
                button:SetScript("OnClick", function()
                    self:BeginDeposit(line, collected)
                end)
            end
            y = y + 26
        end
    end
    if index == 0 then
        index = 1
        local empty = self:AcquireRow(index)
        empty:SetPoint("TOPLEFT", frame.Child, "TOPLEFT", 0, 0)
        empty.Text:SetText("No raid supplies to hand in.")
        empty.Edit:Hide()
        empty.Button:Hide()
        y = 24
    end
    frame.Child:SetHeight(math.max(1, y))
    self:SyncMobileButton()
    self:SyncRangeTicker()
end

function Runtime:Commit(profile, token, events)
    local sync = SF.LootHelperSync
    if sync and sync.CommitConsumablesEvents then
        return sync:CommitConsumablesEvents(profile, token, events)
    end
    return SF.Consumables.CommitEvents(profile, token, events)
end

function Runtime:NextToken(kind)
    self.tokenSeq = (self.tokenSeq or 0) + 1
    return string.format("%s-%s-%d", kind, tostring(GetTime and GetTime() or self.tokenSeq), self.tokenSeq)
end

function Runtime:BeginTrade(line, collected)
    local C = SF.Consumables
    local have = (self.bagCounts and self.bagCounts[line.itemId]) or 0
    local ok, err = C.RevalidateDonation(collected.profile, line, {
        inGroup = collected.inGroup,
        compatible = collected.compatible,
        inRange = collected.inRange,
        guildBankUsable = collected.usable,
    }, have)
    if not ok then
        Warn(err or "Review the donation again.")
        self:RebuildReview()
        return
    end
    if InCombat() then
        Warn("Leave combat before trading raid supplies.")
        return
    end
    local unit = self.groupMap and self.groupMap[line.recipient]
    if not unit or not InitiateTrade then
        Warn("Could not start a trade with that Crafter.")
        return
    end
    self.pendingTrade = {
        line = line,
        recipient = line.recipient,
        token = self:NextToken("trade"),
    }
    InitiateTrade(unit)
end

function Runtime:PlacePendingTrade()
    local pending = self.pendingTrade
    local container = C_Container
    local Workflow = SF.ConsumablesWorkflow
    if not pending or not container or not Workflow then return end
    if InCombat() then
        Warn("Leave combat before trading raid supplies.")
        return
    end
    local line = pending.line
    local stacks = {}
    local rows = (self.bagStacks and self.bagStacks[line.itemId]) or {}
    for i = 1, #rows do
        stacks[i] = rows[i]
    end
    local plan = Workflow.PlanTradeSlots({
        { itemId = line.itemId, quantity = line.quantity, stacks = stacks },
    }, MAX_TRADE_SLOTS)
    pending.remainder = plan.remainder
    for i = 1, #plan.placements do
        local place = plan.placements[i]
        if place.split and container.SplitContainerItem then
            container.SplitContainerItem(place.bag, place.slot, place.quantity)
        elseif container.PickupContainerItem then
            container.PickupContainerItem(place.bag, place.slot)
        end
        if ClickTradeButton then
            ClickTradeButton(place.tradeSlot)
        end
    end
end

function Runtime:CaptureTargetSlots()
    local open = self.openTrade
    if not open or not SF.Consumables then return end
    local actual = {}
    local any = false
    for i = 1, MAX_TRADE_SLOTS do
        local link = GetTradeTargetItemLink and GetTradeTargetItemLink(i) or nil
        local qty = 0
        if GetTradeTargetItemInfo then
            local _, _, count = GetTradeTargetItemInfo(i)
            qty = tonumber(count) or 0
        end
        local itemId = SF.Consumables.ItemIdFromText(link)
        if itemId and qty > 0 then
            actual[itemId] = (actual[itemId] or 0) + qty
            any = true
        end
    end
    if any then
        open.target = actual
    end
end

function Runtime:OnTradeShow()
    local profile = self:Profile()
    local C = SF.Consumables
    if not profile or not C then return end
    local partner = self:UnitId("npc")
    local selfId = self:SelfId()
    local pending = self.pendingTrade
    local donor, receiver, role
    if pending and partner and pending.recipient == partner then
        donor, receiver, role = selfId, partner, "donor"
    else
        donor, receiver, role = partner, selfId, "receiver"
    end
    if not donor or not receiver then return end
    self.openTrade = {
        role = role,
        frozen = C.FreezeTrade(profile, donor, receiver, pending and { pending.line } or nil, pending and pending.token or self:NextToken("trade")),
        both = false,
        target = {},
    }
    if role == "donor" then
        self:PlacePendingTrade()
    end
    Debug("Info", "Trade opened donor=%s receiver=%s", tostring(donor), tostring(receiver))
end

function Runtime:OnTradeAccept(playerAccepted, targetAccepted)
    local open = self.openTrade
    if not open then return end
    if tonumber(playerAccepted) == 1 and tonumber(targetAccepted) == 1 then
        open.both = true
        self:CaptureTargetSlots()
    end
end

function Runtime:OnTradeClosed()
    local open = self.openTrade
    local pending = self.pendingTrade
    self.openTrade = nil
    self.pendingTrade = nil
    if not open then return end
    if open.role == "receiver" and open.both then
        local Workflow = SF.ConsumablesWorkflow
        local events = Workflow and Workflow.TradeEvents(open.frozen, open.target or {}, true) or {}
        local profile = self:ProfileById(open.frozen and open.frozen.profileId)
        if profile and #events > 0 then
            self:Commit(profile, open.frozen.token or self:NextToken("trade"), events)
        elseif not profile and #events > 0 then
            Debug("Warn", "Skipped trade commit because profile %s is gone", tostring(open.frozen and open.frozen.profileId))
        end
    elseif open.role == "donor" and pending and type(pending.remainder) == "table" and #pending.remainder > 0 then
        Info("Some raid supplies did not fit in this trade. Trade again to hand over the rest.")
    end
end

function Runtime:BeginDeposit(line, collected)
    local C = SF.Consumables
    local profile = collected.profile
    local have = (self.bagCounts and self.bagCounts[line.itemId]) or 0
    local ok, err = C.RevalidateDonation(profile, line, {
        inGroup = collected.inGroup,
        compatible = collected.compatible,
        inRange = collected.inRange,
        guildBankUsable = collected.usable,
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
    local beforeTab = (self:TabItemCounts(tab)[line.itemId]) or 0
    local beforeBags = have
    local remaining = line.quantity
    local placed = 0
    local stacks = (self.bagStacks and self.bagStacks[line.itemId]) or {}
    self.placingDeposit = true
    for i = 1, #stacks do
        if remaining <= 0 or placed >= MAX_DEPOSIT_PLACES then break end
        local stack = stacks[i]
        local take = math.min(remaining, stack.count)
        local empty = self:FirstEmptySlot(tab)
        if not empty or take <= 0 then break end
        if take < stack.count and container.SplitContainerItem then
            container.SplitContainerItem(stack.bag, stack.slot, take)
        elseif container.PickupContainerItem then
            container.PickupContainerItem(stack.bag, stack.slot)
        end
        PickupGuildBankItem(tab, empty)
        remaining = remaining - take
        placed = placed + 1
    end
    self.placingDeposit = false
    if placed <= 0 then
        Warn("Could not deposit into the configured guild bank tab.")
        return
    end
    self.depositIntent = {
        itemId = line.itemId,
        tab = tab,
        intended = line.quantity - remaining,
        beforeTab = beforeTab,
        beforeBags = beforeBags,
        token = self:NextToken("deposit"),
        profileId = profile.GetProfileId and profile:GetProfileId() or profile._profileId,
    }
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
        return
    end
    self:ScanBags()
    local guild = self:CurrentGuild()
    local cfg = C.Ensure(profile)
    local afterTab = (self:TabItemCounts(intent.tab)[intent.itemId]) or 0
    local afterBags = (self.bagCounts and self.bagCounts[intent.itemId]) or 0
    local actual, reason = Workflow.InterpretDeposit({
        guildOk = guild and cfg.guild and guild.guid == cfg.guild.guid,
        configuredTab = cfg.bankTab,
        observedTab = intent.tab,
        intendedQty = intent.intended,
        beforeTab = intent.beforeTab,
        afterTab = afterTab,
        beforeBags = intent.beforeBags,
        afterBags = afterBags,
    })
    if reason == "wrong_guild" or reason == "wrong_tab" then
        self.depositIntent = nil
        if self.depositTimer and self.depositTimer.Cancel then
            self.depositTimer:Cancel()
            self.depositTimer = nil
        end
        Warn("That deposit was not in the configured guild bank tab.")
        return
    end
    if actual <= 0 then
        if fromTimer then
            self.depositIntent = nil
            if self.depositTimer and self.depositTimer.Cancel then
                self.depositTimer:Cancel()
                self.depositTimer = nil
            end
        end
        return
    end
    self.depositIntent = nil
    if self.depositTimer and self.depositTimer.Cancel then
        self.depositTimer:Cancel()
        self.depositTimer = nil
    end
    local custody = C.CustodyFor(profile, self:SelfId(), intent.itemId)
    local events = Workflow.DepositEvents({
        generation = cfg.generation,
        itemId = intent.itemId,
        donor = self:SelfId(),
        donorAssigned = C.CrafterHasItem(profile, self:SelfId(), intent.itemId),
        requested = C.IsRequested(profile, intent.itemId),
        custodyQty = custody and custody.quantity or 0,
        timestamp = C.Now and C.Now() or nil,
    }, actual)
    self:Commit(profile, intent.token, events)
    if actual < intent.intended then
        Info(string.format("Deposited %d. The rest is still in your bags.", actual))
    end
    self:CaptureBaseline(false)
end

function Runtime:CaptureBaseline(silent)
    local profile = self:Profile()
    local C = SF.Consumables
    if not profile or not C then return end
    local cfg = C.Ensure(profile)
    if not cfg.bankTab then
        self.bankBaseline = nil
        return
    end
    self.bankBaseline = self:TabItemCounts(cfg.bankTab)
    self.bankBaselineBags = {}
    self:ScanBags()
    for itemId, qty in pairs(self.bagCounts or {}) do
        self.bankBaselineBags[itemId] = qty
    end
    if silent then
        Debug("Verbose", "Guild bank baseline captured")
    end
end

function Runtime:NoteGuildBankPickup(tab, slot)
    if self.placingDeposit then return end
    local C = SF.Consumables
    local profile = self:Profile()
    if not C or not profile or not GetGuildBankItemLink then return end
    local cfg = C.Ensure(profile)
    tab = tonumber(tab)
    slot = tonumber(slot)
    if not tab or tab ~= tonumber(cfg.bankTab) then return end
    local itemId = C.ItemIdFromText(GetGuildBankItemLink(tab, slot))
    if not itemId or not C.IsRequested(profile, itemId) then return end
    local count = 0
    if GetGuildBankItemInfo then
        local _, itemCount = GetGuildBankItemInfo(tab, slot)
        count = tonumber(itemCount) or 0
    end
    if count <= 0 then return end
    self:ScanBags()
    local beforeTab = (self:TabItemCounts(tab)[itemId]) or count
    self.withdrawIntent = {
        tab = tab,
        itemId = itemId,
        intended = count,
        beforeTab = beforeTab,
        beforeBags = (self.bagCounts and self.bagCounts[itemId]) or 0,
        profileId = profile.GetProfileId and profile:GetProfileId() or profile._profileId,
        token = self:NextToken("withdraw"),
    }
    if self.withdrawTimer and self.withdrawTimer.Cancel then
        self.withdrawTimer:Cancel()
    end
    if C_Timer and C_Timer.NewTimer then
        self.withdrawTimer = C_Timer.NewTimer(1.5, function()
            self.withdrawTimer = nil
            self:FinishWithdraw(true)
        end)
    end
end

function Runtime:FinishWithdraw(fromTimer)
    local intent = self.withdrawIntent
    if not intent or self.depositIntent then return end
    local profile = self:ProfileById(intent.profileId)
    local C = SF.Consumables
    local Workflow = SF.ConsumablesWorkflow
    if not profile or not C or not Workflow then
        self.withdrawIntent = nil
        if self.withdrawTimer and self.withdrawTimer.Cancel then
            self.withdrawTimer:Cancel()
            self.withdrawTimer = nil
        end
        return
    end
    self:ScanBags()
    local cfg = C.Ensure(profile)
    local afterTab = (self:TabItemCounts(intent.tab)[intent.itemId]) or 0
    local afterBags = (self.bagCounts and self.bagCounts[intent.itemId]) or 0
    local qty = Workflow.InterpretWithdraw({
        localPickup = true,
        configuredTab = cfg.bankTab,
        observedTab = intent.tab,
        intendedQty = intent.intended,
        beforeTab = intent.beforeTab,
        afterTab = afterTab,
        beforeBags = intent.beforeBags,
        afterBags = afterBags,
    })
    if qty <= 0 then
        if fromTimer then
            self.withdrawIntent = nil
            if self.withdrawTimer and self.withdrawTimer.Cancel then
                self.withdrawTimer:Cancel()
                self.withdrawTimer = nil
            end
        end
        return
    end
    self.withdrawIntent = nil
    if self.withdrawTimer and self.withdrawTimer.Cancel then
        self.withdrawTimer:Cancel()
        self.withdrawTimer = nil
    end
    local selfId = self:SelfId()
    local assignment = cfg.assignments[tostring(intent.itemId)]
    local events = Workflow.WithdrawEvents({
        requested = true,
        withdrawerIsAssignedCrafter = C.CrafterHasItem(profile, selfId, intent.itemId),
        withdrawerIsAdmin = C.IsCanonicalAdmin(profile, selfId),
        withdrawer = selfId,
        generation = cfg.generation,
        epoch = assignment and assignment.epoch or 0,
        timestamp = C.Now and C.Now() or nil,
    }, intent.itemId, qty)
    if #events > 0 then
        self:Commit(profile, intent.token, events)
    end
    self:CaptureBaseline(true)
end

function Runtime:OnBankOpened()
    local first = not self.bankOpen
    self.bankOpen = true
    self:CaptureBaseline(true)
    if first then
        self.autoReviewedThisOpen = false
        self:MaybeAutoReview()
    end
    self:RefreshReminder()
    if self.review and self.review:IsShown() then
        self:RebuildReview()
    end
end

function Runtime:OnBankClosed()
    self.bankOpen = false
    self.bankBaseline = nil
    self.bankBaselineBags = nil
    self.autoReviewedThisOpen = false
    self:RefreshReminder()
end

function Runtime:MaybeAutoReview()
    if self.autoReviewedThisOpen then return end
    self.autoReviewedThisOpen = true
    if not self:RemindersEnabled() then return end
    local C = SF.Consumables
    local Routing = SF.ConsumablesRouting
    local collected = self:Collect()
    if not C or not Routing or not collected then return end
    if C.IsCrafter(collected.profile, self:SelfId()) then return end
    local carries = false
    for i = 1, #collected.plan.lines do
        if collected.plan.lines[i].quantity > 0 then carries = true end
    end
    if not carries then return end
    if not Routing.HasActionablePath(collected.plan.lines, collected.usable) then return end
    self:ShowReview()
end

function Runtime:OnProfileChanged()
    if not self.openTrade and self.review then
        self.review:Hide()
    end
    self.qtyOverrides = {}
    self:RefreshReminder()
end

function Runtime:OnEvent(event, arg1, arg2)
    if event == "PLAYER_REGEN_ENABLED" then
        if self.mobileButtonPending then
            self:SyncMobileButton()
        end
        return
    end
    if event == "BAG_UPDATE_DELAYED" or event == "GROUP_ROSTER_UPDATE" then
        if event == "BAG_UPDATE_DELAYED" and self.depositIntent then
            self:FinishDeposit(false)
        elseif event == "BAG_UPDATE_DELAYED" and self.withdrawIntent then
            self:FinishWithdraw(false)
        end
        self:RefreshReminder()
        if self.review and self.review:IsShown() then
            self:RebuildReview()
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemId = tonumber(arg1)
        if itemId then
            self.pendingItemLoads[itemId] = nil
        end
    elseif event == "TRADE_SHOW" then
        self:OnTradeShow()
    elseif event == "TRADE_CLOSED" then
        self:OnTradeClosed()
    elseif event == "TRADE_ACCEPT_UPDATE" then
        self:OnTradeAccept(arg1, arg2)
    elseif event == "TRADE_TARGET_ITEM_CHANGED" or event == "TRADE_UPDATE" or event == "TRADE_PLAYER_ITEM_CHANGED" then
        self:CaptureTargetSlots()
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
        if self.depositIntent then
            self:FinishDeposit(false)
        elseif self.withdrawIntent then
            self:FinishWithdraw(false)
        end
    end
end

function Runtime:Init()
    if self.frame then return end
    self.qtyOverrides = {}
    self.pendingItemLoads = {}
    self.bagCounts = {}
    self.bagStacks = {}
    self.dismissed = false
    local frame = CreateFrame("Frame")
    self.frame = frame
    frame:SetScript("OnEvent", function(_, event, ...)
        self:OnEvent(event, ...)
    end)
    TryRegister(frame, "BAG_UPDATE_DELAYED")
    TryRegister(frame, "GROUP_ROSTER_UPDATE")
    TryRegister(frame, "ITEM_DATA_LOAD_RESULT")
    TryRegister(frame, "TRADE_SHOW")
    TryRegister(frame, "TRADE_CLOSED")
    TryRegister(frame, "TRADE_ACCEPT_UPDATE")
    TryRegister(frame, "TRADE_PLAYER_ITEM_CHANGED")
    TryRegister(frame, "TRADE_TARGET_ITEM_CHANGED")
    TryRegister(frame, "TRADE_UPDATE")
    TryRegister(frame, "GUILDBANKFRAME_OPENED")
    TryRegister(frame, "GUILDBANKFRAME_CLOSED")
    TryRegister(frame, "GUILDBANKBAGSLOTS_CHANGED")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    TryRegister(frame, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    TryRegister(frame, "PLAYER_REGEN_ENABLED")
    if not self.pickupHooked and type(PickupGuildBankItem) == "function" then
        self.pickupHooked = true
        local originalPickup = PickupGuildBankItem
        PickupGuildBankItem = function(tab, slot)
            self:NoteGuildBankPickup(tab, slot)
            return originalPickup(tab, slot)
        end
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
    Debug("Info", "Raid Consumables runtime initialized")
end
