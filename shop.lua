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
    local prev = term.redirect(term.native())
    print(line)
    term.redirect(prev)
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
    screen = 1,               -- 1=category, 2=materials, 3=quantity, 4=payment, 5=thankyou
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    lastActivity = os.clock(),
}
local paymentCancelled = false

-- Forward declaration for renderCurrentScreen (defined later)
local renderCurrentScreen

-- Peripheral wrappers (initialized after validation)
local relayLock, ae2Adapter, depositor, relayNote, monitor, pedestals

-- Initialize peripherals
local function initPeripherals()
    writeLog("Initializing peripherals")
    relayLock = peripheral.wrap(RELAY_LOCK)
    ae2Adapter = peripheral.wrap(AE2_ADAPTER)
    depositor = peripheral.wrap(DEPOSITOR)
    relayNote = peripheral.wrap(RELAY_NOTE)
    monitor = peripheral.wrap(MONITOR)
    pedestals = {}
    for i, name in ipairs(PEDESTALS) do
        pedestals[i] = peripheral.wrap(name)
        if pedestals[i] then
            writeLog("Pedestal " .. i .. ": " .. name .. " wrapped successfully")
        else
            writeLog("Pedestal " .. i .. ": " .. name .. " failed to wrap")
        end
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
        writeLog("AE2 adapter error: " .. tostring(objects))
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
    for i = 1, #PEDESTALS do
        if pedestals[i] then
            pcall(pedestals[i].setItem, nil)
            pcall(pedestals[i].setLabel, nil)
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
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt and pedestals[idx] then
            pcall(pedestals[idx].setItem, opt.item, opt.label)
            if opt.count then
                pcall(pedestals[idx].setLabel, tostring(opt.count))
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
            pcall(pedestals[i].setItem, nil)
            pcall(pedestals[i].setLabel, nil)
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
        hintLabel:setText(MSG.screen3_hint)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
    elseif state.screen == 4 then
        hintLabel:setText(string.format(MSG.screen4_insert, state.selectedQty) .. " " .. MSG.screen4_cancel)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
    elseif state.screen == 5 then
        hintLabel:setText(MSG.screen5_thanks)
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
    for _, mat in ipairs(MATERIALS) do
        if mat.category == state.selectedCategory then
            local stock = getAE2Stock(mat.item)
            if stock >= mat.minQty then
                table.insert(options, { item = mat.item, label = mat.label })
            end
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

-- Screen 3: Quantity selection
local function renderScreen3()
    writeLog("Rendering screen 3 (quantities) for material: " .. tostring(state.selectedMaterial.item))
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
    writeLog("[MOCK] Dispense " .. state.selectedQty .. "x " .. state.selectedMaterial.item)
    -- Auto-return to screen 1 after CONFIRM_DELAY seconds
    os.sleep(CONFIRM_DELAY)
    state.screen = 1
    state.selectedCategory = nil
    state.selectedMaterial = nil
    state.selectedQty = nil
    renderCurrentScreen()
end

-- Update screen based on state
renderCurrentScreen = function()
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
            writeLog("Pedestal event: " .. event .. " on " .. tostring(eventData[2]))
            if type(eventData[3]) == "table" then
                local info = "name=" .. tostring(eventData[3].name) .. " count=" .. tostring(eventData[3].count) .. " displayName=" .. tostring(eventData[3].displayName)
                writeLog("Event data[3]: " .. info)
            else
                writeLog("Event data[3]: " .. type(eventData[3]))
            end
            local rawPedName = eventData[2]  -- peripheral name (could be string or table)
            local pedName
            writeLog("rawPedName type: " .. type(rawPedName))
            if type(rawPedName) == "string" then
                pedName = rawPedName
            else
                -- Treat as object (table/userdata) and try to get its name
                -- 1. .getName method
                if rawPedName.getName and type(rawPedName.getName) == "function" then
                    local success, result = pcall(rawPedName.getName)
                    if success and type(result) == "string" then
                        pedName = result
                        writeLog("Got pedestal name via .getName(): " .. pedName)
                    end
                end
                -- 2. peripheral.getName
                if not pedName then
                    local success, result = pcall(peripheral.getName, rawPedName)
                    if success and type(result) == "string" then
                        pedName = result
                        writeLog("Got pedestal name via peripheral.getName: " .. pedName)
                    end
                end
                -- 3. .name field
                if not pedName and rawPedName.name and type(rawPedName.name) == "string" then
                    pedName = rawPedName.name
                end
                -- 4. tostring
                if not pedName then
                    pedName = tostring(rawPedName)
                end
            end
            writeLog("pedName determined: " .. pedName)
            local side = (event == "pedestal_right_click") and "right" or "left"
            writeLog("side determined as: " .. side)
            -- Find pedestal index
            local pedIdx = nil
            for i, name in ipairs(PEDESTALS) do
                if name == pedName then pedIdx = i; break end
            end
            if not pedIdx then
                writeLog("Unknown pedestal: " .. pedName .. ", will try to handle by item data")
            else
                writeLog("pedestal index: " .. pedIdx)
            end
            writeLog("side: " .. side .. ", screen: " .. state.screen)
            -- Determine action based on screen and mouse button
            local itemId = type(eventData[3]) == "table" and eventData[3].name
            local itemCount = type(eventData[3]) == "table" and eventData[3].count

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
                    -- Fallback to pedestal index mapping (only if pedIdx known)
                    if not catIdx and pedIdx then
                        local indices = centerPedestalIndices(#CATEGORIES)
                        for i, idx in ipairs(indices) do
                            if idx == pedIdx then catIdx = i; break end
                        end
                    end
                    if catIdx then
                        writeLog("Selected category index: " .. catIdx .. " label: " .. CATEGORIES[catIdx].label)
                        state.selectedCategory = CATEGORIES[catIdx].label
                        state.screen = 2
                        renderCurrentScreen()
                    else
                        writeLog("No category mapped for pedestal index " .. tostring(pedIdx) .. " itemId " .. tostring(itemId))
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
                    -- Fallback to pedestal index mapping (only if pedIdx known)
                    if not matIdx and pedIdx then
                        local indices = centerPedestalIndices(#materialsInCategory)
                        for i, idx in ipairs(indices) do
                            if idx == pedIdx then matIdx = i; break end
                        end
                    end
                    if matIdx then
                        writeLog("Selected material index: " .. matIdx .. " label: " .. materialsInCategory[matIdx].label)
                        state.selectedMaterial = materialsInCategory[matIdx]
                        state.screen = 3
                        renderCurrentScreen()
                    else
                        writeLog("No material mapped for pedestal index " .. tostring(pedIdx) .. " itemId " .. tostring(itemId))
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
                    local qtyIdx = nil
                    -- Try to find quantity by item count from event
                    if itemCount then
                        for i, qty in ipairs(quantities) do
                            if qty == itemCount then
                                qtyIdx = i
                                break
                            end
                        end
                        if qtyIdx then
                            writeLog("Found quantity by count: " .. tostring(itemCount) .. " index: " .. qtyIdx)
                        end
                    end
                    -- Fallback to pedestal index mapping (only if pedIdx known)
                    if not qtyIdx and pedIdx then
                        local indices = centerPedestalIndices(#quantities)
                        for i, idx in ipairs(indices) do
                            if idx == pedIdx then qtyIdx = i; break end
                        end
                    end
                    if qtyIdx then
                        writeLog("Selected quantity index: " .. qtyIdx .. " value: " .. quantities[qtyIdx])
                        state.selectedQty = quantities[qtyIdx]
                        state.screen = 4
                        renderCurrentScreen()
                    else
                        writeLog("No quantity mapped for pedestal index " .. tostring(pedIdx) .. " itemCount " .. tostring(itemCount))
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