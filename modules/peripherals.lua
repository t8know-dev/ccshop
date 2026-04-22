-- modules/peripherals.lua — Peripheral management and AE2 cache
-- Exports: init(), getAE2Stock(), refreshAE2Cache(), playNoteblockSoundHigh(),
--          playNoteblockSoundLow(), playNoteblockSound() [deprecated],
--          getAllRelayInputs(), debugRelayInputs(), lockDepositor(), unlockDepositor(),
--          getPedestals(), getPedestalIndexByName(), getPedestalObjectToIndex(),
--          getRelayLock(), getAe2Adapter(), getDepositor(), getSpeaker(), getMonitor()

local logging, config

-- Peripheral wrappers & cache
local relayLock, ae2Adapter, depositor, speaker, monitor, pedestals
local pedestalIndexByName, pedestalObjectToIndex
local ae2Cache = {
    timestamp = 0,
    data = {},
    ttl = AE2_CACHE_TTL or 30
}

-- Initialize module with dependencies
local function init(loggingModule, configModule)
    logging = loggingModule
    config = configModule
end

-- Peripheral initialization (call after config is loaded)
local function initPeripherals()
    logging.writeLog("INFO", "Initializing peripherals")
    relayLock = peripheral.wrap(RELAY_LOCK)
    -- logging.writeLog("DEBUG", "RELAY_LOCK wrapped: " .. tostring(relayLock))
    ae2Adapter = peripheral.wrap(AE2_ADAPTER)
    if not ae2Adapter then
        -- logging.writeLog("DEBUG", "AE2_ADAPTER wrap failed, trying peripheral.find(\"ae2cc_adapter\")")
        ae2Adapter = peripheral.find("ae2cc_adapter")
    end
    -- logging.writeLog("DEBUG", "AE2_ADAPTER wrapped: " .. tostring(ae2Adapter) .. " (name: " .. AE2_ADAPTER .. ")")
    depositor = peripheral.wrap(DEPOSITOR)
    -- logging.writeLog("DEBUG", "DEPOSITOR wrapped: " .. tostring(depositor))
    speaker = peripheral.wrap(SPEAKER_NAME)
    -- logging.writeLog("DEBUG", "SPEAKER wrapped: " .. tostring(speaker))
    monitor = peripheral.wrap(MONITOR)
    -- logging.writeLog("DEBUG", "MONITOR wrapped: " .. tostring(monitor))
    pedestals = {}
    for i, name in ipairs(PEDESTALS) do
        pedestals[i] = peripheral.wrap(name)
        if pedestals[i] then
            -- logging.writeLog("DEBUG", "Pedestal " .. i .. ": " .. name .. " wrapped successfully")
        else
            logging.writeLog("WARN", "Pedestal " .. i .. ": " .. name .. " failed to wrap")
        end
    end
    -- Create name->index mapping
    pedestalIndexByName = {}
    for i, name in ipairs(PEDESTALS) do
        pedestalIndexByName[name] = i
        -- logging.writeLog("DEBUG", "Pedestal mapping: " .. name .. " -> " .. i)
    end
    -- Create object->index mapping
    pedestalObjectToIndex = {}
    for i, ped in ipairs(pedestals) do
        if ped then
            pedestalObjectToIndex[ped] = i
            -- logging.writeLog("DEBUG", "Pedestal object mapping: " .. tostring(ped) .. " -> " .. i)
        end
    end
    -- Ensure monitor is cleared and set text scale
    pcall(monitor.setTextScale, 0.5)
    pcall(monitor.clear)
    -- Lock depositor on startup
    pcall(relayLock.setOutput, "bottom", true)
end

-- AE2 stock cache
local function refreshAE2Cache()
    if not ae2Adapter then
        -- logging.writeLog("DEBUG", "AE2 adapter not available, cannot refresh cache")
        return
    end
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if ok then
        ae2Cache.data = {}
        for _, obj in ipairs(objects) do
            ae2Cache.data[obj.id] = obj.amount or 0
        end
        ae2Cache.timestamp = os.clock()
        -- logging.writeLog("DEBUG", "AE2 cache refreshed: " .. #objects .. " items")
    else
        logging.writeLog("ERROR", "AE2 cache refresh failed: " .. tostring(objects))
    end
end

-- Helper: get AE2 stock for an item name (with caching)
local function getAE2Stock(itemName)
    -- Refresh cache if stale
    if os.clock() - ae2Cache.timestamp > ae2Cache.ttl then
        -- logging.writeLog("DEBUG", "AE2 cache stale, refreshing")
        refreshAE2Cache()
    end

    if not ae2Adapter then
        logging.writeLog("WARN", "AE2 adapter not initialized, returning stock 0")
        return 0
    end

    -- Check cache first
    if ae2Cache.data[itemName] ~= nil then
        local amount = ae2Cache.data[itemName]
        -- logging.writeLog("DEBUG", "getAE2Stock cache hit: " .. itemName .. " -> " .. amount)
        return amount
    end

    -- Fallback to direct query (should not happen if cache is fresh)
    -- logging.writeLog("DEBUG", "getAE2Stock cache miss: " .. itemName .. ", performing direct query")
    local ok, objects = pcall(ae2Adapter.getAvailableObjects)
    if not ok then
        logging.writeLog("ERROR", "AE2 adapter error: " .. tostring(objects))
        return 0
    end

    for _, obj in ipairs(objects) do
        if obj.id == itemName then
            local amount = obj.amount or 0
            -- Update cache
            ae2Cache.data[itemName] = amount
            -- logging.writeLog("DEBUG", "getAE2Stock direct match: " .. itemName .. " -> " .. amount)
            return amount
        end
    end

    -- logging.writeLog("DEBUG", "getAE2Stock no match for " .. itemName)
    ae2Cache.data[itemName] = 0  -- Cache miss as zero to avoid repeated queries
    return 0
end

-- Helper: play noteblock high sound (harp F) - selection confirm
local function playNoteblockSoundHigh()
    -- logging.writeLog("DEBUG", "Playing high sound: harp F")
    if speaker and speaker.playNote then
        pcall(speaker.playNote, "harp", 1.0, 11)  -- harp instrument, volume 1.0, pitch 11 (F note)
    else
        logging.writeLog("WARN", "Speaker not available or missing playNote method")
    end
end

-- Helper: play noteblock low sound (bass F) - go back / cancel
local function playNoteblockSoundLow()
    -- logging.writeLog("DEBUG", "Playing low sound: bass F")
    if speaker and speaker.playNote then
        pcall(speaker.playNote, "bass", 1.0, 11)  -- bass instrument, volume 1.0, pitch 11 (F note)
    else
        logging.writeLog("WARN", "Speaker not available or missing playNote method")
    end
end

-- Legacy alias for backward compatibility (calls high sound)
local function playNoteblockSound()
    logging.writeLog("WARN", "playNoteblockSound() is deprecated, use playNoteblockSoundHigh/Low")
    playNoteblockSoundHigh()
end

-- Get all relay input sides as table side->value
local function getAllRelayInputs()
    if not relayLock then
        logging.writeLog("ERROR", "relayLock is nil in getAllRelayInputs")
        return {}
    end
    local sides = {"bottom", "top", "front", "back", "left", "right"}
    local inputs = {}
    for _, side in ipairs(sides) do
        local ok, val = pcall(relayLock.getInput, side)
        if ok then
            inputs[side] = val
        else
            logging.writeLog("WARN", "getInput failed for side " .. side .. ": " .. tostring(val))
            inputs[side] = nil
        end
    end
    return inputs
end

-- Debug: log all relay input sides
local function debugRelayInputs()
    local inputs = getAllRelayInputs()
    local results = {}
    for side, val in pairs(inputs) do
        if val ~= nil then
            table.insert(results, side .. "=" .. tostring(val))
        else
            table.insert(results, side .. "=error")
        end
    end
    -- logging.writeLog("DEBUG", "Relay inputs: " .. table.concat(results, ", "))
end

-- Lock depositor (set bottom output true)
local function lockDepositor()
    pcall(relayLock.setOutput, "bottom", true)
end

-- Unlock depositor (set bottom output false)
local function unlockDepositor()
    pcall(relayLock.setOutput, "bottom", false)
end

-- Getters for internal state (for other modules)
local function getPedestals() return pedestals or {} end
local function getPedestalIndexByName() return pedestalIndexByName end
local function getPedestalObjectToIndex() return pedestalObjectToIndex end
local function getRelayLock() return relayLock end
local function getAe2Adapter() return ae2Adapter end
local function getDepositor() return depositor end
local function getSpeaker() return speaker end
local function getMonitor() return monitor end

return {
    init = init,
    initPeripherals = initPeripherals,
    getAE2Stock = getAE2Stock,
    refreshAE2Cache = refreshAE2Cache,
    playNoteblockSoundHigh = playNoteblockSoundHigh,
    playNoteblockSoundLow = playNoteblockSoundLow,
    playNoteblockSound = playNoteblockSound,
    getAllRelayInputs = getAllRelayInputs,
    debugRelayInputs = debugRelayInputs,
    lockDepositor = lockDepositor,
    unlockDepositor = unlockDepositor,
    getPedestals = getPedestals,
    getPedestalIndexByName = getPedestalIndexByName,
    getPedestalObjectToIndex = getPedestalObjectToIndex,
    getRelayLock = getRelayLock,
    getAe2Adapter = getAe2Adapter,
    getDepositor = getDepositor,
    getSpeaker = getSpeaker,
    getMonitor = getMonitor
}