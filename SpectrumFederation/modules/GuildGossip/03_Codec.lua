-- Gossip codec adapter over SyncProtocol envelope helpers.
-- Uncompressed B64CBOR only; compressed gossip is rejected before decompression.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

function GG.ValidateGossipProto(proto)
    if type(proto) ~= "number" or proto ~= math.floor(proto) then
        return false, "BAD_TYPE"
    end
    if proto < GG.PROTO_MIN then
        return false, "TOO_OLD"
    end
    if proto > GG.PROTO_MAX then
        return false, "TOO_NEW"
    end
    return true, nil
end

function GG.PackEnvelope(msgType, enc, payloadStr)
    local SP = SF.SyncProtocol
    if not SP or not SP.PackEnvelope then
        return nil, "SyncProtocol missing"
    end
    return SP.PackEnvelope(msgType, GG.PROTO_CURRENT, enc or GG.ENC_NONE, payloadStr or ""), nil
end

function GG.ParseEnvelope(text)
    local SP = SF.SyncProtocol
    if not SP or not SP.ParseEnvelope then
        return false, nil, nil, nil, nil, "SyncProtocol missing"
    end
    return SP.ParseEnvelope(text)
end

function GG.EncodePayload(payload)
    if payload == nil then
        return "", GG.ENC_NONE, nil
    end
    if type(payload) ~= "table" then
        return nil, nil, "payload must be table or nil"
    end
    if next(payload) == nil then
        return "", GG.ENC_NONE, nil
    end
    local SP = SF.SyncProtocol
    if not SP or not SP.EncodePayloadTable then
        return nil, nil, "SyncProtocol missing"
    end
    -- Force uncompressed gossip encoding.
    local encoded, err = SP.EncodePayloadTable(payload, GG.ENC_B64CBOR)
    if not encoded then
        return nil, nil, err or "encode failed"
    end
    return encoded, GG.ENC_B64CBOR, nil
end

function GG.DecodePayload(payloadStr, enc)
    if enc == nil or enc == GG.ENC_NONE then
        return nil, nil
    end
    -- Reject compressed gossip before any decompression attempt.
    if enc == "B64CBORZ" or enc == (SF.SyncProtocol and SF.SyncProtocol.ENC_B64CBORZ) then
        return nil, "compressed gossip rejected"
    end
    if enc ~= GG.ENC_B64CBOR then
        return nil, "unsupported gossip encoding"
    end
    if type(payloadStr) ~= "string" or payloadStr == "" then
        return nil, nil
    end
    local SP = SF.SyncProtocol
    if not SP or not SP.DecodePayloadTable then
        return nil, "SyncProtocol missing"
    end
    return SP.DecodePayloadTable(payloadStr, GG.ENC_B64CBOR)
end

function GG.BuildWireMessage(msgType, payload)
    local payloadStr, enc, err = GG.EncodePayload(payload)
    if err then
        return nil, err
    end
    local envelope, packErr = GG.PackEnvelope(msgType, enc, payloadStr)
    if not envelope then
        return nil, packErr or "pack failed"
    end
    if #envelope > GG.MAX_ENCODED_ENVELOPE then
        return nil, "envelope exceeds 4 KiB"
    end
    return envelope, nil
end
