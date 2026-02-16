# The Talos Principle Reawakened - Archipelago Mod

A mod for [The Talos Principle Reawakened](https://store.steampowered.com/app/1938910/The_Talos_Principle_Reawakened/) that integrates with [Archipelago](https://archipelago.gg/) multiworld randomizer.

## Features

- **Real-time Sync**: Locations and items sync automatically via WebSocket connection
- **Debug Tools**: F5-F8 keybinds for testing grants and inspecting state

## Installation

### Prerequisites

- [The Talos Principle Reawakened](https://store.steampowered.com/app/1938910/The_Talos_Principle_Reawakened/)
- [UE4SS experimental-latest](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest) (required for Unreal Engine 5.4 support)

### Setup

1. **Install UE4SS**:
   - Download [UE4SS experimental-latest](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest). Ensure it is not the zDEV version
   - Extract the contents of the zip folder.
   - Copy the dwmapi.dll to the Talos1/Binaries/win64
   - Copy the ue4ss folder in the top level directory of your game
   - **Note**: The experimental-latest version is required for Unreal Engine 5.4 support

2. **Install the mod**:
   - Download the latest release
   - Extract to `Talos1/Binaries/Win64/Mods/ArchipelagoMod/`

3. **Install lua-apclientpp**:
   - Download [lua-apclientpp v0.6.4+](https://github.com/black-sliver/lua-apclientpp/releases) (`lua54.7z`)
   - Extract the **`lua54-clang64-static`** build
   - Copy `lua-apclientpp.dll` to `scripts/` folder

4. **Configure connection**:
   - Open the `config.json` file
   - Edit with your AP server details:
     ```json
     {
       "server": "archipelago.gg:38281",
       "slot_name": "slotName",
       "password": "",
       "game": "The Talos Principle"
     }
     ```

5. **Launch the game** and the mod will auto-connect

## Configuration

Edit `scripts/config.json`:

- **server**: AP server address and port (e.g. `archipelago.gg:38281`)
- **slot_name**: Your player/slot name in the multiworld
- **password**: Server password (leave empty `""` if none)
- **game**: Game name (should be `"The Talos Principle"`)

## Debug Keybinds

- **F6**: Dump full state (collection, inventory, progress)
- **F8**: Grants all tetrominos
