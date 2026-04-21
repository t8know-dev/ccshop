-- modules/ui.lua — Basalt UI creation and updates with fixed coordinate positioning
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state, basalt
local mainFrame, headerLabel, cancelButton
local monitorWidth, monitorHeight
local contentLabels = {}  -- key = line number, value = label object
local contentFirstLine = 2
local contentLastLine = 9

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule, basaltModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    basalt = basaltModule
end

-- Create UI frame with fixed coordinate positioning
local function createUI()
    logging.writeLog("DEBUG", "UI createUI called (fixed coordinate)")
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
    monitorWidth = width
    monitorHeight = height
    logging.writeLog("DEBUG", "Monitor dimensions: " .. width .. "x" .. height)

    -- Header (top bar) - Line 1
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(width,1)
        :setBackground(colors.red):setForeground(colors.white)
        :setText(config.MSG.header)
    logging.writeLog("DEBUG", "Header label created (red background)")

    -- Content labels from line 2 up to line (height - 4) to leave gap above button
    contentFirstLine = 2
    contentLastLine = height - 4  -- leave at least 1 line gap above button
    if contentLastLine < contentFirstLine then
        contentLastLine = contentFirstLine
        logging.writeLog("WARN", "Monitor height very small, UI may be cramped")
    end
    logging.writeLog("DEBUG", "Creating content labels lines " .. contentFirstLine .. " to " .. contentLastLine)
    for i = contentFirstLine, contentLastLine do
        contentLabels[i] = mainFrame:addLabel()
            :setPosition(1, i):setSize(width, 1)
            :setBackground(colors.black):setForeground(colors.lightGray)
            :setVisible(false)
        logging.writeLog("DEBUG", "Content label line " .. i .. " created")
    end

    -- Cancel button (bottom-left corner) styled like cashier example
    local btnWidth = math.max(1, math.min(14, width - 4))  -- Fixed width 16, but ensure fits monitor, minimum 1
    local btnText = " " .. config.MSG.cancel_btn .. " "  -- Padded text
    cancelButton = mainFrame:addButton()
        :setText(btnText)
        :setPosition(2, height - 3)  -- Bottom-left with margin
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
        end)
    if cancelButton and cancelButton.setVisible then
        cancelButton:setVisible(false)
    else
        logging.writeLog("ERROR", "cancelButton invalid " .. tostring(cancelButton))
    end
    logging.writeLog("DEBUG", "Cancel button created at line " .. (height - 3))
end

-- Update UI hints and cancel button visibility based on screen
local function updateUI()
    local screen = state.getState("screen")
    local subState = state.getState("subState")

    -- Hide all content labels first
    for line, label in pairs(contentLabels) do
        if label and label.setVisible then
            label:setVisible(false)
        end
    end

    if screen == 1 then
        -- Screen 1: Category selection with discount info
        local discountInfo = config.MSG.screen1_discount_info
        if type(discountInfo) == "table" then
            -- Display each line in separate label
            local line = contentFirstLine
            for _, text in ipairs(discountInfo) do
                if line <= contentLastLine and contentLabels[line] then
                    contentLabels[line]:setText(text)
                    contentLabels[line]:setVisible(true)
                    line = line + 1
                else
                    break
                end
            end
            -- Empty line separator
            if line <= contentLastLine and contentLabels[line] then
                contentLabels[line]:setText("")
                contentLabels[line]:setVisible(true)
                line = line + 1
            end
            -- Hint line
            if line <= contentLastLine and contentLabels[line] then
                contentLabels[line]:setText(config.MSG.screen1_hint)
                contentLabels[line]:setVisible(true)
            end
        else
            -- Fallback: single line hint
            if contentLabels[contentFirstLine] then
                contentLabels[contentFirstLine]:setText(config.MSG.screen1_hint)
                contentLabels[contentFirstLine]:setVisible(true)
            end
        end
        -- Hide cancel button
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(false)
        end

    elseif screen == 2 then
        -- Screen 2: Material selection - single hint line
        if contentLabels[contentFirstLine] then
            contentLabels[contentFirstLine]:setText(config.MSG.screen2_hint)
            contentLabels[contentFirstLine]:setVisible(true)
        end
        -- Show cancel button
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(true)
        end

    elseif screen == 3 then
        if subState == "selecting" then
            -- Screen 3 selecting: show base price and hint
            local basePriceStr = ""
            local selectedMaterial = state.getState("selectedMaterial")
            if selectedMaterial then
                basePriceStr = string.format(config.MSG.screen3_base_price,
                    selectedMaterial.basePrice, selectedMaterial.minQty)
            end
            local hintText = basePriceStr .. " | " .. config.MSG.screen3_hint_select
            if contentLabels[contentFirstLine] then
                contentLabels[contentFirstLine]:setText(hintText)
                contentLabels[contentFirstLine]:setVisible(true)
            end
            -- Show cancel button
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(true)
            end

        elseif subState == "confirming" then
            -- Screen 3 confirming: payment breakdown (lines 2-8)
            local selectedMaterial = state.getState("selectedMaterial")
            local selectedQty = state.getState("selectedQty")
            local calculatedPrice = state.getState("calculatedPrice")
            local basePriceForQty = state.getState("basePriceForQty")
            local discountPercent = state.getState("discountPercent") or 0

            if selectedMaterial and calculatedPrice and basePriceForQty then
                local linesText = {
                    string.format(config.MSG.screen3_base_price,
                        selectedMaterial.basePrice, selectedMaterial.minQty),
                    string.format(config.MSG.screen3_breakdown_line,
                        selectedMaterial.basePrice, selectedQty, selectedMaterial.minQty, basePriceForQty),
                    string.format(config.MSG.screen3_discount_line,
                        discountPercent, basePriceForQty - calculatedPrice),
                    string.format(config.MSG.screen3_total_line, calculatedPrice),
                    "", -- empty line
                    string.format(config.MSG.screen3_insert, calculatedPrice),
                    config.MSG.screen3_pedestal_instruction
                }
                for offset, text in ipairs(linesText) do
                    local line = contentFirstLine + offset - 1
                    if line <= contentLastLine and contentLabels[line] then
                        contentLabels[line]:setText(text)
                        contentLabels[line]:setVisible(true)
                    else
                        break
                    end
                end
            else
                -- Fallback if data missing
                if contentLabels[contentFirstLine] then
                    contentLabels[contentFirstLine]:setText("Price calculation error")
                    contentLabels[contentFirstLine]:setVisible(true)
                end
                if contentLabels[contentFirstLine + 1] and (contentFirstLine + 1) <= contentLastLine then
                    contentLabels[contentFirstLine + 1]:setText("Please contact operator")
                    contentLabels[contentFirstLine + 1]:setVisible(true)
                end
            end
            -- Show cancel button
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(true)
            end
        end

    elseif screen == 4 then
        -- Screen 4: Thank you message
        if contentLabels[contentFirstLine] then
            contentLabels[contentFirstLine]:setText(config.MSG.screen4_thanks)
            contentLabels[contentFirstLine]:setVisible(true)
        end
        -- Hide cancel button
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(false)
        end
    end
end

-- Getters for UI components (for other modules)
local function getFrame() return mainFrame end
local function getCancelButton() return cancelButton end
local function getHintLabel() return contentLabels[contentFirstLine] end  -- Return first content label for error messages

return {
    init = init,
    createUI = createUI,
    updateUI = updateUI,
    getFrame = getFrame,
    getCancelButton = getCancelButton,
    getHintLabel = getHintLabel
}