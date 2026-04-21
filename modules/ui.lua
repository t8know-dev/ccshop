-- modules/ui.lua — Basalt UI creation and updates with fixed coordinate positioning
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state, basalt, MSG
local mainFrame, headerLabel, cancelButton
local monitorWidth, monitorHeight
local contentLabels = {}  -- key = line number, value = label object
local contentFirstLine = 3  -- default, may be increased if monitor height allows
local contentLastLine = 9
local spursToCoins = _G.spursToCoins

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule, basaltModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    basalt = basaltModule
    logging.writeLog("DEBUG", "UI init called, getting MSG from config")
    MSG = configModule.get("MSG")
    logging.writeLog("DEBUG", "UI init: MSG = " .. tostring(MSG))
    if not MSG then
        error("UI init: MSG configuration not loaded")
    end
    logging.writeLog("DEBUG", "UI init: MSG.header = " .. tostring(MSG.header))
end

-- Create UI frame with fixed coordinate positioning
local function createUI()
    logging.writeLog("DEBUG", "UI createUI called (fixed coordinate)")
    -- Ensure MSG is loaded
    if not MSG then
        logging.writeLog("WARN", "MSG is nil in createUI, attempting to load from config")
        MSG = config.get("MSG")
        if not MSG then
            logging.writeLog("ERROR", "MSG not available in createUI")
            return
        end
    end
    logging.writeLog("DEBUG", "UI createUI: MSG.header = " .. tostring(MSG.header))
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

    -- Header (top bar) - Lines 1-2 with larger font, centered
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(width,2)
        :setBackground(colors.red):setForeground(colors.white)
        :setText(MSG.header)
    -- Try to center text
    local alignOk, alignErr = pcall(function() headerLabel:setTextAlign("center") end)
    if alignOk then
        logging.writeLog("DEBUG", "Text centered")
    else
        logging.writeLog("WARN", "setTextAlign failed: " .. tostring(alignErr))
    end
    -- Try to set font size safely
    local fontSizeOk, fontSizeErr = pcall(function() headerLabel:setFontSize(2) end)
    if fontSizeOk then
        logging.writeLog("DEBUG", "Header label created with font size 2")
    else
        logging.writeLog("WARN", "setFontSize failed: " .. tostring(fontSizeErr))
        -- Fallback: increase label height for larger appearance
        headerLabel:setSize(width, 3)
        logging.writeLog("DEBUG", "Header label fallback to height 3")
    end

    -- Determine starting line for content based on available space
    -- We want a gap line between header and content if monitor is tall enough
    local minHeightForGap = 9  -- need at least 9 lines to comfortably have gap
    if height >= minHeightForGap then
        -- Spacer line between header and content (line 3)
        local _ = mainFrame:addLabel()
            :setPosition(1,3):setSize(width,1)
            :setBackground(colors.black):setText("")
        logging.writeLog("DEBUG", "Spacer label created at line 3")
        contentFirstLine = 4  -- header lines 1-2, spacer line 3, content starts at 4
    else
        logging.writeLog("WARN", "Monitor height " .. height .. " is small, skipping spacer line")
        contentFirstLine = 3  -- header lines 1-2, no spacer, content starts at 3
    end

    -- Content labels from contentFirstLine up to line (height - 4) to leave gap above button
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
    local btnText = " " .. MSG.cancel_btn .. " "  -- Padded text
    cancelButton = mainFrame:addButton()
        :setText(btnText)
        :setPosition(2, height - 3)  -- Bottom-left with margin
        :setSize(btnWidth, 3)
        :setBackground(colors.red)
        :setForeground(colors.white)
        :onClick(function()
            logging.writeLog("DEBUG", "Cancel button onClick handler started")
            peripherals.playNoteblockSoundLow()
            -- Lock depositor if on payment screen (screen 3 confirming)
            if state.getState("screen") == 3 and state.getState("subState") == "confirming" then
                logging.writeLog("DEBUG", "Cancel button: locking depositor")
                peripherals.lockDepositor()
            end
            logging.writeLog("DEBUG", "Cancel button clicked, resetting to main screen")
            -- Reset to main screen
            state.resetToMainScreen()
            -- Immediately update UI to reflect screen 1 (hide cancel button, show categories)
            updateUI()
            logging.writeLog("DEBUG", "Cancel button onClick handler finished")
        end)
    logging.writeLog("DEBUG", "Cancel button created: " .. tostring(cancelButton) .. " at line " .. (height - 3))
    if cancelButton and cancelButton.setVisible then
        cancelButton:setVisible(false)
    else
        logging.writeLog("ERROR", "cancelButton invalid " .. tostring(cancelButton))
    end
end

-- Update UI hints and cancel button visibility based on screen
local function updateUI()
    local screen = state.getState("screen")
    local subState = state.getState("subState")
    logging.writeLog("DEBUG", "updateUI called: screen=" .. tostring(screen) .. " subState=" .. tostring(subState))

    -- Hide all content labels first
    for _, label in pairs(contentLabels) do
        if label and label.setVisible then
            label:setVisible(false)
        end
    end

    if screen == 1 then
        -- Screen 1: Category selection with discount info
        local discountInfo = MSG.screen1_discount_info
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
                contentLabels[line]:setText(MSG.screen1_hint)
                contentLabels[line]:setVisible(true)
            end
        else
            -- Fallback: single line hint
            if contentLabels[contentFirstLine] then
                contentLabels[contentFirstLine]:setText(MSG.screen1_hint)
                contentLabels[contentFirstLine]:setVisible(true)
            end
        end
        -- Hide cancel button
        logging.writeLog("DEBUG", "Screen 1: hiding cancel button")
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(false)
        else
            logging.writeLog("WARN", "Screen 1: cancelButton invalid")
        end

    elseif screen == 2 then
        -- Screen 2: Material selection - single hint line
        if contentLabels[contentFirstLine] then
            contentLabels[contentFirstLine]:setText(MSG.screen2_hint)
            contentLabels[contentFirstLine]:setVisible(true)
        end
        -- Show cancel button
        logging.writeLog("DEBUG", "Screen 2: showing cancel button")
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(true)
        else
            logging.writeLog("WARN", "Screen 2: cancelButton invalid")
        end

    elseif screen == 3 then
        if subState == "selecting" then
            -- Screen 3 selecting: show base price and hint
            local basePriceStr = ""
            local selectedMaterial = state.getState("selectedMaterial")
            if selectedMaterial then
                basePriceStr = string.format(MSG.screen3_base_price,
                    selectedMaterial.basePrice, selectedMaterial.minQty)
            end
            local hintText = basePriceStr .. " | " .. MSG.screen3_hint_select
            if contentLabels[contentFirstLine] then
                contentLabels[contentFirstLine]:setText(hintText)
                contentLabels[contentFirstLine]:setVisible(true)
            end
            -- Show cancel button
            logging.writeLog("DEBUG", "Screen 3 selecting: showing cancel button")
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(true)
            else
                logging.writeLog("WARN", "Screen 3 selecting: cancelButton invalid")
            end

        elseif subState == "confirming" then
            -- Screen 3 confirming: payment breakdown (lines 2-8)
            local selectedMaterial = state.getState("selectedMaterial")
            local selectedQty = state.getState("selectedQty")
            local calculatedPrice = state.getState("calculatedPrice")
            local basePriceForQty = state.getState("basePriceForQty")
            local discountPercent = state.getState("discountPercent") or 0

            if selectedMaterial and calculatedPrice and basePriceForQty then
                -- Convert spurs to coin string
                local coinText
                if spursToCoins then
                    coinText = spursToCoins(calculatedPrice)
                else
                    coinText = tostring(calculatedPrice) .. " spurs"
                    logging.writeLog("WARN", "spursToCoins function not available, falling back to spurs")
                end
                local linesText = {
                    string.format(MSG.screen3_base_price,
                        selectedMaterial.basePrice, selectedMaterial.minQty),
                    string.format(MSG.screen3_breakdown_line,
                        selectedMaterial.basePrice, selectedQty, selectedMaterial.minQty, basePriceForQty),
                    string.format(MSG.screen3_discount_line,
                        discountPercent, basePriceForQty - calculatedPrice),
                    string.format(MSG.screen3_total_line, calculatedPrice),
                    "", -- empty line
                    string.format(MSG.screen3_insert, coinText),
                    MSG.screen3_pedestal_instruction
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
            logging.writeLog("DEBUG", "Screen 3 confirming: showing cancel button")
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(true)
            else
                logging.writeLog("WARN", "Screen 3 confirming: cancelButton invalid")
            end
        end

    elseif screen == 4 then
        -- Screen 4: Thank you message
        if contentLabels[contentFirstLine] then
            contentLabels[contentFirstLine]:setText(MSG.screen4_thanks)
            contentLabels[contentFirstLine]:setVisible(true)
        end
        -- Hide cancel button
        logging.writeLog("DEBUG", "Screen 4: hiding cancel button")
        if cancelButton and cancelButton.setVisible then
            cancelButton:setVisible(false)
        else
            logging.writeLog("WARN", "Screen 4: cancelButton invalid")
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