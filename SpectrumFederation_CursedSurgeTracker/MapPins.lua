local addonName, ns = ...

-- luacheck: globals SpectrumFederationCSTPinMixin MapCanvasDataProviderMixin MapCanvasPinMixin CreateFromMixins WorldMapFrame CooldownFrameTemplate

ns.CST = ns.CST or {}
local CST = ns.CST

CST.PIN_TEMPLATE = "SpectrumFederationCSTPinTemplate"

local function ParentAddon()
    return _G[CST.PARENT_ADDON_NAME]
end

local function DebugInfo(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Info(CST.DEBUG_CATEGORY, message, ...)
    end
end

local function DebugWarn(message, ...)
    local SF = ParentAddon()
    if SF and SF.Debug then
        SF.Debug:Warn(CST.DEBUG_CATEGORY, message, ...)
    end
end

local function MixinsReady()
    return type(CreateFromMixins) == "function"
        and type(MapCanvasDataProviderMixin) == "table"
        and type(MapCanvasPinMixin) == "table"
end

local function SafeSetAtlas(texture, atlasName)
    if not texture or type(atlasName) ~= "string" or atlasName == "" then
        return false
    end
    if texture.SetAtlas then
        local ok = pcall(texture.SetAtlas, texture, atlasName, true)
        if ok then
            return true
        end
    end
    return false
end

local function ApplyCooldownUnix(cooldown, startTime, duration)
    if not cooldown or not CST.IsFiniteNumber(startTime) or not CST.IsFiniteNumber(duration) or duration <= 0 then
        return false
    end
    if cooldown.SetCooldownUNIX then
        local ok = pcall(cooldown.SetCooldownUNIX, cooldown, startTime, duration)
        if ok then
            return true
        end
    end
    if cooldown.SetCooldown and GetTime and GetServerTime then
        local elapsed = GetServerTime() - startTime
        local startGetTime = GetTime() - elapsed
        local ok = pcall(cooldown.SetCooldown, cooldown, startGetTime, duration)
        if ok then
            return true
        end
    end
    return false
end

SpectrumFederationCSTPinMixin = {}
if MixinsReady() then
    SpectrumFederationCSTPinMixin = CreateFromMixins(MapCanvasPinMixin)
end

function SpectrumFederationCSTPinMixin:OnLoad()
    if MapCanvasPinMixin and MapCanvasPinMixin.OnLoad then
        MapCanvasPinMixin.OnLoad(self)
    end

    self:SetSize(CST.PIN_SIZE, CST.PIN_SIZE)
    if self.SetScalingLimits then
        -- Keep the pin a stable size so the ring stays centered on the icon
        -- through zoom, maximize/restore, and UI scale.
        self:SetScalingLimits(1, 1.0, 1.0)
    end
    if self.UseFrameLevelType then
        pcall(self.UseFrameLevelType, self, "PIN_FRAME_LEVEL_AREA_POI")
    end
    if self.SetPassThroughButtons then
        pcall(self.SetPassThroughButtons, self, "LeftButton", "RightButton", "MiddleButton")
    end
    self:EnableMouse(true)

    if not self.RingTexture then
        self.RingTexture = self:CreateTexture(nil, "BACKGROUND")
        self.RingTexture:SetSize(CST.RING_SIZE, CST.RING_SIZE)
        self.RingTexture:SetPoint("CENTER")
        self.RingTexture:SetTexture(CST.RING_TEXTURE)
        local color = CST.RING_COLOR_ACTIVE
        self.RingTexture:SetVertexColor(color.r, color.g, color.b, color.a)
        self.RingTexture:Hide()
    end

    if not self.RingCooldown then
        self.RingCooldown = CreateFrame("Cooldown", nil, self, "CooldownFrameTemplate")
        self.RingCooldown:SetSize(CST.RING_SIZE, CST.RING_SIZE)
        self.RingCooldown:SetPoint("CENTER")
        self.RingCooldown:SetFrameLevel(self:GetFrameLevel())
        self.RingCooldown:EnableMouse(false)
        if self.RingCooldown.SetHideCountdownNumbers then
            self.RingCooldown:SetHideCountdownNumbers(true)
        end
        if self.RingCooldown.SetDrawBling then
            self.RingCooldown:SetDrawBling(false)
        end
        if self.RingCooldown.SetDrawEdge then
            -- No rotating edge marker; the annular swipe itself is the signal.
            self.RingCooldown:SetDrawEdge(false)
        end
        if self.RingCooldown.SetUseCircularEdge then
            self.RingCooldown:SetUseCircularEdge(true)
        end
        if self.RingCooldown.SetReverse then
            -- Standard cooldown: full at start, empty at end. Confirm in-game.
            self.RingCooldown:SetReverse(false)
        end
        if self.RingCooldown.SetSwipeTexture then
            self.RingCooldown:SetSwipeTexture(CST.RING_TEXTURE)
        end
        local color = CST.RING_COLOR_INACTIVE
        if self.RingCooldown.SetSwipeColor then
            self.RingCooldown:SetSwipeColor(color.r, color.g, color.b, color.a)
        end
        self.RingCooldown:Hide()
    end

    if not self.Icon then
        self.Icon = self:CreateTexture(nil, "ARTWORK")
        self.Icon:SetSize(CST.ICON_SIZE, CST.ICON_SIZE)
        self.Icon:SetPoint("CENTER")
    end
end

function SpectrumFederationCSTPinMixin:OnAcquired(info)
    self.cstInfo = info
    if info and CST.IsUsableMapPosition(info.x, info.y) then
        self:SetPosition(info.x, info.y)
    end
    self:ApplyVisuals()
end

function SpectrumFederationCSTPinMixin:OnReleased()
    if CST.Tracker and CST.Tracker.OnPinReleased then
        CST.Tracker.OnPinReleased(self)
    end
    self.cstInfo = nil
    if self.RingCooldown then
        if self.RingCooldown.Clear then
            self.RingCooldown:Clear()
        end
        self.RingCooldown:Hide()
    end
    if self.RingTexture then
        self.RingTexture:Hide()
    end
end

function SpectrumFederationCSTPinMixin:ApplyIcon(atlasName)
    if not self.Icon then
        return
    end
    self.Icon:SetSize(CST.ICON_SIZE, CST.ICON_SIZE)
    if SafeSetAtlas(self.Icon, atlasName) then
        self.Icon:SetSize(CST.ICON_SIZE, CST.ICON_SIZE)
        self.Icon:SetVertexColor(1, 1, 1, 1)
        return
    end
    self.Icon:SetTexture(CST.NEUTRAL_FALLBACK_TEXTURE)
    self.Icon:SetVertexColor(0.85, 0.85, 0.85, 1)
    self.Icon:SetSize(CST.ICON_SIZE, CST.ICON_SIZE)
end

function SpectrumFederationCSTPinMixin:ApplyRing(info)
    if not info or not info.ringVisible then
        if self.RingTexture then
            self.RingTexture:Hide()
        end
        if self.RingCooldown then
            if self.RingCooldown.Clear then
                self.RingCooldown:Clear()
            end
            self.RingCooldown:Hide()
        end
        return
    end

    if info.ringMode == "active" then
        if self.RingCooldown then
            if self.RingCooldown.Clear then
                self.RingCooldown:Clear()
            end
            self.RingCooldown:Hide()
        end
        if self.RingTexture then
            local color = CST.RING_COLOR_ACTIVE
            self.RingTexture:SetVertexColor(color.r, color.g, color.b, color.a)
            self.RingTexture:Show()
        end
        return
    end

    -- Inactive: native cooldown animates the annular swipe from full to empty.
    if self.RingTexture then
        self.RingTexture:Hide()
    end
    if self.RingCooldown then
        local previousEnd = info.previousEndTime
        local nextStart = info.next and info.next.startTime
        local duration = nil
        if CST.IsFiniteNumber(previousEnd) and CST.IsFiniteNumber(nextStart) then
            duration = nextStart - previousEnd
        end
        if ApplyCooldownUnix(self.RingCooldown, previousEnd, duration) then
            self.RingCooldown:Show()
        else
            self.RingCooldown:Hide()
        end
    end
end

function SpectrumFederationCSTPinMixin:ApplyVisuals()
    local info = self.cstInfo
    if not info then
        return
    end
    self:ApplyIcon(info.atlas)
    self:ApplyRing(info)
end

function SpectrumFederationCSTPinMixin:OnMouseEnter()
    if CST.Tracker and CST.Tracker.OnPinEnter then
        CST.Tracker.OnPinEnter(self)
    end
end

function SpectrumFederationCSTPinMixin:OnMouseLeave()
    if CST.Tracker and CST.Tracker.OnPinLeave then
        CST.Tracker.OnPinLeave(self)
    end
end

-- Some MapCanvas pin pools call OnEnter/OnLeave instead of OnMouseEnter/Leave.
function SpectrumFederationCSTPinMixin:OnEnter()
    self:OnMouseEnter()
end

function SpectrumFederationCSTPinMixin:OnLeave()
    self:OnMouseLeave()
end

local DataProvider = nil

local function AttachDataProviderMethods(provider)
    function provider:RemoveAllData()
        local map = self.GetMap and self:GetMap()
        if map and map.RemoveAllPinsByTemplate then
            map:RemoveAllPinsByTemplate(CST.PIN_TEMPLATE)
        end
    end

    function provider:RefreshAllData()
        self:RemoveAllData()
        if not (CST.Tracker and CST.Tracker.ShouldShowPins and CST.Tracker.ShouldShowPins()) then
            if CST.Tracker and CST.Tracker.OnPinsHidden then
                CST.Tracker.OnPinsHidden()
            end
            return
        end

        local map = self:GetMap()
        if not map then
            return
        end
        local displayedMapID = map.GetMapID and map:GetMapID()
        if displayedMapID ~= CST.COILED_ISLE_MAP_ID then
            if CST.Tracker and CST.Tracker.OnPinsHidden then
                CST.Tracker.OnPinsHidden()
            end
            return
        end

        local pinInfos = CST.Tracker.GetPinInfos and CST.Tracker.GetPinInfos() or {}
        for index = 1, #pinInfos do
            local info = pinInfos[index]
            if info and CST.IsUsableMapPosition(info.x, info.y) and map.AcquirePin then
                map:AcquirePin(CST.PIN_TEMPLATE, info)
            end
        end

        if CST.Tracker and CST.Tracker.OnPinsShown then
            CST.Tracker.OnPinsShown()
        end
    end

    function provider:OnRemoved(mapCanvas)
        self:RemoveAllData()
        if MapCanvasDataProviderMixin.OnRemoved then
            MapCanvasDataProviderMixin.OnRemoved(self, mapCanvas)
        end
    end
end

local function EnsureDataProvider()
    if DataProvider then
        return DataProvider
    end
    if not MixinsReady() then
        return nil
    end
    if not SpectrumFederationCSTPinMixin.SetPosition and MapCanvasPinMixin then
        local methods = SpectrumFederationCSTPinMixin
        SpectrumFederationCSTPinMixin = CreateFromMixins(MapCanvasPinMixin)
        for key, value in pairs(methods) do
            SpectrumFederationCSTPinMixin[key] = value
        end
    end
    DataProvider = CreateFromMixins(MapCanvasDataProviderMixin)
    AttachDataProviderMethods(DataProvider)
    CST.MapPins.provider = DataProvider
    return DataProvider
end

CST.MapPins = CST.MapPins or {}
local MapPins = CST.MapPins
MapPins.provider = DataProvider
MapPins.registered = false
MapPins.waitingForWorldMap = false

local loadFrame = nil

local function RegisterProvider()
    if MapPins.registered then
        return true
    end
    EnsureDataProvider()
    if not DataProvider then
        DebugWarn("MapCanvas mixins are not available yet")
        return false
    end
    if not WorldMapFrame or not WorldMapFrame.AddDataProvider then
        return false
    end
    WorldMapFrame:AddDataProvider(DataProvider)
    MapPins.registered = true
    DebugInfo("Registered World Map data provider")
    if WorldMapFrame:IsShown() and DataProvider.RefreshAllData then
        DataProvider:RefreshAllData()
    end
    return true
end

local function UnregisterProvider()
    MapPins.waitingForWorldMap = false
    if loadFrame then
        loadFrame:UnregisterEvent("ADDON_LOADED")
    end
    if not MapPins.registered then
        return
    end
    if DataProvider and DataProvider.RemoveAllData then
        DataProvider:RemoveAllData()
    end
    if WorldMapFrame and WorldMapFrame.RemoveDataProvider then
        pcall(WorldMapFrame.RemoveDataProvider, WorldMapFrame, DataProvider)
    end
    MapPins.registered = false
    DebugInfo("Removed World Map data provider")
end

local function IsWorldMapLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded("Blizzard_WorldMap") and true or false
    end
    return WorldMapFrame ~= nil
end

function MapPins.Prepare()
    if MapPins.registered then
        return
    end
    if not MixinsReady() then
        DebugWarn("MapCanvas mixins are not available yet")
    end
    if IsWorldMapLoaded() then
        RegisterProvider()
        return
    end
    if MapPins.waitingForWorldMap then
        return
    end
    MapPins.waitingForWorldMap = true
    if not loadFrame then
        loadFrame = CreateFrame("Frame")
        loadFrame:SetScript("OnEvent", function(_, _, loadedName)
            if loadedName == "Blizzard_WorldMap" then
                loadFrame:UnregisterEvent("ADDON_LOADED")
                MapPins.waitingForWorldMap = false
                if CST.Tracker and CST.Tracker.IsPlayerOnCoiledIsle and CST.Tracker.IsPlayerOnCoiledIsle() then
                    RegisterProvider()
                end
            end
        end)
    end
    loadFrame:RegisterEvent("ADDON_LOADED")
end

function MapPins.Teardown()
    UnregisterProvider()
end

function MapPins.Refresh()
    if not MapPins.registered or not DataProvider then
        return
    end
    DataProvider:RefreshAllData()
end

function MapPins.IsRegistered()
    return MapPins.registered == true
end

function MapPins.GetDisplayedMapID()
    if WorldMapFrame and WorldMapFrame.GetMapID then
        return WorldMapFrame:GetMapID()
    end
    return nil
end

function MapPins.IsWorldMapVisible()
    return WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown() and true or false
end
