-- modules/screens.lua — Screen rendering logic
-- Exports: init(), renderScreen1(), renderScreen2(), renderScreen3Selecting(),
--          renderScreen3Confirming(), renderScreen4(), renderCurrentScreen()

local logging, pedestal, ui, peripherals, config, state, db, MSG
local CATEGORIES = _G.CATEGORIES or {}
local MATERIALS = _G.MATERIALS or {}
local QUANTITIES = _G.QUANTITIES or {}
local PAYMENT_TIMEOUT = _G.PAYMENT_TIMEOUT or 30
local CONFIRM_DELAY = _G.CONFIRM_DELAY or 5
local quantityToNumber = _G.quantityToNumber
local findQuantityIndex = _G.findQuantityIndex
local calculatePriceWithDiscount = _G.calculatePriceWithDiscount

-- Initialize module with dependencies
local function init(loggingModule, pedestalModule, uiModule, peripheralsModule, configModule, stateModule, dbModule)
    logging = loggingModule
    pedestal = pedestalModule
    ui = uiModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    db = dbModule
    -- logging.writeLog("DEBUG", "Screens init called, getting MSG from config")
    MSG = configModule.get("MSG")
    -- logging.writeLog("DEBUG", "Screens init: MSG = " .. tostring(MSG))
    if not MSG then
        error("Screens init: MSG configuration not loaded")
    end
    -- logging.writeLog("DEBUG", "Screens init: MSG.error_deposit = " .. tostring(MSG.error_deposit))
end

-- Helper: execute UI and pedestal updates in parallel or sequential based on config
local function executeParallelOrSequential(uiFunc, pedestalFunc)
    -- logging.writeLog("DEBUG", "executeParallelOrSequential: config=" .. tostring(config) .. " config.get=" .. tostring(config.get))
    local parallelRendering = config.get("PARALLEL_RENDERING")
    -- logging.writeLog("DEBUG", "executeParallelOrSequential: PARALLEL_RENDERING=" .. tostring(parallelRendering) .. " (type: " .. type(parallelRendering) .. ")")
    if parallelRendering == false then
        -- logging.writeLog("DEBUG", "Parallel rendering disabled, executing sequentially")
        uiFunc()
        pedestalFunc()
        -- logging.writeLog("DEBUG", "Sequential execution completed")
    else
        -- Run sequentially to avoid nested parallel.waitForAll calls
        -- (pedestal functions internally use parallel rendering)
        -- logging.writeLog("DEBUG", "Running UI then pedestal sequentially (internal parallel)")
        uiFunc()
        pedestalFunc()
        -- logging.writeLog("DEBUG", "Sequential execution with internal parallel completed")
    end
end

-- Screen 1: Category selection
local function renderScreen1()
    logging.writeLog("INFO", "Rendering screen 1 (categories)")
    -- logging.writeLog("DEBUG", "CATEGORIES count: " .. tostring(#CATEGORIES))
    -- logging.writeLog("DEBUG", "MATERIALS count: " .. tostring(#MATERIALS))
    -- logging.writeLog("DEBUG", "QUANTITIES count: " .. tostring(#QUANTITIES))
    -- Clear pedestals first (like screen 2 and 3 selecting)
    pedestal.clearPedestals()
    local options = {}
    for _, cat in ipairs(CATEGORIES) do
        table.insert(options, { item = cat.item, label = cat.label })
    end
    -- Update UI and pedestals in parallel or sequential based on config
    -- logging.writeLog("DEBUG", "Starting UI and pedestal update for screen 1")
    executeParallelOrSequential(
        function()
            -- logging.writeLog("DEBUG", "UI update task")
            ui.updateUI()
            -- logging.writeLog("DEBUG", "UI update completed")
        end,
        function()
            -- logging.writeLog("DEBUG", "Pedestal update task")
            pedestal.setPedestalOptions(options)
            -- logging.writeLog("DEBUG", "Pedestal update completed")
        end
    )
end

-- Screen 2: Material selection (filtered by category and stock)
local function renderScreen2()
    local selectedCategory = state.getState("selectedCategory")
    logging.writeLog("INFO", "Rendering screen 2 (materials) for category: " .. tostring(selectedCategory))
    pedestal.clearPedestals()
    local options = {}
    -- logging.writeLog("DEBUG", "MATERIALS total: " .. #MATERIALS)
    for idx, mat in ipairs(MATERIALS) do
        if mat.category == selectedCategory then
            -- logging.writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. ", label=" .. mat.label .. ", category=" .. mat.category .. ", minQty=" .. mat.minQty)
            local stock = peripherals.getAE2Stock(mat.item)
            -- logging.writeLog("DEBUG", "  stock=" .. stock)
            if stock >= mat.minQty then
                -- logging.writeLog("DEBUG", "  -> qualifies")
                table.insert(options, { item = mat.item, label = mat.label })
            else
                -- logging.writeLog("DEBUG", "  -> insufficient stock")
            end
        else
            -- logging.writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. " category mismatch (" .. mat.category .. " vs " .. selectedCategory .. ")")
        end
    end
    logging.writeLog("INFO", "Available materials: " .. #options)
    if #options == 0 then
        -- No materials available, go back to screen 1
        logging.writeLog("WARN", "No materials available, returning to screen 1")
        state.updateState({ screen = 1, selectedCategory = nil, paymentDeadline = nil })
        -- Recursive call; but we need to avoid infinite recursion. Use renderCurrentScreen.
        -- We'll call renderCurrentScreen via the main loop. For now, just update state.
        return
    end
    -- Update UI and pedestals in parallel or sequential based on config
    executeParallelOrSequential(
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
end

-- Screen 3: Quantity selection (selecting sub-state)
local function renderScreen3Selecting()
    local selectedMaterial = state.getState("selectedMaterial")
    logging.writeLog("INFO", "Rendering screen 3 (selecting) for material: " .. tostring(selectedMaterial.item))
    pedestal.clearPedestals()
    local stock = peripherals.getAE2Stock(selectedMaterial.item)
    -- logging.writeLog("DEBUG", "Stock: " .. stock .. " minQty: " .. selectedMaterial.minQty)
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
        state.updateState({ screen = 2, selectedMaterial = nil, paymentDeadline = nil })
        return
    end
    local options = {}
    for _, qtyNum in ipairs(quantities) do
        table.insert(options, { item = selectedMaterial.item, label = tostring(qtyNum), count = qtyNum })
    end
    -- Update UI and pedestals in parallel or sequential based on config
    executeParallelOrSequential(
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )
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

    -- Calculate price with bulk discount
    local finalPrice, basePriceForQty, discountLevel, discountPercent =
        calculatePriceWithDiscount(selectedMaterial.basePrice, selectedMaterial.minQty, selectedQty)
    state.updateState({
        calculatedPrice = finalPrice,
        discountLevel = discountLevel,
        discountPercent = discountPercent,
        basePriceForQty = basePriceForQty
    })
    logging.writeLog("INFO", "Price calculated: " .. finalPrice .. " spurs for quantity " .. selectedQty ..
                     " (base: " .. basePriceForQty .. ", discount: " .. discountPercent .. "%, level: " .. discountLevel .. ")")

    -- Set depositor price
    local ok, err = pcall(peripherals.getDepositor().setTotalPrice, finalPrice)
    if not ok then
        logging.writeLog("ERROR", "Depositor setTotalPrice failed: " .. tostring(err))
        -- logging.writeLog("DEBUG", "Depositor error, resetting to main screen")
        local hintLabel = ui.getHintLabel()
        if hintLabel then
            hintLabel:setText(MSG.error_deposit)
            hintLabel:setVisible(true)
        end
        os.sleep(2)
        state.resetToMainScreen()
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

    -- Update UI and pedestals in parallel or sequential based on config
    executeParallelOrSequential(
        function() ui.updateUI() end,
        function() pedestal.setPedestalOptions(options) end
    )

    -- Update pedestal labels: selected quantity gets brackets
    local currentOptions = state.getState("currentOptions")
    local pedestals = peripherals.getPedestals() or {}
    for idx, opt in pairs(currentOptions) do
        if opt.count and pedestals[idx] then
            local label = tostring(opt.count)
            if opt.count == selectedQty then
                label = "[ " .. label .. " ]"
                state.updateState({ lastSelectedPedestal = idx })
            end
            -- logging.writeLog("DEBUG", "Setting pedestal " .. idx .. " label: " .. label)
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
    -- logging.writeLog("DEBUG", "Payment baseline table: " .. textutils.serialize(baselineTable))
    -- logging.writeLog("DEBUG", "renderScreen3Confirming: PAYMENT_TIMEOUT="..tostring(PAYMENT_TIMEOUT).." os.clock()="..os.clock())
    -- Ensure paymentDeadline is set (fallback in case events.lua didn't set it)
    if not state.getState("paymentDeadline") then
        state.updateState({ paymentDeadline = os.clock() + PAYMENT_TIMEOUT })
        logging.writeLog("WARN", "renderScreen3Confirming: paymentDeadline was nil, set fallback deadline")
    end
    state.updateState({
        paymentBaseline = baselineTable,
        paymentPaid = false,
        paymentCheckCount = 0
    })
    
    logging.writeLog("INFO", "Payment deadline: " .. tostring(state.getState("paymentDeadline")) .. " (current time: " .. os.clock() .. ")")
end

-- Screen 4: Thank you
local function renderScreen4()
    -- Clear pedestals and update UI in parallel or sequential based on config
    executeParallelOrSequential(
        function() ui.updateUI() end,
        function() pedestal.clearPedestals() end
    )
    -- Play noteblock sound
    peripherals.playNoteblockSoundHigh()
    -- Log purchase
    local selectedCategory = state.getState("selectedCategory")
    local selectedMaterial = state.getState("selectedMaterial")
    local selectedQty = state.getState("selectedQty")
    local calculatedPrice = state.getState("calculatedPrice")
    local record = {
        timestamp = os.time(),
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
    -- logging.writeLog("DEBUG", "Screen 4 auto-return, resetting to main screen")
    state.resetToMainScreen()
end

-- Update screen based on state
local function renderCurrentScreen()
    logging.writeLog("INFO", "renderCurrentScreen called - screen=" .. tostring(state.getState("screen")) .. " subState=" .. tostring(state.getState("subState")))
    state.updateState({ lastActivity = os.clock() })
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    -- local paymentDeadline = state.getState("paymentDeadline")
    -- logging.writeLog("DEBUG", "screen=" .. tostring(screen) .. " subState=" .. tostring(subState) .. " paymentDeadline=" .. tostring(paymentDeadline))
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