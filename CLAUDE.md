This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **CC:Tweaked (ComputerCraft Tweaked)** Lua application for modded Minecraft. It implements an interactive item display shop using physical pedestals and a monitor UI. The shop supports multiple categories, materials, quantity selection with bulk discounts, and payment via Numismatics depositor, integrated with Applied Energistics 2 (AE2) for stock checking.

## Running the Code

There is no build system. Code runs directly in-game on a ComputerCraft computer:
```
lua shop.lua
```

The program runs until terminated with Ctrl+T (in-game). Ensure all required peripherals are attached and configured in `config.lua`.

**Directory layout:** The script expects `config.lua`, `items.lua`, and `db.lua` to be in the `/ccshop/` directory (same folder as `shop.lua`). Logs are written to `/ccshop/shop_debug.log` and purchases to `/ccshop/purchases.json`.

## Architecture

The system is split across multiple Lua files for modularity:

- **shop.lua** — Main orchestrator that loads modules and runs the main loops.
- **config.lua** — Peripheral names, messages, timeouts, pedestal list, and validation function.
- **items.lua** — Categories, materials, quantity tiers, bulk discount config, currency conversion, and helper functions.
- **db.lua** — Purchase logging (ndjson format) to `/ccshop/purchases.json`.
- **modules/** — Modular components with single responsibilities:
  - **logging.lua** — Logging utilities with log level control.
  - **config.lua** — Enhanced configuration loading and validation.
  - **peripherals.lua** — Peripheral management, AE2 cache, speaker, relay helpers.
  - **state.lua** — Centralized state management with observer pattern and reset functions.
  - **pedestal.lua** — Pedestal rendering and management (custom coroutine scheduler).
  - **ui.lua** — Basalt UI creation and updates (fixed coordinate positioning).
  - **screens.lua** — Screen rendering logic (with re-entrancy guard).
  - **events.lua** — Event handling and state transitions.
  - **payment.lua** — Payment detection and idle timeout monitoring.

The modules use dependency injection to avoid circular dependencies and enable testing.

### Flow of Screens

The shop operates as a four‑screen state machine with Screen 3 having two sub‑states:

1. **Category selection** — Welcome screen. Pedestals show category icons (iron, certus quartz, redstone, dye). Monitor shows bulk discount info and instructions. Right‑click selects a category. No cancel button. Idle timeout does not apply.

2. **Material selection** — Shows only materials belonging to the chosen category that have sufficient stock in AE2. Right‑click selects a material, left‑click returns to category selection. Cancel button visible.

3. **Quantity selection and payment** — Two sub‑states:
   - **3A: Selecting a quantity** — Pedestals show available quantity tiers (from `minQty` up to AE2 stock). Monitor shows base price and hint. Right‑click selects a quantity (transitions immediately to confirming), left‑click returns to material selection. Cancel button visible.
   - **3B: Awaiting payment** — Triggered immediately after quantity selection. Selected pedestal label changes to `"[<qty>]"`. Depositor price is configured and depositor unlocked. Monitor shows detailed payment breakdown: base price formula, price calculation, discount amount, total, coin insert instruction, and pedestal instruction. Cancel button visible.

4. **Thank‑you screen** — Plays a harp F sound, logs the purchase, mocks item dispensing, refreshes AE2 cache, and auto‑returns to screen 1 after `CONFIRM_DELAY` seconds. No cancel button.

### Peripheral Integration

- **Display pedestals** (Pedestals mod) — Show items/labels, receive `pedestal_left_click`/`pedestal_right_click` events.
- **AE2 adapter** (`ae2cc_adapter_14`) — Queries available stock for material items. Cache refreshed every `AE2_CACHE_TTL` (30 s) and after purchases.
- **Numismatics depositor** (`Numismatics_Depositor_8`) — Accepts Spur currency (spurs, bevels, sprockets, cogs, crowns, suns), sends payment signal via redstone relay.
- **Redstone relay** (`redstone_relay_38`) — Locks/unlocks depositor (`bottom` output). Payment detection on `bottom` input (or configured `PAYMENT_DETECTION_SIDE`).
- **Speaker** (`speaker_212`) — Plays `"harp"` instrument, pitch 11 (F note) for selection confirm (right‑click). Plays `"bass"` instrument, pitch 11 (F note) for cancel/back actions (left‑click, cancel button).
- **Monitor** (`monitor_1012`) — Shows fixed‑coordinate Basalt UI with header bar, content labels, and cancel button.

### Concurrency

The main orchestrator runs three coroutines in parallel using `parallel.waitForAny`:
- `basalt.run()` — Basalt UI main loop (handles monitor touch events, cancel button onClick).
- `events.eventLoop` — Listens for pedestal click events and timer events (cancel button async reset).
- `payment.paymentMonitorLoop` — Monitors payment detection and idle timeouts.

Pedestal rendering uses a **custom coroutine scheduler** with event re-queuing to avoid nested `parallel.waitForAll` issues. See [`parallel_execution.md`](./parallel_execution.md) for detailed documentation on the concurrency model.

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
Helpers `quantityToNumber(qty)`, `findQuantityIndex(num)`, and `numericQuantities()` convert between string/numeric representations.

### Bulk Discounts (`items.lua`)
```lua
DISCOUNT_LEVELS = {
    {level = 0, percent = 0},
    {level = 1, percent = 2},
    {level = 2, percent = 5},
    {level = 3, percent = 10},
    {level = 4, percent = 15},
    {level = 5, percent = 20},  -- level 5+ capped at 20%
}
```
- `calculateDiscountLevel(minQty, selectedQty)` — computes offset from `minQty` index to selected index, capped at 5.
- `getDiscountPercent(level)` — returns discount percentage for a given level.
- `calculatePriceWithDiscount(basePrice, minQty, selectedQty)` — returns final price, base price for qty, discount level, and discount percent.

### Currency (`items.lua`)
```lua
CURRENCY_UNITS = {
    { name = "sun",     value = 4096 },
    { name = "crown",   value = 512 },
    { name = "cog",     value = 64 },
    { name = "sprocket", value = 16 },
    { name = "bevel",   value = 8 },
    { name = "spur",    value = 1 },
}
```
`spursToCoins(spurs)` — converts numeric spur amount to human-readable coin string (e.g., `160` → `"2 sprockets, 2 cogs"`).

### State (`modules/state.lua`)
The state is managed by the `state.lua` module, which provides controlled access via:
- `state.getState(key)` — get a specific field (or shallow copy of entire state).
- `state.updateState(changes)` — apply changes and notify subscribers.
- `state.resetState()` — full reset to initial values (currently unused in main flow).
- `state.resetToMainScreen()` — preferred reset: clears selections and payment fields while preserving `lastActivity`, `currentOptions`, `currentPedestalIndices`, `lastSelectedPedestal`.

The state structure:

```lua
local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity/payment, 4=thankyou
    subState = nil,           -- nil, "selecting", or "confirming" (screen 3 only)
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    calculatedPrice = nil,    -- final price after discount
    discountLevel = nil,      -- bulk discount level (0-5, 5+ all get 20%)
    discountPercent = nil,    -- discount percentage (0, 2, 5, 10, 15, 20)
    basePriceForQty = nil,    -- price before discount (for display)
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index → { item, label, count }
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    availableQuantities = nil, -- list of numeric quantities available for selected material
    paymentBaseline = nil,    -- baseline relay input state (captured before unlock)
    paymentDeadline = nil,    -- os.clock() deadline for payment timeout
    paymentPaid = false,
    paymentCheckCount = 0,    -- counter for payment detection checks
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
- **Peripheral name constants**: `RELAY_LOCK`, `AE2_ADAPTER`, `DEPOSITOR`, `SPEAKER_NAME`, `MONITOR`, `PEDESTALS`.
- **Timing constants**:
  - `IDLE_TIMEOUT = 120` — seconds before auto-reset on screens 2, 3A, 3B.
  - `PAYMENT_TIMEOUT = 30` — seconds to wait for payment after unlocking depositor.
  - `CONFIRM_DELAY = 5` — seconds on thank-you screen before auto-return.
- **Payment detection**: `PAYMENT_DETECTION_SIDE = "bottom"` — which relay side to monitor for payment signal.
- **Performance**:
  - `EVENT_LOOP_SLEEP = 0.01` — event loop iteration interval.
  - `AE2_CACHE_TTL = 30` — seconds before refreshing AE2 stock cache.
- **Log level**: `LOG_LEVEL = "DEBUG"` (one of DEBUG, INFO, WARN, ERROR).
- **UI message table** (`MSG`) with required keys:
  ```lua
  MSG = {
    header           = "ccshop",
    screen1_hint     = "Right-click a pedestal to select a category",
    screen1_discount_info = {
        "Bulk discounts:",
        "2% at 1 tier",
        "5% at 2",
        "10% at 3",
        "15% at 4",
        "20% at 5+"
    },
    screen2_hint     = "RMB: select   LMB: go back",
    screen3_hint_select  = "RMB: select quantity   LMB: go back",
    screen3_base_price   = "Base price: %d spurs for %d units",
    screen3_breakdown_line = "Price breakdown: %d * %d/%d = %d",
    screen3_discount_line = "Discount: -%d%% (%d spurs)",
    screen3_total_line = "Total: %d spurs",
    screen3_pedestal_instruction = "Use pedestals to change quantity",
    screen3_insert       = "Please insert %s into the depositor",
    screen4_thanks   = "Your items will be dispensed. Thank you!",
    cancel_btn       = "CANCEL",
    error_ae2        = "AE2 network unavailable",
    error_deposit    = "Depositor unavailable",
    error_relay      = "Relay unavailable",
    timeout_msg      = "Session timed out. Returning to main screen.",
  }
  ```
- `validatePeripherals()` — wraps all peripherals at startup; returns `false + error` if any missing.

### `items.lua`
- `CATEGORIES`, `MATERIALS`, `QUANTITIES` tables.
- Helper functions: `quantityToNumber(qty)`, `numericQuantities()`, `findQuantityIndex(num)`.
- Bulk discount system: `DISCOUNT_LEVELS`, `calculateDiscountLevel()`, `getDiscountPercent()`, `calculatePriceWithDiscount()`.
- Currency conversion: `CURRENCY_UNITS`, `spursToCoins(spurs)`.
- Required structure:
  ```lua
  CATEGORIES = {
    { label = "Metals",   item = "minecraft:iron_ingot"          },
    { label = "Crystals", item = "ae2:certus_quartz_crystal"     },
    { label = "Redstone", item = "minecraft:redstone"            },
    { label = "Dyes",     item = "minecraft:blue_dye"            },
  }

  MATERIALS = {
    {
      label     = "Iron Ingot",
      item      = "minecraft:iron_ingot",
      category  = "Metals",   -- must match a CATEGORIES label exactly
      minQty    = 64,         -- first quantity option shown; must exist in QUANTITIES
      basePrice = 10,         -- price in spurs for minQty units
    },
  }

  QUANTITIES = { 1, 8, 32, 64, 256, 512, 1024, "4k", "16k", "32k" }
  ```
- Prices are calculated as `floor(basePrice * (selectedQty / minQty))` then adjusted by bulk discount multiplier.

### `db.lua`
- `log(record)` — appends a purchase record in ndjson format.
- `readAll()` — reads all logged purchases.

## UI Layout

The UI uses **fixed coordinate positioning** with Basalt:

- **Header** (top bar): Line 1-2, red background, white text "ccshop", centered, font size 2.
- **Spacer**: Line 3 (if monitor ≥ 9 lines tall), black background.
- **Content area**: Lines 4 through `height - 4` (dynamically sized labels).
- **Cancel button**: Positioned at `(2, height - 3)`, size `(min(14, width-4), 3)`, red background, white text, padded text " CANCEL ".

Content labels are created for each line in the content area and shown/hidden per screen state. Each label line is a separate Basalt label object for precise control.

## Cancel button behaviour

| Screen | Cancel button visible | Cancel action |
|---|---|---|
| 1 – Category | No | — |
| 2 – Material | Yes | Return to Screen 1 |
| 3A – Quantity selecting | Yes | Return to Screen 1 |
| 3B – Awaiting payment | Yes | Lock depositor, return to Screen 1 |
| 4 – Thank you | No | — |

- Button position: **bottom‑left** corner of monitor `(2, height - 3)`.
- Label: `"CANCEL"` (padded with spaces in code: `" CANCEL "`).
- **Debouncing**: 500ms debounce window prevents multiple rapid clicks.
- **Async reset**: Click triggers `os.startTimer(0.05)` for a timer-based `state.resetToMainScreen()` in the event loop coroutine — avoids Basalt coroutine issues with nested pedestal operations.
- **Visual feedback**: Button turns gray immediately on click; stays visible for 200ms even on screen 1 for feedback visibility.

## Idle timeout behaviour

- Applies to: Screens 2, 3A, 3B.
- Duration: `IDLE_TIMEOUT` (120 s) of no user interaction.
- Action: if on 3B → lock depositor first; then `state.resetToMainScreen()`.
- `state.lastActivity = os.clock()` is reset on every rendering (pedestal click, cancel press trigger render).

## Event Handling

The `eventLoop` (`modules/events.lua`) blocks on `os.pullEvent()` and handles two event types:

1. **Pedestal click events** (`pedestal_left_click`, `pedestal_right_click`):
   - `eventData[2]`: pedestal object or name string.
   - `eventData[3]`: table with `name` (item ID), `count`, `displayName`.
   - The script maps the pedestal to a pedestal index via `pedestalObjectToIndex` / `pedestalIndexByName`.
   - Retrieves the corresponding option from `state.currentOptions`.
   - Extracts selected count from `displayName` → numeric parsing, with fallback to `opt.count` and `eventData[3].count`.
   - Category and material matching falls back from exact `itemId` match to prefix match (ignoring metadata after colon).

2. **Timer events** (`timer`):
   - Handles the cancel button's async `os.startTimer(0.05)` for debounced state reset.
   - Calls `state.resetToMainScreen()` in the event loop coroutine when the timer fires.

## Screen Rendering Guard

`modules/screens.lua` implements a **rendering guard** with pending render queue to prevent re-entrant rendering and infinite loops:

- `_rendering` flag: prevents concurrent renders. If `renderCurrentScreen()` is called while already rendering, it sets `_pendingRender = true` and returns.
- `_pendingRender` queue: after current render completes, processes pending render exactly once.
- `_lastRenderedScreen` / `_lastRenderedSubState` / `_lastRenderedQty` tracking: skips rendering if nothing meaningful changed since last render — avoids redundant updates.
- **Infinite loop prevention**: If cancel triggers `resetToMainScreen()` during a render → pending render → checks screen/subState → unchanged → skips → loop broken.

## Pedestal Rendering with Custom Coroutine Scheduler

Pedestal updates (`modules/pedestal.lua`) use a **custom coroutine scheduler** (`runPedestalTasksParallel`) that runs pedestal tasks in parallel while preserving events for other top-level coroutines (Basalt, event loop, payment monitor):

- Each pedestal task runs in its own coroutine.
- The scheduler pulls raw events, re-queues non-timer events (so Basalt can process monitor touches for the cancel button), and resumes coroutines.
- Tasks yield with `os.sleep(0)` after each pedestal operation for interleaving.

This avoids the nested `parallel.waitForAll` problem where inner event loops would consume events meant for other coroutines.

## Payment Detection

Payment is detected by monitoring the **redstone relay input** for changes from the established baseline:

1. **Baseline capture**: In `renderScreen3Confirming()`, all relay input sides are sampled **before** unlocking the depositor — eliminates the blind window where coins could be inserted undetected.
2. **Depositor unlocked** after baseline capture.
3. **0.5s stabilization** sleep after unlock.
4. **Payment monitoring**: In `checkPaymentDetection()`, current relay inputs are compared against baseline on the configured `PAYMENT_DETECTION_SIDE` (default: `"bottom"`), with fallback to all other sides.
5. **Payment timeout**: If `paymentDeadline` (`os.clock() + PAYMENT_TIMEOUT`) is reached, depositor is locked and `state.resetToMainScreen()`.
6. **On payment**: Depositor locked, `paymentPaid = true`, screen transitions to 4.

## Pedestal API Notes

The `display_pedestal` peripheral from the Pedestals mod **does not have a `setLabel` method**. Instead, use `setItem(item, label)` with the label as the second argument. (This was discovered and fixed in commit `d3fa13f`; earlier versions incorrectly called `setLabel`.)

The code uses `pcall(pedestals[idx].setItem, opt.item, label)` and wraps `setLabelRendered`/`setItemRendered` calls in `pcall` because these methods may or may not exist depending on the mod version.

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
- Logs include peripheral wrapping results, stock queries, event data, state transitions, and payment detection.
- The debug file is appended each run; clear it manually if it grows too large.
- Purchase records are stored in `/ccshop/purchases.json` (ndjson format).
- Log level controlled by `LOG_LEVEL` in `config.lua` (`DEBUG`, `INFO`, `WARN`, `ERROR`).
- Most debug logging statements are commented out in production; uncomment for detailed diagnosis.

## See Also

- [`state_transitions.md`](./state_transitions.md) — Detailed state machine documentation.
- [`parallel_execution.md`](./parallel_execution.md) — Concurrency model and coroutine scheduler documentation.


## Workflow Orchestration

### 1. Plan Mode Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution

### 3. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

## Task Management

1. **Plan First**: Write plan to `tasks/todo.md` with checkable items
2. **Verify Plan**: Check in before starting implementation
3. **Track Progress**: Mark items complete as you go
4. **Explain Changes**: High-level summary at each step
5. **Document Results**: Add review section to `tasks/todo.md`
6. **Capture Lessons**: Update `tasks/lessons.md` after corrections

## Core Principles

- **Simplicity First**: Make every change as simple as possible. Impact minimal code.
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards.
- **Minimal Impact**: Changes should only touch what's necessary. Avoid introducing bugs.


