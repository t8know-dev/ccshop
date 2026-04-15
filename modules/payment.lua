-- modules/payment.lua — Payment detection and idle timeout monitoring
-- Exports: init(), checkPaymentDetection(), checkIdleTimeout(), paymentMonitorLoop()

local logging, state, peripherals, screens, config

-- Initialize module with dependencies
local function init(loggingModule, stateModule, peripheralsModule, screensModule, configModule)
    logging = loggingModule
    state = stateModule
    peripherals = peripheralsModule
    screens = screensModule
    config = configModule
end

-- Check idle timeout
local lastLoggedActivity = nil
local idleWarningLogged = false
local function checkIdleTimeout()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    if (screen == 2) or (screen == 3 and subState) then
        local lastActivity = state.getState("lastActivity")
        -- Reset warning if lastActivity changed
        if lastActivity ~= lastLoggedActivity then
            lastLoggedActivity = lastActivity
            idleWarningLogged = false
        end
        -- Log warning when approaching idle timeout (last 10 seconds) - only once
        if lastActivity and not idleWarningLogged and os.clock() - lastActivity > IDLE_TIMEOUT - 10 and os.clock() - lastActivity <= IDLE_TIMEOUT then
            logging.writeLog("DEBUG", "checkIdleTimeout: approaching idle timeout, " .. string.format("%.1f", os.clock() - lastActivity) .. " seconds since last activity")
            idleWarningLogged = true
        end
        if lastActivity and os.clock() - lastActivity > IDLE_TIMEOUT then
            -- Timeout: lock depositor if in confirming state, reset to screen 1
            if screen == 3 and subState == 'confirming' then
                peripherals.lockDepositor()
            end
            logging.writeLog("INFO", "Idle timeout triggered, returning to screen 1")
            state.updateState({
                screen = 1,
                selectedCategory = nil,
                selectedMaterial = nil,
                selectedQty = nil,
                subState = nil,
                paymentPaid = false,
                cancelRequested = false,
                paymentCheckCount = 0,
                paymentBaseline = nil,
                paymentDeadline = nil
            })
            -- Show timeout message on hint label (requires ui module)
            -- We'll need to access ui.getHintLabel(); but we don't have ui dependency.
            -- For now, we'll skip. The main script can handle this.
            -- hintLabel:setText(MSG.timeout_msg)
            -- os.sleep(2)
        end
    end
end

-- Check payment detection
local checkPaymentEntryCount = 0
local function checkPaymentDetection()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    local paymentPaid = state.getState("paymentPaid")
    local cancelRequested = state.getState("cancelRequested")

    -- Reset counter if not in screen 3 confirming
    if not (screen == 3 and subState == 'confirming') then
        checkPaymentEntryCount = 0
    end

    -- Diagnostic logging for first 5 entries when in screen 3 confirming
    if screen == 3 and subState == 'confirming' and checkPaymentEntryCount < 5 then
        checkPaymentEntryCount = checkPaymentEntryCount + 1
        logging.writeLog("DEBUG", "checkPaymentDetection diag: screen=3 subState=confirming paymentPaid="..tostring(paymentPaid).." cancelRequested="..tostring(cancelRequested).." entryCount="..checkPaymentEntryCount)
    end

    if screen == 3 and subState == 'confirming' and not paymentPaid and not cancelRequested then
        local paymentDeadline = state.getState("paymentDeadline")
        local paymentCheckCount = state.getState("paymentCheckCount") or 0

        -- Log only first few checks
        if paymentCheckCount <= 3 then
            logging.writeLog("DEBUG", "checkPaymentDetection: screen=3 subState=confirming paymentPaid="..tostring(paymentPaid).." cancelRequested="..tostring(cancelRequested))
            logging.writeLog("DEBUG", "checkPaymentDetection: paymentDeadline="..tostring(paymentDeadline).." os.clock()="..os.clock())
            if paymentDeadline then
                local diff = paymentDeadline - os.clock()
                logging.writeLog("DEBUG", "checkPaymentDetection: time remaining="..string.format("%.3f", diff).." seconds")
            end
        end
        if paymentDeadline and (os.clock() >= paymentDeadline) then
            logging.writeLog("INFO", "Payment timeout reached, locking depositor and returning to main screen")
            peripherals.lockDepositor()  -- lock depositor
            state.updateState({
                screen = 1,
                selectedCategory = nil,
                selectedMaterial = nil,
                selectedQty = nil,
                subState = nil,
                paymentPaid = false,
                cancelRequested = false,
                paymentCheckCount = 0,
                paymentBaseline = nil,
                paymentDeadline = nil
            })
        else
            state.updateState({ paymentCheckCount = state.getState("paymentCheckCount") + 1 })
            local paymentCheckCount = state.getState("paymentCheckCount")
            -- Log first few checks and then periodically
            if paymentCheckCount <= 10 or paymentCheckCount % 20 == 0 then
                local deadlineStr = "deadline not set"
                if paymentDeadline then
                    deadlineStr = string.format("%.1f", paymentDeadline - os.clock()) .. "s"
                end
                logging.writeLog("DEBUG", "Payment detection check #" .. paymentCheckCount .. ", " .. deadlineStr)
                if paymentCheckCount <= 5 or paymentCheckCount % 30 == 0 then
                    peripherals.debugRelayInputs()
                end
            end
            -- Check all relay sides for payment signal
            local currentInputs = peripherals.getAllRelayInputs()
            local paymentDetected = false
            local changedSide = nil
            -- First, check the configured payment detection side specifically (most likely)
            local paymentSide = PAYMENT_DETECTION_SIDE or "bottom"
            local paymentBaseline = state.getState("paymentBaseline")
            if not paymentBaseline then
                logging.writeLog("DEBUG", "paymentBaseline is nil, cannot detect payment")
            end
            if paymentBaseline and paymentBaseline[paymentSide] ~= nil and currentInputs[paymentSide] ~= nil then
                if currentInputs[paymentSide] ~= paymentBaseline[paymentSide] then
                    paymentDetected = true
                    changedSide = paymentSide
                end
            end
            -- If payment side didn't change, check all other sides (fallback)
            if not paymentDetected then
                if paymentBaseline then
                    for side, baselineVal in pairs(paymentBaseline) do
                        if side ~= paymentSide then  -- already checked
                            local currentVal = currentInputs[side]
                            if currentVal ~= nil and currentVal ~= baselineVal then
                                paymentDetected = true
                                changedSide = side
                                break
                            end
                        end
                    end
                end
            end
            if paymentDetected then
                logging.writeLog("INFO", "PAYMENT DETECTED on side " .. tostring(changedSide) .. "! current=" .. tostring(currentInputs[changedSide]) .. " baseline=" .. tostring(paymentBaseline[changedSide]))
                logging.writeLog("INFO", "All sides: " .. textutils.serialize(currentInputs))
                peripherals.lockDepositor()  -- lock depositor
                state.updateState({ paymentPaid = true, screen = 4, paymentDeadline = nil, cancelRequested = false })
            else
                -- Log only occasionally to avoid spam
                if paymentCheckCount % 40 == 0 then
                    logging.writeLog("DEBUG", "Payment detection check #" .. paymentCheckCount .. ", no change on any side.")
                end
            end
        end
    end
end

-- Payment monitor loop - runs continuously in parallel thread
local function paymentMonitorLoop()
    logging.writeLog("INFO", "Payment monitor thread started")
    local iterationCount = 0
    while true do
        local ok, err = pcall(function()
            -- Check idle timeout
            checkIdleTimeout()

            -- Check payment detection
            checkPaymentDetection()

            os.sleep(0.02)  -- 20ms check interval - fast enough to catch short pulses
            iterationCount = iterationCount + 1
            -- Log every 500 iterations (10 seconds) when in screen 3 confirming for debugging
            if iterationCount % 500 == 0 then
                local screen = state.getState("screen")
                local subState = state.getState("subState")
                if screen == 3 and subState == 'confirming' then
                    logging.writeLog("DEBUG", "paymentMonitorLoop alive, iteration="..iterationCount.." screen=3 confirming")
                end
            end
        end)
        if not ok then
            logging.writeLog("ERROR", "Payment monitor loop error: " .. tostring(err))
            os.sleep(1)  -- avoid tight error loop
        end
    end
end

return {
    init = init,
    checkPaymentDetection = checkPaymentDetection,
    checkIdleTimeout = checkIdleTimeout,
    paymentMonitorLoop = paymentMonitorLoop
}