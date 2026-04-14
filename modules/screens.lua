-- modules/screens.lua — Screen rendering logic
-- Exports: init(), renderScreen1(), renderScreen2(), renderScreen3Selecting(),
--          renderScreen3Confirming(), renderScreen4(), renderCurrentScreen()

local logging, pedestal, ui, peripherals, config, state

-- Initialize module with dependencies
local function init(loggingModule, pedestalModule, uiModule, peripheralsModule, configModule, stateModule)
    logging = loggingModule
    pedestal = pedestalModule
    ui = uiModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
end

-- Screen 1: Category selection
local function renderScreen1()
    logging.writeLog("INFO", "Rendering screen 1 (categories)")
    pedestal.clearPedestals()
    local options = {}
    for _, cat in ipairs(CATEGORIES) do
        table.insert(options, { item = cat.item, label = cat.label })
    end
    -- Update UI and pedestals in parallel
    logging.writeLog("DEBUG", "Starting parallel UI and pedestal update")
    local ok, err = pcall(parallel.waitForAll,
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
    if not ok then
        logging.writeLog("WARN", "Parallel render failed: " .. tostring(err) .. ", falling back to sequential")
        ui.updateUI()
        pedestal.setPedestalOptions(options)
    else
        logging.writeLog("DEBUG", "Parallel render completed")
    end
end

-- Screen 2: Material selection (filtered by category and stock)
local function renderScreen2()
    local selectedCategory = state.getState("selectedCategory")
    logging.writeLog("INFO", "Rendering screen 2 (materials) for category: " .. tostring(selectedCategory))
    pedestal.clearPedestals()
    local options = {}
    logging.writeLog("DEBUG", "MATERIALS total: " .. #MATERIALS)
    for idx, mat in ipairs(MATERIALS) do
        if mat.category == selectedCategory then
            logging.writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. ", label=" .. mat.label .. ", category=" .. mat.category .. ", minQty=" .. mat.minQty)
            local stock = peripherals.getAE2Stock(mat.item)
            logging.writeLog("DEBUG", "  stock=" .. stock)
            if stock >= mat.minQty then
                logging.writeLog("DEBUG", "  -> qualifies")
                table.insert(options, { item = mat.item, label = mat.label })
            else
                logging.writeLog("DEBUG", "  -> insufficient stock")
            end
        else
            logging.writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. " category mismatch (" .. mat.category .. " vs " .. selectedCategory .. ")")
        end
    end
    logging.writeLog("INFO", "Available materials: " .. #options)
    if #options == 0 then
        -- No materials available, go back to screen 1
        logging.writeLog("WARN", "No materials available, returning to screen 1")
        state.updateState({ screen = 1 })
        -- Recursive call; but we need to avoid infinite recursion. Use renderCurrentScreen.
        -- We'll call renderCurrentScreen via the main loop. For now, just update state.
        return
    end
    -- Update UI and pedestals in parallel
    local ok, err = pcall(parallel.waitForAll,
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
    if not ok then
        logging.writeLog("WARN", "Parallel render failed: " .. tostring(err) .. ", falling back to sequential")
        ui.updateUI()
        pedestal.setPedestalOptions(options)
    end
end

-- Screen 3: Quantity selection (selecting sub-state)
local function renderScreen3Selecting()
    local selectedMaterial = state.getState("selectedMaterial")
    logging.writeLog("INFO", "Rendering screen 3 (selecting) for material: " .. tostring(selectedMaterial.item))
    pedestal.clearPedestals()
    local stock = peripherals.getAE2Stock(selectedMaterial.item)
    logging.writeLog("DEBUG", "Stock: " .. stock .. " minQty: " .. selectedMaterial.minQty)
    local quantities = {}
    local startIdx = findQuantityIndex(selectedMaterial.minQty)
    if not startIdx then startIdx = 1 end
    for i = startIdx, #QUANTITIES do
        local qtyNum = quantityToNumber(QUANTITIES[i])
        if qtyNum <= stock then
            table.insert(quantities, qtyNum)
        else
            break
        end
    end
    logging.writeLog("INFO", "Available quantities: " .. #quantities)
    state.updateState({ availableQuantities = quantities })
    if #quantities == 0 then
        -- No quantities available (stock less than minQty) – should not happen
        logging.writeLog("WARN", "No quantities available, returning to screen 2")
        state.updateState({ screen = 2 })
        return
    end
    local options = {}
    for _, qtyNum in ipairs(quantities) do
        table.insert(options, { item = selectedMaterial.item, label = tostring(qtyNum), count = qtyNum })
    end
    -- Update UI and pedestals in parallel
    local ok, err = pcall(parallel.waitForAll,
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
    if not ok then
        logging.writeLog("WARN", "Parallel render failed: " .. tostring(err) .. ", falling back to sequential")
        ui.updateUI()
        pedestal.setPedestalOptions(options)
    end
end

-- Screen 3: Payment (confirming sub-state)
local function renderScreen3Confirming()
    local selectedMaterial = state.getState("selectedMaterial")
    local selectedQty = state.getState("selectedQty")
    logging.writeLog("INFO", "Rendering screen 3 (confirming) for material: " .. tostring(selectedMaterial.item) .. " qty: " .. tostring(selectedQty))

    -- Ensure we have available quantities (should be set from screen 3)
    local availableQuantities = state.getState("availableQuantities")
    if not availableQuantities then
        logging.writeLog("ERROR", "availableQuantities not set, recomputing")
        local stock = peripherals.getAE2Stock(selectedMaterial.item)
        local quantities = {}
        local startIdx = findQuantityIndex(selectedMaterial.minQty)
        if not startIdx then startIdx = 1 end
        for i = startIdx, #QUANTITIES do
            local qtyNum = quantityToNumber(QUANTITIES[i])
            if qtyNum <= stock then
                table.insert(quantities, qtyNum)
            else break end
        end
        state.updateState({ availableQuantities = quantities })
        availableQuantities = quantities
    end

    -- Lock depositor first (in case we're changing quantity)
    peripherals.lockDepositor()

    -- Calculate price
    local price = math.floor(selectedMaterial.basePrice * (selectedQty / selectedMaterial.minQty))
    state.updateState({ calculatedPrice = price })
    logging.writeLog("INFO", "Price calculated: " .. price .. " spurs for quantity " .. selectedQty)

    -- Set depositor price
    local ok, err = pcall(peripherals.getDepositor().setTotalPrice, price)
    if not ok then
        ui.getHintLabel():setText(MSG.error_deposit)
        os.sleep(2)
        state.updateState({ screen = 1 })
        return
    end

    -- Create options for all available quantities
    local options = {}
    for _, qtyNum in ipairs(availableQuantities) do
        table.insert(options, {
            item = selectedMaterial.item,
            label = tostring(qtyNum),
            count = qtyNum
        })
    end

    -- Update UI and pedestals in parallel
    local ok, err = pcall(parallel.waitForAll,
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
    if not ok then
        logging.writeLog("WARN", "Parallel render failed: " .. tostring(err) .. ", falling back to sequential")
        ui.updateUI()
        pedestal.setPedestalOptions(options)
    end

    -- Update pedestal labels: selected quantity gets brackets
    local currentOptions = state.getState("currentOptions")
    local pedestals = peripherals.getPedestals()
    for idx, opt in pairs(currentOptions) do
        if opt.count and pedestals[idx] then
            local label = tostring(opt.count)
            if opt.count == selectedQty then
                label = "[ " .. label .. " ]"
                state.updateState({ lastSelectedPedestal = idx })
            end
            logging.writeLog("DEBUG", "Setting pedestal " .. idx .. " label: " .. label)
            pcall(pedestals[idx].setItem, opt.item, label)
            pcall(pedestals[idx].setItemRendered, true)
            pcall(pedestals[idx].setLabelRendered, true)
        end
    end

    -- Unlock depositor and establish baseline for payment detection
    peripherals.unlockDepositor()
    logging.writeLog("INFO", "Depositor unlocked (bottom side set to false), waiting for stabilization...")
    os.sleep(0.5)  -- Give depositor time to stabilize
    -- Get baseline for all sides
    local baselineTable = peripherals.getAllRelayInputs()
    state.updateState({
        paymentBaseline = baselineTable,
        paymentDeadline = os.clock() + PAYMENT_TIMEOUT,
        paymentPaid = false,
        cancelRequested = false,
        paymentCheckCount = 0
    })

    -- Log baseline for all sides
    logging.writeLog("INFO", "Payment detection baseline established:")
    for side, val in pairs(baselineTable) do
        logging.writeLog("INFO", "  " .. side .. " = " .. tostring(val))
    end
    logging.writeLog("INFO", "Payment deadline: " .. state.getState("paymentDeadline") .. " (current time: " .. os.clock() .. ")")
end

-- Screen 4: Thank you
local function renderScreen4()
    -- Clear pedestals and update UI in parallel
    local ok, err = pcall(parallel.waitForAll,
        function() pedestal.clearPedestals() end,
        function() ui.updateUI() end
    )
    if not ok then
        logging.writeLog("WARN", "Parallel clear/render failed: " .. tostring(err) .. ", falling back to sequential")
        pedestal.clearPedestals()
        ui.updateUI()
    end
    -- Play noteblock sound
    peripherals.playNoteblockSound()
    -- Log purchase
    local selectedCategory = state.getState("selectedCategory")
    local selectedMaterial = state.getState("selectedMaterial")
    local selectedQty = state.getState("selectedQty")
    local calculatedPrice = state.getState("calculatedPrice")
    local record = {
        timestamp = os.epoch("utc"),
        playerName = nil, -- not tracked yet
        category = selectedCategory,
        item = selectedMaterial.item,
        qty = selectedQty,
        price = calculatedPrice or math.floor(selectedMaterial.basePrice * (selectedQty / selectedMaterial.minQty))
    }
    -- db is loaded in main script; we need to access it. For now, we'll assume global db.log exists.
    pcall(db.log, record)
    -- Refresh AE2 cache after purchase (stock changed)
    peripherals.refreshAE2Cache()
    -- Mock dispense
    logging.writeLog("INFO", "[MOCK] Dispense " .. selectedQty .. "x " .. selectedMaterial.item)
    -- Auto-return to screen 1 after CONFIRM_DELAY seconds
    os.sleep(CONFIRM_DELAY)
    state.updateState({
        screen = 1,
        selectedCategory = nil,
        selectedMaterial = nil,
        selectedQty = nil,
        subState = nil,
        calculatedPrice = nil,
        paymentPaid = false,
        cancelRequested = false,
        paymentCheckCount = 0,
        paymentBaseline = nil
    })
end

-- Update screen based on state
local function renderCurrentScreen()
    state.updateState({ lastActivity = os.clock() })
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    if screen == 1 then renderScreen1()
    elseif screen == 2 then renderScreen2()
    elseif screen == 3 then
        if subState == "selecting" then renderScreen3Selecting()
        elseif subState == "confirming" then renderScreen3Confirming()
        else renderScreen3Selecting() -- default to selecting
        end
    elseif screen == 4 then renderScreen4() -- formerly screen 5
    end
end

return {
    init = init,
    renderScreen1 = renderScreen1,
    renderScreen2 = renderScreen2,
    renderScreen3Selecting = renderScreen3Selecting,
    renderScreen3Confirming = renderScreen3Confirming,
    renderScreen4 = renderScreen4,
    renderCurrentScreen = renderCurrentScreen
}