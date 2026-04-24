-- modules/crafting.lua — AE2 crafting integration for item dispensing
-- Exports: init(), startCrafting(), handleCraftingDone(), handleCraftingCancelled(),
--          craftingMonitorLoop()
-- Uses a separate AE2 adapter (CRAFTING_ADAPTER) connected to a dedicated dispensing AE2 system.

local logging, peripherals, config, state
local craftingAdapter
local CRAFTING_POLL_INTERVAL, CRAFTING_IDLE_POLL_INTERVAL

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    CRAFTING_POLL_INTERVAL = config.get("CRAFTING_POLL_INTERVAL") or 1
    CRAFTING_IDLE_POLL_INTERVAL = config.get("CRAFTING_IDLE_POLL_INTERVAL") or 5
    craftingAdapter = peripherals.getCraftingAdapter()
end

-- Calculate crafting amount: selectedQty / minQty
-- 1 unit in scheduleCrafting = minQty items (AE2 dispensing system configured this way)
-- Returns amount or nil if invalid
local function calculateCraftingAmount()
    local selectedMaterial = state.getState("selectedMaterial")
    local selectedQty = state.getState("selectedQty")
    if not selectedMaterial or not selectedQty then
        logging.writeLog("ERROR", "Missing material or quantity for crafting calculation")
        return nil
    end
    local minQty = selectedMaterial.minQty
    if selectedQty % minQty ~= 0 then
        logging.writeLog("ERROR", "Selected quantity " .. selectedQty .. " not multiple of minQty " .. minQty)
        return nil
    end
    local amount = math.floor(selectedQty / minQty)
    logging.writeLog("DEBUG", "Crafting amount: " .. selectedQty .. " / " .. minQty .. " = " .. amount)
    return amount
end

-- Start crafting job via the dedicated dispensing AE2 adapter
-- Returns true if job started successfully, false otherwise (falls back to mock dispense)
local function startCrafting()
    if not craftingAdapter then
        logging.writeLog("WARN", "Crafting adapter not available, falling back to mock dispense")
        return false
    end

    local selectedMaterial = state.getState("selectedMaterial")
    local selectedQty = state.getState("selectedQty")
    if not selectedMaterial or not selectedQty then
        logging.writeLog("ERROR", "Cannot start crafting: missing material or quantity")
        return false
    end

    local amount = calculateCraftingAmount()
    if not amount then
        logging.writeLog("ERROR", "Invalid crafting amount calculation")
        return false
    end

    -- Update state to show crafting starting
    state.updateState({
        craftingStatus = "starting",
        totalObjects = amount,
        craftedObjects = 0,
        craftingStartTime = os.clock(),
        craftingLastUpdate = os.clock()
    })

    -- Schedule crafting via AE2 adapter
    logging.writeLog("INFO", "Scheduling crafting: " .. amount .. "x (batch of " .. selectedMaterial.minQty .. ") " .. selectedMaterial.item)
    local ok, result = pcall(craftingAdapter.scheduleCrafting, "item", selectedMaterial.item, amount)

    if not ok then
        logging.writeLog("ERROR", "scheduleCrafting failed: " .. tostring(result))
        state.updateState({ craftingStatus = "failed" })
        return false
    end

    -- Extract job ID from return value (may be direct value or table field)
    local jobId = nil
    if type(result) == "table" then
        jobId = result.jobId or result.id
    else
        jobId = result
    end
    logging.writeLog("INFO", "Crafting job scheduled, jobId: " .. tostring(jobId))

    state.updateState({
        craftingJobId = jobId,
        craftingStatus = "in_progress"
    })

    return true
end

-- Check crafting progress via getCraftingCPUs()
-- Returns true if still in progress, false if done/failed/cancelled
local function checkCraftingProgress()
    if not craftingAdapter then
        logging.writeLog("WARN", "Crafting adapter missing in progress check")
        return false
    end

    local craftingJobId = state.getState("craftingJobId")
    if not craftingJobId then
        logging.writeLog("WARN", "No crafting job ID in state")
        return false
    end

    local ok, cpus = pcall(craftingAdapter.getCraftingCPUs)
    if not ok then
        logging.writeLog("ERROR", "getCraftingCPUs failed: " .. tostring(cpus))
        return true  -- assume still in progress, will retry
    end

    local totalCrafted = 0
    local jobFound = false

    for _, cpu in ipairs(cpus or {}) do
        if cpu.jobId == craftingJobId then
            jobFound = true
            local status = cpu.jobStatus or {}
            local crafted = tonumber(status.craftedObjects) or 0
            local total = tonumber(status.totalObjects) or state.getState("totalObjects") or 0

            logging.writeLog("DEBUG", "Crafting job " .. craftingJobId .. ": " .. crafted .. "/" .. total)

            if crafted > totalCrafted then
                totalCrafted = crafted
            end

            -- Check job completion status
            local jobStatus = (type(status.status) == "string" and status.status:upper()) or ""
            if jobStatus == "DONE" then
                logging.writeLog("INFO", "Crafting job " .. craftingJobId .. " completed")
                state.updateState({
                    craftingStatus = "completed",
                    craftedObjects = total,
                    craftingLastUpdate = os.clock()
                })
                return false
            elseif jobStatus == "CANCELLED" then
                logging.writeLog("WARN", "Crafting job " .. craftingJobId .. " cancelled")
                state.updateState({ craftingStatus = "cancelled" })
                return false
            end
        end
    end

    if not jobFound then
        -- Job not found in CPUs — it may have completed between polls
        logging.writeLog("WARN", "Crafting job " .. craftingJobId .. " not found in CPUs, assuming completed")
        state.updateState({
            craftingStatus = "completed",
            craftedObjects = state.getState("totalObjects") or 0,
            craftingLastUpdate = os.clock()
        })
        return false
    end

    -- Update progress if we have new data
    if totalCrafted > 0 then
        state.updateState({
            craftedObjects = totalCrafted,
            craftingLastUpdate = os.clock()
        })
    end

    return true
end

-- Handle ae2cc:crafting_done event (called from event loop)
local function handleCraftingDone()
    logging.writeLog("INFO", "Crafting done event received")
    state.updateState({
        craftingStatus = "completed",
        craftedObjects = state.getState("totalObjects") or 0,
        craftingLastUpdate = os.clock()
    })
end

-- Handle ae2cc:crafting_cancelled event (called from event loop)
local function handleCraftingCancelled()
    logging.writeLog("WARN", "Crafting cancelled event received")
    state.updateState({ craftingStatus = "cancelled" })
end

-- Handle terminal crafting state (completed/cancelled/failed).
-- Called from craftingMonitorLoop when checkCraftingProgress returns false
-- (i.e., the terminal state was detected by polling getCraftingCPUs).
local function handleTerminalCraftingState()
    local finalStatus = state.getState("craftingStatus")

    if finalStatus == "completed" then
        logging.writeLog("INFO", "Crafting completed successfully, showing collection message")
        os.sleep(CONFIRM_DELAY or 5)
        state.resetToMainScreen()
    elseif finalStatus == "cancelled" then
        logging.writeLog("WARN", "Crafting cancelled, returning to main screen")
        os.sleep(2)
        state.resetToMainScreen()
    elseif finalStatus == "failed" then
        logging.writeLog("ERROR", "Crafting failed, returning to main screen")
        os.sleep(2)
        state.resetToMainScreen()
    end
end

-- Crafting monitor loop — runs as a 4th coroutine in parallel.waitForAny
-- Polls every CRAFTING_POLL_INTERVAL (1s) when active, every
-- CRAFTING_IDLE_POLL_INTERVAL (5s) when idle
local function craftingMonitorLoop()
    logging.writeLog("INFO", "Crafting monitor thread started")

    while true do
        local ok, err = pcall(function()
            local craftingStatus = state.getState("craftingStatus")

            if craftingStatus == "in_progress" then
                -- Actively check progress (polls getCraftingCPUs)
                local stillInProgress = checkCraftingProgress()

                if not stillInProgress then
                    -- checkCraftingProgress detected terminal state and set it
                    handleTerminalCraftingState()
                end

                os.sleep(CRAFTING_POLL_INTERVAL)  -- 1s while active

            elseif craftingStatus == "completed" then
                -- Event handler (ae2cc:crafting_done) already set completed state.
                -- Wait and then return to main screen.
                logging.writeLog("INFO", "Crafting completed (via event), showing collection message")
                os.sleep(CONFIRM_DELAY or 5)
                state.resetToMainScreen()

            elseif craftingStatus == "cancelled" or craftingStatus == "failed" then
                -- Event handler (ae2cc:crafting_cancelled) already set this state.
                -- Show message briefly then return to main screen.
                os.sleep(2)
                state.resetToMainScreen()

            else
                os.sleep(CRAFTING_IDLE_POLL_INTERVAL)  -- 5s while idle
            end
        end)

        if not ok then
            logging.writeLog("ERROR", "Crafting monitor loop error: " .. tostring(err))
            os.sleep(1)  -- avoid tight error loop
        end
    end
end

return {
    init = init,
    startCrafting = startCrafting,
    handleCraftingDone = handleCraftingDone,
    handleCraftingCancelled = handleCraftingCancelled,
    craftingMonitorLoop = craftingMonitorLoop
}
