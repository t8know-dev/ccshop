-- shop.lua — ComputerCraft shop, requires Basalt UI
-- Main script for multi-screen shop with AE2 adapter, Numismatics depositor, redstone relays.

local basalt = require("basalt")

-- Debug logging
local LOG_FILE = "/ccshop/shop_debug.log"
local LOG_LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
local CURRENT_LOG_LEVEL = LOG_LEVELS[LOG_LEVEL] or LOG_LEVELS.INFO

local function writeLog(level, msg)
    -- Support old signature: single argument defaults to INFO
    if msg == nil then
        msg = level
        level = "INFO"
    end
    if LOG_LEVELS[level] < CURRENT_LOG_LEVEL then return end

    local t = os.date("*t")
    local ts = string.format("[%04d-%02d-%02d %02d:%02d:%02d]",
        t.year, t.month, t.day, t.hour, t.min, t.sec)
    local line = ts .. " [" .. level .. "] " .. msg
    local prev
    local ok1, err1 = pcall(function() prev = term.redirect(term.native()) end)
    if ok1 and prev then
        print(line)
        pcall(term.redirect, prev)
    else
        -- Fallback: just print to current terminal
        print(line)
    end
    local f = fs.open(LOG_FILE, "a")
    if f then
        f.writeLine(line)
        f.close()
    end
end

-- Load configuration and items (they define globals)
dofile("/ccshop/config.lua")
dofile("/ccshop/items.lua")
local db = dofile("/ccshop/db.lua")

-- Validate configuration and items
local function validateAll()
    -- 1. Validate peripherals
    local ok, err = validatePeripherals()
    if not ok then
        error("Peripheral validation failed: " .. err)
    end

    -- 2. Every MATERIALS[i].category exists in CATEGORIES labels
    local categoryLabels = {}
    for _, cat in ipairs(CATEGORIES) do
        categoryLabels[cat.label] = true
    end
    for _, mat in ipairs(MATERIALS) do
        if not categoryLabels[mat.category] then
            error("Material '" .. mat.label .. "' references unknown category '" .. mat.category .. "'")
        end
    end

    -- 3. Every MATERIALS[i].minQty exists in the numeric expansion of QUANTITIES
    local quantitySet = {}
    for _, q in ipairs(QUANTITIES) do
        quantitySet[quantityToNumber(q)] = true
    end
    for _, mat in ipairs(MATERIALS) do
        if not quantitySet[mat.minQty] then
            error("Material '" .. mat.label .. "' minQty " .. mat.minQty .. " not in QUANTITIES")
        end
    end

    -- 4. QUANTITIES contains no unknown string values (only "4k", "16k", "32k" allowed as strings)
    for _, q in ipairs(QUANTITIES) do
        if type(q) == "string" then
            if q ~= "4k" and q ~= "16k" and q ~= "32k" then
                error("QUANTITIES contains unknown string value: " .. q)
            end
        elseif type(q) ~= "number" then
            error("QUANTITIES contains non‑numeric, non‑string value: " .. type(q))
        end
    end

    -- 5. basePrice > 0 for all materials
    for _, mat in ipairs(MATERIALS) do
        if mat.basePrice <= 0 then
            error("Material '" .. mat.label .. "' basePrice must be > 0")
        end
    end

    -- 6. At least one category and one material defined
    if #CATEGORIES == 0 then
        error("No categories defined")
    end
    if #MATERIALS == 0 then
        error("No materials defined")
    end

    return true
end

-- Global state (as per spec)
local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity/payment, 4=thankyou
    subState = nil,           -- nil, "selecting", or "confirming" (screen 3 only)
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    calculatedPrice = nil,    -- price for selected quantity
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table (item, label, count)
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    cancelRequested = false,
    availableQuantities = nil, -- list of numeric quantities available for selected material
    paymentBaseline = nil,    -- baseline relay input state for payment detection
    paymentDeadline = nil,    -- os.clock() deadline for payment timeout
    paymentPaid = false,
    paymentCheckCount = 0,    -- counter for payment detection checks
}

-- Forward declaration for renderCurrentScreen (defined later)
local renderCurrentScreen

-- Peripheral wrappers (initialized after validation)
local relayLock, ae2Adapter, depositor, relayNote, monitor, pedestals
local pedestalIndexByName, pedestalObjectToIndex
local ae2Cache = {
    timestamp = 0,
    data = {},
    ttl = AE2_CACHE_TTL or 30
}

-- Initialize peripherals
local function initPeripherals()
    writeLog("INFO", "Initializing peripherals")
    relayLock = peripheral.wrap(RELAY_LOCK)
    writeLog("DEBUG", "RELAY_LOCK wrapped: " .. tostring(relayLock))
    ae2Adapter = peripheral.wrap(AE2_ADAPTER)
    if not ae2Adapter then
        writeLog("DEBUG", "AE2_ADAPTER wrap failed, trying peripheral.find(\"ae2cc_adapter\")")
        ae2Adapter = peripheral.find("ae2cc_adapter")
    end
    writeLog("DEBUG", "AE2_ADAPTER wrapped: " .. tostring(ae2Adapter) .. " (name: " .. AE2_ADAPTER .. ")")
    depositor = peripheral.wrap(DEPOSITOR)
    writeLog("DEBUG", "DEPOSITOR wrapped: " .. tostring(depositor))
    relayNote = peripheral.wrap(RELAY_NOTE)
    writeLog("DEBUG", "RELAY_NOTE wrapped: " .. tostring(relayNote))
    monitor = peripheral.wrap(MONITOR)
    writeLog("DEBUG", "MONITOR wrapped: " .. tostring(monitor))
    pedestals = {}
    for i, name in ipairs(PEDESTALS) do
        pedestals[i] = peripheral.wrap(name)
        if pedestals[i] then
            writeLog("DEBUG", "Pedestal " .. i .. ": " .. name .. " wrapped successfully")
        else
    writeLog("WARN", "Pedestal " .. i .. ": " .. name .. " failed to wrap")
        end
    end
    -- Create name->index mapping
    pedestalIndexByName = {}
    for i, name in ipairs(PEDESTALS) do
        pedestalIndexByName[name] = i
        writeLog("DEBUG", "Pedestal mapping: " .. name .. " -> " .. i)
    end
    -- Create object->index mapping
    pedestalObjectToIndex = {}
    for i, ped in ipairs(pedestals) do
        if ped then
            pedestalObjectToIndex[ped] = i
            writeLog("DEBUG", "Pedestal object mapping: " .. tostring(ped) .. " -> " .. i)
        end
    end
    -- Ensure monitor is cleared and set text scale
    pcall(monitor.setTextScale, 0.5)
    pcall(monitor.clear)
    -- Lock depositor on startup
    pcall(relayLock.setOutput, "bottom", true)
end

-- Helper: refresh AE2 stock cache
local function refreshAE2Cache()
    if not ae2Adapter then
        writeLog("DEBUG", "AE2 adapter not available, cannot refresh cache")
        return
    end
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if ok then
        ae2Cache.data = {}
        for _, obj in ipairs(objects) do
            ae2Cache.data[obj.id] = obj.amount or 0
        end
        ae2Cache.timestamp = os.clock()
        writeLog("DEBUG", "AE2 cache refreshed: " .. #objects .. " items")
    else
        writeLog("ERROR", "AE2 cache refresh failed: " .. tostring(objects))
    end
end

-- Helper: get AE2 stock for an item name (with caching)
local function getAE2Stock(itemName)
    -- Refresh cache if stale
    if os.clock() - ae2Cache.timestamp > ae2Cache.ttl then
        writeLog("DEBUG", "AE2 cache stale, refreshing")
        refreshAE2Cache()
    end

    if not ae2Adapter then
        writeLog("WARN", "AE2 adapter not initialized, returning stock 0")
        return 0
    end

    -- Check cache first
    if ae2Cache.data[itemName] ~= nil then
        local amount = ae2Cache.data[itemName]
        writeLog("DEBUG", "getAE2Stock cache hit: " .. itemName .. " -> " .. amount)
        return amount
    end

    -- Fallback to direct query (should not happen if cache is fresh)
    writeLog("DEBUG", "getAE2Stock cache miss: " .. itemName .. ", performing direct query")
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if not ok then
        writeLog("ERROR", "AE2 adapter error: " .. tostring(objects))
        return 0
    end

    for _, obj in ipairs(objects) do
        if obj.id == itemName then
            local amount = obj.amount or 0
            -- Update cache
            ae2Cache.data[itemName] = amount
            writeLog("DEBUG", "getAE2Stock direct match: " .. itemName .. " -> " .. amount)
            return amount
        end
    end

    writeLog("DEBUG", "getAE2Stock no match for " .. itemName)
    ae2Cache.data[itemName] = 0  -- Cache miss as zero to avoid repeated queries
    return 0
end

-- Helper: play noteblock sound
local function playNoteblockSound()
    writeLog("DEBUG", "Playing noteblock sound")
    pcall(relayNote.setOutput, "front", true)
    os.sleep(0.05)
    pcall(relayNote.setOutput, "front", false)
end

-- Helper: set pedestal label with selection brackets
local function setPedestalSelection(pedestalIdx, selected)
    writeLog("DEBUG", "setPedestalSelection: idx=" .. pedestalIdx .. ", selected=" .. tostring(selected))
    local opt = state.currentOptions[pedestalIdx]
    if not opt or not pedestals[pedestalIdx] then
        writeLog("DEBUG", "  No option or pedestal for index " .. pedestalIdx)
        return
    end

    local label = opt.count and tostring(opt.count) or opt.label
    if selected then
        label = "[ " .. label .. " ]"
    end

    writeLog("DEBUG", "  Setting pedestal " .. pedestalIdx .. " label: " .. label)
    local ok, err = pcall(pedestals[pedestalIdx].setItem, opt.item, label)
    if not ok then
        writeLog("WARN", "  setItem with label failed: " .. tostring(err))
    end
end

-- Helper: clear pedestals (remove items and labels)
local function clearPedestals()
    writeLog("DEBUG", "clearPedestals called")
    -- Clear state tracking
    state.currentOptions = {}
    state.currentPedestalIndices = {}
    state.lastSelectedPedestal = nil
    for i = 1, #PEDESTALS do
        if pedestals[i] then
            writeLog("DEBUG", "Clearing pedestal " .. i)
            pcall(pedestals[i].setItem, nil)
            local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
            local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
            if not ok1 then writeLog("WARN", "  setItemRendered failed: " .. tostring(err1)) end
            if not ok2 then writeLog("WARN", "  setLabelRendered failed: " .. tostring(err2)) end
        end
    end
end

-- Helper: center options across available pedestals
-- Given number of options (<= #PEDESTALS), returns table of pedestal indices to use
local function centerPedestalIndices(numOptions)
    local total = #PEDESTALS
    if numOptions > total then numOptions = total end
    local start = math.floor((total - numOptions) / 2) + 1
    local indices = {}
    for i = start, start + numOptions - 1 do
        table.insert(indices, i)
    end
    writeLog("DEBUG", "centerPedestalIndices: numOptions=" .. numOptions .. " total=" .. total .. " start=" .. start .. " indices: " .. table.concat(indices, ","))
    return indices
end

-- Helper: update pedestals with items and labels
local function setPedestalOptions(options)
    -- options: array of {item=, label=, count=}
    writeLog("INFO", "setPedestalOptions called with " .. #options .. " options")
    for i, opt in ipairs(options) do
        writeLog("DEBUG", "  option " .. i .. ": item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
    end
    local indices = centerPedestalIndices(#options)
    -- Update state tracking
    state.currentOptions = {}
    state.currentPedestalIndices = {}
    for i, idx in ipairs(indices) do
        state.currentPedestalIndices[idx] = true
        if options[i] then
            state.currentOptions[idx] = {
                item = options[i].item,
                label = options[i].label,
                count = options[i].count
            }
            writeLog("DEBUG", "State tracking: pedestal " .. idx .. " -> count=" .. tostring(options[i].count))
        end
    end
    writeLog("DEBUG", "Current pedestal indices: " .. table.concat(indices, ","))
    -- Update used pedestals
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt and pedestals[idx] then
            writeLog("DEBUG", "Setting pedestal " .. idx .. " with item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
            -- Set item with optional label (count takes precedence over label)
            local label = opt.count and tostring(opt.count) or opt.label
            if opt.item then
                if label then
                    writeLog("DEBUG", "  setItem: " .. opt.item .. " label: " .. label)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
                    if not ok then writeLog("WARN", "    setItem with label failed: " .. tostring(err)) end
                else
                    writeLog("DEBUG", "  setItem: " .. opt.item)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item)
                    if not ok then writeLog("WARN", "    setItem failed: " .. tostring(err)) end
                end
                local ok2, err2 = pcall(pedestals[idx].setItemRendered, true)
                if not ok2 then writeLog("WARN", "    setItemRendered failed: " .. tostring(err2)) end
                -- Keep label rendering separate (optional)
                if label then
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, true)
                    if not ok3 then writeLog("WARN", "    setLabelRendered failed: " .. tostring(err3)) end
                else
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, false)
                    if not ok3 then writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err3)) end
                end
            else
                writeLog("DEBUG", "  setItem: nil")
                pcall(pedestals[idx].setItem, nil)
                local ok, err = pcall(pedestals[idx].setItemRendered, false)
                if not ok then writeLog("WARN", "    setItemRendered(false) failed: " .. tostring(err)) end
                local ok2, err2 = pcall(pedestals[idx].setLabelRendered, false)
                if not ok2 then writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err2)) end
            end
        end
    end
    -- Clear unused pedestals
    for i = 1, #PEDESTALS do
        local used = false
        for _, idx in ipairs(indices) do
            if i == idx then used = true break end
        end
        if not used and pedestals[i] then
            writeLog("DEBUG", "Clearing unused pedestal " .. i)
            pcall(pedestals[i].setItem, nil)
            local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
            local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
            if not ok1 then writeLog("WARN", "  setItemRendered(false) failed: " .. tostring(err1)) end
            if not ok2 then writeLog("WARN", "  setLabelRendered(false) failed: " .. tostring(err2)) end
        end
    end
end

-- Basalt UI elements
local frame, headerLabel, hintLabel, cancelButton

-- Create UI frame
local function createUI()
    frame = basalt.createFrame():setTerm(monitor):setBackground(colors.black)
    -- Header (top line)
    headerLabel = frame:addLabel()
        :setPosition(1,1):setSize(monitor.getSize(),1)
        :setBackground(colors.gray):setForeground(colors.white)
        :setText(MSG.header)
    -- Hint line (second line)
    hintLabel = frame:addLabel()
        :setPosition(1,2):setSize(monitor.getSize(),1)
        :setBackground(colors.black):setForeground(colors.lightGray)
    -- Cancel button (top-left, hidden initially)
    cancelButton = frame:addButton()
        :setText(MSG.cancel_btn)
        :setPosition(1,1)
        :setSize(#MSG.cancel_btn, 1)
        :setBackground(colors.gray)
        :setForeground(colors.white)
        :onClick(function()
            playNoteblockSound()
            -- Lock depositor if on payment screen (screen 3 confirming)
            if state.screen == 3 and state.subState == "confirming" then
                pcall(relayLock.setOutput, "bottom", true)  -- lock depositor
                state.cancelRequested = true
                state.paymentPaid = false
            end
            -- Reset to main screen
            state.screen = 1
            state.selectedCategory = nil
            state.selectedMaterial = nil
            state.selectedQty = nil
            state.subState = nil
            state.cancelRequested = false
            state.paymentCheckCount = 0
            state.paymentBaseline = nil
            renderCurrentScreen()
        end)
    if cancelButton and cancelButton.setVisible then
        cancelButton:setVisible(false)
    else
        writeLog("ERROR", "cancelButton invalid " .. tostring(cancelButton))
    end
end

-- Update UI hints and cancel button visibility
local function updateUI()
    if state.screen == 1 then
        hintLabel:setText(MSG.screen1_hint)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(false) end
    elseif state.screen == 2 then
        hintLabel:setText(MSG.screen2_hint)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
    elseif state.screen == 3 then
        if state.subState == "selecting" then
            -- Show base price and hint
            local basePriceStr = ""
            if state.selectedMaterial then
                basePriceStr = string.format(MSG.screen3_base_price, state.selectedMaterial.basePrice, tostring(state.selectedMaterial.minQty)) .. " | "
            end
            hintLabel:setText(basePriceStr .. MSG.screen3_hint_select)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        elseif state.subState == "confirming" then
            -- Show price and insert instruction
            local hint = string.format(MSG.screen3_price_calc, state.calculatedPrice) .. " - " ..
                        string.format(MSG.screen3_insert, state.calculatedPrice)
            hintLabel:setText(hint)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        end
    elseif state.screen == 4 then
        hintLabel:setText(MSG.screen4_thanks)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(false) end
    end
end

-- Screen 1: Category selection
local function renderScreen1()
    writeLog("INFO", "Rendering screen 1 (categories)")
    clearPedestals()
    local options = {}
    for _, cat in ipairs(CATEGORIES) do
        table.insert(options, { item = cat.item, label = cat.label })
    end
    updateUI()
    setPedestalOptions(options)
end

-- Screen 2: Material selection (filtered by category and stock)
local function renderScreen2()
    writeLog("INFO", "Rendering screen 2 (materials) for category: " .. tostring(state.selectedCategory))
    clearPedestals()
    local options = {}
    writeLog("DEBUG", "MATERIALS total: " .. #MATERIALS)
    for idx, mat in ipairs(MATERIALS) do
        if mat.category == state.selectedCategory then
            writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. ", label=" .. mat.label .. ", category=" .. mat.category .. ", minQty=" .. mat.minQty)
            local stock = getAE2Stock(mat.item)
            writeLog("DEBUG", "  stock=" .. stock)
            if stock >= mat.minQty then
                writeLog("DEBUG", "  -> qualifies")
                table.insert(options, { item = mat.item, label = mat.label })
            else
                writeLog("DEBUG", "  -> insufficient stock")
            end
        else
            writeLog("DEBUG", "Material " .. idx .. ": item=" .. mat.item .. " category mismatch (" .. mat.category .. " vs " .. state.selectedCategory .. ")")
        end
    end
    writeLog("INFO", "Available materials: " .. #options)
    if #options == 0 then
        -- No materials available, go back to screen 1
        writeLog("WARN", "No materials available, returning to screen 1")
        state.screen = 1
        renderCurrentScreen()
        return
    end
    updateUI()
    setPedestalOptions(options)
end

-- Screen 3: Quantity selection (selecting sub-state)
local function renderScreen3Selecting()
    writeLog("INFO", "Rendering screen 3 (selecting) for material: " .. tostring(state.selectedMaterial.item))
    clearPedestals()
    local stock = getAE2Stock(state.selectedMaterial.item)
    writeLog("DEBUG", "Stock: " .. stock .. " minQty: " .. state.selectedMaterial.minQty)
    local quantities = {}
    local startIdx = findQuantityIndex(state.selectedMaterial.minQty)
    if not startIdx then startIdx = 1 end
    for i = startIdx, #QUANTITIES do
        local qtyNum = quantityToNumber(QUANTITIES[i])
        if qtyNum <= stock then
            table.insert(quantities, qtyNum)
        else
            break
        end
    end
    writeLog("INFO", "Available quantities: " .. #quantities)
    state.availableQuantities = quantities
    if #quantities == 0 then
        -- No quantities available (stock less than minQty) – should not happen
        writeLog("WARN", "No quantities available, returning to screen 2")
        state.screen = 2
        renderCurrentScreen()
        return
    end
    local options = {}
    for _, qtyNum in ipairs(quantities) do
        table.insert(options, { item = state.selectedMaterial.item, label = tostring(qtyNum), count = qtyNum })
    end
    updateUI()
    setPedestalOptions(options)
end

-- Screen 3: Payment (confirming sub-state)
local function renderScreen3Confirming()
    writeLog("INFO", "Rendering screen 3 (confirming) for material: " .. tostring(state.selectedMaterial.item) .. " qty: " .. tostring(state.selectedQty))

    -- Ensure we have available quantities (should be set from screen 3)
    if not state.availableQuantities then
        writeLog("ERROR", "availableQuantities not set, recomputing")
        local stock = getAE2Stock(state.selectedMaterial.item)
        local quantities = {}
        local startIdx = findQuantityIndex(state.selectedMaterial.minQty)
        if not startIdx then startIdx = 1 end
        for i = startIdx, #QUANTITIES do
            local qtyNum = quantityToNumber(QUANTITIES[i])
            if qtyNum <= stock then
                table.insert(quantities, qtyNum)
            else break end
        end
        state.availableQuantities = quantities
    end

    -- Lock depositor first (in case we're changing quantity)
    pcall(relayLock.setOutput, "bottom", true)

    -- Calculate price
    local price = math.floor(state.selectedMaterial.basePrice * (state.selectedQty / state.selectedMaterial.minQty))
    state.calculatedPrice = price
    writeLog("INFO", "Price calculated: " .. price .. " spurs for quantity " .. state.selectedQty)

    -- Set depositor price
    local ok, err = pcall(depositor.setTotalPrice, price)
    if not ok then
        hintLabel:setText(MSG.error_deposit)
        os.sleep(2)
        state.screen = 1
        renderCurrentScreen()
        return
    end

    -- Update UI (hint will show price and insert instruction)
    updateUI()

    -- Create options for all available quantities
    local options = {}
    for _, qtyNum in ipairs(state.availableQuantities) do
        table.insert(options, {
            item = state.selectedMaterial.item,
            label = tostring(qtyNum),
            count = qtyNum
        })
    end
    setPedestalOptions(options)

    -- Update pedestal labels: selected quantity gets brackets
    for idx, opt in pairs(state.currentOptions) do
        if opt.count and pedestals[idx] then
            local label = tostring(opt.count)
            if opt.count == state.selectedQty then
                label = "[ " .. label .. " ]"
                state.lastSelectedPedestal = idx
            end
            writeLog("DEBUG", "Setting pedestal " .. idx .. " label: " .. label)
            pcall(pedestals[idx].setItem, opt.item, label)
            pcall(pedestals[idx].setItemRendered, true)
            pcall(pedestals[idx].setLabelRendered, true)
        end
    end

    -- Unlock depositor and establish baseline for payment detection
    pcall(relayLock.setOutput, "bottom", false)
    os.sleep(0.3)
    -- Get baseline for all sides
    local baselineTable = getAllRelayInputs()
    state.paymentBaseline = baselineTable
    state.paymentDeadline = os.clock() + PAYMENT_TIMEOUT
    state.paymentPaid = false
    state.cancelRequested = false
    state.paymentCheckCount = 0

    -- Log baseline for top side (for compatibility)
    local topBaseline = baselineTable["top"] or false
    writeLog("INFO", "Depositor unlocked, baseline (top side): " .. tostring(topBaseline) .. ", deadline: " .. state.paymentDeadline)
    debugRelayInputs()  -- Log all sides for debugging
    if topBaseline then
        writeLog("INFO", "Waiting for LOW signal (transition away from HIGH) for payment detection")
    else
        writeLog("INFO", "Waiting for HIGH signal (transition away from LOW) for payment detection")
    end
end

-- Screen 4: Thank you
local function renderScreen4()
    clearPedestals()
    updateUI()
    -- Play noteblock sound
    playNoteblockSound()
    -- Log purchase
    local record = {
        timestamp = os.epoch("utc"),
        playerName = nil, -- not tracked yet
        category = state.selectedCategory,
        item = state.selectedMaterial.item,
        qty = state.selectedQty,
        price = state.calculatedPrice or math.floor(state.selectedMaterial.basePrice * (state.selectedQty / state.selectedMaterial.minQty))
    }
    pcall(db.log, record)
    -- Refresh AE2 cache after purchase (stock changed)
    refreshAE2Cache()
    -- Mock dispense
    writeLog("INFO", "[MOCK] Dispense " .. state.selectedQty .. "x " .. state.selectedMaterial.item)
    -- Auto-return to screen 1 after CONFIRM_DELAY seconds
    os.sleep(CONFIRM_DELAY)
    state.screen = 1
    state.selectedCategory = nil
    state.selectedMaterial = nil
    state.selectedQty = nil
    state.subState = nil
    state.calculatedPrice = nil
    state.paymentPaid = false
    state.cancelRequested = false
    state.paymentCheckCount = 0
    state.paymentBaseline = nil
    renderCurrentScreen()
end

-- Update screen based on state
renderCurrentScreen = function()
    state.lastActivity = os.clock()
    if state.screen == 1 then renderScreen1()
    elseif state.screen == 2 then renderScreen2()
    elseif state.screen == 3 then
        if state.subState == "selecting" then renderScreen3Selecting()
        elseif state.subState == "confirming" then renderScreen3Confirming()
        else renderScreen3Selecting() -- default to selecting
        end
    elseif state.screen == 4 then renderScreen4() -- formerly screen 5
    end
end


-- Map pedestal object/name to index
local function getPedestalIndex(eventData)
    local pedestalIndex = nil
    if type(eventData[2]) == 'table' then
        -- eventData[2] is the pedestal object
        pedestalIndex = pedestalObjectToIndex[eventData[2]]
        if not pedestalIndex then
            -- Fallback: get name from object
            local pedestalName
            local ok, name = pcall(peripheral.getName, eventData[2])
            if ok then pedestalName = name end
            if pedestalName then
                pedestalIndex = pedestalIndexByName[pedestalName]
            end
        end
    else
        -- eventData[2] is already a name string
        local pedestalName = eventData[2]
        pedestalIndex = pedestalIndexByName[pedestalName]
    end
    return pedestalIndex
end

-- Extract selected count from event data and pedestal option
local function getSelectedCount(pedestalOption, eventData)
    local selectedCount = nil
    local displayName = type(eventData[3]) == 'table' and eventData[3].displayName
    -- Try to extract count from displayName first (most reliable)
    if displayName then
        if type(displayName) == 'number' then
            selectedCount = displayName
        else
            local str = tostring(displayName)
            -- Remove brackets and trim whitespace
            local cleanName = str:gsub('%[', ''):gsub('%]', ''):gsub('^%s*(.-)%s*$', '%1')
            local num = tonumber(cleanName)
            if num then
                selectedCount = num
            else
            end
        end
    end
    -- Fallback to pedestal option count
    if not selectedCount and pedestalOption and pedestalOption.count then
        selectedCount = pedestalOption.count
    end
    -- Final fallback to event count
    if not selectedCount then
        selectedCount = type(eventData[3]) == 'table' and eventData[3].count
    end
    return selectedCount
end

-- Handle screen 1 category selection
local function handleScreen1Click(pedestalIndex, pedestalOption, side, itemId)
    -- Category selection: right-click only
    if side == 'right' then
        local catIdx = nil
        -- Try to find category by itemId first (most reliable)
        if itemId then
            -- Exact match
            for i, cat in ipairs(CATEGORIES) do
                if cat.item == itemId then
                    catIdx = i
                    break
                end
            end
            if not catIdx then
                -- Try prefix match (ignore metadata after colon)
                local prefix = itemId:match('^[^:]+')
                if prefix then
                    for i, cat in ipairs(CATEGORIES) do
                        if cat.item == prefix or cat.item:match('^[^:]+') == prefix then
                            catIdx = i
                            break
                        end
                    end
                end
            end
        end
        if catIdx then
            state.selectedCategory = CATEGORIES[catIdx].label
            state.screen = 2
            renderCurrentScreen()
        end
    end
end

-- Handle screen 2 material selection
local function handleScreen2Click(pedestalIndex, pedestalOption, side, itemId)
    -- Material selection: right-click select, left-click back
    if side == 'right' then
        -- Determine which material option is on this pedestal
        local materialsInCategory = {}
        for _, mat in ipairs(MATERIALS) do
            if mat.category == state.selectedCategory then
                table.insert(materialsInCategory, mat)
            end
        end
        local matIdx = nil
        -- Try to find material by itemId first
        if itemId then
            -- Exact match
            for i, mat in ipairs(materialsInCategory) do
                if mat.item == itemId then
                    matIdx = i
                    break
                end
            end
            if matIdx then
            else
                -- Try prefix match (ignore metadata after colon)
                local prefix = itemId:match('^[^:]+')
                if prefix then
                    for i, mat in ipairs(materialsInCategory) do
                        if mat.item == prefix or mat.item:match('^[^:]+') == prefix then
                            matIdx = i
                            break
                        end
                    end
                end
            end
        end
        if matIdx then
            state.selectedMaterial = materialsInCategory[matIdx]
            state.screen = 3
            state.subState = 'selecting'
            renderCurrentScreen()
        else
        end
    elseif side == 'left' then
        -- Back to screen 1
        state.screen = 1
        state.paymentBaseline = nil
        state.paymentCheckCount = 0
        renderCurrentScreen()
    end
end

-- Handle screen 3 quantity selection/payment
local function handleScreen3Click(pedestalIndex, pedestalOption, side, selectedCount)
    -- Screen 3: Quantity selection/payment
    if state.subState == 'selecting' then
        -- Quantity selecting sub-state
        if side == 'right' then
            -- Single RMB click selects quantity and moves to confirming
            if selectedCount then
                state.selectedQty = selectedCount
                state.subState = 'confirming'
                renderCurrentScreen()
            end
        elseif side == 'left' then
            -- LMB goes back to material selection
            state.screen = 2
            state.subState = nil
            state.paymentBaseline = nil
            state.paymentCheckCount = 0
            renderCurrentScreen()
        end
    elseif state.subState == 'confirming' then
        -- Payment awaiting sub-state
        if side == 'right' then
            -- RMB changes quantity (back to selecting)
            if selectedCount and selectedCount ~= state.selectedQty then
                state.selectedQty = selectedCount
                renderCurrentScreen()
            end
        elseif side == 'left' then
            -- LMB goes back to quantity selection, lock depositor
            pcall(relayLock.setOutput, 'bottom', true)
            state.subState = 'selecting'
            state.paymentBaseline = nil
            state.paymentCheckCount = 0
            renderCurrentScreen()
        end
    end
end

-- Handle pedestal click event
local function handlePedestalClick(event, eventData)
    local side = (event == 'pedestal_right_click') and 'right' or 'left'
    -- Play sound on any pedestal click
    playNoteblockSound()
    -- Determine action based on screen and mouse button
    local itemId = type(eventData[3]) == 'table' and eventData[3].name
    local itemCount = type(eventData[3]) == 'table' and eventData[3].count
    local displayName = type(eventData[3]) == 'table' and eventData[3].displayName
    -- Get pedestal index and option
    local pedestalIndex = getPedestalIndex(eventData)
    local pedestalOption = pedestalIndex and state.currentOptions[pedestalIndex]
    if not pedestalOption then
        -- Fallback: try to find option by itemId
        if itemId then
            for idx, opt in pairs(state.currentOptions) do
                if opt.item == itemId or (opt.item and itemId:match('^[^:]+') == opt.item:match('^[^:]+')) then
                    pedestalOption = opt
                    pedestalIndex = idx
                    break
                end
            end
        end
    end
    local selectedCount = getSelectedCount(pedestalOption, eventData)
    if state.screen == 1 then
        handleScreen1Click(pedestalIndex, pedestalOption, side, itemId)
    elseif state.screen == 2 then
        handleScreen2Click(pedestalIndex, pedestalOption, side, itemId)
    elseif state.screen == 3 then
        handleScreen3Click(pedestalIndex, pedestalOption, side, selectedCount)
    elseif state.screen == 4 then
        -- Thank you screen: ignore pedestal clicks (auto-returns to screen 1)
    end
end

-- Check idle timeout
local function checkIdleTimeout()
    if (state.screen == 2) or (state.screen == 3 and state.subState) then
        if os.clock() - state.lastActivity > IDLE_TIMEOUT then
            -- Timeout: lock depositor if in confirming state, reset to screen 1
            if state.screen == 3 and state.subState == 'confirming' then
                pcall(relayLock.setOutput, 'bottom', true)
            end
            state.screen = 1
            -- Reset all state
            state.selectedCategory = nil
            state.selectedMaterial = nil
            state.selectedQty = nil
            state.subState = nil
            state.paymentPaid = false
            state.paymentCheckCount = 0
            state.paymentBaseline = nil
            renderCurrentScreen()
            hintLabel:setText(MSG.timeout_msg)
            os.sleep(2)
        end
    end
end

-- Get all relay input sides as table side->value
local function getAllRelayInputs()
    local sides = {"bottom", "top", "front", "back", "left", "right"}
    local inputs = {}
    for _, side in ipairs(sides) do
        local ok, val = pcall(relayLock.getInput, side)
        if ok then
            inputs[side] = val
        else
            inputs[side] = nil
        end
    end
    return inputs
end

-- Debug: log all relay input sides
local function debugRelayInputs()
    local inputs = getAllRelayInputs()
    local results = {}
    for side, val in pairs(inputs) do
        if val ~= nil then
            table.insert(results, side .. "=" .. tostring(val))
        else
            table.insert(results, side .. "=error")
        end
    end
    writeLog("DEBUG", "Relay inputs: " .. table.concat(results, ", "))
end

-- Check payment detection
local function checkPaymentDetection()
    if state.screen == 3 and state.subState == 'confirming' and not state.paymentPaid and not state.cancelRequested then
        if os.clock() >= state.paymentDeadline then
            writeLog("INFO", "Payment timeout reached, locking depositor and returning to main screen")
            pcall(relayLock.setOutput, 'bottom', true)  -- lock depositor
            state.screen = 1
            -- Reset state
            state.selectedCategory = nil
            state.selectedMaterial = nil
            state.selectedQty = nil
            state.subState = nil
            state.paymentPaid = false
            state.paymentCheckCount = 0
            state.paymentBaseline = nil
            renderCurrentScreen()
        else
            state.paymentCheckCount = state.paymentCheckCount + 1
            if state.paymentCheckCount % 10 == 0 then
                writeLog("DEBUG", "Payment detection check #" .. state.paymentCheckCount .. ", deadline in " .. (state.paymentDeadline - os.clock()) .. "s")
            end
            if state.paymentCheckCount % 20 == 0 then
                debugRelayInputs()
            end
            -- Check all relay sides for payment signal
            local currentInputs = getAllRelayInputs()
            local paymentDetected = false
            local changedSide = nil
            for side, baselineVal in pairs(state.paymentBaseline) do
                local currentVal = currentInputs[side]
                if currentVal ~= nil and currentVal ~= baselineVal then
                    paymentDetected = true
                    changedSide = side
                    break
                end
            end
            if paymentDetected then
                writeLog("INFO", "Payment detected on side " .. tostring(changedSide) .. "! current=" .. tostring(currentInputs[changedSide]) .. " baseline=" .. tostring(state.paymentBaseline[changedSide]))
                pcall(relayLock.setOutput, 'bottom', true)  -- lock depositor
                state.paymentPaid = true
                state.screen = 4  -- Move to thank you screen
                renderCurrentScreen()
            else
                -- Log only occasionally to avoid spam
                if state.paymentCheckCount % 30 == 0 then
                    writeLog("DEBUG", "Payment detection check #" .. state.paymentCheckCount .. ", no change on any side")
                end
            end
        end
    end
end
-- Event loop for pedestal clicks
local function eventLoop()
    while true do
        -- Check idle timeout
        checkIdleTimeout()

        -- Check payment detection
        checkPaymentDetection()

        local eventData = { os.pullEvent() }
        local event = eventData[1]

        -- Pedestal click events from display_pedestal peripheral
        if event == "pedestal_left_click" or event == "pedestal_right_click" then
            handlePedestalClick(event, eventData)
        end

        os.sleep(EVENT_LOOP_SLEEP)
    end
end

-- Main
writeLog("INFO", "Starting shop system...")
local ok, err = pcall(function()
    validateAll()
    initPeripherals()
    createUI()
    renderCurrentScreen()

    parallel.waitForAny(
        function() basalt.run() end,
        eventLoop
    )
end)

if not ok then
    writeLog("ERROR", "Fatal error: " .. tostring(err))
    -- Attempt to lock depositor on crash
    pcall(relayLock.setOutput, "bottom", true)
    error(err)
end