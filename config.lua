-- config.lua — ComputerCraft shop peripheral configuration and messages
-- All peripheral names, messages, timeouts, pedestal order

-- Peripheral names (update to match your setup)
RELAY_LOCK     = "redstone_relay_38"
AE2_ADAPTER    = "ae2cc_adapter_12"
DEPOSITOR      = "Numismatics_Depositor_8"
RELAY_NOTE     = "redstone_relay_37"
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
CONFIRM_DELAY  = 5        -- seconds on thank-you screen

-- Messages (all in English, easy to edit)
MSG = {
  header         = "* SHOP *",
  screen1_hint   = "Right-click a pedestal to select a category",
  screen2_hint   = "RMB: select   LMB: back",
  screen3_hint   = "RMB: choose quantity   LMB: back",
  screen4_insert = "Please insert %d spurs into the depositor",
  screen4_cancel = "Press CANCEL to abort",
  screen5_thanks = "Your items will be dispensed. Thank you!",
  cancel_btn     = "[ CANCEL ]",
  error_ae2      = "AE2 network unavailable",
  error_deposit  = "Depositor unavailable",
  error_relay    = "Relay unavailable",
  timeout_msg    = "Session timed out. Returning to main screen.",
}

-- Validation function: attempt to wrap each peripheral
-- Returns true if all peripherals are present, false + error message otherwise
function validatePeripherals()
  local peripherals = {
    { name = RELAY_LOCK,  type = "redstone_relay" },
    { name = AE2_ADAPTER, type = "ae2cc_adapter" },
    { name = DEPOSITOR,   type = "Numismatics_Depositor" },
    { name = RELAY_NOTE,  type = "redstone_relay" },
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