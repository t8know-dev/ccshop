-- shop.lua — ComputerCraft shop, requires Basalt UI
-- Main script for multi-screen shop with AE2 adapter, Numismatics depositor, redstone relays.

local basalt = require("basalt")

-- Load configuration and items (they define globals)
dofile("ccshop/config.lua")
dofile("ccshop/items.lua")
local db = dofile("ccshop/db.lua")

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
    screen = 1,               -- 1=category, 2=materials, 3=quantity, 4=payment, 5=thankyou
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    lastActivity = os.clock(),
}
local paymentCancelled = false

-- Peripheral wrappers (initialized after validation)
local relayLock, ae2Adapter, depositor, relayNote, monitor, pedestals

-- Initialize peripherals
local function initPeripherals()
    relayLock = peripheral.wrap(RELAY_LOCK)
    ae2Adapter = peripheral.wrap(AE2_ADAPTER)
    depositor = peripheral.wrap(DEPOSITOR)
    relayNote = peripheral.wrap(RELAY_NOTE)
    monitor = peripheral.wrap(MONITOR)
    pedestals = {}
    for i, name in ipairs(PEDESTALS) do
        pedestals[i] = peripheral.wrap(name)
    end
    -- Ensure monitor is cleared and set text scale
    monitor.setTextScale(0.5)
    monitor.clear()
    -- Lock depositor on startup
    pcall(relayLock.setOutput, "bottom", true)
end

-- Helper: get AE2 stock for an item name
local function getAE2Stock(itemName)
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if not ok then
        print("AE2 adapter error: " .. tostring(objects))
        return 0
    end
    for _, obj in ipairs(objects) do
        if obj.name == itemName then
            return obj.amount or 0
        end
    end
    return 0
end

-- Helper: clear pedestals (remove items and labels)
local function clearPedestals()
    for _, ped in ipairs(pedestals) do
        pcall(ped.setItem, nil)
        pcall(ped.setLabel, nil)
    end
end

-- Helper: center options across available pedestals
-- Given number of options (<= #pedestals), returns table of pedestal indices to use
local function centerPedestalIndices(numOptions)
    local total = #pedestals
    if numOptions > total then numOptions = total end
    local start = math.floor((total - numOptions) / 2) + 1
    local indices = {}
    for i = start, start + numOptions - 1 do
        table.insert(indices, i)
    end
    return indices
end

-- Helper: update pedestals with items and labels
local function setPedestalOptions(options)
    -- options: array of {item=, label=, count=}
    local indices = centerPedestalIndices(#options)
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt then
            pcall(pedestals[idx].setItem, opt.item, opt.label)
            if opt.count then
                pcall(pedestals[idx].setLabel, tostring(opt.count))
            end
        end
    end
    -- Clear unused pedestals
    for i = 1, #pedestals do
        local used = false
        for _, idx in ipairs(indices) do
            if i == idx then used = true break end
        end
        if not used then
            pcall(pedestals[i].setItem, nil)
            pcall(pedestals[i].setLabel, nil)
        end
    end
end

-- Basalt UI elements
local frame, headerLabel, hintLabel, cancelButton

-- Create UI frame
local function createUI()
    frame = basalt.createFrame():setTerm(monitor)
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
        :onClick(function()
            if state.screen == 4 then
                pcall(relayLock.setOutput, "bottom", true)  -- lock depositor
                paymentCancelled = true
            end
            state.screen = 1
            state.selectedCategory = nil
            state.selectedMaterial = nil
            state.selectedQty = nil
            renderCurrentScreen()
        end)
    cancelButton:hide()
end

-- Update UI hints and cancel button visibility
local function updateUI()
    if state.screen == 1 then
        hintLabel:setText(MSG.screen1_hint)
        cancelButton:hide()
    elseif state.screen == 2 then
        hintLabel:setText(MSG.screen2_hint)
        cancelButton:show()
    elseif state.screen == 3 then
        hintLabel:setText(MSG.screen3_hint)
        cancelButton:show()
    elseif state.screen == 4 then
        hintLabel:setText(string.format(MSG.screen4_insert, state.selectedQty) .. " " .. MSG.screen4_cancel)
        cancelButton:show()
    elseif state.screen == 5 then
        hintLabel:setText(MSG.screen5_thanks)
        cancelButton:hide()
    end
end

-- Screen 1: Category selection
local function renderScreen1()
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
    clearPedestals()
    local options = {}
    for _, mat in ipairs(MATERIALS) do
        if mat.category == state.selectedCategory then
            local stock = getAE2Stock(mat.item)
            if stock >= mat.minQty then
                table.insert(options, { item = mat.item, label = mat.label })
            end
        end
    end
    if #options == 0 then
        -- No materials available, go back to screen 1
        state.screen = 1
        renderCurrentScreen()
        return
    end
    setPedestalOptions(options)
    updateUI()
end

-- Screen 3: Quantity selection
local function renderScreen3()
    clearPedestals()
    local stock = getAE2Stock(state.selectedMaterial.item)
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
    if #quantities == 0 then
        -- No quantities available (stock less than minQty) – should not happen
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

-- Screen 4: Payment
local function renderScreen4()
    clearPedestals()
    updateUI()
    -- The pedestals remain empty
    -- Unlock depositor and set price
    local price = math.floor(state.selectedMaterial.basePrice * (state.selectedQty / state.selectedMaterial.minQty))
    local ok, err = pcall(depositor.setPrice, price)
    if not ok then
        hintLabel:setText(MSG.error_deposit)
        os.sleep(2)
        state.screen = 1
        renderCurrentScreen()
        return
    end
    -- Unlock relay (bottom output LOW)
    pcall(relayLock.setOutput, "bottom", false)
    os.sleep(0.3)
    local baseline = relayLock.getInput("bottom")
    local paid = false
    local deadline = os.clock() + 300  -- 5 minute payment timeout
    paymentCancelled = false
    while os.clock() < deadline and not paid and not paymentCancelled do
        -- Check for cancel request (handled by cancel button)
        -- Check for payment detection
        if relayLock.getInput("bottom") ~= baseline then
            paid = true
            break
        end
        os.sleep(0.05)
    end
    -- Lock depositor regardless
    pcall(relayLock.setOutput, "bottom", true)
    if paid then
        state.screen = 5
        renderCurrentScreen()
    else
        -- Payment cancelled or timed out
        state.screen = 1
        renderCurrentScreen()
    end
end

-- Screen 5: Thank you
local function renderScreen5()
    clearPedestals()
    updateUI()
    -- Play noteblock sound
    pcall(relayNote.setOutput, "front", true)
    os.sleep(0.1)
    pcall(relayNote.setOutput, "front", false)
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
    print("[MOCK] Dispense " .. state.selectedQty .. "x " .. state.selectedMaterial.item)
    -- Auto-return to screen 1 after CONFIRM_DELAY seconds
    os.sleep(CONFIRM_DELAY)
    state.screen = 1
    state.selectedCategory = nil
    state.selectedMaterial = nil
    state.selectedQty = nil
    renderCurrentScreen()
end

-- Update screen based on state
local function renderCurrentScreen()
    state.lastActivity = os.clock()
    if state.screen == 1 then renderScreen1()
    elseif state.screen == 2 then renderScreen2()
    elseif state.screen == 3 then renderScreen3()
    elseif state.screen == 4 then renderScreen4()
    elseif state.screen == 5 then renderScreen5()
    end
end

-- Event loop for pedestal clicks
local function eventLoop()
    while true do
        -- Check idle timeout (screens 2-4)
        if state.screen >= 2 and state.screen <= 4 then
            if os.clock() - state.lastActivity > IDLE_TIMEOUT then
                -- Timeout: lock depositor, reset to screen 1
                pcall(relayLock.setOutput, "bottom", true)
                state.screen = 1
                state.selectedCategory = nil
                state.selectedMaterial = nil
                state.selectedQty = nil
                renderCurrentScreen()
                hintLabel:setText(MSG.timeout_msg)
                os.sleep(2)
            end
        end

        local eventData = { os.pullEvent() }
        local event = eventData[1]
        -- Pedestal click events from display_pedestal peripheral
        if event == "pedestal_left_click" or event == "pedestal_right_click" then
            local pedName = eventData[2]  -- peripheral name
            local side = (event == "pedestal_right_click") and "right" or "left"
            -- Find pedestal index
            local pedIdx = nil
            for i, name in ipairs(PEDESTALS) do
                if name == pedName then pedIdx = i; break end
            end
            if not pedIdx then break end  -- unknown pedestal
            -- Determine action based on screen and mouse button
            if state.screen == 1 then
                -- Category selection: right-click only
                if side == "right" then
                    local catIdx = nil
                    local indices = centerPedestalIndices(#CATEGORIES)
                    for i, idx in ipairs(indices) do
                        if idx == pedIdx then catIdx = i; break end
                    end
                    if catIdx then
                        state.selectedCategory = CATEGORIES[catIdx].label
                        state.screen = 2
                        renderCurrentScreen()
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
                    local indices = centerPedestalIndices(#materialsInCategory)
                    local matIdx = nil
                    for i, idx in ipairs(indices) do
                        if idx == pedIdx then matIdx = i; break end
                    end
                    if matIdx then
                        state.selectedMaterial = materialsInCategory[matIdx]
                        state.screen = 3
                        renderCurrentScreen()
                    end
                elseif side == "left" then
                    -- Back to screen 1
                    state.screen = 1
                    renderCurrentScreen()
                end
            elseif state.screen == 3 then
                -- Quantity selection: right-click choose, left-click back
                if side == "right" then
                    -- Determine which quantity option
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
                    local indices = centerPedestalIndices(#quantities)
                    local qtyIdx = nil
                    for i, idx in ipairs(indices) do
                        if idx == pedIdx then qtyIdx = i; break end
                    end
                    if qtyIdx then
                        state.selectedQty = quantities[qtyIdx]
                        state.screen = 4
                        renderCurrentScreen()
                    end
                elseif side == "left" then
                    state.screen = 2
                    renderCurrentScreen()
                end
            end
        end

        os.sleep(0.05)
    end
end

-- Main
print("Starting shop system...")
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
    print("Fatal error: " .. tostring(err))
    -- Attempt to lock depositor on crash
    pcall(relayLock.setOutput, "bottom", true)
    error(err)
end