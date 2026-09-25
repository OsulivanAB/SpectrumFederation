---
name: tsm-integration
description: Reads TradeSkillMaster prices through Spectrum Federation's read-only TSM adapter. Use when a feature needs TSM market value, min buyout, another TSM price source, or a TSM custom price expression.
---

# TSM Integration

Spectrum Federation talks to TradeSkillMaster only through `SF.TSM` in `SpectrumFederation/modules/Integrations/TSM.lua`.

Feature code calls that adapter. It does not call `TSM_API`, read `TradeSkillMasterDB`, or depend on TSM internals.

## Current public API

Confirm the live addon API at <https://api.tradeskillmaster.com/addon/> before changing the adapter. The implementation was checked against that page:

- `TSM_API.ToItemString(item)` converts an item link, TSM item string, or WoW item string.
- `TSM_API.GetCustomPriceValue(customPriceStr, itemString)` evaluates a price source key or custom price expression and returns copper, or `nil` plus an error string when the source is invalid.
- `TSM_API` errors on unknown keys. Check functions with `rawget`. Addon load state is not proof the API is ready.

`DBMarket` and `DBMinBuyout` are public price-source keys passed through `GetCustomPriceValue`. They are not separate TSM calls.

## How to use it

```lua
local value, reason = SF.TSM.GetMarketValue(itemLink)
local buyout, buyoutReason = SF.TSM.GetMinBuyout(itemId)
local crafted, craftedReason = SF.TSM.EvaluatePriceSource(itemLink, "DBMarket * 0.5")
```

`IsAvailable()` reports whether `ToItemString` and `GetCustomPriceValue` are both present. Still call the helpers if you want their reason codes; they already fail closed.

Accepted item inputs:

- item link, WoW item string (`item:...`), or TSM item string (`i:...`, `p:...`)
- positive integer item id, as a number or numeric string
- a record with `itemLink`, `itemString`, and/or `itemId`

Links and existing item strings are forwarded intact. Numeric ids become a WoW item string (`item:<id>`) and then go through `ToItemString`. A record tries `itemLink`, then `itemString`, then `itemId`.

## Return values

A number, including `0`, is a real copper value. `nil` means there is no usable value. The second return is a `SF.TSM.REASON` code:

- `unavailable` — required TSM functions are missing
- `invalid_item` — the input could not be converted
- `invalid_source` — the source or expression was rejected
- `no_data` — the source was valid and TSM had no price
- `api_error` — TSM threw, or returned a non-numeric value

Do not treat `nil` as `0`.

## Rules for new work

- Keep TSM optional. No hard dependency, no load failure, no chat message when it is missing, disabled, unfinished, or empty.
- Stay read-only. Do not change TSM settings, groups, operations, prices, or SavedVariables, and do not copy prices into Spectrum SavedVariables.
- Put new shared TSM reads on `SF.TSM`, delegating to `EvaluatePriceSource` when they are another source or expression. Keep one-off logic out of feature modules.
- Do not poll, scan, or query TSM from `OnUpdate`, login, or a timer. Call the adapter when a feature actually needs a value, and reuse that result.
- Expected misses stay quiet. Unexpected TSM failures are caught, returned as `api_error`, and logged with `SF.Debug:Error` under category `TSM` when debug logging is enabled.
- Extend `tests/lua/tsm_integration_tests.lua` for adapter behavior. Stub `TSM_API`; do not require TradeSkillMaster.
- Run `python -m pytest tests/test_tsm_integration.py`.

Write access to TSM needs its own ticket. Do not add it here.
