# **SF Loot Helper Session Sync Sequence**

This page documents the **message choreography** for syncing a Loot Helper profile in a raid session, based on a **log-replication** model:

* **LootLogs are append-only** and are the source of truth.

* Member state is derived by replaying logs.

* Sync is accomplished by exchanging “what logs do you have?” summaries and transferring missing log ranges.

* A **leader/coordinator** starts the session and publishes a **helpers list** so bulk transfers can be distributed.

---

## **Legend**

**Prefixes / traffic classes**

* `SF_LH` \= **Control** (small messages: session start, status, requests)

* `SF_LHB` \= **Bulk** (large payloads: log batches, snapshots; typically compressed)

**Distribution notation**

* `[RAID]` \= broadcast to raid

* `[WHISPER]` \= targeted to one player

**IDs**

* `sessionId` \= identifies the current SF Loot Helper Session (raid-scoped)

* `requestId` \= correlates one request with its responses (bulk transfers, multi-part batches)

* `profileId` \= stable, stored unique ID for the profile (NOT derived from name/owner)

**Log identity**

* `logId = author:counter` (or equivalent stable unique id)

* `authorMax = { [author] = maxCounterSeen }`

---

## **Sequence 1: Session creation and admin convergence (leader pre-sync)**

```mermaid
sequenceDiagram
    autonumber
    participant RL as Raid Leader / Session Coordinator
    participant A1 as Admin (Helper candidate)
    participant A2 as Admin (Helper candidate)
    participant A3 as Admin (Helper candidate)

    Note over RL: Trigger: RL becomes raid leader (or group converts to raid)<br/>RL prompts: "Start SF Loot Helper Session?"
    RL->>RL: Generate sessionId<br/>Select profileId (stable)<br/>Initialize local authorMax map

    par Whisper CONTROL to online admins
        RL->>A1: [WHISPER SF_LH] ADMIN_SYNC(sessionId, profileId)
        RL->>A2: [WHISPER SF_LH] ADMIN_SYNC(sessionId, profileId)
        RL->>A3: [WHISPER SF_LH] ADMIN_SYNC(sessionId, profileId)
    end

    Note over A1,A3: Each admin waits random jitter (0..J ms)<br/>so replies don't spike at the same time.

    par Admins respond with their summary
        A1-->>RL: [WHISPER SF_LH] ADMIN_STATUS(sessionId, profileId, authorMax, hasProfile=true)
        A2-->>RL: [WHISPER SF_LH] ADMIN_STATUS(sessionId, profileId, authorMax, hasProfile=true)
        A3-->>RL: [WHISPER SF_LH] ADMIN_STATUS(sessionId, profileId, authorMax, hasProfile=true)
    end

    Note over RL: RL compares its authorMax to each admin's authorMax<br/>and detects missing counters/gaps per author.

    loop For each author range RL needs
        RL->>A2: [WHISPER SF_LH] LOG_REQ(sessionId, requestId, profileId, author, fromCounter, toCounter?)
        A2-->>RL: [WHISPER SF_LHB] AUTH_LOGS(sessionId, requestId, profileId, author, logs...)
        Note over RL: Merge + dedupe logs by logId<br/>Update authorMax<br/>Rebuild derived state if needed
    end

    RL->>RL: Choose helpers list from online admins<br/>that appear up-to-date<br/>helpers=[A1,A2] (example)
```

**Notes**

* Admin convergence happens **before** the raid sees `SES_START`.

* Bulk transfers (AUTH\_LOGS) are **WHISPER \+ bulk prefix** to keep the raid channel clean.

---

## **Sequence 2: Session announcement and member catch-up using helpers**

```mermaid
sequenceDiagram
    autonumber
    participant RL as Raid Leader / Coordinator
    participant Raid as RAID Channel (broadcast)
    participant H1 as Helper 1 (Admin)
    participant H2 as Helper 2 (Admin)
    participant M1 as Member (no profile)
    participant M2 as Member (has profile, missing logs)
    participant M3 as Member (already up-to-date)

    RL-->>Raid: [RAID SF_LH] SES_START(sessionId, profileId, authorMax, helpers=[H1,H2])

    par All addon users in raid receive SES_START
        Raid-->>M1: SES_START(sessionId, profileId, authorMax, helpers)
        Raid-->>M2: SES_START(sessionId, profileId, authorMax, helpers)
        Raid-->>M3: SES_START(sessionId, profileId, authorMax, helpers)
    end

    Note over M1,M3: Each member deterministically picks a helper<br/>(e.g., hash(playerName) % #helpers)<br/>Fallback target = RL

    alt M1 does NOT have profileId locally
        M1->>H1: [WHISPER SF_LH] NEED_PROFILE(sessionId, requestId, profileId)
        H1-->>M1: [WHISPER SF_LHB] PROFILE_SNAPSHOT(sessionId, requestId, profileId, profileMeta, logs...)
        Note over M1: Import snapshot<br/>Build authorMax<br/>Rebuild state by replaying logs
    else M2 has profile but is missing logs
        M2->>H2: [WHISPER SF_LH] LOG_REQ(sessionId, requestId, profileId, author, fromCounter, toCounter?)
        H2-->>M2: [WHISPER SF_LHB] AUTH_LOGS(sessionId, requestId, profileId, author, logs...)
        Note over M2: Merge + dedupe<br/>Update authorMax<br/>Rebuild derived state if needed
    else M3 already matches authorMax
        Note over M3: No action required
    end

    opt Helper is unresponsive (timeout)
        M1->>RL: [WHISPER SF_LH] NEED_PROFILE(sessionId, requestId, profileId)
        RL-->>M1: [WHISPER SF_LHB] PROFILE_SNAPSHOT(sessionId, requestId, profileId, profileMeta, logs...)
    end
```

**Notes**

* The helpers list is the “middle ground” approach:

  * The leader coordinates.

  * Bulk transfer load is shared across helpers.

* Members only pull data when needed; most clients do nothing.

---

## **Sequence 3: Live updates during raid (append-only log broadcast)**

```mermaid
sequenceDiagram
    autonumber
    participant W as Admin Writer (could be RL/H1/H2)
    participant Raid as RAID Channel (broadcast)
    participant C1 as Client (in sync)
    participant C2 as Client (detects a gap)
    participant H1 as Helper 1

    Note over W: Admin action occurs (award points / gear / role change)<br/>Writer appends new immutable log entry<br/>logId=author:counter

    W-->>Raid: [RAID SF_LH] NEW_LOG(sessionId, profileId, logId, logData)

    par All addon users receive NEW_LOG
        Raid-->>C1: NEW_LOG(sessionId, profileId, logId, logData)
        Raid-->>C2: NEW_LOG(sessionId, profileId, logId, logData)
    end

    C1->>C1: Validate sender permissions<br/>Dedupe by logId<br/>Append log<br/>Update derived state

    C2->>C2: Detect gap (e.g., expected counter=N+1, got N+3)<br/>Do not apply out-of-order blindly
    C2->>H1: [WHISPER SF_LH] LOG_REQ(sessionId, requestId, profileId, author, fromCounter=N+1, toCounter=N+2)
    H1-->>C2: [WHISPER SF_LHB] AUTH_LOGS(sessionId, requestId, profileId, author, logs[N+1..N+2])
    C2->>C2: Apply missing logs<br/>Then apply NEW_LOG<br/>Update derived state
```

---

## **Sequence 4: Raid leader changes mid-session (coordinator handoff)**

This sequence shows how the active session can **continue without a full restart** when raid leadership changes (promotion/demotion or the coordinator disconnecting).

Key idea: session control messages include a **coordinator generation** value (I’ll call it `coordEpoch`). Clients treat the coordinator as:  
 **the sender with the highest `coordEpoch` seen for that `sessionId`.**

```mermaid
sequenceDiagram
    autonumber
    participant RL1 as Old Coordinator (previous RL)
    participant RL2 as New Raid Leader (new Coordinator)
    participant Raid as RAID Channel (broadcast)
    participant H1 as Helper/Admin
    participant H2 as Helper/Admin
    participant M as Member Client

    Note over RL1,Raid: Session already active:<br/>sessionId + profileId<br/>Control messages include coordEpoch=E1, coordinator=RL1

    Note over RL2: Raid leadership changes to RL2<br/>RL2 decides to take over the existing session

    RL2->>RL2: Generate coordEpoch=E2 where E2 > E1<br/>Set coordinator=RL2

    RL2-->>Raid: [RAID SF_LH] COORD_TAKEOVER(sessionId, profileId, coordEpoch=E2, coordinator=RL2)

    par Clients learn the new coordinator
        Raid-->>H1: COORD_TAKEOVER(...)
        Raid-->>H2: COORD_TAKEOVER(...)
        Raid-->>M:  COORD_TAKEOVER(...)
    end

    Note over H1,M: If coordEpoch is newer, set currentCoordinator=RL2<br/>Ignore future control messages from older epochs

    opt Optional acknowledgements (helps RL2 know who is online)
        H1-->>RL2: [WHISPER SF_LH] COORD_ACK(sessionId, coordEpoch=E2)
        H2-->>RL2: [WHISPER SF_LH] COORD_ACK(sessionId, coordEpoch=E2)
        M-->>RL2:  [WHISPER SF_LH] COORD_ACK(sessionId, coordEpoch=E2)
    end

    alt RL2 does NOT have the profile/session data locally
        RL2->>H1: [WHISPER SF_LH] NEED_PROFILE(sessionId, requestId, profileId)
        H1-->>RL2: [WHISPER SF_LHB] PROFILE_SNAPSHOT(sessionId, requestId, profileId, profileMeta, logs...)
        RL2->>RL2: Import snapshot + rebuild derived state
    else RL2 already has the profile
        RL2->>RL2: Use local profile + logs
    end

    Note over RL2: Optional but recommended: re-run admin convergence<br/>so RL2 becomes up-to-date before re-announcing session state

    par Admin convergence (same pattern as Sequence 1)
        RL2->>H1: [WHISPER SF_LH] ADMIN_SYNC(sessionId, profileId)
        RL2->>H2: [WHISPER SF_LH] ADMIN_SYNC(sessionId, profileId)
        H1-->>RL2: [WHISPER SF_LH] ADMIN_STATUS(sessionId, profileId, authorMax, hasProfile=true)
        H2-->>RL2: [WHISPER SF_LH] ADMIN_STATUS(sessionId, profileId, authorMax, hasProfile=true)
    end

    RL2->>RL2: Request missing log ranges if needed<br/>Update authorMax<br/>Choose/refresh helpers list

    RL2-->>Raid: [RAID SF_LH] SES_REANNOUNCE(sessionId, profileId, coordEpoch=E2, authorMax, helpers=[H1,H2])

    opt Old coordinator still online and sending outdated control messages
        RL1-->>Raid: [RAID SF_LH] SES_START(sessionId, profileId, coordEpoch=E1, ...)
        Note over H1,M: Clients ignore this (E1 < E2)<br/>Only accept control messages from latest coordinator epoch
    end

    Note over M: Member catch-up continues as normal<br/>using helpers list from the latest announcement
```

**Implementation notes (still “plan level”, not code):**

* `coordEpoch` can simply be `time()` at takeover. If two takeovers happen in the same second, break ties by choosing the lexicographically larger coordinator name (or add a random suffix).

* This `coordEpoch` rule only applies to **control messages** (session start/reannounce, helper lists, etc.).  
   For **log replication** (`NEW_LOG`), clients should accept messages from any valid admin for that `sessionId/profileId` (deduped by `logId`)—so awarding doesn’t “pause” during a handoff.

* If takeover ever gets messy (e.g., repeated flips), you can add a “hard reset” fallback: RL2 broadcasts `SES_END(oldSessionId)` and then a fresh `SES_START(newSessionId)` (more disruptive, but very deterministic).

**Notes**

* Live updates are “easy mode” because a new log entry is small.

* Gap detection is your safety net for real-world delivery weirdness.

---

## **Operational rules (non-diagram)**

These are the “guardrails” that keep the sequence above stable:

* **Jitter** on replies (admins \+ members): random delay to avoid synchronized bursts.

* **Timeout \+ fallback**: if the chosen helper doesn’t respond, retry with another helper or the leader.

* **Permission validation**: only accept and apply changes from valid admins (per the profile’s admin list).

* **Idempotency**: all log application is safe to repeat (dedupe by `logId`).

* **Rebuild policy**: if you ever insert older logs or fill a gap, recompute derived state by replaying logs.

---

If you want, next we can add a fourth (small) diagram covering the edge-case: **raid leader changes mid-session** (handoff / new coordinator re-announces `SES_START` with the same `sessionId` or a new one), but the three above are the core “happy path \+ gap repair” flows you’ll be implementing first.
