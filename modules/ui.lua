-- modules/ui.lua — Basalt UI creation and updates
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state, basalt
local mainFrame, headerLabel, hintLabel, cancelButton, discountLabel
local monitorWidth, monitorHeight

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule, basaltModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    basalt = basaltModule
end

-- Create UI frame
local function createUI()
    logging.writeLog("DEBUG", "UI createUI called")
    local monitor = peripherals.getMonitor()
    if not monitor then
        logging.writeLog("ERROR", "Monitor not available for UI creation")
        return
    end
    logging.writeLog("DEBUG", "Monitor found, using Basalt")
    if not basalt then
        logging.writeLog("ERROR", "Basalt module not initialized")
        return
    end
    -- Create a frame for the monitor (following Basalt documentation)
    logging.writeLog("DEBUG", "Creating monitor frame with basalt.createFrame()")
    mainFrame = basalt.createFrame()
    logging.writeLog("DEBUG", "basalt.createFrame() returned: " .. tostring(mainFrame))
    if not mainFrame then
        logging.writeLog("ERROR", "basalt.createFrame() returned nil")
        return
    end
    -- Set the monitor as terminal for this frame
    mainFrame:setTerm(monitor)
    logging.writeLog("DEBUG", "Monitor term set")
    mainFrame:setBackground(colors.black)
    logging.writeLog("DEBUG", "Main frame background set")
    -- Get monitor dimensions
    local ok, width, height = pcall(monitor.getSize)
    if not ok or not width then
        logging.writeLog("ERROR", "monitor.getSize() failed: " .. tostring(width))
        -- Fallback to default size
        width, height = 80, 24
    end
    local W, H = width, height
    monitorWidth = W
    monitorHeight = H
    -- Header (top bar)
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(W,1)
        :setBackground(colors.red):setForeground(colors.white)
        :setText(MSG.header)
    -- Hint line (below top bar with 1 line gap if enough space)
    local hintY = 3
    if H - 2 <= 3 then hintY = 2 end  -- avoid overlap with cancel button
    hintLabel = mainFrame:addLabel()
        :setPosition(1, hintY):setSize(W,1)
        :setBackground(colors.black):setForeground(colors.lightGray)
    -- Discount info line (below hint line, only shown on screen 1)
    discountLabel = mainFrame:addLabel()
        :setPosition(1, hintY + 1):setSize(W,1)
        :setBackground(colors.black):setForeground(colors.lightGray)
        :setVisible(false)
    -- Cancel button (bottom-left corner)
    local btnWidth = math.min(W, #MSG.cancel_btn)
    cancelButton = mainFrame:addButton()
        :setText(MSG.cancel_btn)
        :setPosition(1, H - 2)  -- H - 3 + 1, H is total, button height 3
        :setSize(btnWidth, 3)
        :setBackground(colors.gray)
        :setForeground(colors.white)
        :onClick(function()
            peripherals.playNoteblockSoundLow()
            -- Lock depositor if on payment screen (screen 3 confirming)
            if state.getState("screen") == 3 and state.getState("subState") == "confirming" then
                peripherals.lockDepositor()
            end
            logging.writeLog("DEBUG", "Cancel button clicked, resetting to main screen")
            -- Reset to main screen
            state.resetToMainScreen()
            -- Trigger screen render via callback? The main loop will call renderCurrentScreen.
            -- For now, we need to call renderCurrentScreen; but we don't have access to screens module.
            -- We'll rely on the main loop to detect state changes and re-render.
            -- This will be handled by the main script.
        end)
    if cancelButton and cancelButton.setVisible then
        cancelButton:setVisible(false)
    else
        logging.writeLog("ERROR", "cancelButton invalid " .. tostring(cancelButton))
    end
end

-- Update UI hints and cancel button visibility
local function updateUI()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    if screen == 1 then
        -- Discount info lines (either table or string)
        local lines = {}
        local discountInfo = MSG.screen1_discount_info
        if type(discountInfo) == "table" then
            for _, line in ipairs(discountInfo) do
                table.insert(lines, line)
            end
        else
            -- Split by commas and trim spaces
            for part in string.gmatch(discountInfo, "([^,]+)") do
                table.insert(lines, (part:gsub("^%s*(.-)%s*$", "%1")))
            end
            -- If no commas, use the whole text as one line
            if #lines == 0 then
                lines = {discountInfo}
            end
        end
        -- Add empty line and pedestal instruction
        table.insert(lines, "")
        table.insert(lines, MSG.screen1_hint)
        -- Combine lines with newline
        local fullText = table.concat(lines, "\n")
        -- Calculate required height
        local numLines = #lines
        local W = monitorWidth or 80
        hintLabel:setSize(W, numLines)
        hintLabel:setText(fullText)
        discountLabel:setVisible(false)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(false) end
    elseif screen == 2 then
        local W = monitorWidth or 80
        hintLabel:setSize(W, 1)
        hintLabel:setText(MSG.screen2_hint)
        discountLabel:setVisible(false)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
    elseif screen == 3 then
        if subState == "selecting" then
            -- Show base price and hint
            local basePriceStr = ""
            local selectedMaterial = state.getState("selectedMaterial")
            if selectedMaterial then
                basePriceStr = string.format(MSG.screen3_base_price, selectedMaterial.basePrice, selectedMaterial.minQty) .. " | "
            end
            local W = monitorWidth or 80
            hintLabel:setSize(W, 1)
            hintLabel:setText(basePriceStr .. MSG.screen3_hint_select)
            discountLabel:setVisible(false)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        elseif subState == "confirming" then
            -- Show multi-line breakdown: base price, calculation, discount, insert instruction
            local selectedMaterial = state.getState("selectedMaterial")
            local selectedQty = state.getState("selectedQty")
            local calculatedPrice = state.getState("calculatedPrice")
            local basePriceForQty = state.getState("basePriceForQty")
            local discountPercent = state.getState("discountPercent") or 0

            -- Build lines
            local lines = {}

            if selectedMaterial and calculatedPrice then
                table.insert(lines, string.format(MSG.screen3_base_price, selectedMaterial.basePrice, selectedMaterial.minQty))

                if basePriceForQty then
                    local discountAmount = basePriceForQty - calculatedPrice
                    -- Calculation line
                    table.insert(lines, string.format("%d × %d/%d = %d",
                        selectedMaterial.basePrice, selectedQty, selectedMaterial.minQty, basePriceForQty))
                    -- Discount line
                    table.insert(lines, string.format("- %d%% discount (%d spurs)",
                        discountPercent, discountAmount))
                else
                    table.insert(lines, string.format(MSG.screen3_price_calc, calculatedPrice))
                end

                table.insert(lines, string.format(MSG.screen3_insert, calculatedPrice))
            else
                -- Fallback if data missing
                table.insert(lines, "Price calculation error")
                table.insert(lines, "Please contact operator")
            end

            local fullText = table.concat(lines, "\n")
            local W = monitorWidth or 80
            local numLines = #lines
            hintLabel:setSize(W, numLines)
            hintLabel:setText(fullText)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        end
    elseif screen == 4 then
        local W = monitorWidth or 80
        hintLabel:setSize(W, 1)
        hintLabel:setText(MSG.screen4_thanks)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(false) end
    end
end

-- Getters for UI components (for other modules)
local function getFrame() return mainFrame end
local function getCancelButton() return cancelButton end
local function getHintLabel() return hintLabel end

return {
    init = init,
    createUI = createUI,
    updateUI = updateUI,
    getFrame = getFrame,
    getCancelButton = getCancelButton,
    getHintLabel = getHintLabel
}