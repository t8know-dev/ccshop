-- modules/events.lua — Event handling and state transitions
-- Exports: init(), handlePedestalClick(event, eventData), eventLoop(),
--          getPedestalIndex(eventData), getSelectedCount(pedestalOption, eventData)

local logging, state, screens, pedestal, peripherals, config

-- Local copies of mapping tables
local pedestalIndexByName, pedestalObjectToIndex

-- Initialize module with dependencies
local function init(loggingModule, stateModule, screensModule, pedestalModule, peripheralsModule, configModule)
    logging = loggingModule
    state = stateModule
    screens = screensModule
    pedestal = pedestalModule
    peripherals = peripheralsModule
    config = configModule
    pedestalIndexByName = peripherals.getPedestalIndexByName()
    pedestalObjectToIndex = peripherals.getPedestalObjectToIndex()
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
            state.updateState({
                selectedCategory = CATEGORIES[catIdx].label,
                screen = 2
            })
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
            if mat.category == state.getState("selectedCategory") then
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
            state.updateState({
                selectedMaterial = materialsInCategory[matIdx],
                screen = 3,
                subState = 'selecting'
            })
        else
        end
    elseif side == 'left' then
        -- Back to screen 1
        state.updateState({
            screen = 1,
            paymentBaseline = nil,
            paymentCheckCount = 0
        })
    end
end

-- Handle screen 3 quantity selection/payment
local function handleScreen3Click(pedestalIndex, pedestalOption, side, selectedCount)
    -- Screen 3: Quantity selection/payment
    local subState = state.getState("subState")
    if subState == 'selecting' then
        -- Quantity selecting sub-state
        if side == 'right' then
            -- Single RMB click selects quantity and moves to confirming
            if selectedCount then
                state.updateState({
                    selectedQty = selectedCount,
                    subState = 'confirming'
                })
            end
        elseif side == 'left' then
            -- LMB goes back to material selection
            state.updateState({
                screen = 2,
                subState = nil,
                paymentBaseline = nil,
                paymentCheckCount = 0
            })
        end
    elseif subState == 'confirming' then
        -- Payment awaiting sub-state
        if side == 'right' then
            -- RMB changes quantity (back to selecting)
            if selectedCount and selectedCount ~= state.getState("selectedQty") then
                state.updateState({ selectedQty = selectedCount })
            end
        elseif side == 'left' then
            -- LMB goes back to quantity selection, lock depositor
            peripherals.lockDepositor()
            state.updateState({
                subState = 'selecting',
                paymentBaseline = nil,
                paymentCheckCount = 0
            })
        end
    end
end

-- Handle pedestal click event
local function handlePedestalClick(event, eventData)
    local side = (event == 'pedestal_right_click') and 'right' or 'left'
    -- Play sound on any pedestal click
    peripherals.playNoteblockSound()
    -- Determine action based on screen and mouse button
    local itemId = type(eventData[3]) == 'table' and eventData[3].name
    local itemCount = type(eventData[3]) == 'table' and eventData[3].count
    local displayName = type(eventData[3]) == 'table' and eventData[3].displayName
    -- Get pedestal index and option
    local pedestalIndex = getPedestalIndex(eventData)
    local pedestalOption = pedestalIndex and state.getState("currentOptions")[pedestalIndex]
    if not pedestalOption then
        -- Fallback: try to find option by itemId
        if itemId then
            for idx, opt in pairs(state.getState("currentOptions")) do
                if opt.item == itemId or (opt.item and itemId:match('^[^:]+') == opt.item:match('^[^:]+')) then
                    pedestalOption = opt
                    pedestalIndex = idx
                    break
                end
            end
        end
    end
    local selectedCount = getSelectedCount(pedestalOption, eventData)
    local screen = state.getState("screen")
    if screen == 1 then
        handleScreen1Click(pedestalIndex, pedestalOption, side, itemId)
    elseif screen == 2 then
        handleScreen2Click(pedestalIndex, pedestalOption, side, itemId)
    elseif screen == 3 then
        handleScreen3Click(pedestalIndex, pedestalOption, side, selectedCount)
    elseif screen == 4 then
        -- Thank you screen: ignore pedestal clicks (auto-returns to screen 1)
    end
end

-- Event loop for pedestal clicks
local function eventLoop()
    logging.writeLog("INFO", "Event loop thread started")
    while true do
        local ok, err = pcall(function()
            local eventData = { os.pullEvent() }
            local event = eventData[1]

            -- Pedestal click events from display_pedestal peripheral
            if event == "pedestal_left_click" or event == "pedestal_right_click" then
                handlePedestalClick(event, eventData)
            end
        end)
        if not ok then
            logging.writeLog("ERROR", "Event loop error: " .. tostring(err))
            os.sleep(1)  -- avoid tight error loop
        end
    end
end

return {
    init = init,
    handlePedestalClick = handlePedestalClick,
    eventLoop = eventLoop,
    getPedestalIndex = getPedestalIndex,
    getSelectedCount = getSelectedCount
}