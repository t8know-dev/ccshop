-- modules/ui.lua — Basalt UI creation and updates
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state, basalt
local mainFrame, headerLabel, hintLabel, cancelButton, discountLabel
local monitorWidth, monitorHeight, hintYPos

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
    -- Redirect term to monitor (cashier.lua pattern)
    logging.writeLog("DEBUG", "Redirecting term to monitor")
    term.redirect(monitor)
    mainFrame = basalt.getMainFrame()
    logging.writeLog("DEBUG", "basalt.getMainFrame() returned: " .. tostring(mainFrame))
    if not mainFrame then
        logging.writeLog("WARN", "basalt.getMainFrame() returned nil, falling back to basalt.createFrame()")
        mainFrame = basalt.createFrame()
        if mainFrame then
            mainFrame:setTerm(monitor)
            logging.writeLog("DEBUG", "Created frame with setTerm")
        else
            logging.writeLog("ERROR", "basalt.createFrame() also returned nil")
            return
        end
    end
    mainFrame:setBackground(colors.black)
    logging.writeLog("DEBUG", "Main frame background set")
    -- Get monitor dimensions via term.getSize() after redirect
    local width, height = term.getSize()
    local W, H = width, height
    monitorWidth = W
    monitorHeight = H
    -- Header (top bar)
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(W,1)
        :setBackground(colors.brown):setForeground(colors.white)
        :setText(MSG.header)
    -- Hint line (below top bar with 1 line gap if enough space)
    local hintY = 3
    -- Ensure hint line does not overlap button (button occupies rows H-3, H-2, H-1)
    local maxHintY = H - 4  -- at least 1 line gap above button
    if hintY > maxHintY then
        hintY = maxHintY
    end
    -- Ensure hint line is at least row 2 (below header)
    if hintY < 2 then
        hintY = 2
    end
    hintYPos = hintY  -- store for later use in updateUI
    hintLabel = mainFrame:addLabel()
        :setPosition(1, hintY):setSize(W,1)
        :setBackground(colors.black):setForeground(colors.lightGray)
    -- Discount info line (below hint line, only shown on screen 1)
    discountLabel = mainFrame:addLabel()
        :setPosition(1, hintY + 1):setSize(W,1)
        :setBackground(colors.black):setForeground(colors.lightGray)
        :setVisible(false)
    -- Cancel button (bottom-left corner) styled like cashier example
    local btnWidth = math.max(1, math.min(14, W - 4))  -- Fixed width 16, but ensure fits monitor, minimum 1
    local btnText = " " .. MSG.cancel_btn .. " "  -- Padded text
    cancelButton = mainFrame:addButton()
        :setText(btnText)
        :setPosition(2, H - 3)  -- Bottom-left with margin
        :setSize(btnWidth, 3)
        :setBackground(colors.red)
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
        -- Discount info lines (either table or string) - show in discountLabel
        local discountInfo = MSG.screen1_discount_info
        local discountLines = {}
        if type(discountInfo) == "table" then
            -- Add each discount line as separate line
            for _, line in ipairs(discountInfo) do
                table.insert(discountLines, line)
            end
        else
            -- Already a string, treat as single line
            table.insert(discountLines, discountInfo)
        end

        -- Calculate available height for discount label (above cancel button)
        local discountY = hintYPos + 1  -- discount label starts one line below hint label
        local maxDiscountHeight = monitorHeight - 4 - discountY + 1  -- rows from discountY to row above button
        if maxDiscountHeight < 1 then maxDiscountHeight = 1 end

        -- Truncate discount lines if necessary
        if #discountLines > maxDiscountHeight then
            local truncated = {}
            for i = 1, maxDiscountHeight do
                table.insert(truncated, discountLines[i])
            end
            discountLines = truncated
        end

        local discountText = table.concat(discountLines, "\n")
        local discountNumLines = #discountLines
        local W = monitorWidth or 80

        -- Set up hint label (just the instruction)
        hintLabel:setSize(W, 1)
        hintLabel:setText(MSG.screen1_hint)

        -- Set up discount label
        discountLabel:setPosition(1, discountY)
        discountLabel:setSize(W, discountNumLines)
        discountLabel:setText(discountText)
        discountLabel:setVisible(true)

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
            -- Show single-line breakdown: base price, calculation, discount, insert instruction
            local selectedMaterial = state.getState("selectedMaterial")
            local selectedQty = state.getState("selectedQty")
            local calculatedPrice = state.getState("calculatedPrice")
            local basePriceForQty = state.getState("basePriceForQty")
            local discountPercent = state.getState("discountPercent") or 0

            -- Build single line parts
            local parts = {}

            if selectedMaterial and calculatedPrice then
                table.insert(parts, string.format(MSG.screen3_base_price, selectedMaterial.basePrice, selectedMaterial.minQty))

                if basePriceForQty then
                    local discountAmount = basePriceForQty - calculatedPrice
                    -- Calculation part
                    table.insert(parts, string.format("%d × %d/%d = %d",
                        selectedMaterial.basePrice, selectedQty, selectedMaterial.minQty, basePriceForQty))
                    -- Discount part
                    table.insert(parts, string.format("- %d%% discount (%d spurs)",
                        discountPercent, discountAmount))
                else
                    table.insert(parts, string.format(MSG.screen3_price_calc, calculatedPrice))
                end

                table.insert(parts, string.format(MSG.screen3_insert, calculatedPrice))
            else
                -- Fallback if data missing
                table.insert(parts, "Price calculation error")
                table.insert(parts, "Please contact operator")
            end

            local fullText = table.concat(parts, " | ")
            local W = monitorWidth or 80
            hintLabel:setSize(W, 1)
            hintLabel:setText(fullText)
            discountLabel:setVisible(false)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        end
    elseif screen == 4 then
        local W = monitorWidth or 80
        hintLabel:setSize(W, 1)
        hintLabel:setText(MSG.screen4_thanks)
        discountLabel:setVisible(false)
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