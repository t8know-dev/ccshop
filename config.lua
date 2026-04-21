-- config.lua — ComputerCraft shop peripheral configuration and messages
-- All peripheral names, messages, timeouts, pedestal order

-- Peripheral names (update to match your setup)
RELAY_LOCK     = "redstone_relay_38"
AE2_ADAPTER    = "ae2cc_adapter_14"
DEPOSITOR      = "Numismatics_Depositor_8"
SPEAKER_NAME   = "speaker_212"
MONITOR        = "monitor_1012"

-- Pedestal list: left→right display order; script centers options
PEDESTALS = {
  "display_pedestal_12",  -- leftmost
  "display_pedestal_10",
  "display_pedestal_11",
  "display_pedestal_5",
  "display_pedestal_9",
  "display_pedestal_7",   -- rightmost
}

-- Timing (seconds)
IDLE_TIMEOUT   = 120      -- seconds before auto-reset
PAYMENT_TIMEOUT = 30      -- seconds to wait for payment after unlocking depositor
CONFIRM_DELAY  = 5        -- seconds on thank-you screen

-- Payment detection
PAYMENT_DETECTION_SIDE = "bottom"  -- which side of the relay is connected to depositor payment signal

-- Performance tuning
EVENT_LOOP_SLEEP = 0.01   -- seconds between event loop iterations (was 0.05)
AE2_CACHE_TTL    = 30     -- seconds before refreshing AE2 stock cache

-- Log level control (DEBUG, INFO, WARN, ERROR)
LOG_LEVEL = "DEBUG"

-- Parallel rendering (true to enable parallel pedestal and UI updates)
PARALLEL_RENDERING = false

-- Messages (all in English, easy to edit)
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

-- Validation function: attempt to wrap each peripheral
-- Returns true if all peripherals are present, false + error message otherwise
function validatePeripherals()
  local peripherals = {
    { name = RELAY_LOCK,  type = "redstone_relay" },
    { name = AE2_ADAPTER, type = "ae2cc_adapter" },
    { name = DEPOSITOR,   type = "Numismatics_Depositor" },
    { name = SPEAKER_NAME, type = "speaker" },
  }
  for _, p in ipairs(peripherals) do
    local ok, wrapped = pcall(peripheral.wrap, p.name)
    if not ok or wrapped == nil then
      return false, "Peripheral '" .. p.name .. "' (" .. p.type .. ") not found"
    end
  end
  -- Check monitor separately (might be monitor or advanced_monitor)
  local ok, mon = pcall(peripheral.wrap, MONITOR)
  if not ok or mon == nil then
    return false, "Monitor '" .. MONITOR .. "' not found"
  end
  -- Check pedestals
  for _, pedName in ipairs(PEDESTALS) do
    local ok, ped = pcall(peripheral.wrap, pedName)
    if not ok or ped == nil then
      return false, "Pedestal '" .. pedName .. "' not found"
    end
  end
  return true
end