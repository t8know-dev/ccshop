-- shop_main.lua — Main orchestrator for modular CC:Tweaked shop system
-- Replaces monolithic shop.lua with modular architecture.

local basalt = require("basalt")

-- ============================================================================
-- Load original configuration and data files (define globals)
-- ============================================================================
dofile("/ccshop/config.lua")
dofile("/ccshop/items.lua")
local db = dofile("/ccshop/db.lua")

-- ============================================================================
-- Load modules
-- ============================================================================
local logging = require("modules.logging")
local config = require("modules.config")
local peripherals = require("modules.peripherals")
local state = require("modules.state")
local pedestal = require("modules.pedestal")
local ui = require("modules.ui")
local screens = require("modules.screens")
local events = require("modules.events")
local payment = require("modules.payment")

-- ============================================================================
-- Initialize modules with dependencies
-- ============================================================================
-- Note: config module loads config files again; ensure no conflict.
config.loadConfig()

-- Initialize logging (no dependencies)
-- Already loaded and ready.

-- Initialize peripherals (depends on logging, config)
peripherals.init(logging, config)
-- Wrap peripherals and create mappings
peripherals.initPeripherals()

-- Initialize state (no dependencies)
-- Already ready.

-- Initialize pedestal (depends on peripherals, logging, config, state)
pedestal.init(logging, peripherals, config, state)

-- Initialize UI (depends on peripherals, logging, config, state, basalt)
ui.init(logging, peripherals, config, state, basalt)

-- Initialize screens (depends on pedestal, ui, peripherals, config, state, db)
screens.init(logging, pedestal, ui, peripherals, config, state, db)

-- Initialize events (depends on state, screens, pedestal, peripherals, logging, config)
events.init(logging, state, screens, pedestal, peripherals, config)

-- Initialize payment (depends on state, peripherals, screens, config, logging)
payment.init(logging, state, peripherals, screens, config)

-- ============================================================================
-- State change listener: trigger screen re‑render when screen changes
-- ============================================================================
state.subscribe(function(changes)
    if changes.screen ~= nil or changes.subState ~= nil or changes.selectedQty ~= nil then
        logging.writeLog("DEBUG", "State changes: " .. textutils.serialize(changes) .. " triggering render")
        screens.renderCurrentScreen()
    end
end)

-- ============================================================================
-- Startup sequence
-- ============================================================================
logging.writeLog("INFO", "Starting modular shop system...")
local ok, err = pcall(function()
    -- Validate configuration
    config.validateAll()

    -- Create Basalt UI
    logging.writeLog("DEBUG", "Calling ui.createUI()")
    ui.createUI()
    logging.writeLog("DEBUG", "ui.createUI() completed")

    -- Render initial screen (screen 1)
    logging.writeLog("DEBUG", "Calling screens.renderCurrentScreen()")
    screens.renderCurrentScreen()
    logging.writeLog("DEBUG", "screens.renderCurrentScreen() completed")

    -- Run main loops in parallel
    parallel.waitForAny(
        function() basalt.run() end,
        events.eventLoop,
        payment.paymentMonitorLoop
    )
end)

if not ok then
    logging.writeLog("ERROR", "Fatal error: " .. tostring(err))
    -- Attempt to lock depositor on crash
    peripherals.lockDepositor()
    error(err)
end