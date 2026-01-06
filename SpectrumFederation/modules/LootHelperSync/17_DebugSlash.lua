local addonName, SF = ...
SF.LootHelperSync = SF.LootHelperSync or {}
local Sync = SF.LootHelperSync


do
    local function _Trim(s)
        s = tostring(s or "")
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    local function _SafeFormat(fmt, ...)
        if type(fmt) ~= "string" then
            local parts = { tostring(fmt) }
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            return table.concat(parts, " ")
        end

        local ok, out = pcall(string.format, fmt, ...)
        if ok and type(out) == "string" then
            return out
        end

        local parts = { tostring(fmt) }
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        return table.concat(parts, " ")
    end

    local function _CountMap(t)
        if type(t) ~= "table" then return 0 end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    local function _SortedKeys(t, filterLower)
        local keys = {}
        if type(t) ~= "table" then return keys end
        for k in pairs(t) do
            if type(k) == "string" then
                if not filterLower or filterLower == "" then
                    keys[#keys + 1] = k
                else
                    local kl = k:lower()
                    if kl:find(filterLower, 1, true) then
                        keys[#keys + 1] = k
                    end
                end
            end
        end
        table.sort(keys)
        return keys
    end

    local function _Join(list)
        if type(list) ~= "table" or #list == 0 then return "none" end
        local tmp = {}
        for i = 1, #list do
            tmp[#tmp + 1] = tostring(list[i])
        end
        return table.concat(tmp, ", ")
    end

    function Sync:_DebugPrintLine(fmt, ...)
        local line = _SafeFormat(fmt, ...)

        -- Prefer SF print helpers if available (chat colored + consistent)
        if SF and type(SF.PrintInfo) == "function" then
            SF:PrintInfo("%s", line)
            return
        end

        if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SF LootHelper Sync|r " .. tostring(line))
            return
        end

        print("SF LootHelper Sync " .. tostring(line))
    end

    function Sync:_DebugPrintStatus()
        local st = self.state or {}
        local dist = (type(GetGroupDistribution) == "function") and GetGroupDistribution() or nil

        self:_DebugPrintLine("=== LootHelper Sync Debug ===")
        self:_DebugPrintLine("AddonVersion=%s ProtoCurrent=%s",
            tostring(self._GetAddonVersion and self:_GetAddonVersion() or "unknown"),
            tostring((SF.SyncProtocol and SF.SyncProtocol.PROTO_CURRENT) or self.PROTO_VERSION or "unknown")
        )

        self:_DebugPrintLine("Self=%s Enabled=%s InGroup=%s Dist=%s",
            tostring((type(SelfId) == "function") and self:_SelfId() or "unknown"),
            tostring(self._enabled == true),
            tostring(dist ~= nil),
            tostring(dist or "NONE")
        )

        if st and st.active then
            self:_DebugPrintLine("SessionActive=%s SessionId=%s ProfileId=%s",
                tostring(st.active == true),
                tostring(st.sessionId or "nil"),
                tostring(st.profileId or "nil")
            )

            self:_DebugPrintLine("Coordinator=%s CoordEpoch=%s IsCoordinator=%s",
                tostring(st.coordinator or "nil"),
                tostring(st.coordEpoch or "nil"),
                tostring(st.isCoordinator == true)
            )

            local sm = self:_EnsureSafeModeState()
            self:_DebugPrintLine("SafeMode effective=%s session=%s(rev=%s) local=%s",
                tostring(sm._effective == true),
                tostring(sm.sessionEnabled == true),
                tostring(sm.sessionRev or 0),
                tostring(sm.localEnabled == true)
            )

            local helpers = st.helpers or {}
            self:_DebugPrintLine("Helpers(%d): %s", tonumber(#helpers) or 0, _Join(helpers))
        else
            self:_DebugPrintLine("SessionActive=false (no active session)")
        end

        local reqCount = _CountMap(st and st.requests)
        self:_DebugPrintLine("OutstandingRequests=%d (use '/sflhsync requests' for full)", reqCount)

        if reqCount > 0 and type(st.requests) == "table" then
            local arr = {}
            for _, req in pairs(st.requests) do
                if type(req) == "table" then
                    arr[#arr + 1] = req
                end
            end

            table.sort(arr, function(a, b)
                local ac = tonumber(a.createdAt) or 0
                local bc = tonumber(b.createdAt) or 0
                if ac == bc then
                    return tostring(a.id) < tostring(b.id)
                end
                return ac < bc
            end)

            local maxLines = math.min(#arr, 10)
            for i = 1, maxLines do
                local r = arr[i]
                local maxAttempts = 1 + (tonumber(r.maxRetries) or 0)
                local age = (type(r.createdAt) == "number") and ((type(Now) == "function" and self:_Now() or 0) - r.createdAt) or nil
                if type(age) ~= "number" or age < 0 then age = 0 end

                self:_DebugPrintLine(
                    " - %s kind=%s attempt=%d/%d paused=%s age=%.1fs lastTarget=%s",
                    tostring(r.id),
                    tostring(r.kind or "UNKNOWN"),
                    tonumber(r.attempt) or 0,
                    maxAttempts,
                    tostring(r.paused == true),
                    tonumber(age) or 0,
                    tostring(r.lastTarget or "nil")
                )
            end

            if #arr > maxLines then
                self:_DebugPrintLine(" (showing %d/%d; run '/sflhsync requests')", maxLines, #arr)
            end
        end

        local M = (type(self.GetMetricsSnapshot) == "function") and self:GetMetricsSnapshot() or nil
        if type(M) == "table" then
            self:_DebugPrintLine("Metrics enabled=%s startedAt=%s (use '/sflhsync metrics [filter]')",
                tostring(M.enabled == true),
                tostring(M.startedAt or "nil")
            )

            local counters = M.counters or {}
            local gauges = M.gauges or {}

            local function _MetricGet(key)
                if counters[key] ~= nil then return counters[key] end
                if gauges[key] ~= nil then return gauges[key] end
                return nil
            end

            local summaryKeys = {
                "sync.msg.sent.total",
                "sync.msg.recv.total",
                "sync.req.created.total",
                "sync.req.completed.total",
                "sync.req.failed.total",
                "sync.queue.requests.outstanding",
                "sync.queue.requests.paused",
                "sync.heartbeat.sent",
                "sync.heartbeat.recv",
                "sync.safe_mode.on_count",
                "sync.safe_mode.off_count",
            }

            for _, k in ipairs(summaryKeys) do
                local v = _MetricGet(k)
                if v ~= nil then
                    self:_DebugPrintLine(" - %s = %s", tostring(k), tostring(v))
                end
            end
        else
            self:_DebugPrintLine("Metrics unavailable (no metrics table)")
        end
    end

    function Sync:_DebugPrintRequests()
        local st = self.state or {}
        local reqs = st.requests
        local n = _CountMap(reqs)

        self:_DebugPrintLine("=== LootHelper Sync Requests (%d) ===", n)
        if n == 0 or type(reqs) ~= "table" then
            self:_DebugPrintLine("No outstanding requests.")
            return
        end

        local arr = {}
        for _, req in pairs(reqs) do
            if type(req) == "table" then
                arr[#arr + 1] = req
            end
        end

        table.sort(arr, function(a, b)
            local ac = tonumber(a.createdAt) or 0
            local bc = tonumber(b.createdAt) or 0
            if ac == bc then
                return tostring(a.id) < tostring(b.id)
            end
            return ac < bc
        end)

        local now = (type(Now) == "function") and self:_Now() or 0

        for _, r in ipairs(arr) do
            local maxAttempts = 1 + (tonumber(r.maxRetries) or 0)
            local age = (type(r.createdAt) == "number") and (now - r.createdAt) or nil
            if type(age) ~= "number" or age < 0 then age = 0 end

            local meta = (type(r.meta) == "table") and r.meta or {}
            local metaBits = {}

            if type(meta.profileId) == "string" then metaBits[#metaBits + 1] = "profileId=" .. meta.profileId end
            if type(meta.sessionId) == "string" then metaBits[#metaBits + 1] = "sessionId=" .. meta.sessionId end
            if type(meta.author) == "string" then metaBits[#metaBits + 1] = "author=" .. meta.author end
            if meta.fromCounter ~= nil then metaBits[#metaBits + 1] = "from=" .. tostring(meta.fromCounter) end
            if meta.toCounter ~= nil then metaBits[#metaBits + 1] = "to=" .. tostring(meta.toCounter) end

            self:_DebugPrintLine(
                "%s kind=%s attempt=%d/%d paused=%s timeoutSec=%s age=%.1fs lastSentAt=%s lastTarget=%s",
                tostring(r.id),
                tostring(r.kind or "UNKNOWN"),
                tonumber(r.attempt) or 0,
                maxAttempts,
                tostring(r.paused == true),
                tostring(r.timeoutSec or "nil"),
                tonumber(age) or 0,
                tostring(r.lastSentAt or "nil"),
                tostring(r.lastTarget or "nil")
            )

            self:_DebugPrintLine("  targets[%d]=%s", type(r.targets) == "table" and #r.targets or 0, _Join(r.targets))
            if #metaBits > 0 then
                self:_DebugPrintLine("  meta: %s", table.concat(metaBits, " "))
            end
        end
    end

    function Sync:_DebugPrintMetrics(filter)
        local M = (type(self.GetMetricsSnapshot) == "function") and self:GetMetricsSnapshot() or nil
        if type(M) ~= "table" then
            self:_DebugPrintLine("Metrics unavailable.")
            return
        end

        local f = _Trim(filter)
        local fl = (f ~= "" and f:lower()) or nil

        self:_DebugPrintLine("=== LootHelper Sync Metrics ===")
        self:_DebugPrintLine("enabled=%s startedAt=%s filter=%s",
            tostring(M.enabled == true),
            tostring(M.startedAt or "nil"),
            tostring(f ~= "" and f or "none")
        )

        local counters = M.counters or {}
        local gauges = M.gauges or {}
        local stats = M.stats or {}

        self:_DebugPrintLine("-- counters --")
        for _, k in ipairs(_SortedKeys(counters, fl)) do
            self:_DebugPrintLine("%s = %s", k, tostring(counters[k]))
        end

        self:_DebugPrintLine("-- gauges --")
        for _, k in ipairs(_SortedKeys(gauges, fl)) do
            self:_DebugPrintLine("%s = %s", k, tostring(gauges[k]))
        end

        self:_DebugPrintLine("-- stats --")
        for _, k in ipairs(_SortedKeys(stats, fl)) do
            local s = stats[k]
            if type(s) == "table" then
                local count = tonumber(s.count) or 0
                local sum = tonumber(s.sum) or 0
                local avg = (count > 0) and (sum / count) or 0
                self:_DebugPrintLine("%s: count=%d avg=%.3f min=%s max=%s",
                    k, count, avg,
                    tostring(s.min),
                    tostring(s.max)
                )
            end
        end
    end

    function Sync:_HandleDebugSlash(msg)
        msg = _Trim(msg)
        local cmd, rest = msg:match("^(%S+)%s*(.*)$")
        cmd = _Trim(cmd):lower()
        rest = _Trim(rest)

        if cmd == "" or cmd == "status" then
            self:_DebugPrintStatus()
            return
        end

        if cmd == "help" or cmd == "?" then
            self:_DebugPrintLine("LootHelper Sync debug slash commands:")
            self:_DebugPrintLine("  /sflhsync                -> status summary")
            self:_DebugPrintLine("  /sflhsync status         -> status summary")
            self:_DebugPrintLine("  /sflhsync requests|req   -> list outstanding requests")
            self:_DebugPrintLine("  /sflhsync metrics [text] -> print metrics (optional substring filter)")
            return
        end

        if cmd == "requests" or cmd == "req" then
            self:_DebugPrintRequests()
            return
        end

        if cmd == "metrics" then
            self:_DebugPrintMetrics(rest)
            return
        end

        -- Unknown subcommand -> show help, but keep it short
        self:_DebugPrintLine("Unknown subcommand '%s'. Use '/sflhsync help'.", tostring(cmd))
    end

    function Sync:_InstallDebugSlashCommands()
        if self._debugSlashInstalled then return end
        self._debugSlashInstalled = true

        if type(SlashCmdList) ~= "table" then return end

        SLASH_SFLOOTHELPERSYNC1 = "/sflhsync"
        SLASH_SFLOOTHELPERSYNC2 = "/lhsync"

        SlashCmdList["SFLOOTHELPERSYNC"] = function(msg)
            local ok, err = pcall(function()
                Sync:_HandleDebugSlash(msg)
            end)
            if not ok then
                if SF and type(SF.PrintWarning) == "function" then
                    SF:PrintWarning("LootHelper Sync debug slash error: %s", tostring(err))
                else
                    print("LootHelper Sync debug slash error: " .. tostring(err))
                end
            end
        end
    end
end
