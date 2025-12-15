# Development

This guide covers how to set up your local development environment for SpectrumFederation.

## Local Development Setup

### Clone the Repository

```bash
git clone git@github.com:OsulivanAB/SpectrumFederation.git
cd SpectrumFederation
```

### Open in Dev Container

1. Open the repository in Visual Studio Code
2. When prompted, click **"Reopen in Container"** (or use Command Palette → "Dev Containers: Reopen in Container")
3. The dev container will automatically:
   - Install Lua 5.1 and luacheck
   - Download Blizzard UI sources
   - Set up the development environment

### Blizzard UI Sources

After the dev container initializes, Blizzard UI source files are available in:

- **`BlizzardUI/live/`** - Retail (live) WoW UI sources
- **`BlizzardUI/beta/`** - PTR/Beta WoW UI sources

!!! note
    The `BlizzardUI/` folder is git-ignored and must never be committed. It's generated locally by the dev container setup script.

### Create Symlinks to WoW AddOns Folders

To test the addon in-game, create symlinks from your WoW installation to the repository:

#### Windows (PowerShell as Administrator)

```powershell
# For Retail
New-Item -ItemType SymbolicLink -Path "<path-to-your-wow-folder>\_retail_\Interface\AddOns\SpectrumFederation" -Target "<path-to-cloned-repo>\SpectrumFederation\SpectrumFederation"

# For Beta/PTR
New-Item -ItemType SymbolicLink -Path "<path-to-your-wow-folder>\_beta_\Interface\AddOns\SpectrumFederation" -Target "<path-to-cloned-repo>\SpectrumFederation\SpectrumFederation"
```

#### macOS/Linux

```bash
# For Retail
ln -s <path-to-cloned-repo>/SpectrumFederation/SpectrumFederation "<path-to-your-wow-folder>/_retail_/Interface/AddOns/SpectrumFederation"

# For Beta/PTR
ln -s <path-to-cloned-repo>/SpectrumFederation/SpectrumFederation "<path-to-your-wow-folder>/_beta_/Interface/AddOns/SpectrumFederation"
```

!!! tip
    After creating symlinks, restart WoW or use `/reload` in-game. The addon changes will immediately reflect as you edit files.

## Semantic Versioning

We follow [Semantic Versioning 2.0.0](https://semver.org/) with the format `MAJOR.MINOR.PATCH`:

- **MAJOR** (0.x.x): Breaking changes or significant rewrites (we're in 0.x.x during initial development)
- **MINOR** (x.0.x): New features, non-breaking changes
- **PATCH** (x.x.0): Bug fixes, small tweaks

### Version Format Examples

#### Stable Releases (main branch)
```
0.1.0    # First minor release
0.1.1    # Bug fix
0.2.0    # New features added
1.0.0    # First stable release (breaking change)
```

#### Beta Releases (beta branch)
```
0.1.0-beta.1    # First beta for version 0.1.0
0.1.0-beta.2    # Second beta for version 0.1.0
0.1.0           # Stable release (promoted from beta)
0.2.0-beta.1    # First beta for next version
```

!!! note "Beta Versioning Best Practice"
    Beta versions should include a pre-release number (`.1`, `.2`, etc.) after `-beta`. This allows multiple beta iterations before the stable release:
    
    - `0.1.0-beta.1` → `0.1.0-beta.2` → `0.1.0` ✅ Clear progression
    - `0.1.0-beta` → `0.2.0-beta` ❌ Skips patch/minor increments

### Version Bumping Rules

**Every PR to `main` or `beta` MUST bump the version in `SpectrumFederation/SpectrumFederation.toc`:**

- Merging to `main`: Bump to next stable version (`0.1.0`, `0.1.1`, etc.)
- Merging to `beta`: Bump to next beta version (`0.2.0-beta.1`, `0.2.0-beta.2`, etc.)
- CI will fail if version is not bumped

## Branch Strategy

### `main` Branch
- **Purpose**: Retail / Stable releases
- **Version format**: `X.Y.Z` (e.g., `0.1.0`)
- **Target**: Live WoW servers
- **Protection**: Requires PR approval and passing CI checks

### `beta` Branch
- **Purpose**: PTR/Beta / Experimental features
- **Version format**: `X.Y.Z-beta.N` (e.g., `0.1.0-beta.1`)
- **Target**: Beta/PTR WoW servers
- **Protection**: Requires PR approval and passing CI checks

!!! warning
    - Beta versions can **only** be released from the `beta` branch
    - Stable versions can **only** be released from the `main` branch
    - The release workflow enforces these rules automatically

## Running Tests and Documentation Locally

### Run luacheck (Lua Linter)

```bash
# Check all Lua files in the addon
luacheck SpectrumFederation --only 0

# Check a specific file
luacheck SpectrumFederation/SpectrumFederation.lua
```

### Serve Documentation Locally

```bash
# Install dependencies
pip install -r requirements-docs.txt

# Serve documentation with live reload
mkdocs serve
```

The documentation will be available at `http://127.0.0.1:8000/`

!!! tip
    Changes to markdown files will automatically reload in your browser while `mkdocs serve` is running.

