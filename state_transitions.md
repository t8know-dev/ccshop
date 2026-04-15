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
    calculatedPrice = nil,    -- price for selected quantity
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table {item, label, count}
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    availableQuantities = nil, -- list of numeric quantities available for selected material
    paymentBaseline = nil,    -- baseline relay input state for payment detection
    paymentDeadline = nil,    -- os.clock() deadline for payment timeout
    paymentPaid = false,
    paymentCheckCount = 0,    -- counter for payment detection checks
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
- **Screen 4**: Thank you (no substate)

## Sources of State Transitions

1. **Pedestal clicks** (`events.lua`) – handling `pedestal_left_click` and `pedestal_right_click` events
2. **Cancel button** (`ui.lua`) – clicking the cancel button
3. **Idle timeout** (`payment.lua` – `checkIdleTimeout`) – no user activity for `IDLE_TIMEOUT` (120s)
4. **Payment timeout** (`payment.lua` – `checkPaymentDetection`) – no payment before `paymentDeadline`
5. **Payment detection** (`payment.lua` – `checkPaymentDetection`) – relay state change
6. **Screen rendering** (`screens.lua`) – automatic transitions when materials/quantities are unavailable
7. **Thank you screen 4** (`screens.lua` – `renderScreen4`) – automatic return to screen 1 after `CONFIRM_DELAY`
8. **Pedestal state updates** (`pedestal.lua`) – updating `currentOptions` and `currentPedestalIndices`
9. **State reset** (`state.lua` – `resetState`) – restoring initial state

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
      paymentDeadline = nil
  })
  ```

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
  state.updateState({ selectedQty = selectedCount, paymentDeadline = nil })
  ```
- **Note**: Remains in `subState = 'confirming'`? The code only updates `selectedQty` and `paymentDeadline`. However `renderCurrentScreen` will call `renderScreen3Confirming` again, which will reset `paymentDeadline` and `paymentBaseline`. This transition allows changing quantity without returning to selecting.

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
  ```lua
  -- If screen == 3 and subState == "confirming", lock depositor
  if state.getState("screen") == 3 and state.getState("subState") == "confirming" then
      peripherals.lockDepositor()
  end
  -- Reset to main screen using centralized function
  state.resetToMainScreen()
  ```
- **Note**: Uses `resetToMainScreen()` which clears selection and payment fields while preserving `lastActivity` and pedestal state.

### 3. Idle Timeout (`payment.lua` – `checkIdleTimeout`)

#### Timeout on screen 2 or 3 (with substate)
- **Condition**: `screen == 2` or `(screen == 3 and subState)`, `lastActivity` exists and `os.clock() - lastActivity > IDLE_TIMEOUT` (120s)
- **Action**:
  ```lua
  -- If screen == 3 and subState == 'confirming', lock depositor
  if screen == 3 and subState == 'confirming' then
      peripherals.lockDepositor()
  end
  -- Reset to main screen using centralized function
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
- **Note**: Transition to screen 4 (thank you). `paymentPaid` set to `true`, but screen 4 will reset it later.

### 6. Automatic Transitions During Rendering (`screens.lua`)

#### No materials available (screen 2 → screen 1)
- **Condition**: `renderScreen2`, `#options == 0` (no materials with sufficient stock)
- **Action**:
  ```lua
  state.updateState({ screen = 1, selectedCategory = nil, paymentDeadline = nil })
  ```
- **Note**: Returns to screen 1 and resets `selectedCategory` (fixed).

#### No quantities available (screen 3 selecting → screen 2)
- **Condition**: `renderScreen3Selecting`, `#quantities == 0` (stock less than `minQty`)
- **Action**:
  ```lua
  state.updateState({ screen = 2, selectedMaterial = nil, paymentDeadline = nil })
  ```
- **Note**: Returns to screen 2 and resets `selectedMaterial` (fixed).

#### Depositor error (screen 3 confirming → screen 1)
- **Condition**: `renderScreen3Confirming`, `setTotalPrice` fails
- **Action**:
  ```lua
  ui.getHintLabel():setText(MSG.error_deposit)
  os.sleep(2)
  state.resetToMainScreen()
  ```

### 7. Screen 4: Automatic Return to Screen 1 (`screens.lua` – `renderScreen4`)

#### After `CONFIRM_DELAY` seconds
- **Condition**: `screen == 4`, after `os.sleep(CONFIRM_DELAY)`
- **Action**:
  ```lua
  state.resetToMainScreen()
  ```
- **Note**: Uses centralized reset function that clears selection and payment fields while preserving `lastActivity`, `currentOptions`, `currentPedestalIndices`, `lastSelectedPedestal`.

### 8. Pedestal State Updates (`pedestal.lua`)

#### When setting pedestal options
- **Called**: `setPedestalOptions` or `setPedestalOptionsParallel`
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

### 9. State Reset Functions (`state.lua`)

#### `resetState()` – Full reset to initial state (currently unused)
- **Action**:
  ```lua
  local initialState = { ... }  -- full initial state
  updateState(initialState)
  ```

#### `resetToMainScreen()` – Reset to main screen while preserving pedestal state
- **Called**: Cancel button, idle timeout, payment timeout, screen 4 auto-return, depositor error
- **Action**:
  ```lua
  updateState({
      screen = 1,
      selectedCategory = nil,
      selectedMaterial = nil,
      selectedQty = nil,
      subState = nil,
      calculatedPrice = nil,
      availableQuantities = nil,
      paymentPaid = false,
      paymentCheckCount = 0,
      paymentBaseline = nil,
      paymentDeadline = nil
  })
  ```
- **Note**: Does not reset `lastActivity`, `currentOptions`, `currentPedestalIndices`, `lastSelectedPedestal`. This is the preferred way to return to the main screen.

### 11. Other State Updates

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

#### `calculatedPrice` set in `renderScreen3Confirming`
- **Action**:
  ```lua
  state.updateState({ calculatedPrice = price })
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

## State Transition Diagram (simplified)

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
    v                         |
Screen 4 (Thank you)          |
    | Auto-return after CONFIRM_DELAY
    v
Screen 1
```

---

## Impact of Transitions on Key State Fields

### `paymentDeadline`
- **Set**: only in `renderScreen3Confirming` (`os.clock() + PAYMENT_TIMEOUT`)
- **Reset to nil** in:
  - Transitions from screen 3 confirming (cancel, payment timeout, payment detected, idle timeout)
  - Transitions from screen 3 selecting to screen 2 (LMB)
  - Transitions from screen 2 to screen 1 (LMB, cancel, idle timeout)
  - Transitions from screen 1 to screen 2 (RMB)
  - Automatic transitions (no materials/quantities, depositor error)
  - Screen 4 after returning to screen 1
- **Purpose**: tracking payment timeout only in `screen=3, subState=confirming` state

### `paymentBaseline`
- **Set**: only in `renderScreen3Confirming` (baseline relay inputs)
- **Reset to nil** in:
  - Transitions from screen 3 confirming (cancel, timeout, payment detected, idle timeout)
  - Transitions from screen 3 selecting to screen 2 (LMB)
  - Transitions from screen 2 to screen 1 (LMB, cancel, idle timeout)
  - Screen 4 after returning to screen 1
- **Purpose**: storing baseline relay state for payment detection


### `paymentPaid`
- **Set to `true`**: when payment detected
- **Reset to `false`**: in idle timeout, payment timeout, cancel, screen 4
- **Purpose**: preventing multiple payment detections

### `selectedCategory`, `selectedMaterial`, `selectedQty`
- **Set**: when selecting category, material, quantity
- **Reset to nil**:
  - `selectedCategory`: in `resetToMainScreen()` (cancel, timeouts, screen 4), LMB back from screen 2 to 1, and when no materials available (screen 2 → 1)
  - `selectedMaterial`: in `resetToMainScreen()` (cancel, timeouts, screen 4), LMB back from screen 3 selecting to 2, and when no quantities available (screen 3 → 2)
  - `selectedQty`: in `resetToMainScreen()` (transitions to screen 1)
- **Note**: `selectedCategory` is now reset to `nil` when no materials available (screen 2 → 1).

### `availableQuantities`
- **Set**: in `renderScreen3Selecting` (list of numeric quantities available for selected material)
- **Reset to nil**: in `resetToMainScreen()` (transitions to screen 1)
- **Purpose**: caching available quantity tiers for screen 3 confirming display

### `calculatedPrice`
- **Set**: in `renderScreen3Confirming` (price for selected quantity)
- **Reset to nil**: in `resetToMainScreen()` (transitions to screen 1)
- **Purpose**: storing calculated price for display and logging

### `currentOptions` and `currentPedestalIndices`
- **Set**: when rendering pedestal options (`setPedestalOptions`)
- **Reset**: when clearing pedestals (`clearPedestals`)
- **Purpose**: tracking currently displayed options on pedestals

### `lastActivity`
- **Set**: when rendering any screen (`renderCurrentScreen`)
- **Used**: for idle timeout detection
- **Purpose**: tracking last user activity

---

## Potential Issues and Inconsistencies

1. **`selectedCategory` remains set after no materials** – **FIXED**: now reset to `nil` when no materials available (screen 2 → 1).

2. **`selectedMaterial` remains set after no quantities** – **FIXED**: now reset to `nil` when no quantities available (screen 3 → 2).

3. **`paymentDeadline` reset in many places** – while necessary, may lead to missed deadline if resetting happens too early.

4. **No reset of `availableQuantities` during transitions** – **FIXED**: now included in `resetToMainScreen()`.

5. **Transition from screen 3 confirming to selecting via LMB resets `paymentBaseline` and `paymentCheckCount`**, but does not reset `selectedQty` – user can select a different quantity.

6. **Transition from screen 3 confirming to selecting via RMB (change quantity) does not reset `paymentBaseline`** – but `renderScreen3Confirming` will be called again, setting a new baseline. However `paymentDeadline` is only updated via `selectedQty` update (not reset). `renderScreen3Confirming` will set a new deadline.

---

## Recommendations

1. **State transition documentation** – this document should be maintained alongside code changes.

2. **Consistent field resetting** – **ADDRESSED**: implemented centralized `resetToMainScreen()` function that resets all selection and payment fields while preserving pedestal state and activity timestamp.

3. **Testing all paths** – test every possible transition sequence, especially edge cases: timeouts, cancel, simultaneous events.

4. **Logging state changes** – consider adding logging of each state change (with values) for debugging.

5. **State diagram** – create a graphical state transition diagram for better visualization.

## Configuration Constants Affecting Transitions

### From `config.lua`

| Constant | Default Value | Description | Impact on Transitions |
|----------|---------------|-------------|-----------------------|
| `IDLE_TIMEOUT` | 120 seconds | Idle time before automatic return to screen 1 | Determines condition in `checkIdleTimeout` |
| `PAYMENT_TIMEOUT` | 30 seconds | Time to make payment after unlocking depositor | Used to calculate `paymentDeadline` in `renderScreen3Confirming` |
| `CONFIRM_DELAY` | 5 seconds | Display time for thank you screen before return | Determines `os.sleep` duration in `renderScreen4` |
| `PAYMENT_DETECTION_SIDE` | `"bottom"` | Relay side connected to payment signal | Used in `checkPaymentDetection` to check state change |
| `PARALLEL_RENDERING` | `true` | Whether to use parallel pedestal rendering | Affects performance, not state transitions |
| `EVENT_LOOP_SLEEP` | 0.01 seconds | Delay between event loop iterations | Affects responsiveness |
| `AE2_CACHE_TTL` | 30 seconds | AE2 stock cache time-to-live | Affects stock data freshness |
| `LOG_LEVEL` | `"DEBUG"` | Logging level | Affects log volume |

### From `items.lua`

| Table | Content | Impact on Transitions |
|-------|---------|-----------------------|
| `CATEGORIES` | List of categories with label and item | Determines options displayed on screen 1 |
| `MATERIALS` | List of materials with category, minQty, basePrice | Determines available materials on screen 2 (filtered by AE2 stock) |
| `QUANTITIES` | List of quantity tiers (numbers or strings) | Determines available quantities on screen 3 (filtered by stock and minQty) |

### AE2 Stock-Related Conditions

- **Screen 2**: Material is displayed only if `stock >= minQty`
- **Screen 3 selecting**: Quantity is displayed only if `quantity <= stock` and `quantity >= minQty` (starting from `minQty` in `QUANTITIES` list)
- **Automatic transitions**: Missing materials/quantities cause return to previous screen (see section 6)

---
*Document generated 2026-04-15 based on code analysis.*