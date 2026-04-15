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
local function checkIdleTimeout()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    if (screen == 2) or (screen == 3 and subState) then
        if os.clock() - state.getState("lastActivity") > IDLE_TIMEOUT then
            -- Timeout: lock depositor if in confirming state, reset to screen 1
            if screen == 3 and subState == 'confirming' then
                peripherals.lockDepositor()
            end
            state.updateState({
                screen = 1,
                selectedCategory = nil,
                selectedMaterial = nil,
                selectedQty = nil,
                subState = nil,
                paymentPaid = false,
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
local function checkPaymentDetection()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    local paymentPaid = state.getState("paymentPaid")
    local cancelRequested = state.getState("cancelRequested")
    if screen == 3 and subState == 'confirming' and not paymentPaid and not cancelRequested then
        local paymentDeadline = state.getState("paymentDeadline")
        if paymentDeadline and os.clock() >= paymentDeadline then
            logging.writeLog("INFO", "Payment timeout reached, locking depositor and returning to main screen")
            peripherals.lockDepositor()  -- lock depositor
            state.updateState({
                screen = 1,
                selectedCategory = nil,
                selectedMaterial = nil,
                selectedQty = nil,
                subState = nil,
                paymentPaid = false,
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
            if paymentBaseline[paymentSide] ~= nil and currentInputs[paymentSide] ~= nil then
                if currentInputs[paymentSide] ~= paymentBaseline[paymentSide] then
                    paymentDetected = true
                    changedSide = paymentSide
                end
            end
            -- If payment side didn't change, check all other sides (fallback)
            if not paymentDetected then
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
            if paymentDetected then
                logging.writeLog("INFO", "PAYMENT DETECTED on side " .. tostring(changedSide) .. "! current=" .. tostring(currentInputs[changedSide]) .. " baseline=" .. tostring(paymentBaseline[changedSide]))
                logging.writeLog("INFO", "All sides: " .. textutils.serialize(currentInputs))
                peripherals.lockDepositor()  -- lock depositor
                state.updateState({ paymentPaid = true, screen = 4, paymentDeadline = nil })
            else
                -- Log only occasionally to avoid spam
                if paymentCheckCount % 40 == 0 then
                    logging.writeLog("DEBUG", "Payment detection check #" .. paymentCheckCount .. ", no change on any side")
                end
            end
        end
    end
end

-- Payment monitor loop - runs continuously in parallel thread
local function paymentMonitorLoop()
    logging.writeLog("INFO", "Payment monitor thread started")
    while true do
        local ok, err = pcall(function()
            -- Check idle timeout
            checkIdleTimeout()

            -- Check payment detection
            checkPaymentDetection()

            os.sleep(0.02)  -- 20ms check interval - fast enough to catch short pulses
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