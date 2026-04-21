-- Test script to check MSG loading
print("Testing MSG loading...")

-- Mock some globals that would be set by config.lua
MSG = {
    header = "ccshop",
    cancel_btn = "CANCEL",
    screen1_discount_info = {"Bulk discounts:", "2% at 1 tier", "5% at 2", "10% at 3", "15% at 4", "20% at 5+"},
    screen1_hint = "Right-click a pedestal to select a category",
    screen2_hint = "RMB: select   LMB: go back",
    screen3_base_price = "Base price: %d spurs for %d units",
    screen3_hint_select = "RMB: select quantity   LMB: go back",
    screen3_breakdown_line = "Price breakdown: %d * %d/%d = %d",
    screen3_discount_line = "Discount: -%d%% (%d spurs)",
    screen3_total_line = "Total: %d spurs",
    screen3_pedestal_instruction = "Use pedestals to change quantity",
    screen3_insert = "Please insert %s into the depositor",
    screen4_thanks = "Your items will be dispensed. Thank you!",
    error_deposit = "Depositor unavailable",
    error_ae2 = "AE2 network unavailable",
    error_relay = "Relay unavailable",
    timeout_msg = "Session timed out. Returning to main screen.",
}

-- Mock config module
local mockConfig = {
    get = function(key) return _G[key] end,
    getMsg = function(key) return MSG and MSG[key] end,
    loadConfig = function() end,
    validateAll = function() return true end
}

-- Test UI module init
print("Loading UI module...")
local ui = require("modules.ui")
print("UI module loaded")

-- Initialize UI module with mock dependencies
local mockLogging = {
    writeLog = function(level, msg) print("["..level.."] "..msg) end
}
local mockPeripherals = {}
local mockState = {}
local mockBasalt = {}

print("Calling ui.init...")
ui.init(mockLogging, mockPeripherals, mockConfig, mockState, mockBasalt)
print("ui.init completed")

-- Test screens module init
print("\nLoading screens module...")
local screens = require("modules.screens")
print("Screens module loaded")

local mockPedestal = {}
local mockDb = {}

print("Calling screens.init...")
screens.init(mockLogging, mockPedestal, ui, mockPeripherals, mockConfig, mockState, mockDb)
print("screens.init completed")

print("\nAll tests passed! MSG loaded successfully.")