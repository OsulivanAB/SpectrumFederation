-- Public API surface for Guild Gossip Phase 1.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

--- Initialize the gossip engine (idempotent). Safe without an active Loot Helper profile.
function GG:Initialize(opts)
    return GG.Init(opts)
end

--- Register a gossip provider. See docs/development/guild-gossip/ for the contract.
function GG:Register(spec)
    return GG.RegisterProvider(spec)
end

function GG:Unregister(providerId)
    return GG.UnregisterProvider(providerId)
end

function GG:EnableProvider(providerId)
    return GG.SetProviderEnabled(providerId, true)
end

function GG:DisableProvider(providerId)
    return GG.SetProviderEnabled(providerId, false)
end

--- Explicit synthetic-provider activation for Retail smoke / developer tests.
--- Disabled by default. Records stay in runtime-only synthetic stores.
function GG:EnableSynthetic(opts)
    GG.Init()
    return GG.EnableSyntheticProvider(opts)
end

function GG:DisableSynthetic(providerId)
    return GG.DisableSyntheticProvider(providerId)
end

function GG:IsReady()
    return GG.IsGuildReady() and (SF.LootHelperComm and SF.LootHelperComm._ready) and true or false
end

function GG:HasWork()
    return GG.HasActiveProvider()
end

function GG:GetStats()
    local stats = GG.GetEngineStats()
    local guard = GG.GetReceiveGuardStats and GG.GetReceiveGuardStats() or {}
    stats.mode = GG.GetSchedMode and GG.GetSchedMode() or "SLOW"
    stats.paused = GG.IsSchedPaused and GG.IsSchedPaused() or false
    stats.partialCount = guard.partialCount
    stats.partialBytes = guard.partialBytes
    stats.activeProviders = GG._providers and GG._providers.activeCount or 0
    return stats
end
