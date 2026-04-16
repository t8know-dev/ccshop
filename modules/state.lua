-- modules/state.lua — Centralized state management
-- Exports: getState(), updateState(changes), resetState(), subscribe(callback), notifyChanges()

local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity/payment, 4=thankyou
    subState = nil,           -- nil, "selecting", or "confirming" (screen 3 only)
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    calculatedPrice = nil,    -- price for selected quantity
    discountLevel = nil,      -- bulk discount level (0-5+)
    discountPercent = nil,    -- discount percentage (0-20)
    basePriceForQty = nil,    -- price before discount (for display)
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table (item, label, count)
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    availableQuantities = nil, -- list of numeric quantities available for selected material
    paymentBaseline = nil,    -- baseline relay input state for payment detection
    paymentDeadline = nil,    -- os.clock() deadline for payment timeout
    paymentPaid = false,
    paymentCheckCount = 0,    -- counter for payment detection checks
}

local subscribers = {}

-- Get a copy of the current state (or a specific field)
local function getState(key)
    if key then
        return state[key]
    end
    -- Return shallow copy to prevent external mutation
    local copy = {}
    for k, v in pairs(state) do
        copy[k] = v
    end
    return copy
end

-- Update state with a table of changes
local function updateState(changes)
    local changed = false
    -- Log only important state changes (to reduce log volume)
    local ok, logging = pcall(require, "modules.logging")
    local importantKeys = {
        screen = false, subState = false, selectedCategory = false,
        selectedMaterial = false, selectedQty = false,
        paymentDeadline = true, paymentPaid = false, paymentBaseline = false, calculatedPrice = false,
        discountLevel = false, discountPercent = false, basePriceForQty = false
    }

    -- Log only if changes contain important keys
    local hasImportantChange = false
    for k, _ in pairs(changes) do
        if importantKeys[k] then
            hasImportantChange = true
            break
        end
    end

    if ok and logging.writeLog and hasImportantChange then
        logging.writeLog("DEBUG", "updateState called with important changes: " .. textutils.serialize(changes))
    end

    for k, v in pairs(changes) do
        if state[k] ~= v then
            if ok and logging.writeLog and importantKeys[k] then
                logging.writeLog("DEBUG", "  updating " .. k .. ": " .. tostring(state[k]) .. " -> " .. tostring(v))
            end
            state[k] = v
            changed = true
        end
    end

    if changed then
        if ok and logging.writeLog and hasImportantChange then
            logging.writeLog("DEBUG", "State changed, notifying " .. #subscribers .. " subscribers")
        end
        for _, callback in ipairs(subscribers) do
            pcall(callback, changes)
        end
    end
end

-- Reset state to initial values (except lastActivity?)
local function resetState()
    local initialState = {
        screen = 1,
        subState = nil,
        selectedCategory = nil,
        selectedMaterial = nil,
        selectedQty = nil,
        calculatedPrice = nil,
        discountLevel = nil,
        discountPercent = nil,
        basePriceForQty = nil,
        lastActivity = os.clock(),
        currentOptions = {},
        currentPedestalIndices = {},
        lastSelectedPedestal = nil,
        availableQuantities = nil,
        paymentBaseline = nil,
        paymentDeadline = nil,
        paymentPaid = false,
        paymentCheckCount = 0,
    }
    updateState(initialState)
end

-- Reset to main screen (preserves lastActivity, currentOptions, etc.)
local function resetToMainScreen()
    local ok, logging = pcall(require, "modules.logging")
    if ok and logging.writeLog then
        logging.writeLog("DEBUG", "resetToMainScreen called")
    end
    updateState({
        screen = 1,
        selectedCategory = nil,
        selectedMaterial = nil,
        selectedQty = nil,
        subState = nil,
        calculatedPrice = nil,
        discountLevel = nil,
        discountPercent = nil,
        basePriceForQty = nil,
        availableQuantities = nil,
        paymentPaid = false,
        paymentCheckCount = 0,
        paymentBaseline = nil,
        paymentDeadline = nil
    })
end

-- Subscribe to state changes
local function subscribe(callback)
    table.insert(subscribers, callback)
end

-- Notify subscribers manually (optional)
local function notifyChanges()
    for _, callback in ipairs(subscribers) do
        pcall(callback, {})
    end
end

return {
    getState = getState,
    updateState = updateState,
    resetState = resetState,
    resetToMainScreen = resetToMainScreen,
    subscribe = subscribe,
    notifyChanges = notifyChanges
}