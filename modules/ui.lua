-- modules/ui.lua — Basalt UI creation and updates with fixed coordinate positioning
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state, basalt, MSG
local mainFrame, headerLabel, cancelButton
local monitorWidth, monitorHeight
local contentLabels = {}  -- key = line number, value = label object
local contentFirstLine = 3  -- default, may be increased if monitor height allows
local contentLastLine = 9
local spursToCoins = _G.spursToCoins

-- Cancel button debouncing and state tracking
local _cancelButtonLastClick = 0
local _cancelButtonProcessing = false
local _cancelButtonDebounceMs = 500  -- milliseconds
local _cancelButtonJustClicked = false  -- true for 200ms after click to keep visible for feedback

-- Cancel button timer tracking
local _cancelButtonTimerId = nil
local _cancelButtonResetTimerId = nil
local _cancelButtonTimerStart = 0
local _cancelButtonTimerDuration = 0.2  -- 200ms for color restoration
local _cancelButtonResetTimerDuration = 0.05  -- 50ms for async reset

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule, basaltModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    basalt = basaltModule
    -- logging.writeLog("DEBUG", "UI init called, getting MSG from config")
    MSG = configModule.get("MSG")
    -- logging.writeLog("DEBUG", "UI init: MSG = " .. tostring(MSG))
    if not MSG then
        error("UI init: MSG configuration not loaded")
    end
    -- logging.writeLog("DEBUG", "UI init: MSG.header = " .. tostring(MSG.header))
end


-- Create UI frame with fixed coordinate positioning
local function createUI()
    -- logging.writeLog("DEBUG", "UI createUI called (fixed coordinate)")
    -- Ensure MSG is loaded
    if not MSG then
        logging.writeLog("WARN", "MSG is nil in createUI, attempting to load from config")
        MSG = config.get("MSG")
        if not MSG then
            logging.writeLog("ERROR", "MSG not available in createUI")
            return
        end
    end
    -- logging.writeLog("DEBUG", "UI createUI: MSG.header = " .. tostring(MSG.header))
    local monitor = peripherals.getMonitor()
    if not monitor then
        logging.writeLog("ERROR", "Monitor not available for UI creation")
        return
    end
    -- logging.writeLog("DEBUG", "Monitor found, using Basalt")
    if not basalt then
        logging.writeLog("ERROR", "Basalt module not initialized")
        return
    end
    -- Redirect term to monitor (cashier.lua pattern)
    -- logging.writeLog("DEBUG", "Redirecting term to monitor")
    term.redirect(monitor)
    mainFrame = basalt.getMainFrame()
    -- logging.writeLog("DEBUG", "basalt.getMainFrame() returned: " .. tostring(mainFrame))
    if not mainFrame then
        logging.writeLog("WARN", "basalt.getMainFrame() returned nil, falling back to basalt.createFrame()")
        mainFrame = basalt.createFrame()
        if mainFrame then
            mainFrame:setTerm(monitor)
            -- logging.writeLog("DEBUG", "Created frame with setTerm")
        else
            logging.writeLog("ERROR", "basalt.createFrame() also returned nil")
            return
        end
    end
    mainFrame:setBackground(colors.black)
    -- logging.writeLog("DEBUG", "Main frame background set")
    -- Get monitor dimensions via term.getSize() after redirect
    local width, height = term.getSize()
    monitorWidth = width
    monitorHeight = height
    -- logging.writeLog("DEBUG", "Monitor dimensions: " .. width .. "x" .. height)

    -- Header (top bar) - Lines 1-2 with larger font, centered
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(width,2)
        :setBackground(colors.red):setForeground(colors.white)
        :setText(MSG.header)
    -- Try to center text
    local alignOk, alignErr = pcall(function() headerLabel:setTextAlign("center") end)
    if alignOk then
        -- logging.writeLog("DEBUG", "Text centered")
    else
        logging.writeLog("WARN", "setTextAlign failed: " .. tostring(alignErr))
    end
    -- Try to set font size safely
    local fontSizeOk, fontSizeErr = pcall(function() headerLabel:setFontSize(2) end)
    if fontSizeOk then
        -- logging.writeLog("DEBUG", "Header label created with font size 2")
    else
        logging.writeLog("WARN", "setFontSize failed: " .. tostring(fontSizeErr))
        -- Fallback: increase label height for larger appearance
        headerLabel:setSize(width, 3)
        -- logging.writeLog("DEBUG", "Header label fallback to height 3")
    end

    -- Determine starting line for content based on available space
    -- We want a gap line between header and content if monitor is tall enough
    local minHeightForGap = 9  -- need at least 9 lines to comfortably have gap
    if height >= minHeightForGap then
        -- Spacer line between header and content (line 3)
        local _ = mainFrame:addLabel()
            :setPosition(1,3):setSize(width,1)
            :setBackground(colors.black):setText("")
        -- logging.writeLog("DEBUG", "Spacer label created at line 3")
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
    -- logging.writeLog("DEBUG", "Creating content labels lines " .. contentFirstLine .. " to " .. contentLastLine)
    for i = contentFirstLine, contentLastLine do
        contentLabels[i] = mainFrame:addLabel()
            :setPosition(1, i):setSize(width, 1)
            :setBackground(colors.black):setForeground(colors.lightGray)
            :setVisible(false)
        -- logging.writeLog("DEBUG", "Content label line " .. i .. " created")
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
            local now = os.clock()
            -- Debounce check
            if _cancelButtonProcessing then
                logging.writeLog("DEBUG", "Cancel button click ignored - already processing")
                return
            end
            if (now - _cancelButtonLastClick) * 1000 < _cancelButtonDebounceMs then
                logging.writeLog("DEBUG", "Cancel button click ignored - within debounce window")
                return
            end
            _cancelButtonLastClick = now
            _cancelButtonProcessing = true
            _cancelButtonJustClicked = true
            logging.writeLog("DEBUG", "Cancel button click accepted, processing started (last click: " ..
                tostring(_cancelButtonLastClick) .. ", debounce ms: " .. _cancelButtonDebounceMs .. ")")

            -- Cancel any existing timer
            if _cancelButtonTimerId then
                local cancelOk, cancelErr = pcall(os.cancelTimer, _cancelButtonTimerId)
                if cancelOk then
                    logging.writeLog("DEBUG", "Cancelled previous timer ID " .. tostring(_cancelButtonTimerId))
                else
                    logging.writeLog("WARN", "Failed to cancel previous timer: " .. tostring(cancelErr))
                end
                _cancelButtonTimerId = nil
            end

            -- Immediate visual feedback: change button color to gray
            logging.writeLog("DEBUG", "Attempting to set cancel button color to gray for visual feedback")
            if cancelButton and cancelButton.setBackground then
                -- Also ensure foreground stays white for contrast
                if cancelButton.setForeground then
                    pcall(cancelButton.setForeground, cancelButton, colors.white)
                end
                local colorOk, colorErr = pcall(cancelButton.setBackground, cancelButton, colors.gray)
                if colorOk then
                    logging.writeLog("DEBUG", "Cancel button color changed to gray (visual feedback)")
                    -- Try to force redraw if method exists
                    if cancelButton.draw then
                        pcall(cancelButton.draw, cancelButton)
                    end
                else
                    logging.writeLog("ERROR", "Failed to set cancel button color to gray: " .. tostring(colorErr))
                end
            else
                logging.writeLog("WARN", "Cancel button or setBackground missing")
            end

            -- Immediately hide the button for better UX
            logging.writeLog("DEBUG", "Immediately hiding cancel button")
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(false)
            end

            -- Audio feedback
            peripherals.playNoteblockSoundLow()

            -- Lock depositor if on payment screen (screen 3 confirming)
            if state.getState("screen") == 3 and state.getState("subState") == "confirming" then
                -- logging.writeLog("DEBUG", "Cancel button: locking depositor")
                peripherals.lockDepositor()
            end

            -- Queue async reset via timer (safer than custom event for os.pullEvent compatibility)
            logging.writeLog("DEBUG", "Starting reset timer for async processing (duration: " ..
                tostring(_cancelButtonResetTimerDuration) .. "s)")
            local resetTimerOk, resetTimerIdOrErr = pcall(os.startTimer, _cancelButtonResetTimerDuration)
            if resetTimerOk then
                _cancelButtonResetTimerId = resetTimerIdOrErr
                logging.writeLog("DEBUG", "Reset timer started with ID " .. tostring(_cancelButtonResetTimerId))
            else
                logging.writeLog("ERROR", "Failed to start reset timer: " .. tostring(resetTimerIdOrErr))
            end

            -- Start timer for color restoration and flag reset (fires after reset is processed)
            logging.writeLog("DEBUG", "Starting timer for color restoration (duration: " ..
                tostring(_cancelButtonTimerDuration) .. "s)")
            local timerOk, timerIdOrErr = pcall(os.startTimer, _cancelButtonTimerDuration)
            if timerOk then
                _cancelButtonTimerId = timerIdOrErr
                _cancelButtonTimerStart = now
                logging.writeLog("DEBUG", "Timer started with ID " .. tostring(_cancelButtonTimerId))
            else
                logging.writeLog("ERROR", "Failed to start timer: " .. tostring(timerIdOrErr))
                -- Reset flags immediately if timer fails
                _cancelButtonJustClicked = false
                _cancelButtonProcessing = false
            end

            logging.writeLog("DEBUG", "Cancel button onClick handler finished (async processing queued)")
        end)
    -- logging.writeLog("DEBUG", "Cancel button created: " .. tostring(cancelButton) .. " at line " .. (height - 3))
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
    -- logging.writeLog("DEBUG", "updateUI called: screen=" .. tostring(screen) .. " subState=" .. tostring(subState))

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
        -- Safety: reset processing flag if stuck for more than 2 seconds
        if _cancelButtonProcessing and (os.clock() - _cancelButtonLastClick) > 2 then
            logging.writeLog("WARN", "Safety: resetting stuck cancel button processing flag (>2s since last click)")
            _cancelButtonProcessing = false
            _cancelButtonJustClicked = false
            _cancelButtonTimerId = nil
            _cancelButtonResetTimerId = nil
        end

        -- Hide cancel button unless it was just clicked (keep visible for feedback)
        if _cancelButtonJustClicked then
            logging.writeLog("DEBUG", "Screen 1: cancel button just clicked, keeping visible with gray color")
            if cancelButton and cancelButton.setVisible then
                cancelButton:setVisible(true)
                if cancelButton.setBackground then
                    logging.writeLog("DEBUG", "Screen 1: setting cancel button background to gray")
                    cancelButton:setBackground(colors.gray)  -- Keep gray for feedback
                end
                if cancelButton.setForeground then
                    cancelButton:setForeground(colors.white)
                end
            end
        else
            logging.writeLog("DEBUG", "Screen 1: hiding cancel button")
            if cancelButton and cancelButton.setVisible then
                -- Reset color to red before hiding for next time
                if cancelButton.setBackground then
                    logging.writeLog("DEBUG", "Screen 1: setting cancel button background to red before hide")
                    cancelButton:setBackground(colors.red)
                end
                cancelButton:setVisible(false)
                -- Ensure processing flag is reset when button hidden (safety)
                _cancelButtonProcessing = false
            else
                logging.writeLog("WARN", "Screen 1: cancelButton invalid")
            end
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
            if cancelButton.setBackground then
                cancelButton:setBackground(colors.red)  -- Ensure red color when shown
            end
            if cancelButton.setActive then
                cancelButton:setActive(true)
                logging.writeLog("DEBUG", "Cancel button activated")
            end
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
                if cancelButton.setBackground then
                    cancelButton:setBackground(colors.red)  -- Ensure red color when shown
                end
                if cancelButton.setActive then
                    cancelButton:setActive(true)
                    logging.writeLog("DEBUG", "Cancel button activated")
                end
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
                if cancelButton.setBackground then
                    cancelButton:setBackground(colors.red)  -- Ensure red color when shown
                end
                if cancelButton.setActive then
                    cancelButton:setActive(true)
                    logging.writeLog("DEBUG", "Cancel button activated")
                end
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
            -- Reset color to red before hiding for next time
            if cancelButton.setBackground then
                cancelButton:setBackground(colors.red)
            end
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

-- Timer management for cancel button
local function getCancelButtonTimerId()
    return _cancelButtonTimerId
end

local function getCancelButtonResetTimerId()
    return _cancelButtonResetTimerId
end

local function restoreCancelButtonColor(timerId)
    -- Check if this is our timer
    if timerId ~= _cancelButtonTimerId then
        logging.writeLog("DEBUG", "Timer ID " .. tostring(timerId) .. " does not match current timer " .. tostring(_cancelButtonTimerId) .. ", ignoring")
        return
    end

    logging.writeLog("DEBUG", "Processing cancel button color restoration timer")

    -- Reset flags
    _cancelButtonJustClicked = false
    _cancelButtonProcessing = false
    _cancelButtonTimerId = nil
    _cancelButtonResetTimerId = nil

    -- Safety: if state wasn't reset by eventLoop (e.g. Basalt consumed the event),
    -- reset it now directly
    local currentScreen = state.getState("screen")
    if currentScreen ~= 1 then
        logging.writeLog("WARN", "Cancel button timer expired but screen is still " ..
            tostring(currentScreen) .. ", state may not have been reset")
        state.resetToMainScreen()
        -- Return early; updateUI will handle button visibility
        return
    end

    -- Restore red color if button is visible
    if cancelButton and cancelButton.setBackground then
        if currentScreen == 2 or currentScreen == 3 then
            -- On screens 2 and 3 button should be visible and red
            logging.writeLog("DEBUG", "Restoring cancel button to red (screen " .. tostring(currentScreen) .. ")")
            cancelButton:setBackground(colors.red)
            -- Ensure button is visible (should already be)
            if cancelButton.setVisible then
                cancelButton:setVisible(true)
            end
        else
            -- On screen 1 or 4 button should be hidden
            logging.writeLog("DEBUG", "Cancel button not needed on screen " .. tostring(currentScreen) .. ", hiding")
            if cancelButton.setVisible then
                cancelButton:setVisible(false)
            end
            -- Trigger UI update to ensure button visibility is correct on screen 1
            if currentScreen == 1 then
                updateUI()
            end
        end
    else
        logging.writeLog("WARN", "Cancel button or setBackground missing during color restoration")
    end
end

return {
    init = init,
    createUI = createUI,
    updateUI = updateUI,
    getFrame = getFrame,
    getCancelButton = getCancelButton,
    getHintLabel = getHintLabel,
    getCancelButtonTimerId = getCancelButtonTimerId,
    getCancelButtonResetTimerId = getCancelButtonResetTimerId,
    restoreCancelButtonColor = restoreCancelButtonColor
}