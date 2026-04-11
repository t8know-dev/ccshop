This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **CC:Tweaked (ComputerCraft Tweaked)** Lua application for modded Minecraft. It implements an interactive item display shop using physical pedestals and a monitor UI. The shop supports multiple categories, materials, quantity selection, and payment via Numismatics depositor, integrated with Applied Energistics 2 (AE2) for stock checking.

## Running the Code

There is no build system. Code runs directly in-game on a ComputerCraft computer:
```
lua shop.lua
```

The program runs until terminated with Ctrl+T (in-game). Ensure all required peripherals are attached and configured in `config.lua`.

**Directory layout:** The script expects `config.lua`, `items.lua`, and `db.lua` to be in the `/ccshop/` directory (same folder as `shop.lua`). Logs are written to `/ccshop/shop_debug.log` and purchases to `/ccshop/purchases.json`.

## Architecture

The system is split across multiple Lua files for modularity:

- **shop.lua** — Main script orchestrates UI, event handling, and business logic.
- **config.lua** — Peripheral names, messages, timeouts, pedestal list, and validation function.
- **items.lua** — Categories, materials, quantity tiers, price definitions, and helper functions.
- **db.lua** — Purchase logging (ndjson format) to `/ccshop/purchases.json`.

### Flow of Screens

The shop operates as a five‑screen state machine:

1. **Category selection** — Right‑click a pedestal showing a category icon (iron, certus quartz, redstone, dye). The pedestal list is centered across available pedestals.

2. **Material selection** — Shows only materials belonging to the chosen category that have sufficient stock in AE2. Right‑click selects a material, left‑click returns to category selection.

3. **Quantity selection** — Displays available quantity tiers (from the material’s `minQty` up to stock). Right‑click chooses a quantity, left‑click goes back.

4. **Payment** — Unlocks the Numismatics depositor, shows hint with required spurs, and waits for payment. The user can cancel with the UI cancel button.

5. **Thank‑you screen** — Plays a noteblock sound, logs the purchase, and returns to screen 1 after `CONFIRM_DELAY` seconds.

### Peripheral Integration

- **Display pedestals** (Pedestals mod) — Show items/labels, receive `pedestal_left_click`/`pedestal_right_click` events.
- **AE2 adapter** (`ae2cc_adapter`) — Queries available stock for material items.
- **Numismatics depositor** — Accepts spur currency, signals payment via redstone relay.
- **Redstone relays** — One locks/unlocks the depositor, another triggers a noteblock.
- **Monitor** — Shows Basalt UI with header, hint line, and cancel button.

### Concurrency

The main loop runs two coroutines in parallel:
- `basalt.autoUpdate` — UI render loop.
- `eventLoop` — Listens for pedestal click events and handles idle timeouts.

## Key Data Structures

### Pedestal List (`config.lua`)
```lua
PEDESTALS = {
  "display_pedestal_12",  -- leftmost
  "display_pedestal_10",
  "display_pedestal_11",
  "display_pedestal_5",
  "display_pedestal_9",
  "display_pedestal_7",   -- rightmost
}
```
The script centers the currently active options across all pedestals; unused pedestals are cleared.

### Categories (`items.lua`)
```lua
CATEGORIES = {
  { label = "Metals",   item = "minecraft:iron_ingot" },
  { label = "Crystals", item = "ae2:certus_quartz_crystal" },
  { label = "Redstone", item = "minecraft:redstone" },
  { label = "Dyes",     item = "minecraft:blue_dye" },
}
```

### Materials (`items.lua`)
```lua
MATERIALS = {
  {
    label    = "Iron Ingot",
    item     = "minecraft:iron_ingot",
    category = "Metals",       -- must match a CATEGORIES label exactly
    minQty   = 64,             -- first quantity option shown; must be in QUANTITIES
    basePrice = 10,            -- price in spurs for minQty units
  },
  ...
}
```

### Quantity Tiers (`items.lua`)
```lua
QUANTITIES = { 1, 8, 32, 64, 256, 512, 1024, "4k", "16k", "32k" }
```
Helpers `quantityToNumber(qty)` and `findQuantityIndex(num)` convert between string/numeric representations.

### State (`shop.lua`)
```lua
local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity, 4=payment, 5=thankyou
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table (item, label, count)
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
}
```

## Dependencies

- **Basalt** — UI framework, must be present on the ComputerCraft computer (`require("basalt")`).
- **CC:Tweaked built‑ins** — `peripheral`, `fs`, `os`, `parallel`, `colors`, `textutils`.
- **Mod peripherals** (must be attached and named correctly):
  - `display_pedestal` (Pedestals mod)
  - `ae2cc_adapter` (AE2 CC Bridge)
  - `Numismatics_Depositor` (Numismatics)
  - `redstone_relay` (CC:Tweaked redstone integration)

## Configuration Files

### `config.lua`
- Peripheral name constants (`RELAY_LOCK`, `AE2_ADAPTER`, `DEPOSITOR`, `RELAY_NOTE`, `MONITOR`, `PEDESTALS`).
- Timing constants (`IDLE_TIMEOUT`, `CONFIRM_DELAY`).
- UI message table (`MSG`).
- `validatePeripherals()` – attempts to wrap each peripheral; called at startup.

### `items.lua`
- `CATEGORIES`, `MATERIALS`, `QUANTITIES` tables.
- Helper functions for quantity conversion and lookup.

### `db.lua`
- `log(record)` – appends a purchase record in ndjson format.
- `readAll()` – reads all logged purchases.

## Pedestal API Notes

The `display_pedestal` peripheral from the Pedestals mod **does not have a `setLabel` method**. Instead, use `setItem(item, label)` with the label as the second argument. (This was discovered and fixed in commit `d3fa13f`; earlier versions incorrectly called `setLabel`.)

The code uses `pcall(pedestals[idx].setItem, opt.item, label)` and wraps `setLabelRendered` calls in `pcall` because that method may or may not exist.

Example from `setPedestalOptions`:
```lua
if label then
    local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
else
    local ok, err = pcall(pedestals[idx].setItem, opt.item)
end
```

## Event Handling

The `eventLoop` listens for `pedestal_left_click` and `pedestal_right_click` events. Each event carries:
- The pedestal object or name (as `eventData[2]`).
- A table describing the item in hand (`eventData[3]`), containing `name`, `count`, `displayName`.

The script maps the pedestal object/name to an index using `pedestalObjectToIndex` and `pedestalIndexByName` lookups, then retrieves the corresponding option from `state.currentOptions`.

## Adding a New Pedestal

1. Add the peripheral name to the `PEDESTALS` array in `config.lua`.
2. The script will automatically center options across all defined pedestals; no other changes are needed.

## Adding a New Category or Material

1. Add a category entry to `CATEGORIES` in `items.lua` (label and representative item).
2. Add material entries to `MATERIALS` with the correct `category` label, `minQty`, and `basePrice`.
3. Ensure the `item` field matches the exact in‑game item ID (e.g., `"minecraft:iron_ingot"`).
4. The material will appear in the UI only when its stock in AE2 is at least `minQty`.

## Debugging

- The script writes detailed logs to `/ccshop/shop_debug.log` via `writeLog()`.
- Logs include peripheral wrapping results, stock queries, event data, and state transitions.
- The debug file is appended each run; clear it manually if it grows too large.
- Purchase records are stored in `/ccshop/purchases.json` (ndjson format).