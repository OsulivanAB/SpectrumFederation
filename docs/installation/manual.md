# Manual Installation

If you prefer not to use an addon manager, you can install Spectrum Federation manually.

## From GitHub Releases

### Step 1: Download

1. Visit the [Releases page](https://github.com/OsulivanAB/SpectrumFederation/releases)
2. Find the latest release (or choose a specific version)
3. Download the `.zip` file (e.g., `SpectrumFederation-0.0.5-beta.zip`)

### Step 2: Extract

1. Locate your World of Warcraft installation directory
2. Navigate to the appropriate `Interface\AddOns` folder:
    - **Retail/Live**: `_retail_/Interface/AddOns/`
    - **Beta/PTR**: `_beta_/Interface/AddOns/` or `_ptr_/Interface/AddOns/`
3. Extract the contents of the zip file into the `AddOns` folder
4. You should have a folder named `SpectrumFederation` inside `AddOns`

### Step 3: Verify Structure

Your directory structure should look like this:

```
Interface/
└── AddOns/
    └── SpectrumFederation/
        ├── SpectrumFederation.lua
        ├── SpectrumFederation.toc
        ├── locale/
        │   └── enUS.lua
        ├── media/
        └── modules/
            ├── core.lua
            └── ui.lua
```

### Step 4: Enable in Game

1. Launch World of Warcraft
2. At the character selection screen, click **AddOns**
3. Find "Spectrum Federation" and ensure it's checked/enabled
4. Click **Okay** and enter the game

## From Source Code

If you want to run the latest development version:

### Step 1: Clone the Repository

```bash
git clone https://github.com/OsulivanAB/SpectrumFederation.git
```

### Step 2: Copy Addon Folder

Copy the `SpectrumFederation` folder (the one containing the `.toc` file) to your WoW `AddOns` directory:

```bash
# Example for Retail
cp -r SpectrumFederation/SpectrumFederation /path/to/wow/_retail_/Interface/AddOns/

# Example for Beta
cp -r SpectrumFederation/SpectrumFederation /path/to/wow/_beta_/Interface/AddOns/
```

!!! warning "Development Version"
    Running from source means you're using the latest development code, which may be unstable or incomplete.

## Updating

To update manually:

1. Delete the old `SpectrumFederation` folder from your `AddOns` directory
2. Follow the installation steps above with the new version
3. In-game, type `/reload` to reload your UI

!!! tip "Keep Configuration"
    Your saved variables (in `WTF` folder) are preserved when updating

## Common Installation Locations

### Windows
- Retail: `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\`
- Beta: `C:\Program Files (x86)\World of Warcraft\_beta_\Interface\AddOns\`

### macOS
- Retail: `/Applications/World of Warcraft/_retail_/Interface/AddOns/`
- Beta: `/Applications/World of Warcraft/_beta_/Interface/AddOns/`

### Linux (Wine/Proton)
- Varies by installation; typically in your wine prefix or Steam library

## Troubleshooting

!!! failure "Addon Not Showing Up"
    - Verify the folder name is exactly `SpectrumFederation` (case-sensitive on some systems)
    - Check that `SpectrumFederation.toc` is directly inside the addon folder
    - Ensure you extracted to the correct WoW version folder

!!! failure "Addon Shows as Out of Date"
    The addon's interface version may not match your game version. You can:
    
    - Enable "Load out of date AddOns" at the character select screen
    - Wait for an update, or report the issue on GitHub
