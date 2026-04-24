# State Transition Analysis for CC:Tweaked Display Shop System

## Global State Structure

Definition in `modules/state.lua`:

```lua
local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity/payment, 4=thankyou
    subState = nil,           -- nil, "selecting", or "confirming" (screen 3 only)
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    calculatedPrice = nil,    -- final price after discount
    discountLevel = nil,      -- bulk discount level (0-5, 5+ all get 20%)
    discountPercent = nil,    -- discount percentage (0, 2, 5, 10, 15, 20)
    basePriceForQty = nil,    -- price before discount (for display)
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table {item, label, count}
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    availableQuantities = nil, -- list of numeric quantities available for selected material
    paymentBaseline = nil,    -- baseline relay input state (captured before unlock)
    paymentDeadline = nil,    -- os.clock() deadline for payment timeout
    paymentPaid = false,
    paymentCheckCount = 0,    -- counter for payment detection checks
    -- Crafting fields
    craftingJobId = nil,      -- Job ID returned by scheduleCrafting
    craftingStatus = nil,     -- nil, "starting", "in_progress", "completed", "failed", "cancelled"
    craftedObjects = 0,       -- Number of objects crafted so far
    totalObjects = 0,         -- Total objects to craft (selectedQty / minQty)
    craftingStartTime = nil,  -- os.clock() when crafting started
    craftingLastUpdate = nil, -- Last progress update time
}
```

## Initial State

After script startup, state is initialized with values from `modules/state.lua`:
- `screen = 1` (category screen)
- all other fields have values `nil`, `false`, `0`, or empty tables
- `lastActivity = os.clock()` (start time)

The `resetState()` function restores this same initial state, but is currently unused in the main flow.

## Screens and Substates

- **Screen 1**: Category selection (no substate)
- **Screen 2**: Material selection (no substate)
- **Screen 3**: Quantity selection and payment
  - **subState = "selecting"**: Quantity selection
  - **subState = "confirming"**: Awaiting payment
- **Screen 4**: Thank you / Crafting (no substate, but internal `craftingStatus` drives UI)
  - `craftingStatus = nil`: Initial entry, shows thank you message
  - `craftingStatus = "starting"`: Crafting job being scheduled
  - `craftingStatus = "in_progress"`: Crafting in progress (progress counter + bar)
  - `craftingStatus = "completed"`: Crafting done (collection message shown for CONFIRM_DELAY)
  - `craftingStatus = "failed"` or `"cancelled"`: Error state (brief display, then return)

## Sources of State Transitions

1. **Pedestal clicks** (`events.lua`) – handling `pedestal_left_click` and `pedestal_right_click` events
2. **Cancel button** (`ui.lua`) – clicking the cancel button
3. **Idle timeout** (`payment.lua` – `checkIdleTimeout`) – no user activity for `IDLE_TIMEOUT` (120s)
4. **Payment timeout** (`payment.lua` – `checkPaymentDetection`) – no payment before `paymentDeadline`
5. **Payment detection** (`payment.lua` – `checkPaymentDetection`) – relay state change
6. **Screen rendering** (`screens.lua`) – automatic transitions when materials/quantities are unavailable
7. **Screen 4 rendering** (`screens.lua` – `renderScreen4`) – starts crafting via `crafting.startCrafting()`
8. **Crafting module** (`crafting.lua`):
   - `craftingMonitorLoop` – polls progress, handles terminal states, resets to screen 1
   - `handleCraftingDone` / `handleCraftingCancelled` (from event loop) – sets terminal crafting status
9. **Pedestal state updates** (`pedestal.lua`) – updating `currentOptions` and `currentPedestalIndices`
10. **State reset** (`state.lua` – `resetState`) – restoring initial state

---

## Detailed State Transitions

### 1. Transitions from Pedestal Clicks (`events.lua`)

#### Screen 1 → Screen 2 (category selection)
- **Condition**: `screen == 1`, `side == 'right'`, category found by `itemId`
- **Action** (`handleScreen1Click`):
  ```lua
  state.updateState({
      selectedCategory = CATEGORIES[catIdx].label,
      screen = 2,
      paymentDeadline = nil
  })
  ```
- **Note**: Right button (RMB) only. Left button ignored.

#### Screen 2 → Screen 3 selecting (material selection)
- **Condition**: `screen == 2`, `side == 'right'`, material found by `itemId`
- **Action** (`handleScreen2Click`):
  ```lua
  state.updateState({
      selectedMaterial = materialsInCategory[matIdx],
      screen = 3,
      subState = 'selecting',
      paymentDeadline = nil
  })
  ```

#### Screen 2 → Screen 1 (return to categories)
- **Condition**: `screen == 2`, `side == 'left'`
- **Action** (`handleScreen2Click`):
  ```lua
  state.updateState({
      screen = 1,
      paymentBaseline = nil,
      paymentCheckCount = 0,
      paymentDeadline = nil
  })
  ```

#### Screen 3 selecting → Screen 3 confirming (quantity selection)
- **Condition**: `screen == 3`, `subState == 'selecting'`, `side == 'right'`, `selectedCount` exists
- **Action** (`handleScreen3Click`):
  ```lua
  state.updateState({
      selectedQty = selectedCount,
      subState = 'confirming',
      paymentDeadline = os.clock() + PAYMENT_TIMEOUT
  })
  ```
- **Note**: `paymentDeadline` is set here so the payment timeout starts immediately upon quantity selection, before `renderScreen3Confirming` runs. `renderScreen3Confirming` may also set it again as a fallback.

#### Screen 3 selecting → Screen 2 (return to material selection)
- **Condition**: `screen == 3`, `subState == 'selecting'`, `side == 'left'`
- **Action** (`handleScreen3Click`):
  ```lua
  state.updateState({
      screen = 2,
      subState = nil,
      paymentBaseline = nil,
      paymentCheckCount = 0,
      paymentDeadline = nil
  })
  ```

#### Screen 3 confirming → Screen 3 selecting (change quantity)
- **Condition**: `screen == 3`, `subState == 'confirming'`, `side == 'right'`, `selectedCount` exists and differs from current `selectedQty`
- **Action** (`handleScreen3Click`):
  ```lua
  state.updateState({ selectedQty = selectedCount, paymentDeadline = os.clock() + PAYMENT_TIMEOUT })
  ```
- **Note**: Remains in `subState = 'confirming'`. `renderScreen3Confirming` will be called again (since `selectedQty` changed), which captures a new baseline and sets a new payment deadline.

#### Screen 3 confirming → Screen 3 selecting (return to quantity selection)
- **Condition**: `screen == 3`, `subState == 'confirming'`, `side == 'left'`
- **Action** (`handleScreen3Click`):
  ```lua
  peripherals.lockDepositor()
  state.updateState({
      subState = 'selecting',
      paymentBaseline = nil,
      paymentCheckCount = 0,
      paymentDeadline = nil
  })
  ```
- **Note**: Locks depositor before returning.

#### Screen 4 (ignore)
- **Condition**: `screen == 4`
- **Action**: None – ignores clicks.

### 2. Transitions from Cancel Button (`ui.lua`)

#### Cancel on screen 2, 3 selecting, 3 confirming
- **Condition**: Cancel button click, `screen == 2` or `screen == 3` with any `subState`
- **Action** (in `onClick`):
  1. Debounce check (500ms window) — if too soon, return.
  2. Immediate visual feedback: button turns gray.
  3. Play low sound (bass F).
  4. If `screen == 3` and `subState == "confirming"`, lock depositor.
  5. Start async timer (`os.startTimer(0.05)`) — timer fires in event loop coroutine, which calls `state.resetToMainScreen()`.
  6. Fallback: if `os.startTimer` fails, call `state.resetToMainScreen()` directly.
- **Note**: Async timer avoids Basalt coroutine issues with nested pedestal operations. `resetToMainScreen()` clears selection, payment, and crafting fields, preserving only `lastActivity`.

### 3. Idle Timeout (`payment.lua` – `checkIdleTimeout`)

#### Timeout on screen 2 or 3 (with substate)
- **Condition**: `screen == 2` or `(screen == 3 and subState)`, `lastActivity` exists and `os.clock() - lastActivity > IDLE_TIMEOUT` (120s)
- **Action**:
  ```lua
  if screen == 3 and subState == 'confirming' then
      peripherals.lockDepositor()
  end
  state.resetToMainScreen()
  ```
- **Note**: Works on screens 2, 3 selecting, 3 confirming. Does not work on screen 1 (no timeout) or 4.

### 4. Payment Timeout (`payment.lua` – `checkPaymentDetection`)

#### Payment timeout on screen 3 confirming
- **Condition**: `screen == 3`, `subState == 'confirming'`, `paymentDeadline` exists and `os.clock() >= paymentDeadline`
- **Action**:
  ```lua
  peripherals.lockDepositor()
  state.resetToMainScreen()
  ```

### 5. Payment Detection (`payment.lua` – `checkPaymentDetection`)

#### Payment detected on screen 3 confirming
- **Condition**: `screen == 3`, `subState == 'confirming'`, `paymentPaid == false`, relay state change relative to `paymentBaseline`
- **Action**:
  ```lua
  peripherals.lockDepositor()
  state.updateState({ paymentPaid = true, screen = 4, paymentDeadline = nil })
  ```
- **Note**: Transition to screen 4. `paymentPaid` set to `true`. `renderScreen4` will start crafting via `crafting.startCrafting()`.

### 6. Automatic Transitions During Rendering (`screens.lua`)

#### No materials available (screen 2 → screen 1)
- **Condition**: `renderScreen2`, `#options == 0` (no materials with sufficient stock)
- **Action**:
  ```lua
  state.updateState({ screen = 1, selectedCategory = nil, paymentDeadline = nil })
  ```

#### No quantities available (screen 3 selecting → screen 2)
- **Condition**: `renderScreen3Selecting`, `#quantities == 0` (stock less than `minQty`)
- **Action**:
  ```lua
  state.updateState({ screen = 2, selectedMaterial = nil, paymentDeadline = nil })
  ```

#### Depositor error (screen 3 confirming → screen 1)
- **Condition**: `renderScreen3Confirming`, `setTotalPrice` fails
- **Action**:
  ```lua
  ui.getHintLabel():setText(MSG.error_deposit)
  os.sleep(2)
  state.resetToMainScreen()
  ```

### 7. Screen 4: Crafting Flow (`screens.lua` – `renderScreen4`)

The screen 4 flow splits into two paths: crafting (primary) and mock dispense (fallback).

#### Path A: Crafting started successfully
- **Condition**: `crafting.startCrafting()` returns `true`
- **Flow**:
  1. `startCrafting()` calls `scheduleCrafting("item", item, amount)` on `ae2cc_adapter_13`
  2. Sets `craftingStatus = "starting"` → `"in_progress"` (subscriber triggers UI re-render via pending render; re-entrancy guard prevents double execution of `renderScreen4`)
  3. Returns immediately — the crafting monitor loop handles timing

#### Path B: Crafting failed / adapter unavailable (fallback)
- **Condition**: `crafting.startCrafting()` returns `false`
- **Action**:
  ```lua
  logging.writeLog("INFO", "[MOCK] Dispense " .. selectedQty .. "x " .. selectedMaterial.item)
  os.sleep(CONFIRM_DELAY)
  state.resetToMainScreen()
  ```

#### Re-entrancy guard
- `_renderScreen4Running` flag prevents `renderScreen4()` from executing twice.
- Without this guard, the `craftingStatus` state changes inside `startCrafting()` would trigger a pending render that re-calls `renderScreen4()`, causing a **second `scheduleCrafting()` call** (double dispense).

### 8. Crafting Module Transitions (`crafting.lua`)

#### Crafting started (screen 4 → crafting starting)
- **Action** (`startCrafting`):
  ```lua
  state.updateState({
      craftingStatus = "starting",
      totalObjects = amount,    -- selectedQty / minQty
      craftedObjects = 0,
      craftingStartTime = os.clock()
  })
  ```
- **Note**: `amount = math.floor(selectedQty / minQty)` because the dispensing AE2 system is configured to emit `minQty` items per crafting unit.

#### Crafting in progress (starting → in_progress)
- **Condition**: `scheduleCrafting()` succeeds
- **Action** (`startCrafting`):
  ```lua
  state.updateState({
      craftingJobId = jobId,
      craftingStatus = "in_progress"
  })
  ```

#### Crafting progressed (polling update)
- **Source**: `checkCraftingProgress()` called from `craftingMonitorLoop` at `CRAFTING_POLL_INTERVAL` (1s)
- **Action**: Updates `craftedObjects` when new progress data available from `getCraftingCPUs()`
  ```lua
  state.updateState({
      craftedObjects = totalCrafted,
      craftingLastUpdate = os.clock()
  })
  ```

#### Crafting completed (polling detection)
- **Condition**: `getCraftingCPUs()` reports `cpu.jobStatus.status == "DONE"`
- **Action** (`checkCraftingProgress`):
  ```lua
  state.updateState({
      craftingStatus = "completed",
      craftedObjects = total,
      craftingLastUpdate = os.clock()
  })
  ```

#### Crafting completed (event detection)
- **Source**: `ae2cc:crafting_done` event from `events.lua` event loop
- **Action** (`handleCraftingDone`):
  ```lua
  state.updateState({
      craftingStatus = "completed",
      craftedObjects = totalObjects,
      craftingLastUpdate = os.clock()
  })
  ```

#### Crafting cancelled (polling or event)
- **Source**: `getCraftingCPUs()` reports `"CANCELLED"` OR `ae2cc:crafting_cancelled` event
- **Action** (`handleCraftingCancelled` / `checkCraftingProgress`):
  ```lua
  state.updateState({ craftingStatus = "cancelled" })
  ```

#### Crafting failed
- **Condition**: `scheduleCrafting()` pcall fails
- **Action** (`startCrafting`):
  ```lua
  state.updateState({ craftingStatus = "failed" })
  return false  -- triggers mock dispense fallback in renderScreen4
  ```

### 9. Crafting Monitor Loop Terminal State Handling (`crafting.craftingMonitorLoop`)

The monitor loop (4th coroutine in `parallel.waitForAny`) handles terminal states from both its own polling AND event handler pre-emption:

#### When monitor detects completion (via `checkCraftingProgress`)
- **Action**:
  ```lua
  os.sleep(CONFIRM_DELAY)   -- show collection message for 5s
  state.resetToMainScreen()
  ```

#### When event handler pre-emptively set `craftingStatus = "completed"`
- **Condition**: Monitor loop sees `craftingStatus == "completed"` (not via checkCraftingProgress)
- **Action**:
  ```lua
  os.sleep(CONFIRM_DELAY)   -- same wait
  state.resetToMainScreen()
  ```

#### When event handler pre-emptively set `craftingStatus = "cancelled"` or `"failed"`
- **Condition**: Monitor loop sees `craftingStatus == "cancelled"` or `"failed"` (not via checkCraftingProgress)
- **Action**:
  ```lua
  os.sleep(2)
  state.resetToMainScreen()
  ```

#### Why both polling and event handling are needed
- The event loop handles `ae2cc:crafting_done` / `ae2cc:crafting_cancelled` for immediate status updates (UI responsiveness)
- The monitor loop provides a backup and handles timing/delay management for all terminal states
- The monitor loop poll interval: `CRAFTING_POLL_INTERVAL` (1s) when active, `CRAFTING_IDLE_POLL_INTERVAL` (5s) when idle

### 10. Pedestal State Updates (`pedestal.lua`)

#### When setting pedestal options
- **Called**: `setPedestalOptions`
- **Action**:
  ```lua
  state.updateState({
      currentOptions = currentOptions,
      currentPedestalIndices = currentPedestalIndices
  })
  ```

#### When clearing pedestals
- **Called**: `clearPedestals`
- **Action**:
  ```lua
  state.updateState({
      currentOptions = {},
      currentPedestalIndices = {},
      lastSelectedPedestal = nil
  })
  ```

### 11. Crafting Event Handling (`events.lua`)

The event loop handles two AE2 crafting events:

#### `ae2cc:crafting_done`
- **Action**:
  ```lua
  local crafting = require("modules.crafting")
  crafting.handleCraftingDone()
  ```

#### `ae2cc:crafting_cancelled`
- **Action**:
  ```lua
  local crafting = require("modules.crafting")
  crafting.handleCraftingCancelled()
  ```

### 12. State Reset Functions (`state.lua`)

#### `resetState()` – Full reset to initial state (currently unused)
- **Action**:
  ```lua
  local initialState = { ... }  -- full initial state including crafting fields
  updateState(initialState)
  ```

#### `resetToMainScreen()` – Reset to main screen while preserving pedestal state
- **Called**: Cancel button, idle timeout, payment timeout, crafting completion/cancellation/failure, depositor error
- **Action**:
  ```lua
  updateState({
      screen = 1,
      selectedCategory = nil,
      selectedMaterial = nil,
      selectedQty = nil,
      subState = nil,
      calculatedPrice = nil,
      discountLevel = nil,
      discountPercent = nil,
      basePriceForQty = nil,
      availableQuantities = nil,
      paymentPaid = false,
      paymentCheckCount = 0,
      paymentBaseline = nil,
      paymentDeadline = nil,
      currentOptions = {},
      currentPedestalIndices = {},
      lastSelectedPedestal = nil,
      -- Crafting fields cleared:
      craftingJobId = nil,
      craftingStatus = nil,
      craftedObjects = 0,
      totalObjects = 0,
      craftingStartTime = nil,
      craftingLastUpdate = nil,
  })
  ```
- **Note**: Only `lastActivity` is preserved. All crafting fields are cleared.

### 13. Other State Updates

#### `lastActivity` reset during rendering
- **Called**: `screens.renderCurrentScreen`
- **Action**:
  ```lua
  state.updateState({ lastActivity = os.clock() })
  ```

#### `availableQuantities` set in `renderScreen3Selecting`
- **Action**:
  ```lua
  state.updateState({ availableQuantities = quantities })
  ```

#### `calculatedPrice`, `discountLevel`, `discountPercent`, `basePriceForQty` set in `renderScreen3Confirming`
- **Action**:
  ```lua
  state.updateState({
      calculatedPrice = finalPrice,
      discountLevel = discountLevel,
      discountPercent = discountPercent,
      basePriceForQty = basePriceForQty
  })
  ```

#### `lastSelectedPedestal` set in `renderScreen3Confirming`
- **Action**:
  ```lua
  state.updateState({ lastSelectedPedestal = idx })
  ```

#### `paymentBaseline`, `paymentDeadline`, `paymentPaid`, `paymentCheckCount` set in `renderScreen3Confirming`
- **Action**:
  ```lua
  state.updateState({
      paymentBaseline = baselineTable,
      paymentDeadline = os.clock() + PAYMENT_TIMEOUT,
      paymentPaid = false,
      paymentCheckCount = 0
  })
  ```

#### `paymentCheckCount` incremented in `checkPaymentDetection`
- **Action**:
  ```lua
  state.updateState({ paymentCheckCount = state.getState("paymentCheckCount") + 1 })
  ```

---

## State Transition Diagram

```
Screen 1 (Category)
    | RMB (category)
    v
Screen 2 (Material)
    | RMB (material)          LMB / Cancel / Idle Timeout
    v                         |
Screen 3 selecting (Quantity) <--+
    | RMB (quantity)          LMB / Cancel / Idle Timeout
    v                         |
Screen 3 confirming (Payment) <--+
    | Payment detected        LMB / Cancel / Idle Timeout / Payment Timeout
    v
Screen 4 (Thank you / Crafting)
    |
    +-- crafting.startCrafting() --+
    |     |                        |
    |  success                  fail (mock dispense)
    |     |                        |
    |     v                        v
    |  craftingStatus =       os.sleep(CONFIRM_DELAY)
    |  "starting"                 |
    |     |                       v
    |  scheduleCrafting()    Screen 1
    |     |
    |  craftingStatus =
    |  "in_progress"
    |     |
    |  [monitor polls 1s] ---- polling ----+
    |     |  OR                            |
    |  ae2cc:crafting_done event          |
    |     |                                |
    |  craftingStatus =                   |
    |  "completed"                         |
    |     |                                |
    |  os.sleep(CONFIRM_DELAY)            |
    |     |                                |
    |  [show collection message]          |
    |     |                                |
    +-----+--------------------------------+
          |
          v
       Screen 1

Alternate paths:
  craftingStatus = "cancelled" → os.sleep(2) → Screen 1
  craftingStatus = "failed"    → os.sleep(2) → Screen 1  (or fallback to mock)
```

---

## Impact of Transitions on Key State Fields

### `paymentDeadline`
- **Set**:
  - In `events.lua` `handleScreen3Click` on transition from screen 3 selecting → confirming: `os.clock() + PAYMENT_TIMEOUT`
  - In `events.lua` when changing quantity in confirming state.
  - In `renderScreen3Confirming` as fallback if nil.
- **Reset to nil** in:
  - Transitions from screen 3 confirming (cancel, payment timeout, payment detected, idle timeout)
  - Transitions from screen 3 selecting to screen 2 (LMB)
  - Transitions from screen 2 to screen 1 (LMB, cancel, idle timeout)
  - Transitions from screen 1 to screen 2 (RMB)
  - Automatic transitions (no materials/quantities, depositor error)
  - Screen 4 after returning to screen 1

### `paymentBaseline`
- **Set**: only in `renderScreen3Confirming` (baseline relay inputs)
- **Reset to nil** in:
  - Transitions from screen 3 confirming (cancel, timeout, payment detected, idle timeout)
  - Transitions from screen 3 selecting to screen 2 (LMB)
  - Transitions from screen 2 to screen 1 (LMB, cancel, idle timeout)
  - Screen 4 after returning to screen 1

### `paymentPaid`
- **Set to `true`**: when payment detected (transition to screen 4)
- **Reset to `false`**: in idle timeout, payment timeout, cancel, `resetToMainScreen()`

### `selectedCategory`, `selectedMaterial`, `selectedQty`
- **Set**: when selecting category, material, quantity
- **Reset to nil**: via `resetToMainScreen()` or specific back transitions

### `availableQuantities`
- **Set**: in `renderScreen3Selecting`
- **Reset to nil**: in `resetToMainScreen()`

### `calculatedPrice`
- **Set**: in `renderScreen3Confirming`
- **Reset to nil**: in `resetToMainScreen()`

### `currentOptions` and `currentPedestalIndices`
- **Set**: in `setPedestalOptions`
- **Reset**: in `clearPedestals` and `resetToMainScreen()`

### `lastActivity`
- **Set**: when rendering any screen (`renderCurrentScreen`)
- **Preserved**: in `resetToMainScreen()` – not cleared
- **Used**: for idle timeout detection

### Crafting Fields

#### `craftingJobId`
- **Set**: in `startCrafting()` after successful `scheduleCrafting()` (return value or `table.jobId`)
- **Reset to nil**: in `resetToMainScreen()` and `resetState()`
- **Purpose**: tracking which AE2 crafting job belongs to this transaction

#### `craftingStatus`
- **Set to `"starting"`**: in `startCrafting()` before calling `scheduleCrafting()`
- **Set to `"in_progress"`**: after `scheduleCrafting()` succeeds
- **Set to `"completed"`**: in `checkCraftingProgress()` (CPU status == DONE), `handleCraftingDone()` (event), or when job not found in CPUs
- **Set to `"cancelled"`**: in `checkCraftingProgress()` (CPU status == CANCELLED) or `handleCraftingCancelled()` (event)
- **Set to `"failed"`**: in `startCrafting()` when `scheduleCrafting()` pcall fails
- **Reset to nil**: in `resetToMainScreen()` and `resetState()`
- **Purpose**: drives UI rendering of screen 4 (progress counter, bar, collection message)

#### `craftedObjects`
- **Set**: updated by `checkCraftingProgress()` each poll cycle; set to `total` on completion
- **Reset to 0**: in `startCrafting()`, `resetToMainScreen()`, `resetState()`
- **Purpose**: progress display counter

#### `totalObjects`
- **Set**: in `startCrafting()` (amount = selectedQty / minQty)
- **Reset to 0**: in `resetToMainScreen()`, `resetState()`
- **Purpose**: total count for progress display

#### `craftingStartTime` / `craftingLastUpdate`
- **Set**: in `startCrafting()` and each progress update in `checkCraftingProgress()`
- **Reset to nil**: in `resetToMainScreen()`, `resetState()`
- **Purpose**: timing tracking (for potential timeout monitoring)

---

## Subscriber and Rendering Guard Updates

### State Subscriber (`shop.lua`)
The subscriber triggers rendering on changes to: `screen`, `subState`, `selectedQty`, and `craftingStatus`.

```lua
state.subscribe(function(changes)
    if changes.screen ~= nil or changes.subState ~= nil
       or changes.selectedQty ~= nil or changes.craftingStatus ~= nil then
        screens.renderCurrentScreen()
    end
end)
```
- **Note**: `craftedObjects` changes alone do NOT trigger re-render. The UI updates on status transitions (starting → in_progress → completed). Progress bar animation during in_progress requires adding `craftedObjects` to this filter.

### Rendering Guard (`screens.lua`)
The guard tracks `_lastRenderedCraftingStatus` alongside `_lastRenderedScreen`, `_lastRenderedSubState`, and `_lastRenderedQty`:

```lua
local _lastRenderedCraftingStatus = nil

-- Skip check includes craftingStatus:
if screen == _lastRenderedScreen and subState == _lastRenderedSubState
   and selectedQty == _lastRenderedQty
   and craftingStatus == _lastRenderedCraftingStatus then
    return  -- skip
end
```

---

## Concurrency Model for Crafting

### Coroutines (4 total in `parallel.waitForAny`)

| Coroutine | Purpose | Yield pattern |
|---|---|---|
| Basalt (A) | UI event processing | `os.pullEvent()` internally |
| Event loop (B) | Pedestal clicks, timer, AE2 events | `os.pullEvent()` |
| Payment monitor (C) | Payment detection, idle timeout | `os.sleep(0.02)` |
| Crafting monitor (D) | Crafting progress polling, terminal state handling | `os.sleep(1s or 5s)` |

### Event flow for crafting completion (two paths)

**Path 1 — Event driven (fast jobs):**
1. AE2 fires `ae2cc:crafting_done`
2. Coroutine B (event loop) pulls the event
3. Calls `crafting.handleCraftingDone()` → `state.updateState({craftingStatus = "completed"})`
4. Subscriber → `renderCurrentScreen()` → UI shows collection message
5. Later, Coroutine D (monitor) sees status = "completed" → sleeps CONFIRM_DELAY → resets

**Path 2 — Polling driven (long jobs):**
1. Coroutine D (monitor) pulls `os.sleep(1)` completion
2. Calls `checkCraftingProgress()` → detects DONE → sets `craftingStatus = "completed"`
3. Monitor handles terminal state: sleeps CONFIRM_DELAY → resets

### Re-entrancy protection
- `renderScreen4` has `_renderScreen4Running` guard → prevents double `scheduleCrafting()` from pending renders triggered by craftingStatus changes
- `renderCurrentScreen` has `_rendering` guard + `_pendingRender` queue → prevents infinite loops
- Terminal state handling runs in both event loop and monitor, but `resetToMainScreen()` is idempotent

---

## Potential Issues and Inconsistencies

1. **`selectedCategory` remains set after no materials** – **FIXED**: now reset to `nil` when no materials available (screen 2 → 1).

2. **`selectedMaterial` remains set after no quantities** – **FIXED**: now reset to `nil` when no quantities available (screen 3 → 2).

3. **`paymentDeadline` reset in many places** – while necessary, may lead to missed deadline if resetting happens too early.

4. **No reset of `availableQuantities` during transitions** – **FIXED**: now included in `resetToMainScreen()`.

5. **Transition from screen 3 confirming to selecting via LMB resets `paymentBaseline` and `paymentCheckCount`**, but does not reset `selectedQty` – user can select a different quantity.

6. **RMB in confirming state changes quantity but stays in confirming** – `selectedQty` is updated, subState remains `'confirming'`. `renderScreen3Confirming` runs again and captures a new baseline, sets a new deadline, and re-unlocks the depositor.

7. **Crafting re-entrancy with pending render guard** – The `_renderScreen4Running` guard is essential. Without it, `startCrafting()`'s internal `craftingStatus` state changes would trigger a pending render that re-calls `renderScreen4()` → second `scheduleCrafting()` → double dispense.

8. **Event handler vs monitor loop for terminal states** – If the event handler (`ae2cc:crafting_done`) fires before the monitor poll, the monitor enters a dedicated `"completed"` branch (not idle sleep) to handle the delay and reset. Both paths produce the same result.

9. **No craftedObjects subscriber trigger** – Progress bar during "in_progress" does not animate because `craftedObjects` changes alone don't trigger `renderCurrentScreen()`. The bar updates on status transitions (`starting` → `in_progress` → `completed`). To add animation, expand the subscriber filter.

10. **Screen 4 ignores pedestal clicks during crafting** – existing behavior, no change.

---

## Recommendations

1. **State transition documentation** – this document should be maintained alongside code changes.

2. **Consistent field resetting** – **ADDRESSED**: `resetToMainScreen()` clears all crafting fields.

3. **Testing all paths** – test every possible transition sequence, especially edge cases: timeouts, cancel, crafting failure, double completion (event + poll).

4. **Logging state changes** – consider adding logging of each state change (with values) for debugging.

5. **Progress bar animation** – to show live progress during "in_progress", add `craftedObjects` to the subscriber filter and add `_lastRenderedCraftedObjects` to the rendering guard.

---

## Configuration Constants Affecting Transitions

### From `config.lua`

| Constant | Default Value | Description | Impact on Transitions |
|----------|---------------|-------------|-----------------------|
| `IDLE_TIMEOUT` | 120 seconds | Idle time before automatic return to screen 1 | Determines condition in `checkIdleTimeout` |
| `PAYMENT_TIMEOUT` | 30 seconds | Time to make payment after unlocking depositor | Used to calculate `paymentDeadline` |
| `CONFIRM_DELAY` | 5 seconds | Display time for thank you / collection message | Determines `os.sleep` in `renderScreen4` and crafting terminal handling |
| `CRAFTING_POLL_INTERVAL` | 1 second | Poll interval when crafting is active | How often `checkCraftingProgress()` runs |
| `CRAFTING_IDLE_POLL_INTERVAL` | 5 seconds | Poll interval when no active craft | How often monitor loop checks when idle |
| `PAYMENT_DETECTION_SIDE` | `"bottom"` | Relay side connected to payment signal | Used in `checkPaymentDetection` |
| `EVENT_LOOP_SLEEP` | 0.01 seconds | Delay between event loop iterations | Affects responsiveness |
| `AE2_CACHE_TTL` | 30 seconds | AE2 stock cache time-to-live | Affects stock data freshness |
| `LOG_LEVEL` | `"DEBUG"` | Logging level | Affects log volume |

### From `items.lua`

| Table | Content | Impact on Transitions |
|-------|---------|-----------------------|
| `CATEGORIES` | List of categories with label and item | Determines options displayed on screen 1 |
| `MATERIALS` | List of materials with category, minQty, basePrice | Determines available materials on screen 2 |
| `QUANTITIES` | List of quantity tiers (numbers or strings) | Determines available quantities on screen 3 |

### From `config.lua` — Peripheral names

| Constant | Value | Purpose |
|----------|-------|---------|
| `AE2_ADAPTER` | `"ae2cc_adapter_14"` | Stock queries (existing AE2 system) |
| `CRAFTING_ADAPTER` | `"ae2cc_adapter_13"` | Item dispensing (separate AE2 system, 1 unit = minQty items) |
| `RELAY_LOCK` | `"redstone_relay_38"` | Depositor lock/unlock |
| `DEPOSITOR` | `"Numismatics_Depositor_8"` | Payment acceptance |
| `SPEAKER_NAME` | `"speaker_212"` | Sound effects |
| `MONITOR` | `"monitor_1012"` | UI display |

### AE2 Stock-Related Conditions

- **Screen 2**: Material is displayed only if `stock >= minQty`
- **Screen 3 selecting**: Quantity is displayed only if `quantity <= stock` and `quantity >= minQty`
- **Screen 4 crafting**: Amount = `selectedQty / minQty` (must be integer; validated in `calculateCraftingAmount`)
- **Automatic transitions**: Missing materials/quantities cause return to previous screen

---
*Document updated 2026-04-23 — Added AE2 crafting integration details.*
