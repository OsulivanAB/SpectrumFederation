# Sync Issues Analysis

This document contains issues found during comprehensive review of the LootHelperSync system. Analysis covered authorization checks, complete flow tracing (Session Start/End, Point Changes, Gear Toggling, Profile/Logs Requests), and examination from all user perspectives (Coordinator, Helper, Admin, Member, Non-Member).

---

## Issue #1: Equipment Toggle Changes Never Broadcast to Raid

**Details**: When an admin toggles an equipment slot via `ToggleEquipment()` in `Members.lua`, the change is logged locally but NEVER broadcast to other raid members. Unlike point increases/decreases which call `BroadcastNewLog()`, equipment toggles have no network synchronization mechanism.

**Reason**: 
- `ToggleEquipment()` creates a LootLog entry and adds it to the local profile
- The method calls `AddLootLog()` which should trigger broadcast via `BroadcastNewLog()`
- However, the broadcast return value is not checked, and if it fails, the change remains local-only
- Other members never receive the EQUIPMENT_TOGGLE log and display stale armor slot status

**Impact**: CRITICAL - Equipment status diverges across raid members, breaking core functionality

**Recommendation**: 
1. Verify `AddLootLog()` properly calls `BroadcastNewLog()` for EQUIPMENT_TOGGLE event types
2. Add error handling in `ToggleEquipment()` to detect broadcast failures
3. Consider implementing a retry mechanism or forcing a full profile sync if broadcast fails

**Location**: `modules/LootHelper/Members.lua:380-480`

---

## Issue #2: Coordinator Can Start Session Without Having Profile Locally

**Details**: In `BeginAdminConvergence()`, if the coordinator calls `StartSession()` but doesn't have the profile loaded locally, the convergence process completes silently and broadcasts `SES_START` with empty `authorMax={}`. This causes members to believe no logs exist and skip gap detection.

**Reason**: 
- `BeginAdminConvergence()` checks `if not profile` at line 15
- Instead of failing, it immediately calls the completion hook which broadcasts the session start
- This was likely intended as a safety mechanism but creates incorrect state

**Impact**: HIGH - Members receive incomplete synchronization data, won't request logs they actually need

**Recommendation**: Add validation in `StartSession()` to ensure coordinator has profile before beginning convergence:
```lua
local profile = self:FindLocalProfileById(profileId)
if not profile then
    if SF.PrintError then
        SF:PrintError("Cannot start session: profile not loaded locally")
    end
    return nil
end
```

**Location**: `modules/LootHelperSync/09_AdminConvergence.lua:15-25`

---

## Issue #3: Chosen Helpers May Not Have Received SES_START Yet

**Details**: During admin convergence, helpers are chosen based on admin status responses, but the SES_START broadcast to helpers may not have arrived before members start requesting profiles from them. When a member sends NEED_PROFILE to a helper who hasn't received SES_START, the helper rejects the request (not in active session), causing the member's request to fail silently.

**Reason**:
- Admin convergence completes and chooses helpers at coordinator
- SES_START broadcast sent to entire raid (including helpers)
- Network latency means helpers may receive SES_START after members do
- Members immediately request profiles from helpers who return "no active session"
- Request retry falls back to coordinator (slow path)

**Impact**: HIGH - Profile bootstrap is delayed, members wait through retry timeouts

**Recommendation**: 
1. Implement handshake confirmation where helpers acknowledge SES_START before being used
2. Or delay member requests with additional jitter to ensure helpers are ready
3. Or include helper preparation phase before broadcasting to members

**Location**: `modules/LootHelperSync/09_AdminConvergence.lua:263-349`, `modules/LootHelperSync/14_HandlersControl.lua:524-529`

---

## Issue #4: Session End Has No Authorization Check

**Details**: The `EndSession()` function checks if caller is coordinator only to decide whether to broadcast, but doesn't validate authorization to end the session. A non-coordinator member can call `EndSession()`, which succeeds locally and resets their session state, leaving them out of sync with the raid.

**Reason**:
- `EndSession()` at line 526 only checks `if not self.state.active`
- Broadcast decision at line 531-533 defaults to `self.state.isCoordinator`
- Non-coordinators can call this and silently end their local session
- Line 556 always calls `_ResetSessionState()` regardless of authorization

**Impact**: MEDIUM - Allows members to desync themselves, though coordinator and others continue normally

**Recommendation**: Add authorization check at the start of `EndSession()`:
```lua
function Sync:EndSession(reason, broadcast)
    if not self.state.active then return false end
    
    -- Only coordinator should explicitly end session
    if not self.state.isCoordinator then
        if SF.Debug then
            SF.Debug:Warn("SYNC", "Non-coordinator attempted to end session")
        end
        return false
    end
    -- ... rest of function
end
```

**Location**: `modules/LootHelperSync/18_PublicAPI.lua:524-563`

---

## Issue #5: Partial Log Responses Can Cause Duplicate Merges

**Details**: When `HandleAuthLogs()` receives a partial response (some logs but not all requested), it merges the received logs immediately, then calls `_RetryRequestSoon()` to request the full range again. On retry, the server may resend overlapping logs, causing duplicates if deduplication fails.

**Reason**:
- Line 161 calls `MergeLogs()` before checking if request is satisfied
- Line 192 calls `_RetryRequestSoon()` when `contig < toCounter`
- Next retry requests same range (fromCounter to toCounter)
- If server resends logs 1-8 again, and dedup by logId fails, logs appear twice

**Impact**: HIGH - Log corruption through duplicates, point calculations may be wrong

**Recommendation**: 
1. Track which logs were successfully merged per request
2. Adjust retry to request only missing range (e.g., if got 1-8, next request should be 9-toCounter)
3. Ensure `MergeLogs()` uses robust deduplication by logId
4. Add verification that received logs match requested range before merge

**Location**: `modules/LootHelperSync/15_HandlersBulk.lua:161-194`

---

## Issue #6: Gap Detection Uses Count Instead of Contiguity Check

**Details**: The `BuildAdminStatus()` function determines if a profile has gaps by comparing the count of logs per author against the max counter. This gives false negatives - a profile with logs [1,2,5,10] has count=4 and max=10, correctly showing gaps, but if it has [1,2,3,4], it shows no gaps even if max elsewhere is 10.

**Reason**:
- Lines 69-77 count logs by author
- Lines 79-86 check if `count < max`
- This only detects gaps if local count is less than max counter seen
- Does not detect non-contiguous sequences like missing middle logs

**Impact**: MEDIUM - Admins with gaps may report `hasGaps=false`, preventing gap repair

**Recommendation**: Replace count-based check with contiguity check:
```lua
-- Check for contiguity by verifying counters 1..max all exist
for author, maxCounter in pairs(status.authorMax) do
    local logs = self:_GetLogsForAuthor(profile, author)
    for i = 1, maxCounter do
        if not logs[i] then
            status.hasGaps = true
            break
        end
    end
end
```

**Location**: `modules/LootHelperSync/14_HandlersControl.lua:69-86`

---

## Issue #7: Broadcast Failures Are Silently Ignored

**Details**: When `AddLootLog()` calls `BroadcastNewLog()`, the return value indicating success/failure is not checked. If the broadcast fails (no session, not authorized, not in group, safe mode), the log is added locally but other members never receive it, causing silent desync.

**Reason**:
- `Profiles.lua:498` calls `SF.LootHelperSync:BroadcastNewLog()` 
- Return value is discarded (no `local ok, err = ...`)
- Caller continues as if broadcast succeeded
- Error only logged via Debug system, not visible to user

**Impact**: MEDIUM - Changes appear successful locally but don't propagate, confusing admins

**Recommendation**: Check broadcast result and handle failures:
```lua
local ok, err = SF.LootHelperSync:BroadcastNewLog(self:GetProfileId(), lootLog:ToTable())
if not ok then
    if SF.PrintWarning then
        SF:PrintWarning("Failed to broadcast change: " .. tostring(err))
    end
    -- Consider: retry, or mark profile as "needs sync"
end
```

**Location**: `modules/LootHelper/Profiles.lua:486-501`

---

## Issue #8: Profile Request Dedupe Marker Survives Session Changes

**Details**: `RequestProfileSnapshot()` uses `self.state._profileReqInFlight` as a deduplication marker to prevent multiple simultaneous requests. However, this marker is set to the current sessionId and only cleared after profile arrives. If the session changes while a request is pending, the stale marker blocks legitimate requests for the new session.

**Reason**:
- Line 209 checks `if self.state._profileReqInFlight == self.state.sessionId`
- If session changes from SES1 to SES2, marker still equals SES1
- New request for SES2 is blocked because marker != nil
- Marker is only cleared in `HandleProfileSnapshot()` at line 316

**Impact**: MEDIUM - Members can't request profiles after session changes, must wait for timeout

**Recommendation**: Clear `_profileReqInFlight` marker in `_ResetSessionState()`:
```lua
function Sync:_ResetSessionState(reason)
    -- ... existing code ...
    
    -- Clear dedupe markers
    self.state._sentJoinStatusForSessionId = nil
    self.state._sentJoinStatusType = nil
    self.state._profileReqInFlight = nil  -- Add this line
    -- ... rest of function
end
```

**Location**: `modules/LootHelperSync/11_Heartbeat.lua:203-213`, `modules/LootHelperSync/18_PublicAPI.lua:473-478`

---

## Issue #9: No Admin Verification When Serving Profile Snapshots

**Details**: `HandleNeedProfile()` checks if the sender is in the group and if the responder is coordinator/helper, but doesn't verify that the helper serving the profile is actually an admin for that profile. A non-admin who happens to be chosen as helper could serve profiles they shouldn't have access to.

**Reason**:
- Helper selection in `ChooseHelpers()` only checks for `hasGaps=false` and admin status from convergence
- But doesn't re-verify admin status at serve time
- Profile membership could change between convergence and serve time
- Non-admin could be promoted to helper if they report good status

**Impact**: LOW-MEDIUM - Potential for unauthorized profile access if helper selection is compromised

**Recommendation**: Add admin check in `HandleNeedProfile()`:
```lua
function Sync:HandleNeedProfile(sender, payload)
    -- ... existing checks ...
    
    -- Verify we're still authorized for this profile
    if not self:IsSenderAuthorized(self.state.profileId, self:_SelfId()) then
        if SF.Debug then
            SF.Debug:Warn("SYNC", "Not authorized to serve profile (no longer admin)")
        end
        return
    end
    
    -- ... rest of function
end
```

**Location**: `modules/LootHelperSync/14_HandlersControl.lua:489-590`

---

## Issue #10: Admin Convergence Timeout Too Short for Large Profiles

**Details**: Admin convergence waits 1.5 seconds for all admins to respond with their status. For profiles with many logs or slow network conditions, admins may not respond in time, causing their log data to be excluded from the initial `authorMax` broadcast. Members then request wrong ranges or miss logs entirely.

**Reason**:
- `cfg.adminConvergenceCollectSec = 1.5` (02_State.lua:14)
- Admins must: receive ADMIN_SYNC, compute `BuildAdminStatus()`, send ADMIN_STATUS
- `ComputeAuthorMax()` and gap detection can take time for profiles with 100+ logs
- Network latency adds additional delay

**Impact**: MEDIUM - Incomplete initial sync, requires additional round-trips to repair gaps

**Recommendation**: 
1. Increase timeout to 3-5 seconds for better reliability
2. Or implement adaptive timeout based on profile size
3. Or implement progressive convergence (accept late responses and update authorMax)

**Location**: `modules/LootHelperSync/02_State.lua:14`, `modules/LootHelperSync/09_AdminConvergence.lua:49`

---

## Summary

**Critical Issues** (Require Immediate Attention):
- Issue #1: Equipment toggles never broadcast (breaks sync)
- Issue #5: Partial log responses cause duplicates (data corruption)

**High Priority Issues**:
- Issue #2: Coordinator can start without profile (incomplete sync)
- Issue #3: Helper selection race condition (slow bootstrap)
- Issue #6: Gap detection misses non-contiguous gaps

**Medium Priority Issues**:
- Issue #4: No authorization on EndSession
- Issue #7: Broadcast failures silent
- Issue #8: Request dedupe survives session changes
- Issue #9: No admin re-verification when serving
- Issue #10: Convergence timeout too short

**Total Issues Found**: 10
**Issues Requiring Code Changes**: 10
**Issues That Could Cause Silent Sync Failures**: 7 (Issues #1, #2, #3, #5, #6, #7, #8)
