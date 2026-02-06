-- modules/CraftingOrdersScan.lua
-- Cross-Expansion Crafting Orders Scan Feature
--
-- This module adds a manual "Scan All" button to the Blizzard Professions → Crafting Orders UI
-- that scans crafter orders across all expansion child skill lines for the currently opened profession.
--
-- Non-goals (scope creep blockers):
-- - No custom results window / scroll list / new frames to show orders
-- - No continuous scan / periodic scanning / auto-run on open
-- - No persistent storage/database of scanned orders (in-memory only)
-- - No protected/hardware-event APIs to open professions
-- - No Blizzard XML edits

local addonName, SF = ...

SF.CraftingOrdersScan = SF.CraftingOrdersScan or {}
local COS = SF.CraftingOrdersScan

-- Constants
local CATEGORY = "CraftingOrdersScan"
local BUTTON_TEXT_SCAN = "Scan All"
local BUTTON_TEXT_SCANNING = "Scanning..."
local SCAN_TIMEOUT_SECONDS = 7

-- Module state
local initialized = false
local scanButton = nil
local scanState = nil

-- Event frame for handling WoW events
local eventFrame = CreateFrame("Frame")

-- ============================================================================
-- Helpers
-- ============================================================================

-- Check if the feature is enabled via settings
-- @return boolean True if enabled, false otherwise
local function IsFeatureEnabled()
	local store = SF.SettingsStore
	if not store then return false end
	return store:Get("global.enable_cross_expansion_crafting_orders_scan_button") == true
end

-- Get the Crafting Orders host frame (the main frame we'll attach our button to)
-- @return Frame|nil The Crafting Orders page frame, or nil if not found
local function GetCraftingOrdersHostFrame()
	if not ProfessionsFrame then return nil end
	if not ProfessionsFrame.OrdersPage then return nil end
	return ProfessionsFrame.OrdersPage
end

-- Check if we're currently viewing the Crafting Orders page
-- @return boolean True if on Crafting Orders page, false otherwise
local function IsOnCraftingOrdersPage()
	if not ProfessionsFrame then return false end
	if not ProfessionsFrame:IsShown() then return false end
	
	local ordersPage = GetCraftingOrdersHostFrame()
	if not ordersPage then return false end
	
	return ordersPage:IsShown()
end

-- Build list of child skill line IDs for the current profession
-- @return table|nil Array of skill line IDs, or nil on error
-- @return string|nil Error message if failed
local function BuildChildSkillLineIDsForCurrentProfession()
	-- Get current profession info
	local tradeSkillLineID = C_TradeSkillUI.GetTradeSkillLine()
	if not tradeSkillLineID then
		return nil, "No profession is currently open"
	end

	-- Get profession info to find the parent profession family
	local profInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID(tradeSkillLineID)
	if not profInfo or not profInfo.professionID then
		return nil, "Could not get profession info for skill line " .. tostring(tradeSkillLineID)
	end

	local targetProfessionID = profInfo.professionID

	-- Enumerate all profession trade skill lines
	local allLines = C_TradeSkillUI.GetAllProfessionTradeSkillLines()
	if not allLines then
		return nil, "Could not enumerate profession trade skill lines"
	end

	-- Filter to those matching our profession family
	local childSkillLineIDs = {}
	for _, lineID in ipairs(allLines) do
		local lineInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID(lineID)
		if lineInfo and lineInfo.professionID == targetProfessionID then
			table.insert(childSkillLineIDs, lineID)
		end
	end

	if #childSkillLineIDs == 0 then
		return nil, "No child skill lines found for profession " .. tostring(targetProfessionID)
	end

	-- Sort for determinism
	table.sort(childSkillLineIDs)

	return childSkillLineIDs, nil
end

-- Build list of order types to scan
-- @return table Array of order type enums
local function BuildOrderTypeList()
	local orderTypes = {}
	
	-- Always include these
	table.insert(orderTypes, Enum.CraftingOrderType.Public)
	table.insert(orderTypes, Enum.CraftingOrderType.Guild)
	table.insert(orderTypes, Enum.CraftingOrderType.Personal)
	
	-- Include Npc (Patron) if available
	if Enum.CraftingOrderType.Npc then
		table.insert(orderTypes, Enum.CraftingOrderType.Npc)
	end
	
	return orderTypes
end

-- Get display name for order type
-- @param orderType number Order type enum value
-- @return string Display name
local function GetOrderTypeName(orderType)
	if orderType == Enum.CraftingOrderType.Public then
		return "Public"
	elseif orderType == Enum.CraftingOrderType.Guild then
		return "Guild"
	elseif orderType == Enum.CraftingOrderType.Personal then
		return "Personal"
	elseif orderType == Enum.CraftingOrderType.Npc then
		return "Patron"
	else
		return "Unknown(" .. tostring(orderType) .. ")"
	end
end

-- ============================================================================
-- Scan State Machine
-- ============================================================================

-- Initialize scan state
-- @return table|nil Initialized state, or nil on error
-- @return string|nil Error message if failed
local function InitializeScanState()
	-- Verify profession is open
	local tradeSkillLineID = C_TradeSkillUI.GetTradeSkillLine()
	if not tradeSkillLineID then
		return nil, "No profession is currently open"
	end

	-- Get current child skill line to restore later
	local originalChildSkillLineID = C_TradeSkillUI.GetProfessionChildSkillLineID()

	-- Build expansion list
	local childSkillLineIDs, err = BuildChildSkillLineIDsForCurrentProfession()
	if not childSkillLineIDs then
		return nil, err
	end

	-- Build order types list
	local orderTypes = BuildOrderTypeList()

	-- Get profession name for logging
	local profInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID(tradeSkillLineID)
	local professionName = (profInfo and profInfo.professionName) or "Unknown"
	local professionID = (profInfo and profInfo.professionID) or "Unknown"

	local state = {
		running = true,
		startedAt = GetTime(),
		professionName = professionName,
		professionID = professionID,
		parentSkillLineID = tradeSkillLineID,
		originalChildSkillLineID = originalChildSkillLineID,
		childSkillLineIDs = childSkillLineIDs,
		orderTypes = orderTypes,
		skillIdx = 1,
		orderIdx = 1,
		offset = 0,
		results = {},
		requestCallback = nil,
		timeoutTimer = nil,
		dumpedShape = false,
	}

	-- Initialize results structure
	for _, skillLineID in ipairs(childSkillLineIDs) do
		state.results[skillLineID] = {}
		for _, orderType in ipairs(orderTypes) do
			state.results[skillLineID][orderType] = {
				total = 0,
				pages = 0,
				lastDisplayBuckets = false,
			}
		end
	end

	return state, nil
end

-- Abort the current scan
-- @param reason string Reason for abort
local function AbortScan(reason)
	if not scanState or not scanState.running then
		return
	end

	SF.Debug:Warn(CATEGORY, "Aborting scan: %s", tostring(reason))

	-- Cancel timeout timer
	if scanState.timeoutTimer then
		scanState.timeoutTimer:Cancel()
		scanState.timeoutTimer = nil
	end

	-- Cancel callback
	if scanState.requestCallback then
		scanState.requestCallback:Cancel()
		scanState.requestCallback = nil
	end

	-- Restore original child skill line
	if scanState.originalChildSkillLineID then
		pcall(C_TradeSkillUI.SetProfessionChildSkillLineID, scanState.originalChildSkillLineID)
	end

	-- Log partial results
	local duration = GetTime() - scanState.startedAt
	SF.Debug:Info(CATEGORY, "Scan aborted after %.1fs - partial results available", duration)

	-- Reset state
	scanState.running = false
	scanState = nil

	-- Re-enable button
	if scanButton then
		scanButton:SetEnabled(true)
		scanButton:SetText(BUTTON_TEXT_SCAN)
	end

	-- User message
	SF:PrintWarning("Crafting Orders scan aborted: " .. reason)
end

-- Finish the scan successfully
local function FinishScan()
	if not scanState or not scanState.running then
		return
	end

	local duration = GetTime() - scanState.startedAt

	SF.Debug:Info(CATEGORY, "Scan completed in %.1fs", duration)

	-- Calculate totals per order type
	local totals = {}
	for _, orderType in ipairs(scanState.orderTypes) do
		totals[orderType] = 0
	end

	local expansionCount = #scanState.childSkillLineIDs

	-- Sum up results
	for skillLineID, skillResults in pairs(scanState.results) do
		for orderType, data in pairs(skillResults) do
			totals[orderType] = (totals[orderType] or 0) + data.total
			SF.Debug:Info(CATEGORY, "  SkillLine %d, %s: %d orders (%d pages)",
				skillLineID, GetOrderTypeName(orderType), data.total, data.pages)
		end
	end

	-- Build summary message
	local summaryParts = {}
	for _, orderType in ipairs(scanState.orderTypes) do
		local count = totals[orderType] or 0
		table.insert(summaryParts, GetOrderTypeName(orderType) .. ": " .. count)
	end
	local summary = table.concat(summaryParts, ", ")

	-- Restore original child skill line
	if scanState.originalChildSkillLineID then
		pcall(C_TradeSkillUI.SetProfessionChildSkillLineID, scanState.originalChildSkillLineID)
	end

	-- User message
	SF:PrintSuccess(string.format("Scan complete: %d expansions scanned — %s (see debug for details)", 
		expansionCount, summary))

	-- Reset state
	scanState.running = false
	scanState = nil

	-- Re-enable button
	if scanButton then
		scanButton:SetEnabled(true)
		scanButton:SetText(BUTTON_TEXT_SCAN)
	end
end

-- Request the next page in the scan sequence
local function RequestNext()
	if not scanState or not scanState.running then
		return
	end

	-- Check if we're done
	if scanState.skillIdx > #scanState.childSkillLineIDs then
		FinishScan()
		return
	end

	local skillLineID = scanState.childSkillLineIDs[scanState.skillIdx]
	
	-- Check if done with current skill line
	if scanState.orderIdx > #scanState.orderTypes then
		-- Move to next skill line
		scanState.skillIdx = scanState.skillIdx + 1
		scanState.orderIdx = 1
		scanState.offset = 0
		RequestNext()
		return
	end

	local orderType = scanState.orderTypes[scanState.orderIdx]

	-- Switch to the appropriate child skill line
	pcall(C_TradeSkillUI.SetProfessionChildSkillLineID, skillLineID)

	-- Get profession enum for request
	local childProfInfo = C_TradeSkillUI.GetChildProfessionInfo()
	if not childProfInfo or not childProfInfo.profession then
		AbortScan("Could not get child profession info for skill line " .. tostring(skillLineID))
		return
	end

	local professionEnum = childProfInfo.profession

	SF.Debug:Verbose(CATEGORY, "Requesting: skillLineID=%d, orderType=%s, offset=%d, profession=%d",
		skillLineID, GetOrderTypeName(orderType), scanState.offset, professionEnum)

	-- Create callback
	local callback = C_FunctionContainers.CreateCallback(function(result, returnedOrderType, displayBuckets, expectMoreRows, offset, isSorted)
		-- Cancel timeout
		if scanState and scanState.timeoutTimer then
			scanState.timeoutTimer:Cancel()
			scanState.timeoutTimer = nil
		end

		if not scanState or not scanState.running then
			return
		end

		SF.Debug:Verbose(CATEGORY, "Callback: result=%s, displayBuckets=%s, expectMoreRows=%s, offset=%d",
			tostring(result), tostring(displayBuckets), tostring(expectMoreRows), offset)

		local count = 0

		-- Count orders/buckets
		if displayBuckets then
			local buckets = C_CraftingOrders.GetCrafterBuckets()
			if buckets then
				-- Dump shape once for debugging
				if not scanState.dumpedShape and #buckets > 0 then
					SF.Debug:Verbose(CATEGORY, "First bucket shape: %s", tostring(buckets[1].orderType))
					scanState.dumpedShape = true
				end

				for _, bucket in ipairs(buckets) do
					-- Each bucket may have a count field; sum them if available
					-- Otherwise just count the buckets themselves
					if bucket.numOrders then
						count = count + bucket.numOrders
					else
						count = count + 1
					end
				end
			end
		else
			local orders = C_CraftingOrders.GetCrafterOrders()
			if orders then
				-- Dump shape once for debugging
				if not scanState.dumpedShape and #orders > 0 then
					SF.Debug:Verbose(CATEGORY, "First order shape: orderType=%s", tostring(orders[1].orderType))
					scanState.dumpedShape = true
				end
				count = #orders
			end
		end

		-- Update results
		local skillLineID = scanState.childSkillLineIDs[scanState.skillIdx]
		local orderType = scanState.orderTypes[scanState.orderIdx]
		local resultEntry = scanState.results[skillLineID][orderType]
		
		resultEntry.total = resultEntry.total + count
		resultEntry.pages = resultEntry.pages + 1
		resultEntry.lastDisplayBuckets = displayBuckets

		SF.Debug:Verbose(CATEGORY, "  Added %d items (total now %d for this type)", count, resultEntry.total)

		-- Handle pagination
		if expectMoreRows then
			-- More pages for this order type
			scanState.offset = scanState.offset + count
			RequestNext()
		else
			-- Done with this order type, move to next
			scanState.orderIdx = scanState.orderIdx + 1
			scanState.offset = 0
			RequestNext()
		end
	end)

	scanState.requestCallback = callback

	-- Start timeout timer
	scanState.timeoutTimer = C_Timer.NewTimer(SCAN_TIMEOUT_SECONDS, function()
		if scanState and scanState.running then
			AbortScan("Request timeout (no response after " .. SCAN_TIMEOUT_SECONDS .. "s)")
		end
	end)

	-- Build request
	local request = {
		orderType = orderType,
		forCrafter = true,
		offset = scanState.offset,
		profession = professionEnum,
		callback = callback,
	}

	-- Make request
	C_CraftingOrders.RequestCrafterOrders(request)
end

-- Start a new scan
local function StartScan()
	-- Prevent multiple scans
	if scanState and scanState.running then
		SF:PrintInfo("A scan is already in progress")
		return
	end

	-- Initialize scan state
	local state, err = InitializeScanState()
	if not state then
		SF:PrintError("Cannot start scan: " .. tostring(err))
		return
	end

	scanState = state

	SF.Debug:Info(CATEGORY, "Starting scan: profession=%s (ID=%s), parent=%d, %d expansions, %d order types",
		state.professionName, tostring(state.professionID), state.parentSkillLineID,
		#state.childSkillLineIDs, #state.orderTypes)

	-- Disable button
	if scanButton then
		scanButton:SetEnabled(false)
		scanButton:SetText(BUTTON_TEXT_SCANNING)
	end

	-- Start scan
	RequestNext()
end

-- ============================================================================
-- Button Management
-- ============================================================================

-- Update button enabled state based on game conditions
local function UpdateButtonEnabled()
	if not scanButton then return end

	-- Disable if scan is running
	if scanState and scanState.running then
		scanButton:SetEnabled(false)
		return
	end

	-- Check if orders can be requested
	local canRequest = C_CraftingOrders.CanRequestCrafterOrders()
	scanButton:SetEnabled(canRequest)
end

-- Attach the scan button to the Crafting Orders UI
local function AttachButton()
	if scanButton then
		-- Already attached
		return
	end

	local hostFrame = GetCraftingOrdersHostFrame()
	if not hostFrame then
		SF.Debug:Verbose(CATEGORY, "Cannot attach button: host frame not found")
		return
	end

	-- Create button
	local btn = CreateFrame("Button", nil, hostFrame, "UIPanelButtonTemplate")
	btn:SetSize(80, 22)
	btn:SetText(BUTTON_TEXT_SCAN)

	-- Try to anchor near search area; fallback to safe top-right
	local searchBox = hostFrame.SearchBox
	if searchBox then
		btn:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
		SF.Debug:Info(CATEGORY, "Button attached next to SearchBox")
	else
		btn:SetPoint("TOPRIGHT", hostFrame, "TOPRIGHT", -10, -10)
		SF.Debug:Info(CATEGORY, "Button attached to top-right (SearchBox not found)")
	end

	btn:SetScript("OnClick", function()
		StartScan()
	end)

	scanButton = btn

	-- Initial state
	UpdateButtonEnabled()
end

-- Remove the scan button
local function RemoveButton()
	if not scanButton then
		return
	end

	SF.Debug:Verbose(CATEGORY, "Removing scan button")

	scanButton:Hide()
	scanButton:SetParent(nil)
	scanButton = nil
end

-- Refresh button visibility based on settings and UI state
local function RefreshButtonState()
	local enabled = IsFeatureEnabled()
	local onPage = IsOnCraftingOrdersPage()

	if enabled and onPage then
		AttachButton()
	else
		RemoveButton()
	end
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

-- Handle ADDON_LOADED event
local function OnAddonLoaded(loadedAddonName)
	if loadedAddonName == "Blizzard_Professions" then
		SF.Debug:Verbose(CATEGORY, "Blizzard_Professions loaded")
		RefreshButtonState()
	end
end

-- Handle Crafting Orders can request state change
local function OnCraftingOrdersCanRequest()
	UpdateButtonEnabled()
end

-- Handle UI visibility changes
local function OnUIVisibilityChanged()
	-- Refresh button state when UI visibility changes
	RefreshButtonState()

	-- If we're scanning and the UI closes, abort
	if scanState and scanState.running and not IsOnCraftingOrdersPage() then
		AbortScan("Professions UI closed")
	end
end

-- Handle combat state changes
local function OnCombatStateChanged(inCombat)
	if inCombat and scanState and scanState.running then
		-- Abort scan if entering combat
		AbortScan("Entered combat")
	end
end

-- ============================================================================
-- Module Initialization
-- ============================================================================

-- Initialize the module
function COS:Init()
	if initialized then
		return
	end

	SF.Debug:Info(CATEGORY, "Initializing CraftingOrdersScan module")

	-- Register events
	eventFrame:RegisterEvent("ADDON_LOADED")
	eventFrame:RegisterEvent("CRAFTINGORDERS_CAN_REQUEST")
	eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

	eventFrame:SetScript("OnEvent", function(self, event, ...)
		if event == "ADDON_LOADED" then
			OnAddonLoaded(...)
		elseif event == "CRAFTINGORDERS_CAN_REQUEST" then
			OnCraftingOrdersCanRequest()
		elseif event == "PLAYER_REGEN_DISABLED" then
			OnCombatStateChanged(true)
		elseif event == "PLAYER_REGEN_ENABLED" then
			OnCombatStateChanged(false)
		end
	end)

	-- Hook into ProfessionsFrame to detect page changes
	if ProfessionsFrame then
		-- Try to hook the show/hide events
		hooksecurefunc(ProfessionsFrame, "Show", OnUIVisibilityChanged)
		hooksecurefunc(ProfessionsFrame, "Hide", OnUIVisibilityChanged)
		
		-- If OrdersPage exists, hook it too
		if ProfessionsFrame.OrdersPage then
			hooksecurefunc(ProfessionsFrame.OrdersPage, "Show", OnUIVisibilityChanged)
			hooksecurefunc(ProfessionsFrame.OrdersPage, "Hide", OnUIVisibilityChanged)
		end
	end

	-- Register callback for settings changes
	local store = SF.SettingsStore
	if store and store.RegisterCallback then
		store:RegisterCallback("global.enable_cross_expansion_crafting_orders_scan_button", function(newValue)
			SF.Debug:Info(CATEGORY, "Setting toggled: %s", tostring(newValue))
			
			-- Abort scan if turning off mid-scan
			if not newValue and scanState and scanState.running then
				AbortScan("Feature disabled via settings")
			end
			
			RefreshButtonState()
		end)
	end

	initialized = true

	SF.Debug:Info(CATEGORY, "CraftingOrdersScan module initialized")
end

-- Expose the initialization function for external use
function COS:RefreshEnabledState()
	RefreshButtonState()
end
