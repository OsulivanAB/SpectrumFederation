-- modules/UI/LootHelper/RosterModel.lua
local addonName, SF = ...

SF.LootHelperWindow = SF.LootHelperWindow or {}
local LH = SF.LootHelperWindow

LH.RosterModel = LH.RosterModel or {}
local Model = LH.RosterModel
Model._classByMemberId = Model._classByMemberId or {}

local function NormalizeNameRealm(id)
    if type(id) ~= "string" then return nil end
    if SF.NameUtil and SF.NameUtil.NormalizeNameRealm then
        local norm = SF.NameUtil.NormalizeNameRealm(id)
        return norm or id
    end
    return id
end

local function ShortName(id)
    if type(id) ~= "string" then return "" end
    return id:match("^([^%-]+)") or id  -- name without realm
end

local function GetSetting(path, fallback)
    if SF.SettingsStore and SF.SettingsStore.Get then
        local v = SF.SettingsStore:Get(path)
        if v ~= nil then return v end
    end
    local db = SF.lootHelperDB or (SpectrumFederationDB and SpectrumFederationDB.lootHelper) or nil
    if not db then return fallback end

    local key = path:match("^lootHelper%.(.+)$")
    if key and db[key] ~= nil then return db[key] end

    return fallback
end

local function BuildRaidMap()
    local raidById = {}     -- [id] = { unit="raid1", class="SHAMAN" }

    if not IsInRaid() then
        return raidById
    end

    local n = GetNumGroupMembers() or 0
    for i = 1, n do
        local unit = "raid" .. i
        local name, realm = UnitFullName(unit)
        if name then
            realm = realm or GetRealmName()
            if realm then realm = realm:gsub("%s+", "") end -- remove spaces

            local id = NormalizeNameRealm(name .. "-" .. tostring(realm or ""))
            local _, class = UnitClass(unit)
            class = class and string.upper(class) or "UNKNOWN"

            if id and id ~= "" then
                raidById[id] = { unit = unit, class = class }
            end
        end
    end

    return raidById
end

-- local function CollectProfileMembers(profile)
--     -- Returns:
--     -- members = array of { id=..., member=..., class=... }
--     -- memberSet = map [id]=true
--     local members = {}
--     local memberSet = {}

--     if profile.getMemberIds and profile.getMemberByID then
--         local ids = profile:getMemberIds() or {}
--         for _, id in ipairs(ids) do
--             local m = profile:getMemberByID(id)
--             if m then
--                 local class = (m.GetClass and m:GetClass()) or m.class
--                 class = class and string.upper(class) or "UNKNOWN"
--                 id = NormalizeNameRealm(id)
--                 if id then
--                     table.insert(members, { id = id, member = m, class = class })
--                     memberSet[id] = true
--                 end
--             end
--         end
--         return members, memberSet
--     end

--     -- Legacy
--     if profile.GetMemberList then
--         local list = profile:GetMemberList() or {}
--         for _, m in ipairs(list) do
--             local id = (m and m.GetFullIdentifier and m:GetFullIdentifier()) or m.identifier
--             id = NormalizeNameRealm(id)
--             if id then
--                 local class = (m.GetClass and m:GetClass()) or m.class
--                 class = class and string.upper(class) or "UNKNOWN"
--                 table.insert(members, { id = id, member = m, class = class })
--                 memberSet[id] = true
--             end
--         end
--     end

--     return members, memberSet
-- end

local function CollectProfileMembers(profile)
	-- Returns:
	-- members = array of { id=..., member=..., class=... }
	-- memberSet = map [id]=true
	local members = {}
	local memberSet = {}

	local function AddMember(id, m)
		id = NormalizeNameRealm(id)
		if not id or not m then return end

		local class = (m.GetClass and m:GetClass()) or m.class or m.className
		class = class and string.upper(class):gsub("[%s%-%_]", "") or "UNKNOWN"

		table.insert(members, { id = id, member = m, class = class })
		memberSet[id] = true
	end

	local function IterateIdContainer(idsTbl, getByIdFn)
		if type(idsTbl) ~= "table" then return end

		-- Case A: array of ids: { "A", "B" }
		if #idsTbl > 0 then
			for _, rawId in ipairs(idsTbl) do
				if type(rawId) == "string" then
					local m = nil
					if type(getByIdFn) == "function" then
						m = getByIdFn(profile, rawId)
					end
					AddMember(rawId, m)
				elseif type(rawId) == "table" then
					-- Some implementations might return array of members
					local id = (rawId.GetFullIdentifier and rawId:GetFullIdentifier()) or rawId.identifier or rawId.id
					AddMember(id, rawId)
				end
			end
			return
		end

		-- Case B: map keyed by id: { ["A"]=memberObj, ["B"]=memberObj }
		for k, v in pairs(idsTbl) do
			if type(k) == "string" and type(v) == "table" then
				AddMember(k, v)
			elseif type(v) == "string" then
				-- map-ish: { [1]="A", [2]="B" } but stored oddly
				local m = nil
				if type(getByIdFn) == "function" then
					m = getByIdFn(profile, v)
				end
				AddMember(v, m)
			elseif type(k) == "string" then
				-- map of ids -> true, or ids -> something
				local m = nil
				if type(getByIdFn) == "function" then
					m = getByIdFn(profile, k)
				end
				AddMember(k, m)
			end
		end
	end

	-- ---- Preferred (new API) ----
	local getIds =
		profile.getMemberIds or profile.getMemberIDs or profile.GetMemberIds or profile.GetMemberIDs
	local getById =
		profile.getMemberByID or profile.getMemberById or profile.GetMemberByID or profile.GetMemberById

	if type(getIds) == "function" then
		local idsTbl = getIds(profile)
		IterateIdContainer(idsTbl, getById)
		return members, memberSet
	end

	-- ---- Legacy API ----
	local getList = profile.GetMemberList or profile.getMemberList
	if type(getList) == "function" then
		local list = getList(profile)
		IterateIdContainer(list, nil) -- list might be array of members or map id->member
		return members, memberSet
	end

	-- ---- Raw field fallbacks (helps if profile lost metatable after reload) ----
	if type(profile._members) == "table" then
		IterateIdContainer(profile._members, nil)
	end
	if type(profile.members) == "table" and next(profile.members) ~= nil then
		IterateIdContainer(profile.members, nil)
	end

	return members, memberSet
end

function Model:Build(profile)
    local rows = {}
    local meta = {}

    if not profile then
        meta.emptyText = "No active profile.\nCreate or select a LootHelper profile in settings."
        if SF.Debug then
            SF.Debug:Verbose("LH_ROSTER", "Build: No profile provided")
        end
        return rows, meta
    end

    if SF.Debug then
        SF.Debug:Verbose("LH_ROSTER", "Build: Building roster for profile")
    end

    -- settings
    local showMembersNotInRaid = GetSetting("lootHelper.showMembersNotInRaid", false) and true or false

    -- permissions (effective local admin while impersonating)
    local canAdmin = false
    local Imp = SF.LootHelperImpersonation
    if Imp and Imp.IsEffectiveLocalAdmin then
        canAdmin = Imp:IsEffectiveLocalAdmin(profile) and true or false
    elseif profile.IsCurrentUserAdmin then
        canAdmin = profile:IsCurrentUserAdmin() and true or false
    end
    local rewardPot = profile.IsRewardPotMode and profile:IsRewardPotMode() and true or false

    local raidById = BuildRaidMap()
    for id, info in pairs(raidById) do
        if id and info and info.class and info.class ~= "UNKNOWN" then
            self._classByMemberId[id] = info.class
        end
    end
    local profMembers, profSet = CollectProfileMembers(profile)

    -- Profile members
    for _, entry in ipairs(profMembers) do
        local id = entry.id
        local raidInfo = raidById[id]
        local inRaid = raidInfo ~= nil

        if showMembersNotInRaid or inRaid then
            local m = entry.member
            local points = 0
            if rewardPot then
                points = (m and m.GetAttendanceBalance and m:GetAttendanceBalance()) or (m and m.attendanceBalance) or 0
            else
                points = (m and m.GetPointBalance and m:GetPointBalance()) or (m and m.pointBalance) or 0
            end
            local resolvedClass = (raidInfo and raidInfo.class) or entry.class or self._classByMemberId[id] or "UNKNOWN"
            if resolvedClass == "UNKNOWN" and SF.Debug then
                SF.Debug:Warn("LH_ICON", "Unable to resolve class metadata (member=%s classRaw=%s inRaid=%s)",
                    tostring(id), tostring(entry.class), tostring(inRaid))
            end
            if m and resolvedClass ~= "UNKNOWN" and m.class ~= resolvedClass then
                m.class = resolvedClass
                m.className = resolvedClass
            end

            table.insert(rows, {
                type = "PROFILE_MEMBER",
                memberId = id,
                displayName = ShortName(id),
                class = resolvedClass,
                unit = raidInfo and raidInfo.unit or nil,
                points = tonumber(points) or 0,
                member = m,
                canAdmin = canAdmin,
                inRaid = inRaid,
                rewardPot = rewardPot,
            })
        end
    end

    if IsInRaid() then
        for id, info in pairs(raidById) do
            if not profSet[id] then
                table.insert(rows, {
                    type = "RAID_NONMEMBER",
                    memberId = id,
                    displayName = ShortName(id),
                    sortKey = string.lower(ShortName(id)),
                    class = info.class,
                    unit = info.unit,
                    points = nil,
                    member = nil,
                    canAdmin = canAdmin,
                    inRaid = true,
                })
            end
        end
    end

    table.sort(rows, function(a, b)
        return (a.sortKey or "") < (b.sortKey or "")
    end)

    if SF.Debug then
        SF.Debug:Verbose("LH_ROSTER", "Build: Generated %d rows (%d profile members, %d raid non-members)", 
            #rows, #profMembers, #rows - #profMembers)
    end

    if #rows == 0 then
        if not IsInRaid() and not showMembersNotInRaid then
            meta.emptyText = "No rows to show.\nJoin a raid or enable 'Show Members not in raid' in settings."
        else
            meta.emptyText = "No members to show."
        end
    end

    return rows, meta
end
