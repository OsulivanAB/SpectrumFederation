-- Grab the namespace
local addonName, SF = ...

SF.LootHelperComm = SF.LootHelperComm or {}
local Comm = SF.LootHelperComm

Comm.cfg = Comm.cfg or {
    ignoreSelf          = true,
    nackPrio            = "ALERT",
    controlPrio         = "NORMAL",
    bulkPrio            = "BULK",
    logUnknownMsgType   = true,
}

Comm.PREFIX = Comm.PREFIX or {
    CONTROL = "SF_LH",
    BULK    = "SF_LHB"
}

Comm._handlers = Comm._handlers or {
    CONTROL = {},
    BULK    = {}
}

-- =====================================================================
-- Small logging helpers (ties into debug + message helpers)
-- =====================================================================

-- Function to log normal messages
-- @param fmt The format string
-- @param ... The format arguments
-- @return nil
local function DVerbose(fmt, ...)
    if SF.Debug and SF.Debug.Verbose then
        SF.Debug:Verbose("LH_COMM", fmt, ...)
    end
end

-- Function to log info messages
-- @param fmt The format string
-- @param ... The format arguments
-- @return nil
local function DInfo(fmt, ...)
    if SF.Debug and SF.Debug.Info then
        SF.Debug:Info("LH_COMM", fmt, ...)
    end
end

-- Function to log warning messages
-- @param fmt The format string
-- @param ... The format arguments
-- @return nil
local function DWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn then
        SF.Debug:Warn("LH_COMM", fmt, ...)
    end
end

-- Function to log error messages
-- @param fmt The format string
-- @param ... The format arguments
-- @return nil
local function DError(fmt, ...)
    if SF.Debug and SF.Debug.Error then
        SF.Debug:Error("LH_COMM", fmt, ...)
    end
end

-- Function to get the player's full name (name-realm)
-- @param none
-- @return The player's full name
local function PlayerFullName()
    if SF.GetPlayerFullIdentifier then
        local ok, id = pcall(function() return SF:GetPlayerFullIdentifier() end)
        if ok and id then return id end
    end
    local name, realm = UnitFullName("player")
    realm = realm or GetRealmName()
    if realm then realm = realm:gsub("%s+", "") end
    return name and realm and (name .. "-" .. realm) or (name or "unknown")
end

-- Function to check if a prefix registration was successful
-- @param res The result of the registration
-- @return true if successful, false otherwise
local function IsPrefixRegSuccess(res)
    if res == true then return true end
    if res == 0 then return true end
    return false
end

-- Function to register an addon message prefix
-- @param prefix The prefix to register
-- @return true if successful, false otherwise
function Comm:_RegisterPrefix(prefix)
    if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then
        return true
    end

    local res = C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    local ok = IsPrefixRegSuccess(res)

    if not ok then
        DWarn("RegisterAddonMessagePrefix(%s) failed; result=%s", tostring(prefix), tostring(res))
    else
        DVerbose("RegisterAddonMessagePrefix(%s) ok; result=%s", tostring(prefix), tostring(res))
    end

  return ok
end

-- Function to get the kind of message from its prefix
-- @param prefix The message prefix
-- @return The kind of message ("CONTROL", "BULK", or nil)
function Comm:_KindFromPrefix(prefix)
    if prefix == self.PREFIX.CONTROL then return "CONTROL" end
    if prefix == self.PREFIX.BULK then return "BULK" end
    return nil
end

-- =====================================================================
-- Public Comm API
-- =====================================================================

-- Function Initialize comm module: embed AceComm, register prefixes, register receive callbacks.
-- Safe to call multiple times.
function Comm:Init(opts)
    if self._inited then return end
    self._inited = true

    if type(opts) == "table" then
        for k, v in pairs(opts) do
            self.cfg[k] = v
        end
    end

    if not LibStub then
        error("LibStub not found. Ensure AceComm libs are loaded before Comm.lua")
    end

    local AceComm = LibStub("AceComm-3.0", true)
    if not AceComm then
        error("AceComm-3.0 not found. Ensure AceComm libs are loaded before Comm.lua")
    end

    -- AceComm docs recommend embedding for ergonomic usage.
    AceComm:Embed(self)

    self:_RegisterPrefix(self.PREFIX.CONTROL)
    self:_RegisterPrefix(self.PREFIX.BULK)

    self:RegisterComm(self.PREFIX.CONTROL, "OnCommReceived")
    self:RegisterComm(self.PREFIX.BULK, "OnCommReceived")

    DInfo("Comm init complete (CONTROL=%s, BULK=%s)", self.PREFIX.CONTROL, self.PREFIX.BULK)  
end

-- Function Register a message handler for a specific kind + msgType
-- @param kind string - "CONTROL" or "BULK"
-- @param msgType string - the message type to handle
-- @param fn function - the handler function to call when a message of this type is received
-- @return nil
function Comm:RegisterHandler(kind, msgType, fn)
    assert(kind == "CONTROL" or kind == "BULK", "kind must be CONTROL or BULK")
    assert(type(msgType) == "string", "msgType must be a  string")
    assert(type(fn) == "function", "fn must be a function")
    
    self._handlers[kind][msgType] = fn
end

-- Function Send a protocol-envelope message via AceComm
-- payload: nil (no payload) or table (CBOR+Base64)
-- @param kind string - "CONTROL" or "BULK"
-- @param msgType string - the message type to send
-- @param payload table or nil - the payload data to send
-- @param distribution string - the AceComm distribution method (e.g., "WHISPER
-- @param target string or nil - the target player (for WHISPER)
-- @param prio string or nil - the AceComm priority (overrides config)
-- @return true if sent, false on error
function Comm:Send(kind, msgType, payload, distribution, target, prio, opts)
    opts = opts or {}

    local SP = SF.SyncProtocol
    if not SP then 
        error("SF.SyncProtocol not loaded. Load SyncProtocol.lua before Comm.lua")
    end

    local enc
    if opts.enc then
        enc = opts.enc
    else
        -- default behavior:
        -- CONTROL: uncompressed
        -- BULK: compressed
        if kind == "BULK" and SP.CanCompress() then
            enc = SP.ENC_B64CBORZ
        else
            enc = SP.ENC_B64CBOR
        end
    end

    local prefix = (kind == "BULK") and self.PREFIX.BULK or self.PREFIX.CONTROL

    local proto = SP.PROTO_CURRENT
    local enc = SP.ENC_NONE
    local payloadStr = ""

    if payload ~= nil then
        local encoded, err = SP.EncodePayloadTable(payload, enc)

        -- Fallback: if compression chosen but unavailable, retry uncompressed
        if not encoded and enc == SP.ENC_B64CBORZ then
            enc = SP.ENC_B64CBOR
            encoded, err = SP.EncodePayloadTable(payload, enc)
        end

        if not encoded then
            DError("EncodePayloadTable failed for %s: %s", tostring(msgType), tostring(err))
            return false
        end
        payloadStr = encoded
    else
        enc = SP.ENC_NONE
    end

    local envelope = SP.PackEnvelope(msgType, proto, enc, payloadStr)

    prio = prio
        or ((kind == "BULK") and self.cfg.bulkPrio or self.cfg.controlPrio)
        or "NORMAL"

    self:SendCommMessage(prefix, envelope, distribution, target, prio)
    return true
end

-- =====================================================================
-- Receive path (AceComm callback)
-- =====================================================================

-- Function AceComm callback for incoming messages
-- @param prefix The message prefix
-- @param text The message text (envelope)
-- @param distribution The distribution method
-- @param sender The sender's full name
-- @return nil
function Comm:OnCommReceived(prefix, text, distribution, sender)
    -- Defensive guards
    if not prefix or not text or not sender then
        return
    end

    if self.cfg.ignoreSelf then
        local me = PlayerFullName()
        if me and sender == me then
            return
        end
    end

    local kind = self:_KindFromPrefix(prefix)
    if not kind then
        return
    end

    self:_HandleIncoming(kind, text, distribution, sender)
end

-- Function Internal handler for incoming messages
-- @param kind The message kind ("CONTROL" or "BULK")
-- @param text The message text (envelope)
-- @param distribution The distribution method
-- @param sender The sender's full name
-- @return nil
function Comm:_HandleIncoming(kind, text, distribution, sender)
    local SP = SF.SyncProtocol
    if not SP then
        DError("Incomming message but SF.SyncProtocol missing")
        return
    end

    -- 1) Parse Envelope
    local ok, msgType, proto, enc, payloadStr, parseErr = SP.ParseEnvelope(text)
    if not ok then
        DVerbose("Drop: bad envelope from %s (%s)", tostring(sender), tostring(parseErr))
        return
    end

    -- 2) Always allow PROTO_NACK feedback
    if msgType == SP.MSG_PROTO_NACK then
        local payload = nil
        if enc == SP.ENC_B64CBOR and payloadStr and payloadStr ~= "" then
            payload = SP.DecodePayloadTable(payloadStr)
        end
        SP.OnProtoNack(sender, payload)
        return
    end

    -- 3) Proto validation (strict safety + graceful fallback)
    local okProto = SP.ValidateProtocolVersion(proto)
    if not okProto then
        local nackEnvelope = SP.OnUnsupportedProto(sender, proto, msgType)
        if nackEnvelope then
            self:SendCommMessage(self.PREFIX.CONTROL, nackEnvelope, "WHISPER", sender, self.cfg.nackPrio or "ALERT")
        end
        return
    end

    -- 4) Decode payload
    local payload = nil
    if enc ~= SP.ENC_NONE and payloadStr and payloadStr ~= "" then
        payload, err = SP.DecodePayloadTable(payloadStr)
        if not payload then
            DError("Drop: payload decode failed from %s type=%s err=%s", tostring(sender), tostring(msgType), tostring(err))
            return
        end
    end

    -- 5) Dispatch
    self:_Dispatch(kind, msgType, sender, payload, distribution, proto)
end

-- Function Internal dispatcher for incoming messages
-- @param kind The message kind ("CONTROL" or "BULK")
-- @param msgType The message type
-- @param sender The sender's full name
-- @param payload The decoded payload table or nil
-- @param distribution The distribution method
-- @param proto The protocol version
-- @return nil
function Comm:_Dispatch(kind, msgType, sender, payload, distribution, proto)
    local fn = self._handlers[kind] and self._handlers[kind][msgType]
    if fn then 
        local ok, err = pcall(fn, sender, payload, distribution, proto)
        if not ok then
            DErr("Handler error kind=%s type=%s from=%s err=%s", tostring(kind), tostring(msgType), tostring(sender), tostring(err))
        end
        return
    end

    -- Default "bridge" into Sync.lua
    local Sync = SF.LootHelperSync
    if Sync then
        if kind == "CONTROL" and Sync.OnControlMessage then
            Sync:OnControlMessage(sender, msgType, payload, distribution)
            return
        end
        if kind == "BULK" and Sync.OnBulkMessage then
            Sync:OnBulkMessage(sender, msgType, payload, distribution)
            return
        end
    end

    if self.cfg.logUnknownMsgType then
        DVerbose("No handler for kind=%s type=%s from=%s", tostring(kind), tostring(msgType), tostring(sender))
    end
end