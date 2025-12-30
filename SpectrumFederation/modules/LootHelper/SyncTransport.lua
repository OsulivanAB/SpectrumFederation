-- Grab the namespace
local addonName, SF = ...

SF.LootHelperSyncTransport = SF.LootHelperSyncTransport or {}
local Transport = SF.LootHelperSyncTransport

Transport.cfg = Transport.cfg or {}

-- ============================================================================
-- Lifecycle
-- ============================================================================

-- Function Initialize transport layer: register prefixes, wire callbacks to Sync:OnControlMessage/OnBulkMessage.
-- @param controlPrefix string Prefix for control messages
-- @param bulkPrefix string Prefix for bulk messages
-- @param onControl function Callback(sender, msgType, payload, distribution)
-- @param onBulk function Callback(sender, msgType, payload, distribution)
-- @param cfg table|nil Optional config (libraries, priorities, compression settings)
-- @return nil
function Transport:Init(controlPrefix, bulkPrefix, onControl, onBulk, cfg)
end

-- Function Shutdown / disable callbacks (if needed).
-- @param none
-- @return nil
function Transport:Shutdown()
end

-- ============================================================================
-- Sending
-- ============================================================================

-- Function Send a CONTROL message (small) using the chosen comm library.
-- @param msgType string Message type
-- @param payload table Message payload
-- @param distribution string Distribution method (e.g., "WHISPER", "GUILD", etc)
-- @param target string|nil Target recipient (for WHISPER)
-- @param opts table|nil Optional: priority, queue, ect
-- @return boolean success
function Transport:SendControl(msgType, payload, distribution, target, opts)
end

-- Function Send a BULK message (large) using the chosen comm library (chunking/throttling handled by libs).
-- @param msgType string Message type
-- @param payload table Message payload
-- @param distribution string Distribution method (e.g., "WHISPER", "GUILD", etc)
-- @param target string|nil Target recipient (for WHISPER)
-- @param opts table|nil Optional: priority, compression, etc
-- @return boolean success
function Transport:SendBulk(msgType, payload, distribution, target, opts)
end

-- ============================================================================
-- Receiving (called by underlying library)
-- ============================================================================

-- Function Handle an incoming raw comm message; decode and route to onControl/onBulk based on prefix.
-- @param prefix string Message prefix
-- @param message string Raw message payload
-- @param distribution string Distribution method (e.g., "WHISPER", "GUILD", etc)
-- @param sender string Sender full identifier "Name-Realm"
-- @return nil
function Transport:OnMessage(prefix, message, distribution, sender)
end

-- ============================================================================
-- Codec (serialize/compress/encode)
-- ============================================================================

-- Function Encode a control payload into a string suitable for addon message transport.
-- @param msgType string Message type
-- @param payload table Message payload
-- @return string Encoded message
function Transport:EncodeControl(msgType, payload)
end

-- Function Decode a control message string into msgType + payload.
-- @param message string Encoded message
-- @return boolean success
-- @return string|nil msgType Message type
-- @return table|nil payload Message payload
function Transport:DecodeControl(message)
end

-- Function Encode a builk payload into a compressed/encoded string.
-- @param msgType string Message type
-- @param payload table Message payload
-- @return string Encoded message
function Transport:EncodeBulk(msgType, payload)
end

-- Function Decode a bulk message string into msgType + payload.
-- @param message string Encoded message
-- @return boolean success
-- @return string|nil msgType Message type
-- @return table|nil payload Message payload
function Transport:DecodeBulk(message)
end

-- ============================================================================
-- Library hooks (optional)
-- ============================================================================

-- Function Return whether transport has the required libraries available (AceComm/LibSerialize/LibDeflate ect.).
-- @param none
-- @return boolean available
function Transport:HasDependencies()
end