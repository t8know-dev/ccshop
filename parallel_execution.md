# Parallel Execution Architecture

This document describes how `parallel.waitForAny` is used in the Display Shop project and how nested parallel execution was eliminated.

---

## 1. Overview: Cooperative Multitasking

CC:Tweaked's `parallel` API implements **cooperative multitasking** — not preemptive parallelism. Only one coroutine runs at a time. A coroutine yields control only at blocking calls (`os.pullEvent()`, `os.sleep()`, etc.). There is no true parallelism, which means:

- **No race conditions on shared state at the Lua level** — two coroutines cannot execute simultaneously.
- **Coroutines are interleaved at yield points** — the scheduler switches coroutines when the running coroutine yields.

---

## 2. Top-Level Parallel Execution

**File:** `shop.lua:90-94`

```lua
parallel.waitForAny(
    function() basalt.run() end,   -- Coroutine A
    events.eventLoop,               -- Coroutine B
    payment.paymentMonitorLoop      -- Coroutine C
)
```

Three coroutines run concurrently until **any one of them exits** (which never happens — all use `while true` loops). The program is terminated externally via Ctrl+T.

### Coroutine A: Basalt UI (`basalt.run()`)

- Processes monitor touch events (cancel button clicks, Basalt internal events).
- The cancel button's `onClick` handler starts an async timer (`os.startTimer(0.05)`) instead of calling `state.resetToMainScreen()` directly — avoids Basalt coroutine issues with nested pedestal operations. The timer fires in Coroutine B (event loop), which calls `state.resetToMainScreen()`. Direct `resetToMainScreen()` is only used as a fallback if `os.startTimer` fails.
- UI updates triggered by state changes run **inside this coroutine** if the state change originated here.

### Coroutine B: Event Loop (`events.eventLoop`)

- **File:** `events.lua:259-285`
- Blocks on `os.pullEvent()`, waiting for **any** event.
- Filters for `pedestal_left_click`, `pedestal_right_click`, and `timer` events.
- Timer events handle the cancel button's async `os.startTimer(0.05)` → calls `state.resetToMainScreen()`.
- Calls `handlePedestalClick()` → `state.updateState()` → subscriber → `renderCurrentScreen()`.
- **Entire rendering pipeline runs inside this coroutine** when a pedestal click triggers a state change.

### Coroutine C: Payment Monitor (`payment.paymentMonitorLoop`)

- **File:** `payment.lua:155-182`
- Polls every **20ms** (`os.sleep(0.02)`).
- Checks:
  - `checkIdleTimeout()` — 120s inactivity timeout on screens 2, 3A, 3B.
  - `checkPaymentDetection()` — compares relay input against baseline.
- When either triggers: calls `state.updateState()` or `state.resetToMainScreen()` → subscriber → `renderCurrentScreen()`.
- **Entire rendering pipeline runs inside this coroutine** when timeout/payment triggers a state change.

### Scheduling

| Coroutine | Yield pattern | Typical time slice |
|---|---|---|
| Basalt (A) | Yields on `os.pullEvent()` internally | Variable, one event at a time |
| Event loop (B) | Yields on `os.pullEvent()` | Blocks until an event arrives |
| Payment monitor (C) | Yields on `os.sleep(0.02)` | ~20ms burst every 20ms |

All three coroutines get fair time slices. Coroutine C yields most frequently (every 20ms), so it cannot dominate execution.

---

## 3. Pedestal Rendering: Custom Coroutine Scheduler with Event Re‑queuing

Pedestal rendering uses a custom coroutine scheduler (`runPedestalTasksParallel`) that runs pedestal tasks in parallel while preserving events for other top‑level coroutines (Basalt, event loop, payment monitor). This provides both responsiveness and correct cancel‑button behavior.

```
Top-level waitForAny (shop.lua)
  └── renderCurrentScreen()
        └── executeSequential()
              ├── ui.updateUI()
              └── pedestal.setPedestalOptions() or pedestal.clearPedestals()
                    └── runPedestalTasksParallel(tasks)
                          ├── Task 1 (pedestal 1) – coroutine
                          ├── Task 2 (pedestal 2) – coroutine
                          └── … (each pedestal in its own coroutine)
```

**Why not `parallel.waitForAll`?** Using `parallel.waitForAll` inside a coroutine already running under `parallel.waitForAny` creates an inner event loop that consumes ALL events from the queue. Events meant for other top‑level coroutines (e.g., `monitor_touch` for the cancel button handled by Basalt) get consumed by the inner scheduler and lost. The custom scheduler solves this by re‑queuing non‑timer events before resuming pedestal coroutines.

**File:** `modules/pedestal.lua`

**Custom scheduler algorithm (`runPedestalTasksParallel`):**
1. Create a coroutine for each pedestal task.
2. Loop while any coroutine is alive:
   - Pull the next raw event (`os.pullEventRaw()`).
   - If the event is **not** a timer event, re‑queue it (`os.queueEvent`) so other coroutines (Basalt) can process it.
   - Resume all alive coroutines with the event.
   - Remove dead coroutines from the set.
3. Each task yields with `os.sleep(0)` after its pedestal operation, allowing other pedestal tasks to interleave.

**Event safety:** Non‑timer events (monitor touches, pedestal clicks) are re‑queued, preserving them for the appropriate handler. Timer events are consumed by the scheduler (they are meant for the waiting coroutines).

**Key differences from the removed parallel approach:**

| Aspect | Old parallel (removed) | Current custom coroutine scheduler |
|---|---|---|
| Mechanism | `parallel.waitForAll` + `waitForAny` timeout | Manual coroutine management with event re‑queuing |
| Event safety | Consumes events meant for other coroutines | Re‑queues non‑timer events → events go to the right handler |
| Guard mechanism | `_parallelBusy` flag (buggy, never cleared) | `_rendering` guard with pending‑render queue |
| Timeout guard | 1‑second timeout with sequential fallback | None needed — `setItem()` doesn't hang |
| Re‑entry protection | Separate `_parallelBusy` flag | Unified `_rendering` guard with pending‑render queue |

---

## 4. Rendering Guard with Pending Render Queue

A `_rendering` guard with pending render queue in `modules/screens.lua` prevents re-entrant rendering and infinite loops:

```lua
local _rendering = false
local _pendingRender = false
local _lastRenderedScreen = nil
local _lastRenderedSubState = nil
local _lastRenderedQty = nil

local function renderCurrentScreen()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    local selectedQty = state.getState("selectedQty")

    -- If already rendering, check if a meaningful change happened
    if _rendering then
        if screen ~= _lastRenderedScreen or subState ~= _lastRenderedSubState or selectedQty ~= _lastRenderedQty then
            logging.writeLog("WARN", "renderCurrentScreen called while already rendering, queuing pending render")
            _pendingRender = true
        else
            logging.writeLog("DEBUG", "renderCurrentScreen called while already rendering, unchanged, skipping")
        end
        return
    end

    -- Skip if nothing meaningful changed (also track selectedQty for confirming state quantity changes)
    if screen == _lastRenderedScreen and subState == _lastRenderedSubState and selectedQty == _lastRenderedQty then
        logging.writeLog("DEBUG", "renderCurrentScreen: screen/subState/qty unchanged, skipping render")
        return
    end
    _rendering = true
    local ok, err = pcall(function()
        logging.writeLog("INFO", "renderCurrentScreen called - screen=" .. tostring(screen) .. " subState=" .. tostring(subState) .. " qty=" .. tostring(selectedQty))
        state.updateState({ lastActivity = os.clock() })
        if screen == 1 then renderScreen1()
        elseif screen == 2 then renderScreen2()
        elseif screen == 3 then
            if subState == "selecting" then renderScreen3Selecting()
            elseif subState == "confirming" then renderScreen3Confirming()
            else renderScreen3Selecting()
            end
        elseif screen == 4 then renderScreen4()
        end
        -- Remember what we just rendered
        _lastRenderedScreen = screen
        _lastRenderedSubState = subState
        _lastRenderedQty = selectedQty
    end)
    _rendering = false
    -- After rendering completes, check if a pending render was requested
    if _pendingRender then
        logging.writeLog("INFO", "Processing pending render after completion")
        _pendingRender = false
        pcall(renderCurrentScreen)
    end
    if not ok then
        pcall(logging.writeLog, "ERROR", "renderCurrentScreen failed: " .. tostring(err))
    end
end
```

This ensures:
1. **No infinite recursion** – re-entrant calls are queued as pending renders instead of causing deadlock
2. **No missed state changes** – pending renders are processed after current render completes
3. **No redundant renders** – skips rendering if screen/subState/selectedQty haven't changed since last render
4. **Cancel button works** – state changes from cancel clicks are processed correctly without infinite loops
5. **Correct handling of quantity changes** – when a different quantity pedestal is clicked in confirming state, the render is not skipped (selectedQty has changed)

---

## 5. State Communication Between Coroutines

State communication uses a **shared global state table** (`state.lua`) with a publish-subscribe pattern:

```
Coroutine (A/B/C)
  └── state.updateState({ screen = 3, ... })
        ├── Writes to `state` table (module-local)
        └── Iterates subscribers and calls each synchronously
              └── shop.lua subscriber:
                    └── screens.renderCurrentScreen()
                          ├── ui.updateUI()
                          └── pedestal.setPedestalOptions()
```

**Key properties:**
- Subscriber callbacks run **synchronously within the updating coroutine**.
- There is **no message queue, no deferred execution, no cross-coroutine signaling**.
- When coroutine A updates state, coroutine B sees the new state on its next time slice (next read from the state table).

---

## 6. Known Concurrency Issues (Fixed)

### Issue 1 (Fixed): `os.sleep(0.5)` Blind Window in `renderScreen3Confirming`

**Previously:** Depositor was unlocked BEFORE capturing the baseline, with a 0.5s sleep in between. This created a window where coins inserted during the 0.5s would not be detected.

**Fixed:** Baseline is captured BEFORE unlocking the depositor:

```
1. Capture baseline (relay inputs)
2. Unlock depositor
3. os.sleep(0.5) for stabilization
4. Set paymentDeadline and paymentBaseline in state
```

No blind window because payment can't change before the depositor is unlocked.

### Issue 2 (Fixed): Re-entrant Rendering

**Previously:** If a state change occurred during rendering, the subscriber triggered a re-entrant `renderCurrentScreen()` call, leaving pedestals in an inconsistent state.

**Fixed:** The `_rendering` guard with pending‑render queue in `modules/screens.lua` prevents re‑entrant calls. If `renderCurrentScreen()` is called while already rendering, it logs a warning, sets `_pendingRender = true`, and returns immediately. After the current render completes, the pending render is processed, ensuring no state change is missed. The guard also skips rendering if the screen/subState haven't changed since the last render, eliminating redundant updates.

### Issue 3 (Mitigated): Screen 4 Auto-Return and Idle Timeout Race

`renderScreen4()` does:

```lua
os.sleep(CONFIRM_DELAY)  -- 5 seconds
state.resetToMainScreen()
```

During the 5-second sleep, the payment monitor could detect an idle timeout and call `state.resetToMainScreen()` first. When `renderScreen4` resumes and also calls `state.resetToMainScreen()`, it triggers a redundant state change. This is harmless (idempotent) but wasteful.

---

## 7. Design Assumptions

1. **CC:Tweaked's `parallel` API is cooperative** — only one coroutine runs at a time.
2. **Peripheral calls (AE2 stock queries, pedestal.setItem, etc.) are fast** — they don't yield the coroutine for significant time.
3. **State subscriber callbacks are synchronous** — rendering completes within the updating coroutine before control yields.
4. **The payment detection baseline is stable** — the 0.5s stabilization window is sufficient for the relay to settle.
5. **No two state changes happen simultaneously** — because CC:Tweaked is cooperative, only one coroutine is active at a time.
6. **The cancel button's `onClick` handler runs in Basalt's coroutine** — state changes from cancel always originate from coroutine A.

---

## 8. Call Site Summary

| File | Line(s) | API Call | Purpose |
|---|---|---|---|
| `shop.lua` | 90-94 | `parallel.waitForAny` | Top-level: 3 coroutines (basalt, events, payment) |
| `modules/pedestal.lua` | 66-98 | `runPedestalTasksParallel` | Custom coroutine scheduler with event re-queuing |

---

## 9. Files Changed in the Parallel Rendering Fix

| File | Change |
|---|---|
| `modules/pedestal.lua` | Added custom coroutine scheduler `runPedestalTasksParallel()` with event re‑queuing. Pedestal tasks run in parallel while preserving `monitor_touch` events for the cancel button. No `parallel.waitForAll`, no `_parallelBusy` flag, no timeout guard. |
| `modules/screens.lua` | Enhanced `_rendering` guard with pending‑render queue and screen‑change detection. Prevents infinite loops while ensuring no state change is missed. Fixed blind window (baseline before unlock). Renamed `executeParallelOrSequential()` to `executeSequential()`. |
| `config.lua` | Removed `PARALLEL_RENDERING` constant. |

---

## 10. Infinite Loop Fix: Pending Render Queue with State Change Detection

### Problem
When the cancel button was clicked during pedestal rendering, `state.resetToMainScreen()` triggered a state change while `renderCurrentScreen()` was still executing. The guard (`_rendering = true`) prevented immediate re‑entry, but after the current render completed, the pending render was processed, causing screen 1 to render again. However, screen 1's own pedestal updates could trigger another state change (through the subscriber), leading to another pending render, creating an infinite loop.

### Solution
Two complementary mechanisms eliminate the loop:

1. **Pending render queue** – When `renderCurrentScreen()` is called while already rendering, it sets `_pendingRender = true` and returns immediately. After the current render finishes, the pending render is processed **exactly once**.

2. **Screen/subState change detection** – Before rendering, the function compares the current `screen` and `subState` with `_lastRenderedScreen` and `_lastRenderedSubState`. If they haven't changed, the render is skipped entirely. This prevents redundant renders when the state change doesn't affect the visible screen.

### How It Works Together
- Cancel click → `state.resetToMainScreen()` → subscriber calls `renderCurrentScreen()`
- If already rendering: `_pendingRender = true`, return
- Current render completes → processes pending render
- Pending render checks screen/subState: screen 1 → screen 1 (no change) → **skip**
- Loop broken

### Log Messages
The fix produces clear log traces:
- `"renderCurrentScreen called while already rendering, queuing pending render"`
- `"Processing pending render after completion"`
- `"renderCurrentScreen: screen/subState/qty unchanged, skipping render"`

---

## 11. Pending Render Queue Optimization

### Problem
Even with the pending‑render queue, multiple state changes during a single render could cause unnecessary pending renders. For example, if the system is rendering screen 2 and receives two state changes (screen 1 → screen 2) in quick succession, both would set `_pendingRender = true`, but only the last would matter.

### Solution: State‑Change‑Aware Queueing
The pending‑render logic now checks whether the requested screen/subState/selectedQty actually differs from the last rendered state **before** setting `_pendingRender = true`:

```lua
if _rendering then
    if screen ~= _lastRenderedScreen or subState ~= _lastRenderedSubState or selectedQty ~= _lastRenderedQty then
        logging.writeLog("WARN", "renderCurrentScreen called while already rendering, queuing pending render")
        _pendingRender = true
    else
        logging.writeLog("DEBUG", "renderCurrentScreen called while already rendering, unchanged, skipping")
    end
    return
end
```

### Benefits
1. **Fewer pending renders** – No queueing when the target screen/subState/quantity is already the one being rendered (or was just rendered).
2. **Reduced log noise** – Only logs a warning when a real change is pending.
3. **Better performance** – Avoids unnecessary render attempts after the current render completes.
4. **Correct quantity changes** – When a different quantity is selected in confirming state, `selectedQty` changes trigger a re-render even if screen/subState are the same.

### Updated Log Messages
- `"renderCurrentScreen called while already rendering, unchanged, skipping"` (new)
- `"renderCurrentScreen called while already rendering, queuing pending render"` (only when change needed)
