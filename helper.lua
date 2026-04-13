-- Map pedestal object/name to index
local function getPedestalIndex(eventData)
    writeLog('getPedestalIndex called')
    local pedestalIndex = nil
    if type(eventData[2]) == 'table' then
        -- eventData[2] is the pedestal object
        pedestalIndex = pedestalObjectToIndex[eventData[2]]
        if pedestalIndex then
            writeLog('Found pedestal index via object mapping: ' .. pedestalIndex)
        else
            -- Fallback: get name from object
            local pedestalName
            local ok, name = pcall(peripheral.getName, eventData[2])
            if ok then pedestalName = name end
            writeLog('Object mapping failed, trying peripheral.getName: ' .. tostring(pedestalName))
            if pedestalName then
                pedestalIndex = pedestalIndexByName[pedestalName]
                writeLog('Name mapping result: ' .. tostring(pedestalIndex))
            end
        end
    else
        -- eventData[2] is already a name string
        local pedestalName = eventData[2]
        writeLog('Pedestal name as string: ' .. tostring(pedestalName))
        pedestalIndex = pedestalIndexByName[pedestalName]
        writeLog('Name mapping result: ' .. tostring(pedestalIndex))
    end
    writeLog('pedestalIndex lookup result: ' .. tostring(pedestalIndex))
    if not pedestalIndex then
        writeLog('DEBUG: pedestalIndexByName keys:')
        for name, idx in pairs(pedestalIndexByName) do
            writeLog('  ' .. name .. ' -> ' .. idx)
        end
        writeLog('DEBUG: pedestalObjectToIndex keys:')
        for obj, idx in pairs(pedestalObjectToIndex) do
            writeLog('  ' .. tostring(obj) .. ' -> ' .. idx)
        end
    end
    return pedestalIndex
end

-- Extract selected count from event data and pedestal option
local function getSelectedCount(pedestalOption, eventData)
    local selectedCount = nil
    local displayName = type(eventData[3]) == 'table' and eventData[3].displayName
    -- Try to extract count from displayName first (most reliable)
    if displayName then
        writeLog('DEBUG displayName value: ' .. tostring(displayName) .. ', type: ' .. type(displayName))
        if type(displayName) == 'number' then
            selectedCount = displayName
            writeLog('Using count from displayName (number): ' .. selectedCount)
        else
            local str = tostring(displayName)
            writeLog('displayName raw: "' .. str .. '" (type: ' .. type(displayName) .. ')')
            -- Remove brackets and trim whitespace
            local cleanName = str:gsub('%[', ''):gsub('%]', ''):gsub('^%s*(.-)%s*$', '%1')
            writeLog('Clean displayName: "' .. cleanName .. '"')
            local num = tonumber(cleanName)
            if num then
                selectedCount = num
                writeLog('Using count from displayName (parsed): ' .. selectedCount)
            else
                writeLog('displayName "' .. cleanName .. '" is not a number')
            end
        end
    end
    -- Fallback to pedestal option count
    if not selectedCount and pedestalOption and pedestalOption.count then
        selectedCount = pedestalOption.count
        writeLog('Using count from pedestal option: ' .. selectedCount)
    end
    -- Final fallback to event count
    if not selectedCount then
        selectedCount = type(eventData[3]) == 'table' and eventData[3].count
        writeLog('Using count from event: ' .. tostring(selectedCount))
    end
    return selectedCount
end

-- Handle screen 1 category selection
local function handleScreen1Click(pedestalIndex, pedestalOption, side, itemId)
    writeLog('handleScreen1Click: side=' .. side .. ' itemId=' .. tostring(itemId))
    -- Category selection: right-click only
    if side == 'right' then
        writeLog('Screen 1 right-click, itemId=' .. tostring(itemId))
        writeLog('CATEGORIES count: ' .. #CATEGORIES)
        for i, cat in ipairs(CATEGORIES) do
            writeLog('  ' .. i .. ': item=' .. cat.item .. ' label=' .. cat.label)
        end
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
            if catIdx then
                writeLog('Found category by exact itemId: ' .. tostring(itemId) .. ' index: ' .. catIdx)
            else
                -- Try prefix match (ignore metadata after colon)
                local prefix = itemId:match('^[^:]+')
                writeLog('Trying prefix match, prefix=' .. tostring(prefix))
                if prefix then
                    for i, cat in ipairs(CATEGORIES) do
                        if cat.item == prefix or cat.item:match('^[^:]+') == prefix then
                            catIdx = i
                            writeLog('Matched category by prefix: ' .. cat.item)
                            break
                        end
                    end
                end
            end
        end
        if catIdx then
            writeLog('Selected category index: ' .. catIdx .. ' label: ' .. CATEGORIES[catIdx].label)
            state.selectedCategory = CATEGORIES[catIdx].label
            state.screen = 2
            renderCurrentScreen()
        else
            writeLog('No category found for itemId ' .. tostring(itemId))
        end
    end
end

-- Handle screen 2 material selection
local function handleScreen2Click(pedestalIndex, pedestalOption, side, itemId)
    writeLog('handleScreen2Click: side=' .. side .. ' itemId=' .. tostring(itemId))
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
                writeLog('Found material by exact itemId: ' .. tostring(itemId) .. ' index: ' .. matIdx)
            else
                -- Try prefix match (ignore metadata after colon)
                local prefix = itemId:match('^[^:]+')
                writeLog('Trying prefix match, prefix=' .. tostring(prefix))
                if prefix then
                    for i, mat in ipairs(materialsInCategory) do
                        if mat.item == prefix or mat.item:match('^[^:]+') == prefix then
                            matIdx = i
                            writeLog('Matched material by prefix: ' .. mat.item)
                            break
                        end
                    end
                end
            end
        end
        if matIdx then
            writeLog('Selected material index: ' .. matIdx .. ' label: ' .. materialsInCategory[matIdx].label)
            state.selectedMaterial = materialsInCategory[matIdx]
            state.screen = 3
            state.subState = 'selecting'
            renderCurrentScreen()
        else
            writeLog('No material found for itemId ' .. tostring(itemId))
        end
    elseif side == 'left' then
        -- Back to screen 1
        state.screen = 1
        renderCurrentScreen()
    end
end

-- Handle screen 3 quantity selection/payment
local function handleScreen3Click(pedestalIndex, pedestalOption, side, selectedCount)
    writeLog('handleScreen3Click: side=' .. side .. ' selectedCount=' .. tostring(selectedCount) .. ' subState=' .. tostring(state.subState))
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
            renderCurrentScreen()
        end
    end
end

-- Handle pedestal click event
local function handlePedestalClick(event, eventData)
    writeLog('Pedestal event: ' .. event .. ' on ' .. tostring(eventData[2]))
    writeLog('Event data[2] type: ' .. type(eventData[2]))
    -- Log mapping tables for debugging
    writeLog('pedestalObjectToIndex count: ' .. tostring(pedestalObjectToIndex and #pedestalObjectToIndex or 0))
    writeLog('pedestalIndexByName count: ' .. tostring(pedestalIndexByName and #pedestalIndexByName or 0))
    if type(eventData[3]) == 'table' then
        local info = 'name=' .. tostring(eventData[3].name) .. ' count=' .. tostring(eventData[3].count) .. ' displayName=' .. tostring(eventData[3].displayName)
        writeLog('Event data[3]: ' .. info)
        writeLog('Full eventData[3] table:')
        for k, v in pairs(eventData[3]) do
            writeLog('  ' .. tostring(k) .. ' = ' .. tostring(v))
        end
    else
        writeLog('Event data[3]: ' .. type(eventData[3]))
    end
    local side = (event == 'pedestal_right_click') and 'right' or 'left'
    writeLog('side: ' .. side .. ', screen: ' .. state.screen)
    -- Play sound on any pedestal click
    playNoteblockSound()
    -- Determine action based on screen and mouse button
    local itemId = type(eventData[3]) == 'table' and eventData[3].name
    local itemCount = type(eventData[3]) == 'table' and eventData[3].count
    local displayName = type(eventData[3]) == 'table' and eventData[3].displayName
    -- Get pedestal index and option
    writeLog('eventData[2] type: ' .. type(eventData[2]) .. ' value: ' .. tostring(eventData[2]))
    local pedestalIndex = getPedestalIndex(eventData)
    local pedestalOption = pedestalIndex and state.currentOptions[pedestalIndex]
    writeLog('Pedestal index: ' .. tostring(pedestalIndex) .. ', option: ' .. (pedestalOption and 'yes' or 'no'))
    if pedestalOption then
        writeLog('Pedestal option details: item=' .. tostring(pedestalOption.item) .. ' label=' .. tostring(pedestalOption.label) .. ' count=' .. tostring(pedestalOption.count))
    else
        writeLog('Current options state:')
        for idx, opt in pairs(state.currentOptions) do
            writeLog('  idx ' .. idx .. ': item=' .. tostring(opt.item) .. ' label=' .. tostring(opt.label) .. ' count=' .. tostring(opt.count))
        end
        -- Fallback: try to find option by itemId
        if itemId and not pedestalOption then
            writeLog('Fallback search for itemId: ' .. itemId)
            for idx, opt in pairs(state.currentOptions) do
                if opt.item == itemId or (opt.item and itemId:match('^[^:]+') == opt.item:match('^[^:]+')) then
                    writeLog('Found matching option at index ' .. idx)
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
        writeLog('Click on thank you screen ignored')
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
            renderCurrentScreen()
            hintLabel:setText(MSG.timeout_msg)
            os.sleep(2)
        end
    end
end

-- Check payment detection
local function checkPaymentDetection()
    if state.screen == 3 and state.subState == 'confirming' and not state.paymentPaid and not state.cancelRequested then
        if os.clock() >= state.paymentDeadline then
            writeLog('Payment timeout')
            pcall(relayLock.setOutput, 'bottom', true)  -- lock depositor
            state.screen = 1
            -- Reset state
            state.selectedCategory = nil
            state.selectedMaterial = nil
            state.selectedQty = nil
            state.subState = nil
            state.paymentPaid = false
            renderCurrentScreen()
        else
            local ok, current = pcall(relayLock.getInput, 'bottom')
            if ok and current ~= state.paymentBaseline then
                writeLog('Payment detected')
                pcall(relayLock.setOutput, 'bottom', true)  -- lock depositor
                state.paymentPaid = true
                state.screen = 4  -- Move to thank you screen
                renderCurrentScreen()
            end
        end
    end
end
