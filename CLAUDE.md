This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **CC:Tweaked (ComputerCraft Tweaked)** Lua application for modded Minecraft. It implements an interactive item display shop using physical pedestals and a monitor UI.

## Running the Code

There is no build system. Code runs directly in-game on a ComputerCraft computer:
```
lua shop.lua
```

The program runs until terminated with Ctrl+T (in-game).

## Architecture

All logic lives in `shop.lua`. The program has five responsibilities:

1. **Pedestal initialization** — Configures 3 display pedestals (via `peripheral.wrap`) with item data and rendering settings. Lookup tables (`pedestalsByName`, `pedestalsByItem`) allow O(1) resolution from event data.

2. **UI rendering** — Uses the [Basalt](https://basalt.madefor.cc/) UI framework to render to an attached monitor at 0.5 text scale. UI is laid out statically at startup; only the "selected item" section updates at runtime.

3. **Event handling** — The main loop listens for `pedestal_left_click` / `pedestal_right_click` events (fired by the Pedestals mod) and routes them to `onPedestalClick()`. Each event carries the item-in-hand and the item-on-pedestal.

4. **Selection state** — `onPedestalClick()` manages which pedestal is "selected" (at most one at a time), updates bracket notation on pedestal labels, and refreshes list highlighting in the UI.

5. **Debug logging** — `dumpEvent()` serializes full event tables to `/pedestal_dump.log` using recursive `dumpTableToFile()` (depth-limited to 5). This is separate from normal program flow.

Concurrency is handled by `parallel.waitForAny(basalt.autoUpdate, eventLoop)` — Basalt's render loop and the pedestal event loop run together.

## Key Data Structure
```lua
PEDESTALS = {
  { name = "...", item = "mod:item_id", label = "...", color = colors.X }
}
```

Adding a new pedestal means adding an entry here; initialization, lookup maps, and UI list rendering are all driven from this table.

## Dependencies

- **Basalt** — UI framework, must be present on the ComputerCraft computer (`require("basalt")`)
- All other APIs are CC:Tweaked built-ins: `peripheral`, `fs`, `os`, `parallel`, `colors`