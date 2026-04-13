-- shop.lua — ComputerCraft shop, requires Basalt UI
-- Main script for multi-screen shop with AE2 adapter, Numismatics depositor, redstone relays.

local basalt = require("basalt")

-- Debug logging
local LOG_FILE = "/ccshop/shop_debug.log"
local function writeLog(msg)
    local t = os.date("*t")
    local ts = string.format("[%04d-%02d-%02d %02d:%02d:%02d]",
        t.year, t.month, t.day, t.hour, t.min, t.sec)
    local line = ts .. " " .. msg
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
}

-- Forward declaration for renderCurrentScreen (defined later)
local renderCurrentScreen

-- Peripheral wrappers (initialized after validation)
local relayLock, ae2Adapter, depositor, relayNote, monitor, pedestals
local pedestalIndexByName, pedestalObjectToIndex

-- Initialize peripherals
local function initPeripherals()
    writeLog("Initializing peripherals")
    relayLock = peripheral.wrap(RELAY_LOCK)
    writeLog("RELAY_LOCK wrapped: " .. tostring(relayLock))
    ae2Adapter = peripheral.wrap(AE2_ADAPTER)
    if not ae2Adapter then
        writeLog("AE2_ADAPTER wrap failed, trying peripheral.find(\"ae2cc_adapter\")")
        ae2Adapter = peripheral.find("ae2cc_adapter")
    end
    writeLog("AE2_ADAPTER wrapped: " .. tostring(ae2Adapter) .. " (name: " .. AE2_ADAPTER .. ")")
    depositor = peripheral.wrap(DEPOSITOR)
    writeLog("DEPOSITOR wrapped: " .. tostring(depositor))
    relayNote = peripheral.wrap(RELAY_NOTE)
    writeLog("RELAY_NOTE wrapped: " .. tostring(relayNote))
    monitor = peripheral.wrap(MONITOR)
    writeLog("MONITOR wrapped: " .. tostring(monitor))
    pedestals = {}
    for i, name in ipairs(PEDESTALS) do
        pedestals[i] = peripheral.wrap(name)
        if pedestals[i] then
            writeLog("Pedestal " .. i .. ": " .. name .. " wrapped successfully")
        else
            writeLog("Pedestal " .. i .. ": " .. name .. " failed to wrap")
        end
    end
    -- Create name->index mapping
    pedestalIndexByName = {}
    for i, name in ipairs(PEDESTALS) do
        pedestalIndexByName[name] = i
        writeLog("Pedestal mapping: " .. name .. " -> " .. i)
    end
    -- Create object->index mapping
    pedestalObjectToIndex = {}
    for i, ped in ipairs(pedestals) do
        if ped then
            pedestalObjectToIndex[ped] = i
            writeLog("Pedestal object mapping: " .. tostring(ped) .. " -> " .. i)
        end
    end
    -- Ensure monitor is cleared and set text scale
    pcall(monitor.setTextScale, 0.5)
    pcall(monitor.clear)
    -- Lock depositor on startup
    pcall(relayLock.setOutput, "bottom", true)
end

-- Helper: get AE2 stock for an item name
local function getAE2Stock(itemName)
    if not ae2Adapter then
        writeLog("AE2 adapter not initialized, returning stock 0")
        return 0
    end
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if not ok then
        writeLog("AE2 adapter error: " .. tostring(objects))
        return 0
    end
    writeLog("getAE2Stock: itemName=" .. tostring(itemName) .. ", total objects=" .. #objects)
    for i, obj in ipairs(objects) do
        writeLog("  obj[" .. i .. "]: id=" .. tostring(obj.id) .. ", name=" .. tostring(obj.name) .. ", amount=" .. tostring(obj.amount) .. ", displayName=" .. tostring(obj.displayName))
        if obj.id == itemName then
            writeLog("  -> MATCH, returning amount " .. tostring(obj.amount or 0))
            return obj.amount or 0
        end
    end
    writeLog("  No match found")
    return 0
end

-- Helper: play noteblock sound
local function playNoteblockSound()
    writeLog("Playing noteblock sound")
    pcall(relayNote.setOutput, "front", true)
    os.sleep(0.1)
    pcall(relayNote.setOutput, "front", false)
end

-- Helper: set pedestal label with selection brackets
local function setPedestalSelection(pedestalIdx, selected)
    writeLog("setPedestalSelection: idx=" .. pedestalIdx .. ", selected=" .. tostring(selected))
    local opt = state.currentOptions[pedestalIdx]
    if not opt or not pedestals[pedestalIdx] then
        writeLog("  No option or pedestal for index " .. pedestalIdx)
        return
    end

    local label = opt.count and tostring(opt.count) or opt.label
    if selected then
        label = "[ " .. label .. " ]"
    end

    writeLog("  Setting pedestal " .. pedestalIdx .. " label: " .. label)
    local ok, err = pcall(pedestals[pedestalIdx].setItem, opt.item, label)
    if not ok then
        writeLog("  setItem with label failed: " .. tostring(err))
    end
end

-- Helper: clear pedestals (remove items and labels)
local function clearPedestals()
    writeLog("clearPedestals called")
    -- Clear state tracking
    state.currentOptions = {}
    state.currentPedestalIndices = {}
    state.lastSelectedPedestal = nil
    for i = 1, #PEDESTALS do
        if pedestals[i] then
            writeLog("Clearing pedestal " .. i)
            pcall(pedestals[i].setItem, nil)
            local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
            local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
            if not ok1 then writeLog("  setItemRendered failed: " .. tostring(err1)) end
            if not ok2 then writeLog("  setLabelRendered failed: " .. tostring(err2)) end
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
    writeLog("centerPedestalIndices: numOptions=" .. numOptions .. " total=" .. total .. " start=" .. start .. " indices: " .. table.concat(indices, ","))
    return indices
end

-- Helper: update pedestals with items and labels
local function setPedestalOptions(options)
    -- options: array of {item=, label=, count=}
    writeLog("setPedestalOptions called with " .. #options .. " options")
    for i, opt in ipairs(options) do
        writeLog("  option " .. i .. ": item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
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
            writeLog("State tracking: pedestal " .. idx .. " -> count=" .. tostring(options[i].count))
        end
    end
    writeLog("Current pedestal indices: " .. table.concat(indices, ","))
    -- Update used pedestals
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt and pedestals[idx] then
            writeLog("Setting pedestal " .. idx .. " with item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
            -- Set item with optional label (count takes precedence over label)
            local label = opt.count and tostring(opt.count) or opt.label
            if opt.item then
                if label then
                    writeLog("  setItem: " .. opt.item .. " label: " .. label)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
                    if not ok then writeLog("    setItem with label failed: " .. tostring(err)) end
                else
                    writeLog("  setItem: " .. opt.item)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item)
                    if not ok then writeLog("    setItem failed: " .. tostring(err)) end
                end
                local ok2, err2 = pcall(pedestals[idx].setItemRendered, true)
                if not ok2 then writeLog("    setItemRendered failed: " .. tostring(err2)) end
                -- Keep label rendering separate (optional)
                if label then
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, true)
                    if not ok3 then writeLog("    setLabelRendered failed: " .. tostring(err3)) end
                else
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, false)
                    if not ok3 then writeLog("    setLabelRendered(false) failed: " .. tostring(err3)) end
                end
            else
                writeLog("  setItem: nil")
                pcall(pedestals[idx].setItem, nil)
                local ok, err = pcall(pedestals[idx].setItemRendered, false)
                if not ok then writeLog("    setItemRendered(false) failed: " .. tostring(err)) end
                local ok2, err2 = pcall(pedestals[idx].setLabelRendered, false)
                if not ok2 then writeLog("    setLabelRendered(false) failed: " .. tostring(err2)) end
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
            writeLog("Clearing unused pedestal " .. i)
            pcall(pedestals[i].setItem, nil)
            local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
            local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
            if not ok1 then writeLog("  setItemRendered(false) failed: " .. tostring(err1)) end
            if not ok2 then writeLog("  setLabelRendered(false) failed: " .. tostring(err2)) end
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
            renderCurrentScreen()
        end)
    if cancelButton and cancelButton.setVisible then
        cancelButton:setVisible(false)
    else
        writeLog("ERROR: cancelButton invalid " .. tostring(cancelButton))
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
                basePriceStr = string.format(MSG.screen3_base_price, state.selectedMaterial.basePrice, state.selectedMaterial.minQty) .. " | "
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
    writeLog("Rendering screen 1 (categories)")
    clearPedestals()
    local options = {}
    for _, cat in ipairs(CATEGORIES) do
        table.insert(options, { item = cat.item, label = cat.label })
    end
    setPedestalOptions(options)
    updateUI()
end

-- Screen 2: Material selection (filtered by category and stock)
local function renderScreen2()
    writeLog("Rendering screen 2 (materials) for category: " .. tostring(state.selectedCategory))
    clearPedestals()
    local options = {}
    writeLog("MATERIALS total: " .. #MATERIALS)
    for idx, mat in ipairs(MATERIALS) do
        if mat.category == state.selectedCategory then
            writeLog("Material " .. idx .. ": item=" .. mat.item .. ", label=" .. mat.label .. ", category=" .. mat.category .. ", minQty=" .. mat.minQty)
            local stock = getAE2Stock(mat.item)
            writeLog("  stock=" .. stock)
            if stock >= mat.minQty then
                writeLog("  -> qualifies")
                table.insert(options, { item = mat.item, label = mat.label })
            else
                writeLog("  -> insufficient stock")
            end
        else
            writeLog("Material " .. idx .. ": item=" .. mat.item .. " category mismatch (" .. mat.category .. " vs " .. state.selectedCategory .. ")")
        end
    end
    writeLog("Available materials: " .. #options)
    if #options == 0 then
        -- No materials available, go back to screen 1
        writeLog("No materials available, returning to screen 1")
        state.screen = 1
        renderCurrentScreen()
        return
    end
    setPedestalOptions(options)
    updateUI()
end

-- Screen 3: Quantity selection (selecting sub-state)
local function renderScreen3Selecting()
    writeLog("Rendering screen 3 (selecting) for material: " .. tostring(state.selectedMaterial.item))
    clearPedestals()
    local stock = getAE2Stock(state.selectedMaterial.item)
    writeLog("Stock: " .. stock .. " minQty: " .. state.selectedMaterial.minQty)
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
    writeLog("Available quantities: " .. #quantities)
    state.availableQuantities = quantities
    if #quantities == 0 then
        -- No quantities available (stock less than minQty) – should not happen
        writeLog("No quantities available, returning to screen 2")
        state.screen = 2
        renderCurrentScreen()
        return
    end
    local options = {}
    for _, qtyNum in ipairs(quantities) do
        table.insert(options, { item = state.selectedMaterial.item, label = tostring(qtyNum), count = qtyNum })
    end
    setPedestalOptions(options)
    updateUI()
end

-- Screen 3: Payment (confirming sub-state)
local function renderScreen3Confirming()
    writeLog("Rendering screen 3 (confirming) for material: " .. tostring(state.selectedMaterial.item) .. " qty: " .. tostring(state.selectedQty))

    -- Ensure we have available quantities (should be set from screen 3)
    if not state.availableQuantities then
        writeLog("ERROR: availableQuantities not set, recomputing")
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
            writeLog("Setting pedestal " .. idx .. " label: " .. label)
            pcall(pedestals[idx].setItem, opt.item, label)
            pcall(pedestals[idx].setItemRendered, true)
            pcall(pedestals[idx].setLabelRendered, true)
        end
    end

    -- Lock depositor first (in case we're changing quantity)
    pcall(relayLock.setOutput, "bottom", true)

    -- Calculate price
    local price = math.floor(state.selectedMaterial.basePrice * (state.selectedQty / state.selectedMaterial.minQty))
    state.calculatedPrice = price
    writeLog("Price calculated: " .. price .. " spurs for quantity " .. state.selectedQty)

    -- Set depositor price
    local ok, err = pcall(depositor.setPrice, price)
    if not ok then
        hintLabel:setText(MSG.error_deposit)
        os.sleep(2)
        state.screen = 1
        renderCurrentScreen()
        return
    end

    -- Unlock depositor and establish baseline for payment detection
    pcall(relayLock.setOutput, "bottom", false)
    os.sleep(0.3)
    local baseline = false
    local ok, result = pcall(relayLock.getInput, "bottom")
    if ok then baseline = result end
    state.paymentBaseline = baseline
    state.paymentDeadline = os.clock() + IDLE_TIMEOUT
    state.paymentPaid = false
    state.cancelRequested = false

    writeLog("Depositor unlocked, baseline: " .. tostring(baseline) .. ", deadline: " .. state.paymentDeadline)

    -- Update UI (hint will be set by updateUI)
    updateUI()
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
        price = math.floor(state.selectedMaterial.basePrice * (state.selectedQty / state.selectedMaterial.minQty))
    }
    pcall(db.log, record)
    -- Mock dispense
    writeLog("[MOCK] Dispense " .. state.selectedQty .. "x " .. state.selectedMaterial.item)
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

-- Event loop for pedestal clicks
local function eventLoop()
    while true do
        -- Check idle timeout (screens 2 and 3)
        if (state.screen == 2) or (state.screen == 3 and state.subState) then
            if os.clock() - state.lastActivity > IDLE_TIMEOUT then
                -- Timeout: lock depositor if in confirming state, reset to screen 1
                if state.screen == 3 and state.subState == "confirming" then
                    pcall(relayLock.setOutput, "bottom", true)
                end
                state.screen = 1
                -- Reset all state
                state.selectedCategory = nil
                state.selectedMaterial = nil
                state.selectedQty = nil
                state.subState = nil
                state.paymentPaid = false
                renderCurrentScreen()
                hintLabel:setText(MSG.timeout_msg)
                os.sleep(2)
            end
        end

        local eventData = { os.pullEvent(0.05) }
        local event = eventData[1]

        -- Payment detection (screen 3 confirming sub-state)
        if state.screen == 3 and state.subState == "confirming" and not state.paymentPaid and not state.cancelRequested then
            if os.clock() >= state.paymentDeadline then
                writeLog("Payment timeout")
                pcall(relayLock.setOutput, "bottom", true)  -- lock depositor
                state.screen = 1
                -- Reset state
                state.selectedCategory = nil
                state.selectedMaterial = nil
                state.selectedQty = nil
                state.subState = nil
                state.paymentPaid = false
                renderCurrentScreen()
            else
                local ok, current = pcall(relayLock.getInput, "bottom")
                if ok and current ~= state.paymentBaseline then
                    writeLog("Payment detected")
                    pcall(relayLock.setOutput, "bottom", true)  -- lock depositor
                    state.paymentPaid = true
                    state.screen = 4  -- Move to thank you screen
                    renderCurrentScreen()
                end
            end
        end

        -- Pedestal click events from display_pedestal peripheral
        if event ~= nil and (event == "pedestal_left_click" or event == "pedestal_right_click") then
            writeLog("Pedestal event: " .. event .. " on " .. tostring(eventData[2]))
            if type(eventData[3]) == "table" then
                local info = "name=" .. tostring(eventData[3].name) .. " count=" .. tostring(eventData[3].count) .. " displayName=" .. tostring(eventData[3].displayName)
                writeLog("Event data[3]: " .. info)
            else
                writeLog("Event data[3]: " .. type(eventData[3]))
            end
            local side = (event == "pedestal_right_click") and "right" or "left"
            writeLog("side: " .. side .. ", screen: " .. state.screen)
            -- Play sound on any pedestal click
            playNoteblockSound()
            -- Determine action based on screen and mouse button
            local itemId = type(eventData[3]) == "table" and eventData[3].name
            local itemCount = type(eventData[3]) == "table" and eventData[3].count
            local displayName = type(eventData[3]) == "table" and eventData[3].displayName
            -- Get pedestal index and option
            writeLog("eventData[2] type: " .. type(eventData[2]) .. " value: " .. tostring(eventData[2]))
            local pedestalIndex = nil
            if type(eventData[2]) == "table" then
                -- eventData[2] is the pedestal object
                pedestalIndex = pedestalObjectToIndex[eventData[2]]
                if pedestalIndex then
                    writeLog("Found pedestal index via object mapping: " .. pedestalIndex)
                else
                    -- Fallback: get name from object
                    local pedestalName
                    local ok, name = pcall(peripheral.getName, eventData[2])
                    if ok then pedestalName = name end
                    writeLog("Object mapping failed, trying peripheral.getName: " .. tostring(pedestalName))
                    if pedestalName then
                        pedestalIndex = pedestalIndexByName[pedestalName]
                        writeLog("Name mapping result: " .. tostring(pedestalIndex))
                    end
                end
            else
                -- eventData[2] is already a name string
                local pedestalName = eventData[2]
                writeLog("Pedestal name as string: " .. tostring(pedestalName))
                pedestalIndex = pedestalIndexByName[pedestalName]
                writeLog("Name mapping result: " .. tostring(pedestalIndex))
            end
            writeLog("pedestalIndex lookup result: " .. tostring(pedestalIndex))
            local pedestalOption = pedestalIndex and state.currentOptions[pedestalIndex]
            writeLog("Pedestal index: " .. tostring(pedestalIndex) .. ", option: " .. (pedestalOption and "yes" or "no"))
            if pedestalOption then
                writeLog("Pedestal option details: item=" .. tostring(pedestalOption.item) .. " label=" .. tostring(pedestalOption.label) .. " count=" .. tostring(pedestalOption.count))
            else
                writeLog("Current options state:")
                for idx, opt in pairs(state.currentOptions) do
                    writeLog("  idx " .. idx .. ": item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
                end
            end
            local selectedCount = nil
            -- Try to extract count from displayName first (most reliable)
            if displayName then
                writeLog("DEBUG displayName value: " .. tostring(displayName) .. ", type: " .. type(displayName))
                if type(displayName) == "number" then
                    selectedCount = displayName
                    writeLog("Using count from displayName (number): " .. selectedCount)
                else
                    local str = tostring(displayName)
                    writeLog("displayName raw: '" .. str .. "' (type: " .. type(displayName) .. ")")
                    -- Remove brackets and trim whitespace
                    local cleanName = str:gsub("%[", ""):gsub("%]", ""):gsub("^%s*(.-)%s*$", "%1")
                    writeLog("Clean displayName: '" .. cleanName .. "'")
                    local num = tonumber(cleanName)
                    if num then
                        selectedCount = num
                        writeLog("Using count from displayName (parsed): " .. selectedCount)
                    else
                        writeLog("displayName '" .. cleanName .. "' is not a number")
                    end
                end
            end

            -- Fallback to pedestal option count
            if not selectedCount and pedestalOption and pedestalOption.count then
                selectedCount = pedestalOption.count
                writeLog("Using count from pedestal option: " .. selectedCount)
            end

            -- Final fallback to event count
            if not selectedCount then
                selectedCount = itemCount
                writeLog("Using count from event: " .. tostring(itemCount))
            end

            if state.screen == 1 then
                -- Category selection: right-click only
                if side == "right" then
                    local catIdx = nil
                    -- Try to find category by itemId first (most reliable)
                    if itemId then
                        for i, cat in ipairs(CATEGORIES) do
                            if cat.item == itemId then
                                catIdx = i
                                break
                            end
                        end
                        if catIdx then
                            writeLog("Found category by itemId: " .. tostring(itemId) .. " index: " .. catIdx)
                        end
                    end
                    if catIdx then
                        writeLog("Selected category index: " .. catIdx .. " label: " .. CATEGORIES[catIdx].label)
                        state.selectedCategory = CATEGORIES[catIdx].label
                        state.screen = 2
                        renderCurrentScreen()
                    else
                        writeLog("No category found for itemId " .. tostring(itemId))
                    end
                end
            elseif state.screen == 2 then
                -- Material selection: right-click select, left-click back
                if side == "right" then
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
                        for i, mat in ipairs(materialsInCategory) do
                            if mat.item == itemId then
                                matIdx = i
                                break
                            end
                        end
                        if matIdx then
                            writeLog("Found material by itemId: " .. tostring(itemId) .. " index: " .. matIdx)
                        end
                    end
                    if matIdx then
                        writeLog("Selected material index: " .. matIdx .. " label: " .. materialsInCategory[matIdx].label)
                        state.selectedMaterial = materialsInCategory[matIdx]
                        state.screen = 3
                        state.subState = "selecting"
                        renderCurrentScreen()
                    else
                        writeLog("No material found for itemId " .. tostring(itemId))
                    end
                elseif side == "left" then
                    -- Back to screen 1
                    state.screen = 1
                    renderCurrentScreen()
                end
            elseif state.screen == 3 then
                -- Screen 3: Quantity selection/payment
                if state.subState == "selecting" then
                    -- Quantity selecting sub-state
                    if side == "right" then
                        -- Single RMB click selects quantity and moves to confirming
                        if selectedCount then
                            state.selectedQty = selectedCount
                            state.subState = "confirming"
                            renderCurrentScreen()
                        end
                    elseif side == "left" then
                        -- LMB goes back to material selection
                        state.screen = 2
                        state.subState = nil
                        renderCurrentScreen()
                    end
                elseif state.subState == "confirming" then
                    -- Payment awaiting sub-state
                    if side == "right" then
                        -- RMB changes quantity (back to selecting)
                        if selectedCount and selectedCount ~= state.selectedQty then
                            state.selectedQty = selectedCount
                            renderCurrentScreen()
                        end
                    elseif side == "left" then
                        -- LMB goes back to quantity selection, lock depositor
                        pcall(relayLock.setOutput, "bottom", true)
                        state.subState = "selecting"
                        renderCurrentScreen()
                    end
                end
            elseif state.screen == 4 then
                -- Thank you screen: ignore pedestal clicks (auto-returns to screen 1)
                writeLog("Click on thank you screen ignored")
            end
        end

        os.sleep(0.05)
    end
end

-- Main
writeLog("Starting shop system...")
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
    writeLog("Fatal error: " .. tostring(err))
    -- Attempt to lock depositor on crash
    pcall(relayLock.setOutput, "bottom", true)
    error(err)
end