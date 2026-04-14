-- modules/state.lua — Centralized state management
-- Exports: getState(), updateState(changes), resetState(), subscribe(callback), notifyChanges()

local state = {
    screen = 1,               -- 1=category, 2=materials, 3=quantity/payment, 4=thankyou
    subState = nil,           -- nil, "selecting", or "confirming" (screen 3 only)
    selectedCategory = nil,
    selectedMaterial = nil,
    selectedQty = nil,
    calculatedPrice = nil,    -- price for selected quantity
    lastActivity = os.clock(),
    currentOptions = {},      -- pedestal index -> option table (item, label, count)
    currentPedestalIndices = {}, -- which pedestal indices are currently used
    lastSelectedPedestal = nil, -- last selected pedestal index
    cancelRequested = false,
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
    for k, v in pairs(changes) do
        if state[k] ~= v then
            state[k] = v
            changed = true
        end
    end
    if changed then
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
        lastActivity = os.clock(),
        currentOptions = {},
        currentPedestalIndices = {},
        lastSelectedPedestal = nil,
        cancelRequested = false,
        availableQuantities = nil,
        paymentBaseline = nil,
        paymentDeadline = nil,
        paymentPaid = false,
        paymentCheckCount = 0,
    }
    updateState(initialState)
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
    subscribe = subscribe,
    notifyChanges = notifyChanges
}