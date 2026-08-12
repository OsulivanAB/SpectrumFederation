# Contributing

Spectrum Federation is a World of Warcraft Retail addon written for WoW's embedded Lua 5.1 runtime. The repository also contains Python release automation, GitHub Actions workflows, a standalone Google Sheet utility, and this MkDocs site.

## Repository map

```text
SpectrumFederation/
  SpectrumFederation.toc       authoritative manifest and load order
  SpectrumFederation.lua       login initialization
  modules/
    LootHelper/                profiles, members, logs, and transport
    LootHelperSync/            session protocol and synchronization
    Settings/                  schema, persistence, and apply behavior
    UI/Settings/               standalone settings framework and pages
    UI/LootHelper/             roster and equipment windows
    RaidCheck.lua              inspection, preparation checks, and awards
  locale/                      early localization work (not currently loaded by the TOC)
.github/scripts/               validation and release helpers
.github/workflows/             PR, beta, promotion, and rollback automation
assets/                        standalone Google Sheet sync utility
docs/                          MkDocs content
tests/                         interface-sync parser tests
```

Always inspect `SpectrumFederation/SpectrumFederation.toc` before changing load order, packaged files, Interface metadata, or addon versioning.

## Local setup

Install Lua 5.1, `luacheck` 1.2.0-1, and the Python lint dependencies used by CI:

```bash
sudo apt-get install lua5.1 luarocks
sudo luarocks install luacheck 1.2.0-1
python3 -m pip install -r .github/requirements-lint.txt
python3 -m pip install -r requirements-docs.txt
```

Link `SpectrumFederation/` into the Retail client's `Interface/AddOns/` directory for in-game testing. Enable Lua errors while developing:

```text
/console scriptErrors 1
/reload
```

## Branch and version policy

Normal work starts from and targets `beta`. `main` is updated by the promotion workflow.

Addon behavior or UI changes require a new version in `SpectrumFederation.toc`; documentation-only changes do not. Beta addon releases use `X.Y.Z-beta.N`, while promoted stable releases use `X.Y.Z`.

## Addon conventions

- Start modules with `local addonName, SF = ...` (or `local _, SF = ...`) and attach shared APIs to `SF`; do not introduce globals.
- Remain compatible with Lua 5.1 and the WoW sandbox.
- Add every packaged Lua file to the TOC after its dependencies.
- Prefer `SF.Debug:Verbose/Info/Warn/Error` for diagnostics.
- Prefer `SF:PrintSuccess/Error/Warning/Info` for user-visible chat output.
- Normalize character identifiers through `NameUtil` rather than comparing raw names.
- Guard protected UI work during combat and prefer `hooksecurefunc` over replacing Blizzard functions.
- Follow nearby code for naming. Existing persisted keys use both legacy camelCase and newer stable keys, so migrations matter more than cosmetic renaming.

Most current UI text is hardcoded English. `locale/enUS.lua` is not listed in the TOC, so do not assume `ns.L` strings are available at runtime until localization initialization and load order are implemented.

## Validation

Choose checks by the files changed:

```bash
# Addon Lua, TOC, workflows, or CI scripts
python3 .github/scripts/lint_all.py

# Packaging or release behavior
python3 .github/scripts/validate_packaging.py

# Documentation, README, or mkdocs.yml
python3 .github/scripts/validate_docs.py

# Interface-sync parser or fixtures
python -m pytest tests/test_wow_interface_sync.py
```

Do not weaken a check to make a change pass.

## In-game testing

Test the behavior you changed and its restrictions:

- reload without Lua errors;
- exercise admin and non-admin states for profile mutations;
- test solo, party, and raid visibility where relevant;
- confirm settings persist across `/reload`;
- test combat deferral for protected/CVar work;
- use at least two clients for synchronization changes;
- inspect `/sf debug show` for warnings and errors.

## Adding a slash command

Register module commands after the slash-command system is available:

```lua
SF:RegisterSlashCommand("example", function(args)
    SF:PrintInfo("Received: " .. tostring(args))
end, "Describe the command")
```

Handlers receive the remaining argument string. Validate and normalize arguments in the handler. The dispatcher lowercases all input before splitting it, which also lowercases arguments; do not add a command that requires case-preserving input without first changing and testing that contract.

Update the [Slash Command Reference](../../reference/slash-commands.md) for user-facing commands.

## Further reading

- [Addon Architecture](../architecture.md)
- [Settings System](../settings-ui/index.md)
- [Loot Helper Internals](../loot-helper/index.md)
- [Automation and Releases](../automation.md)

