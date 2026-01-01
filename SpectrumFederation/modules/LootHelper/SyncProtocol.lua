-- Grab the namespace
local addonName, SF = ...

SF.SyncProtocol = SF.SyncProtocol or {}
local P = SF.SyncProtocol

P.PROTO_MIN     = 1
P.PROTO_MAX     = 1
P.PROTO_CURRENT = 1

-- Encoding constants
P.ENC_NONE      = "NONE"
P.ENC_B64CBOR   = "B64CBOR"

-- Special message type used for graceful fallback
P.MSG_PROTO_NACK = "PROTO_NACK"

-- ================================================================
-- Throttling (prevent spam)
-- ================================================================
local NACK_COOLDOWN_SECONDS = 10
local WARN_COOLDOWN_SECONDS = 10

local lastNackAt = {}   -- [sender] = time
local lastWarnAt = {}   -- [sender] = time

-- Function to get current time
-- @param none
-- @return number Current unix utc timestamp
local function Now()
    if SF.Now then
        return SF:Now()
    end
    return GetServerTime and GetServerTime() or time()
end

-- Function to get the addon's version
-- @param none
-- @return string Addon version
local function GetAddonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(addonName, "Version") or "unknown"
    end
    if GetAddOnMetadata then
        return GetAddonOnMetadata(addonName, "Version") or "unknown"
    end
    return "unknown"
end

-- Function to print a warning message
-- @param msg string Message to print
-- @return none
local function PrintWarning(msg)
    if SF.PrintWarning then
        SF:PrintWarning(msg)
    else
        print(addonName .. ": WARNING: " .. msg)
    end
end

-- Function to log a Debug warning message
-- @param fmt string Format string
-- @param ... any Format arguments
-- @return none
local function DebugWarn(fmt, ...)
    if SF.Debug and SF.Debug.Warn then
        SF.Debug:Warn("SYNC_PROTO", fmt, ...)
    end
end

-- ===============================================================
-- Protocol validation
-- ===============================================================

-- Function Validate protocol version.
-- @param proto number Protocol version
-- @return ok boolean True if valid
-- @return string|nil errMsg Error message if not valid
-- @return string|nil code ("BAD_TYPE"|"TOO_OLD"|"TOO_NEW")
function P.ValidateProtocolVersion(proto)
    if type(proto) ~= "number" or proto ~= math.floor(proto) then
        return false, "Protocol version must be an integer", "BAD_TYPE"
    end
    if proto < P.PROTO_MIN then
        return false, ("Protocol too old (got %d, min %d)"):format(proto, P.PROTO_MIN), "TOO_OLD"
    end
    if proto > P.PROTO_MAX then
        return false, ("Protocol too new (got %d, max %d)"):format(proto, P.PROTO_MAX), "TOO_NEW"
    end
    return true, nil, nil
end

-- ================================================================
-- Envelope parse/pack
-- ================================================================

-- Envelope v1:
--  TYPE \t PROTO \t ENC \t PAYLOAD
-- PAYLOD may be empty.
--
-- @param text string Full message text
-- @return ok boolean
-- @return string|nil msgType
-- @return number|nil proto
-- @return string|nil enc
-- @return string|nil payloadStr
-- @return string|nil errMsg
function P.ParseEnvelope(text)
    if type(text) ~= "string" or text == "" then
        return false, nil, nil, nil, nil, "empty message"
    end

    local msgType, protoStr, enc, payload = string.match(text, "^([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
    if not msgType then
        return false, nil, nil, nil, nil, "bad envelope (expected 4 tab-separated fields)"
    end

    if not msgType:match("^[A-Z0-9_]+$") then
        return false, nil, nil, nil, nil, "invalid msgType token"
    end

    local proto = tonumber(protoStr)
    if not proto then
        return false, nil, nil, nil, nil, "protocol version is not a number"
    end

    if enc ~= P.ENC_NONE and enc ~= P.ENC_B64CBOR then
        return false, nil, nil, nil, nil, "unsupported encoding"
    end

    return true, msgType, proto, enc, payload, nil
end

-- Function to pack an envelope message
-- @param msgType string Message type
-- @param proto number Protocol version
-- @param enc string Encoding type
-- @param payloadStr string|nil Payload string (optional)
-- @return string Packed envelope message
function P.PackEnvelope(msgType, proto, enc, payloadStr)
    payloadStr = payloadStr or ""
    enc = enc or P.ENC_NONE
    return ("%s\t%d\t%s\t%s"):format(msgType, proto, enc, payloadStr)
end

-- ================================================================
-- Payload codec (B64(CBOR(table)))
-- ================================================================

-- Function to decode a payload string into a table
-- @param payload table
-- @return string|nil encoded
-- @return string|nil errMsg
function P.EncodePayloadTable(payload)
    if type(payload) ~= "table" then
        return nil, "payload must be a table"
    end

    local ok, cbor = pcall(C_EncodingUtil.SerializeCBOR, payload)
    if not ok or not cbor then
        return nil, "SerializeCBOR failed"
    end

    local b64 = C_EncodingUtil.EncodeBase64(cbor)
    if not b64 then
        return nil, "EncodeBase64 failed"
    end

    return b64, nil
end

-- Function to decode a payload string into a table
-- @param encoded string Encoded payload string
-- @return table|nil payload
-- @return string|nil errMsg
function P.DecodePayloadTable(encoded)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "empty payload"
    end

    local raw = C_EncodingUtil.DecodeBase64(encoded)
    if not raw then
        return nil, "DecodeBase64 failed"
    end

    local ok, t = pcall(C_EncodingUtil.DeserializeCBOR, raw)
    if not ok or type(t) ~= "table" then
        return nil, "DeserializeCBOR failed"
    end

    return t, nil
end

-- ================================================================
-- Graceful fallback: warnings + PROTO_NACK
-- ================================================================

-- Function to determine if we should send a NACK to the sender
-- @param sender string Sender name
-- @return boolean True if we should send a NACK
function P.ShouldWarn(sender)
    local now = Now()
    local last = lastWarnAt[sender]
    if last and (now - last) < WARN_COOLDOWN_SECONDS then
        return false
    end
    lastWarnAt[sender] = now
    return true
end

-- Function to determine if we should send a NACK to the sender
-- @param sender string Sender name
-- @return boolean True if we should send a NACK
function P.ShouldNack(sender)
    local now = Now()
    local last = lastNackAt[sender]
    if last and (now - last) < NACK_COOLDOWN_SECONDS then
        return false
    end
    lastNackAt[sender] = now
    return true
end

-- Function Build a PROTO_NACK payload
-- @param seenProto number Protocol version seen
-- @param msgType strin|nil Message type we couldn't process
-- @return table Payload table
function P.BuildProtoNackPayload(seenProto, msgType)
    return {
        kind = P.MSG_PROTO_NACK,
        seenProto = seenProto,
        seenType = msgType,
        supportedMin = P.PROTO_MIN,
        supportedMax = P.PROTO_MAX,
        addonVersion = GetAddonVersion(),
    }
end

-- Function Handle an unsupported protocol version event (local warn + return an optional NACK envelope)
-- IMPORTANT: This does not send anything; it just returns the envelope string so transport can whisper it.
-- @param sender string Sender name
-- @param seenProto number Protocol version seen
-- @param seenType string Message type seen
-- @return string|nil NACK envelope message or nil if none should be sent
function P.OnUnsupportedProto(sender, seenProto, seenType)
    DebugWarn("Unsupported proto from %s: type=%s proto=%s", tostring(sender), tostring(seenType), tostring(seenProto))

    if P.ShouldWarn(sender) then
        PrintWarning(("Sync: %s is using unsupported protocol %s (this client supports %d..%d). Ask them to update."):
            format(tostring(sender), tostring(seenProto), P.PROTO_MIN, P.PROTO_MAX))
    end

    if not P.ShouldNack(sender) then
        return nil
    end

    local payload = P.BuildProtoNackPayload(seenProto, seenType)
    local b64, err = P.EncodePayloadTable(payload)
    if not b64 then
        DebugWarn("Failed to encode PROTO_NACK payload: %s", tostring(err))
        return nil
    end

    return P.PackEnvelope(P.MSG_PROTO_NACK, P.PROTO_CURRENT, P.ENC_B64CBOR, b64)
end

-- Function Handle receiving a PROTO_NACK (always show local warning; this is the "graceful feedback" loop).
-- @param sender string Sender name
-- @param payload table|nil Decoded payload table
-- @return nil
function P.OnProtoNack(sender, payload)
    local theirs = payload and payload.seenProto or "?"
    local minV = payload and payload.supportedMin or "?"
    local maxV = payload and payload.supportedMax or "?"
    local ver = payload and payload.addonVersion or "unknown"

   PrintWarning(("Sync: %s says our protocol/version is incompatible (they saw proto=%s; they support %s..%s; addon ver=%s)."):
        format(tostring(sender), tostring(theirs), tostring(minV), tostring(maxV), tostring(ver)))
end