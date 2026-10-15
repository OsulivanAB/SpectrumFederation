-- D1 scheduling and FPS policy for Guild Gossip.
local addonName, SF = ...

SF.GuildGossip = SF.GuildGossip or {}
local GG = SF.GuildGossip

GG._sched = GG._sched or {
    mode = "SLOW",
    fpsStreakMode = nil,
    fpsStreakStart = nil,
    lastFpsSampleAt = nil,
    lastFps = nil,
    ticker = nil,
    nextStepAt = 0,
    paused = false,
    pauseReason = nil,
    resumeAt = nil,
    workPending = false,
    dirtyFollowUp = false,
    changeDebounceAt = nil,
    changeFirstAt = nil,
}

function GG.GetSchedMode()
    return GG._sched.mode or "SLOW"
end

function GG.IsSchedPaused()
    return GG._sched.paused == true
end

function GG.MarkWorkPending()
    GG._sched.workPending = true
    GG._EnsureScheduler()
end

function GG.ClearWorkPendingIfIdle()
    -- Engine decides when truly idle; this only clears the flag when asked.
    GG._sched.workPending = false
end

function GG.NotifyMeaningfulChange()
    local st = GG._sched
    local now = GG._Now()
    if not st.changeFirstAt then
        st.changeFirstAt = now
    end
    local debounce = GG.CHANGE_DEBOUNCE_SEC
    local maxWait = GG.CHANGE_DEBOUNCE_MAX_SEC
    local due = now + debounce
    if st.changeFirstAt and (due - st.changeFirstAt) > maxWait then
        due = st.changeFirstAt + maxWait
    end
    if not st.changeDebounceAt or due < st.changeDebounceAt then
        st.changeDebounceAt = due
    end
    -- Active exchange keeps a single follow-up dirty flag rather than restarting
    -- the current pass (initiated or served).
    if GG._engine and (GG._engine.outPull or GG._engine.inPull) then
        st.dirtyFollowUp = true
    end
    -- Local accepted changes clear coverage so a follow-up pass can run.
    -- Remote peers learn via discovery changeGen, not by wiping on receipt alone.
    if GG._engine and GG._engine.peers then
        for _, peer in pairs(GG._engine.peers) do
            peer.covered = {}
        end
    end
    -- Clear scoped unresolved backoff so suspended peers can be reconsidered.
    -- Full obligation/bookmark reopen is owned by NotifyProviderChanged, remote
    -- change-identity updates, TTL expiry, and cap eviction — not every accepted
    -- apply (which also calls this helper and must not wipe sibling obligations).
    if GG._engine then
        GG._engine.unresolvedBackoffUntil = {}
    end
    GG.MarkWorkPending()
end

function GG.ConsumeChangeDebounce(now)
    local st = GG._sched
    now = now or GG._Now()
    if not st.changeDebounceAt then
        return false
    end
    if now < st.changeDebounceAt then
        return false
    end
    st.changeDebounceAt = nil
    st.changeFirstAt = nil
    return true
end

function GG.HasDirtyFollowUp()
    return GG._sched.dirtyFollowUp == true
end

function GG.ClearDirtyFollowUp()
    GG._sched.dirtyFollowUp = false
end

local function readFps()
    if type(GetFramerate) == "function" then
        local fps = GetFramerate()
        fps = tonumber(fps)
        if fps and fps > 0 then
            return fps
        end
    end
    return nil
end

local function clearFpsStreak(st)
    st.fpsStreakMode = nil
    st.fpsStreakStart = nil
end

function GG.SampleFps(now)
    local st = GG._sched
    now = now or GG._Now()
    if not st.workPending and not st.paused then
        -- Idle: do not sample; clear streaks so idle time is not recovery evidence.
        clearFpsStreak(st)
        st.lastFpsSampleAt = nil
        return st.mode
    end
    if st.lastFpsSampleAt and (now - st.lastFpsSampleAt) < GG.FPS_SAMPLE_INTERVAL_SEC then
        return st.mode
    end
    -- Sampling gap clears streaks.
    if st.lastFpsSampleAt and (now - st.lastFpsSampleAt) > (GG.FPS_SAMPLE_INTERVAL_SEC * 2.5) then
        clearFpsStreak(st)
    end
    st.lastFpsSampleAt = now
    local fps = readFps()
    st.lastFps = fps
    if not fps then
        st.mode = "SLOW"
        clearFpsStreak(st)
        return st.mode
    end

    if fps < GG.FPS_ENTER_SLOW then
        if st.mode ~= "SLOW" then
            if st.fpsStreakMode ~= "enter_slow" then
                st.fpsStreakMode = "enter_slow"
                st.fpsStreakStart = now
            elseif (now - st.fpsStreakStart) >= GG.FPS_ENTER_SLOW_STREAK_SEC then
                st.mode = "SLOW"
                clearFpsStreak(st)
            end
        else
            clearFpsStreak(st)
        end
    elseif fps >= GG.FPS_RETURN_NORMAL then
        if st.mode ~= "NORMAL" then
            if st.fpsStreakMode ~= "return_normal" then
                st.fpsStreakMode = "return_normal"
                st.fpsStreakStart = now
            elseif (now - st.fpsStreakStart) >= GG.FPS_RETURN_NORMAL_STREAK_SEC then
                st.mode = "NORMAL"
                clearFpsStreak(st)
            end
        else
            clearFpsStreak(st)
        end
    else
        -- Hysteresis band: preserve mode, clear qualifying streak.
        clearFpsStreak(st)
    end
    return st.mode
end

function GG.GetStepLimits(mode)
    mode = mode or GG.GetSchedMode()
    if mode ~= "NORMAL" then
        mode = "SLOW"
    end
    return {
        mode = mode,
        cadence = GG.STEP_CADENCE[mode],
        cpuMs = GG.CPU_TARGET_MS[mode],
        apps = GG.INCOMING_APPS_PER_STEP[mode],
        indexEntries = GG.INDEX_ENTRIES_PER_STEP[mode],
        manifestEntries = GG.MANIFEST_ENTRIES[mode],
        bodies = GG.BODIES_PER_MESSAGE[mode],
    }
end

function GG.UpdatePauseState(now)
    local st = GG._sched
    now = now or GG._Now()
    local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
    local loading = false
    if IsLoadingScreenShown and IsLoadingScreenShown() then
        loading = true
    end
    if InCombatLockdown and false then
        -- Combat lockdown alone is not used; UnitAffectingCombat is the gate.
    end

    if inCombat or loading then
        if not st.paused then
            st.paused = true
            st.pauseReason = inCombat and "combat" or "loading"
            if GG.OnGossipPauseChanged then
                GG.OnGossipPauseChanged(true, now)
            end
            GG._DVerbose("Gossip paused (%s)", st.pauseReason)
        end
        st.resumeAt = nil
        return true
    end

    if st.paused then
        if not st.resumeAt then
            st.resumeAt = now + GG.RandomInRange(GG.RESUME_JITTER[1], GG.RESUME_JITTER[2])
            GG._DVerbose("Gossip resume scheduled at +%.1fs", st.resumeAt - now)
        end
        if now < st.resumeAt then
            return true
        end
        st.paused = false
        st.pauseReason = nil
        st.resumeAt = nil
        if GG.OnGossipPauseChanged then
            GG.OnGossipPauseChanged(false, now)
        end
        -- Start SLOW after recovery; FPS sampling may promote later.
        st.mode = "SLOW"
        clearFpsStreak(st)
        GG._DVerbose("Gossip resumed (SLOW)")
    end
    return false
end

function GG._TickScheduler()
    local st = GG._sched
    if not GG.HasActiveProvider or not GG.HasActiveProvider() then
        GG._StopScheduler()
        return
    end
    local now = GG._Now()
    -- Multipart reassembly has its own lifetime and must expire even while
    -- normal provider work is paused for combat/loading.
    if GG.ExpireStalePartials then
        GG.ExpireStalePartials(now)
    end
    if GG.UpdatePauseState(now) then
        -- Paused: do not consume view idle retry time (engine checks pause).
        return
    end
    GG.SampleFps(now)
    if st.nextStepAt and now < st.nextStepAt then
        return
    end
    local limits = GG.GetStepLimits()
    st.nextStepAt = now + limits.cadence
    if GG.OnSchedulerStep then
        GG.OnSchedulerStep(limits, now)
    end
end

function GG._EnsureScheduler()
    local st = GG._sched
    if st.ticker then
        return
    end
    if not GG.HasActiveProvider or not GG.HasActiveProvider() then
        return
    end
    if C_Timer and C_Timer.NewTicker then
        -- 0.1s ticker; SLOW cadence enforced via nextStepAt.
        st.ticker = C_Timer.NewTicker(0.1, function()
            GG._TickScheduler()
        end)
    end
end

function GG._StopScheduler()
    local st = GG._sched
    if st.ticker and st.ticker.Cancel then
        pcall(function()
            st.ticker:Cancel()
        end)
    end
    st.ticker = nil
    st.workPending = false
    st.changeDebounceAt = nil
    st.changeFirstAt = nil
    clearFpsStreak(st)
end

function GG.ResetSchedulerForTests(opts)
    GG._StopScheduler()
    local st = GG._sched
    st.mode = (opts and opts.mode) or "SLOW"
    st.paused = false
    st.pauseReason = nil
    st.resumeAt = nil
    st.dirtyFollowUp = false
    st.lastFps = nil
    st.lastFpsSampleAt = nil
    st.nextStepAt = 0
end
