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

    queueEnabled        = true,

    -- hard caps (bounded memory)
    maxQueue            = 200,
    maxPerTarget       = 50,

    -- pacing
    pumpIntervalSec         = 0.03, -- How often we try to send
    perTargetMinIntervalSec = 0.06, -- per-target spacing
    maxSendsPerPump         = 1,    -- keep frames cheap
}

Comm.PREFIX = Comm.PREFIX or {
    CONTROL = "SF_LH",
    BULK    = "SF_LHB"
}

Comm._handlers = Comm._handlers or {
    CONTROL = {},
    BULK    = {}
}

Comm.state = Comm.state or {
    total       = 0,
    byKey       = {},   -- [targetKey] = {items... }
    keys        = {},   -- round-robin list of keys
    rr          = 0,
    lastSent    = {},   -- [targetKey] = timestamp
    ticker      = nil,
}

-- Function to get the current time in seconds
-- @param none
-- @return current time in seconds
local function _CommNow()
    return (GetTime and GetTime()) or time()
end

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
	if SF.NameUtil and SF.NameUtil.GetSelfId then
		return SF.NameUtil.GetSelfId()
	end
	-- Fallback
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

    -- Set ready flag after successful registration
    self._ready = true

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
-- @param channelKey string - the target channel key (for logging/tracking)
-- @param msgType string - the message type to send
-- @param payload table or nil - the payload data to send
-- @param distribution string - the AceComm distribution method (e.g., "WHISPER
-- @param target string or nil - the target player (for WHISPER)
-- @param prio string or nil - the AceComm priority (overrides config)
-- @return true if sent, false on error
function Comm:Send(channelKey, msgType, payload, distribution, target, prio, opts)
    if not self._ready then return false end

    local SP = SF and SF.SyncProtocol
    if not SP then
        if SF and SF.PrintWarning then
            SF:PrintWarning("Cannot send message: SyncProtocol not initialized")
        end
        DError("Cannot send: SF.SyncProtocol missing")
        return false
    end

    local prefix = (channelKey == "BULK") and self.PREFIX.BULK or self.PREFIX.CONTROL
    local proto = SP.PROTO_CURRENT
    local enc = (opts and opts.enc) or SP.ENC_B64CBOR

    local payloadStr = ""
    if payload == nil or next(payload) == nil then
        enc = SP.ENC_NONE
        payloadStr = ""
    else
        local err
        payloadStr, err = SP.EncodePayloadTable(payload, enc)
        if not payloadStr then
            DError("Payload encode failed: %s", tostring(err))
            return false
        end
    end

    local envelope = SP.PackEnvelope(msgType, proto, enc, payloadStr)
    if not envelope then
        DError("PackEnvelope failed")
        return false
    end

    local msg = envelope
    
    -- Resolve priority: use explicit prio, fall back to config based on channel
    if not prio then
        prio = (channelKey == "BULK") and self.cfg.bulkPrio or self.cfg.controlPrio
    end
    
    DVerbose("Send: channelKey=%s type=%s prio=%s dist=%s target=%s", 
        tostring(channelKey), tostring(msgType), tostring(prio), 
        tostring(distribution), tostring(target or "nil"))
    
    local callback = opts and opts.callback or nil

    -- By default: queue BULK; CONTROL sends immediately
    local shouldQueue = (channelKey == "BULK") or (opts and opts.queue == true)
    if shouldQueue and not (opts and opts.immediate) then
        return self:_EnqueueSend(prefix, msg, distribution, target, prio, callback)
    end

    self:SendCommMessage(prefix, msg, distribution, target, prio, callback)
    return true
end

-- Function Generate a target key string for tracking
-- @param distribution string - the AceComm distribution method
-- @param target string or nil - the target player (for WHISPER)
-- @return string - the target key
function Comm:_TargetKey(distribution, target)
    if distribution == "WHISPER" then
        return "WHISPER:" .. tostring(target or "")
    end
    return tostring(distribution or "UNKNOWN")
end

-- Function Ensure the queue pump ticker is running
-- @param none
-- @return nil
function Comm:_EnsureTicker()
    if not self.cfg.queueEnabled then return end
    if self.state.ticker then return end
    if not C_Timer or not C_Timer.NewTicker then return end

    local interval = tonumber(self.cfg.pumpIntervalSec) or 0.03
    self.state.ticker = C_Timer.NewTicker(interval, function()
        if not self._ready then return end
        self:_PumpQueue()
    end)
end

-- Function Enqueue a message for sending later
-- @param prefix string - the message prefix
-- @param msg string - the message to send
-- @param distribution string - the AceComm distribution method
-- @param target string or nil - the target player (for WHISPER)
-- @param prio string - the AceComm priority
-- @param callback function or nil - the callback function for SendCommMessage
-- @return true if enqueued, false if dropped
function Comm:_EnqueueSend(prefix, msg, distribution, target, prio, callback)
    if not self.cfg.queueEnabled then
        self:SendCommMessage(prefix, msg, distribution, target, prio, callback)
        return true
    end

    local st = self.state
    local maxQ = tonumber(self.cfg.maxQueue) or 200
    if (st.total or 0) >= maxQ then
        if SF and SF.PrintWarning then
            SF:PrintWarning(("Comm queue full (%d/%d): dropping message"):format(st.total, maxQ))
        end
        return false
    end

    local key = self:_TargetKey(distribution, target)
    local q = st.byKey[key]
    if not q then
        q = {}
        st.byKey[key] = q
        table.insert(st.keys, key)
    end

    local maxPer = tonumber(self.cfg.maxPerTarget) or 50
    if #q >= maxPer then
        if SF and SF.PrintWarning then
            SF:PrintWarning(("Comm per-target queue full for %s (%d/%d): dropping message"):format(tostring(key), #q, maxPer))
        end
        return false
    end

    table.insert(q, {
        prefix      = prefix,
        msg         = msg,
        dist        = distribution,
        target      = target,
        prio        = prio,
        callback    = callback,
    })

    st.total = (st.total or 0) + 1

    self:_EnsureTicker()
    return true
end

-- Function Pump the send queue, sending messages as allowed by pacing config
-- @param none
-- @return nil
function Comm:_PumpQueue()
    local st = self.state
    if not st or not st.keys or #st.keys == 0 then
        -- Stop ticker when idle
        if st and st.ticker and st.ticker.Cancel then
            pcall(function() st.ticker:Cancel() end)
        end
        if st then st.ticker = nil end
        return
    end

    local now = _CommNow()
    local maxSends = tonumber(self.cfg.maxSendsPerPump) or 1
    local minGap = tonumber(self.cfg.perTargetMinIntervalSec) or 0.06
    if minGap < 0 then minGap = 0 end

    local sent = 0
    local tries = 0

    while sent < maxSends and tries < (#st.keys * 2) do
        tries = tries + 1
        st.rr = (st.rr or 0) + 1
        if st.rr > #st.keys then
            st.rr = 1
        end

        local key = st.keys[st.rr]
        local q = st.byKey[key]

        if not q or #q == 0 then
            st.byKey[key] = nil
            table.remove(st.keys, st.rr)
            st.rr = st.rr - 1
        else
            local last = st.lastSent[key] or 0
            if (now - last) >= minGap then
                local item = table.remove(q, 1)
                st.total = math.max(0, (st.total or 1) - 1)
                st.lastSent[key] = now

                self:SendCommMessage(item.prefix, item.msg, item.dist, item.target, item.prio, item.callback)
                sent = sent + 1
            end
        end
    end
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

	-- Normalize sender name
	if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
		sender = SF.NameUtil.NormalizeNameRealm(sender)
		if not sender then return end
	end

	if self.cfg.ignoreSelf then
		local me = PlayerFullName()
		if me then
			if SF.NameUtil and SF.NameUtil.SamePlayer then
				if SF.NameUtil.SamePlayer(sender, me) then
					return
				end
			else
				if sender == me then
					return
				end
			end
		end
	end

	local kind = self:_KindFromPrefix(prefix)
	if not kind then
		return
	end

	self:_HandleIncoming(kind, text, distribution, sender)
end

-- Function Handle incoming messages
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
        if enc ~= SP.ENC_NONE and payloadStr and payloadStr ~= "" then
            local decodeOk, decodeResult = pcall(SP.DecodePayloadTable, payloadStr, enc)
            if decodeOk then
                payload = decodeResult
            end
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
        local err = nil
        if payloadStr and payloadStr ~= "" and enc ~= SP.ENC_NONE then
            payload, err = SP.DecodePayloadTable(payloadStr, enc)
            if err then
                DVerbose("Drop: bad payload decode from %s (%s)", sender, tostring(err))
                return
            end
        end
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
            DError("Handler error kind=%s type=%s from=%s err=%s", tostring(kind), tostring(msgType), tostring(sender), tostring(err))
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