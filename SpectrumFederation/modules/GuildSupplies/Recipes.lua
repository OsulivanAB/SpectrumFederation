-- Guild Supplies Quick Withdraw recipe configuration (#457).
-- Campaign-scoped recipe map keyed by output item ID. Distinct from requestedItems.
local addonName, SF = ...

SF.GuildSupplies = SF.GuildSupplies or {}
local GS = SF.GuildSupplies

-- Finite limits sized for wire/snapshot budgets (do not raise global transport caps).
GS.MAX_RECIPES = 32
GS.MAX_REAGENTS_PER_RECIPE = 16
GS.MAX_RECIPE_PER_CRAFT = 10000
GS.MAX_RECIPE_CRAFT_COUNT = 999
GS.MAX_WITHDRAW_AGGREGATE = 100000
-- Informational withdrawal history: separately bounded so donation capacity is protected.
GS.MAX_WITHDRAWAL_EVENTS = 1024
GS.MAX_ARCHIVED_WITHDRAWAL_EVENTS = 1024

GS.KIND = GS.KIND or {}
GS.KIND.SET_RECIPE = "set-recipe"

local function IsPositiveItemId(raw)
    local itemId = tonumber(raw)
    if not itemId or itemId ~= itemId or itemId == math.huge or itemId == -math.huge then
        return nil
    end
    if itemId ~= math.floor(itemId) or itemId < 1 then
        return nil
    end
    return itemId
end

local function IsNonnegWhole(raw, maxVal)
    local n = tonumber(raw)
    if not n or n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    if n ~= math.floor(n) or n < 0 then
        return nil
    end
    if maxVal and n > maxVal then
        return nil
    end
    return n
end

--- Canonical recipe target: { itemId = positive output item id }.
function GS.CanonicalRecipeTarget(target)
    local raw
    if type(target) == "table" then
        raw = target.itemId
    elseif type(target) == "number" or type(target) == "string" then
        raw = target
    else
        return nil
    end
    local itemId = IsPositiveItemId(raw)
    if not itemId then
        return nil
    end
    return { itemId = itemId }
end

--- Normalize reagents map: omit zeros; require ≥1 positive coefficient when not removed.
-- @return reagents table|nil, err string|nil, positiveCount number
function GS.NormalizeRecipeReagents(raw)
    if raw == nil then
        return {}, nil, 0
    end
    if type(raw) ~= "table" then
        return nil, "invalid_reagents"
    end
    local maxReagents = GS.MAX_REAGENTS_PER_RECIPE or 16
    local maxPerCraft = GS.MAX_RECIPE_PER_CRAFT or 10000
    local out = {}
    local n = 0
    local positive = 0
    local seen = {}
    for key, qty in pairs(raw) do
        local itemId = IsPositiveItemId(type(key) == "table" and key.itemId or key)
        if not itemId then
            -- Allow numeric values keyed under nested {itemId=...} only via string keys.
            itemId = IsPositiveItemId(key)
        end
        if not itemId then
            return nil, "invalid_reagent_id"
        end
        local canonKey = tostring(itemId)
        if seen[canonKey] then
            return nil, "duplicate_reagent"
        end
        seen[canonKey] = true
        local amount = IsNonnegWhole(qty, maxPerCraft)
        if amount == nil then
            return nil, "invalid_reagent_qty"
        end
        n = n + 1
        if n > maxReagents then
            return nil, "reagents_overflow"
        end
        if amount > 0 then
            out[canonKey] = amount
            positive = positive + 1
        end
        -- Zero means unused and is omitted from the canonical map.
    end
    return out, nil, positive
end

--- Canonical set-recipe value: removed sentinel or { itemId, reagents }.
function GS.NormalizeRecipeValue(value)
    if value == nil then
        return { removed = true }
    end
    if type(value) ~= "table" then
        return nil, "invalid_recipe_value"
    end
    if value.removed == true then
        return { removed = true }
    end
    local canon = GS.CanonicalRecipeTarget(value)
    if not canon then
        return nil, "invalid_item_id"
    end
    local reagents, err, positive = GS.NormalizeRecipeReagents(value.reagents)
    if not reagents then
        return nil, err or "invalid_reagents"
    end
    if positive < 1 then
        return nil, "empty_reagents"
    end
    return {
        itemId = canon.itemId,
        reagents = reagents,
        removed = false,
    }
end

function GS.CanonicalRecipeValue(value)
    local normalized, err = GS.NormalizeRecipeValue(value)
    if not normalized then
        return nil, err
    end
    if normalized.removed then
        return { removed = true }
    end
    return {
        itemId = normalized.itemId,
        reagents = normalized.reagents,
        removed = false,
    }
end

local function ValidateRecipeEntry(key, row)
    if type(row) ~= "table" then
        return false, "recipes_malformed"
    end
    local itemId = IsPositiveItemId(row.itemId)
    if not itemId then
        return false, "recipes_malformed"
    end
    local canonicalKey = tostring(itemId)
    if type(key) ~= "string" or key ~= canonicalKey then
        return false, "recipes_malformed"
    end
    local reagents, err, positive = GS.NormalizeRecipeReagents(row.reagents)
    if not reagents then
        return false, err or "recipes_malformed"
    end
    if positive < 1 then
        return false, "recipes_malformed"
    end
    -- Reject unknown fields that would not survive canonicalize (strict stored shape).
    for k in pairs(row) do
        if k ~= "itemId" and k ~= "reagents" then
            return false, "recipes_malformed"
        end
    end
    return true, nil, itemId, reagents
end

--- Deep-copy a recipes map with validation. Over-cap / malformed fail closed.
function GS.CopyRecipes(recipes)
    if type(recipes) ~= "table" then
        return {}
    end
    local maxRecipes = GS.MAX_RECIPES or 32
    local out = {}
    local n = 0
    for key, row in pairs(recipes) do
        n = n + 1
        if n > maxRecipes then
            return nil, "recipes_overflow"
        end
        local ok, err, itemId, reagents = ValidateRecipeEntry(key, row)
        if not ok then
            return nil, err or "recipes_malformed"
        end
        local reagentsCopy = {}
        for rk, rv in pairs(reagents) do
            reagentsCopy[rk] = rv
        end
        out[tostring(itemId)] = {
            itemId = itemId,
            reagents = reagentsCopy,
        }
    end
    return out
end

function GS.ValidateRecipesMap(recipes)
    if recipes == nil then
        return true
    end
    if type(recipes) ~= "table" then
        return false, "invalid_accounting"
    end
    local maxRecipes = GS.MAX_RECIPES or 32
    local n = 0
    for key, row in pairs(recipes) do
        n = n + 1
        if n > maxRecipes then
            return false, "recipes_overflow"
        end
        local ok, err = ValidateRecipeEntry(key, row)
        if not ok then
            return false, err or "recipes_malformed"
        end
    end
    return true
end

--- Shallow nested copy for confirmation shadows (does not validate).
function GS.CloneRecipesMap(recipes)
    if type(recipes) ~= "table" then
        return {}
    end
    local out = {}
    for k, v in pairs(recipes) do
        if type(v) == "table" then
            local copy = { itemId = v.itemId }
            if type(v.reagents) == "table" then
                local reagents = {}
                for rk, rv in pairs(v.reagents) do
                    reagents[rk] = rv
                end
                copy.reagents = reagents
            else
                copy.reagents = {}
            end
            out[k] = copy
        end
    end
    return out
end

--- Whether a recipe's positive reagents are all currently requested (usable for withdraw).
-- Missing/removed reagents leave the definition intact but mark it unavailable.
function GS.RecipeAvailability(record, recipe)
    if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
        return false, "invalid_recipe"
    end
    local missing = {}
    for reagentKey, qty in pairs(recipe.reagents) do
        local amount = tonumber(qty) or 0
        if amount > 0 then
            local itemId = IsPositiveItemId(reagentKey)
            if not itemId then
                missing[#missing + 1] = tostring(reagentKey)
            elseif GS.IsCurrentRequestedItem and not GS.IsCurrentRequestedItem(record, itemId) then
                missing[#missing + 1] = tostring(itemId)
            end
        end
    end
    if #missing > 0 then
        return false, "reagent_not_requested", missing
    end
    return true
end

--- Aggregate reagent quantities for craft counts: requested[i] = sum(crafts * perCraft).
-- @param selections { [outputItemId] = craftCount }
-- @param recipes map
-- @return amounts {[itemId]=qty}|nil, err|nil
function GS.AggregateRecipeWithdrawal(selections, recipes)
    if type(selections) ~= "table" or type(recipes) ~= "table" then
        return nil, "invalid_selection"
    end
    local maxCraft = GS.MAX_RECIPE_CRAFT_COUNT or 999
    local maxAgg = GS.MAX_WITHDRAW_AGGREGATE or 100000
    local amounts = {}
    local any = false
    for outputKey, craftCount in pairs(selections) do
        local crafts = IsNonnegWhole(craftCount, maxCraft)
        if crafts == nil then
            return nil, "invalid_craft_count"
        end
        if crafts > 0 then
            local recipe = recipes[tostring(outputKey)] or recipes[outputKey]
            if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
                return nil, "unknown_recipe"
            end
            any = true
            for reagentKey, perCraft in pairs(recipe.reagents) do
                local per = tonumber(perCraft) or 0
                if per > 0 then
                    local itemId = IsPositiveItemId(reagentKey)
                    if not itemId then
                        return nil, "invalid_reagent_id"
                    end
                    -- Overflow-safe product then sum.
                    if crafts > 0 and per > math.floor(maxAgg / crafts) then
                        return nil, "aggregate_overflow"
                    end
                    local add = crafts * per
                    local key = tostring(itemId)
                    local prev = amounts[key] or 0
                    if prev > maxAgg - add then
                        return nil, "aggregate_overflow"
                    end
                    amounts[key] = prev + add
                end
            end
        end
    end
    if not any then
        return nil, "empty_selection"
    end
    return amounts
end

--- Sorted recipe list for deterministic UI ordering.
function GS.ListCampaignRecipes(record)
    local cfg = record and record.accounting and record.accounting._consumables
    local recipes = cfg and cfg.recipes
    if type(recipes) ~= "table" then
        return {}
    end
    local list = {}
    for key, row in pairs(recipes) do
        if type(row) == "table" then
            list[#list + 1] = {
                itemId = tonumber(row.itemId) or tonumber(key),
                reagents = row.reagents,
                key = tostring(key),
            }
        end
    end
    table.sort(list, function(a, b)
        return (a.itemId or 0) < (b.itemId or 0)
    end)
    return list
end
