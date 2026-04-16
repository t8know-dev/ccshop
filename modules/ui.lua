-- modules/ui.lua — Basalt UI creation and updates
-- Exports: init(), createUI(), updateUI(), getFrame(), getCancelButton(), getHintLabel()

local logging, peripherals, config, state
local mainFrame, headerLabel, hintLabel, cancelButton

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
end

-- Create UI frame
local function createUI()
    local monitor = peripherals.getMonitor()
    if not monitor then
        logging.writeLog("ERROR", "Monitor not available for UI creation")
        return
    end

    -- Redirect term to monitor (Basalt will use the redirected term)
    term.redirect(monitor)
    local basalt = require("basalt")
    mainFrame = basalt.getMainFrame()
    mainFrame:setBackground(colors.black)
    local W, H = term.getSize()
    -- Header (top bar)
    headerLabel = mainFrame:addLabel()
        :setPosition(1,1):setSize(W,1)
        :setBackground(colors.brown):setForeground(colors.white)
        :setText(MSG.header)
    -- Hint line (below top bar with 1 line gap if enough space)
    local hintY = 3
    if H - 2 <= 3 then hintY = 2 end  -- avoid overlap with cancel button
    hintLabel = mainFrame:addLabel()
        :setPosition(1, hintY):setSize(W,1)
        :setBackground(colors.black):setForeground(colors.lightGray)
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
        hintLabel:setText(MSG.screen1_hint)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(false) end
    elseif screen == 2 then
        hintLabel:setText(MSG.screen2_hint)
        if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
    elseif screen == 3 then
        if subState == "selecting" then
            -- Show base price and hint
            local basePriceStr = ""
            local selectedMaterial = state.getState("selectedMaterial")
            if selectedMaterial then
                basePriceStr = string.format(MSG.screen3_base_price, selectedMaterial.basePrice, tostring(selectedMaterial.minQty)) .. " | "
            end
            hintLabel:setText(basePriceStr .. MSG.screen3_hint_select)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        elseif subState == "confirming" then
            -- Show price and insert instruction
            local calculatedPrice = state.getState("calculatedPrice")
            local hint = string.format(MSG.screen3_price_calc, calculatedPrice) .. " - " ..
                        string.format(MSG.screen3_insert, calculatedPrice)
            hintLabel:setText(hint)
            if cancelButton and cancelButton.setVisible then cancelButton:setVisible(true) end
        end
    elseif screen == 4 then
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