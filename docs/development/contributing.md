# Contributing

Thank you for your interest in contributing to the Spectrum Federation addon!

## Development Environment

### Dev Container

The easiest way to get started is using the provided dev container:

1. Install [Docker](https://www.docker.com/products/docker-desktop) and [VS Code](https://code.visualstudio.com/)
2. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
3. Clone the repository
4. Open the folder in VS Code
5. When prompted, click "Reopen in Container"

The dev container includes:
- Lua 5.1
- Luacheck for linting
- BlizzardUI reference sources (auto-fetched)
- Git and other development tools

### Local Setup

If you prefer not to use a dev container:

1. Install Lua 5.1 and Luacheck
2. Clone the repository
3. Copy the `SpectrumFederation/` folder to your WoW `AddOns` directory

## Branch Strategy

- `main` - Stable releases
- `beta` - Beta releases
- Feature branches - For development

**Always create feature branches from `beta`**, not from `main`.

## Making Changes

### 1. Create a Feature Branch

```bash
git checkout beta
git pull
git checkout -b feature/your-feature-name
```

### 2. Make Your Changes

- Edit files in the `SpectrumFederation/` directory
- Add new modules to the `.toc` file if needed
- Follow the existing code style and patterns

### 3. Test Your Changes

1. Copy your modified `SpectrumFederation/` folder to WoW's `AddOns` directory
2. Launch WoW and test thoroughly
3. Enable script errors: `/console scriptErrors 1`
4. Reload UI after changes: `/reload`

### 4. Lint Your Code

```bash
luacheck SpectrumFederation/
```

Fix any errors before committing.

### 5. Update Version

**IMPORTANT:** Every PR must bump the version in `SpectrumFederation.toc`:

```
## Version: 0.0.6-beta
```

Follow semantic versioning:
- Beta releases: `X.Y.Z-beta.N`
- Stable releases: `X.Y.Z`

### 6. Commit and Push

```bash
git add .
git commit -m "Brief description of changes"
git push origin feature/your-feature-name
```

### 7. Create a Pull Request

1. Go to the [GitHub repository](https://github.com/OsulivanAB/SpectrumFederation)
2. Click "Pull Requests" → "New Pull Request"
3. Set the base branch to `beta`
4. Provide a clear description of your changes
5. Submit the PR

## Code Style

### Lua Conventions

- Use the standard WoW addon namespace pattern:
  ```lua
  local addonName, ns = ...
  ```
- Store shared state in `ns` (e.g., `ns.core`, `ns.ui`, `ns.L`)
- Avoid creating globals
- Use `snake_case` or `camelCase` for local variables (be consistent within a file)

### Localization

- Add user-facing strings to `locale/enUS.lua`
- Reference them via `ns.L["KEY"]`
- Example:
  ```lua
  -- In locale/enUS.lua
  L["GREETING"] = "Hello, %s!"
  
  -- In your code
  print(string.format(ns.L["GREETING"], playerName))
  ```

### Module Organization

- **Core logic** → `modules/core.lua`
- **UI elements** → `modules/ui.lua`
- **Event handling** → `SpectrumFederation.lua` (main file)

## CI/CD Checks

Your PR must pass:

1. **Luacheck** - No Lua errors
2. **Version bump** - Version must be incremented
3. **Packaging validation** - Addon structure must be correct

## Questions?

- Open a [Discussion](https://github.com/OsulivanAB/SpectrumFederation/discussions)
- Check existing [Issues](https://github.com/OsulivanAB/SpectrumFederation/issues)
- Review the [Copilot Instructions](.github/copilot-instructions.md) for detailed technical guidelines

Thank you for contributing! 🎉
