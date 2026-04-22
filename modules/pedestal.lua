-- modules/pedestal.lua — Pedestal rendering and management
-- Exports: init(), setPedestalOptions(), clearPedestals(), setPedestalSelection(),
--          getCurrentOptions(), getCurrentPedestalIndices()

local logging, peripherals, config, state
local pedestals
local PEDESTALS = _G.PEDESTALS or {}
local parallel = _G.parallel

-- Initialize module with dependencies
local function init(loggingModule, peripheralsModule, configModule, stateModule)
    logging = loggingModule
    peripherals = peripheralsModule
    config = configModule
    state = stateModule
    pedestals = peripherals.getPedestals()
    if not pedestals then
        logging.writeLog("WARN", "pedestals is nil from peripherals.getPedestals(), using empty table")
        pedestals = {}
    end
end

-- Set pedestal label with selection brackets
local function setPedestalSelection(pedestalIdx, selected)
    -- logging.writeLog("DEBUG", "setPedestalSelection: idx=" .. pedestalIdx .. ", selected=" .. tostring(selected))
    if not pedestals then
        -- logging.writeLog("DEBUG", "  pedestals not initialized")
        return
    end
    local opt = state.getState("currentOptions")[pedestalIdx]
    if not opt or not pedestals[pedestalIdx] then
        -- logging.writeLog("DEBUG", "  No option or pedestal for index " .. pedestalIdx)
        return
    end

    local label = opt.count and tostring(opt.count) or opt.label
    if selected then
        label = "[ " .. label .. " ]"
    end

    -- logging.writeLog("DEBUG", "  Setting pedestal " .. pedestalIdx .. " label: " .. label)
    local ok, err = pcall(pedestals[pedestalIdx].setItem, opt.item, label)
    if not ok then
        logging.writeLog("WARN", "  setItem with label failed: " .. tostring(err))
    end
end

-- Helper: center options across available pedestals
-- Given number of options (<= #PEDESTALS), returns table of pedestal indices to use
local function centerPedestalIndices(numOptions)
    local total = #PEDESTALS
    if numOptions > total then numOptions = total end
    local start = math.floor((total - numOptions) / 2) + 1
    local indices = {}
    for i = start, start + numOptions - 1 do
        table.insert(indices, i)
    end
    -- logging.writeLog("DEBUG", "centerPedestalIndices: numOptions=" .. numOptions .. " total=" .. total .. " start=" .. start .. " indices: " .. table.concat(indices, ","))
    return indices
end

-- Update pedestals with centered options (parallel)
-- Each pedestal runs in its own coroutine for better responsiveness.
-- os.sleep(0) yields control so the top-level scheduler can interleave.
local function updatePedestals(options)
    local indices = centerPedestalIndices(#options)
    local tasks = {}

    -- Add tasks for used pedestals
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt and pedestals[idx] then
            local label = opt.count and tostring(opt.count) or opt.label
            table.insert(tasks, function()
                if opt.item then
                    if label then
                        local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
                        if not ok then logging.writeLog("WARN", "    setItem with label failed: " .. tostring(err)) end
                    else
                        local ok, err = pcall(pedestals[idx].setItem, opt.item)
                        if not ok then logging.writeLog("WARN", "    setItem failed: " .. tostring(err)) end
                    end
                    local ok2, err2 = pcall(pedestals[idx].setItemRendered, true)
                    if not ok2 then logging.writeLog("WARN", "    setItemRendered failed: " .. tostring(err2)) end
                    if label then
                        local ok3, err3 = pcall(pedestals[idx].setLabelRendered, true)
                        if not ok3 then logging.writeLog("WARN", "    setLabelRendered failed: " .. tostring(err3)) end
                    else
                        local ok3, err3 = pcall(pedestals[idx].setLabelRendered, false)
                        if not ok3 then logging.writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err3)) end
                    end
                else
                    pcall(pedestals[idx].setItem, "minecraft:air")
                    local ok, err = pcall(pedestals[idx].setItemRendered, false)
                    if not ok then logging.writeLog("WARN", "    setItemRendered(false) failed: " .. tostring(err)) end
                    local ok2, err2 = pcall(pedestals[idx].setLabelRendered, false)
                    if not ok2 then logging.writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err2)) end
                end
                os.sleep(0)  -- Yield to allow interleaving
            end)
        end
    end

    -- Add tasks for unused pedestals (clear them)
    for i = 1, #PEDESTALS do
        local used = false
        for _, idx in ipairs(indices) do
            if i == idx then used = true break end
        end
        if not used and pedestals[i] then
            table.insert(tasks, function()
                pcall(pedestals[i].setItem, "minecraft:air")
                local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
                local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
                if not ok1 then logging.writeLog("WARN", "  setItemRendered(false) failed: " .. tostring(err1)) end
                if not ok2 then logging.writeLog("WARN", "  setLabelRendered(false) failed: " .. tostring(err2)) end
                os.sleep(0)  -- Yield to allow interleaving
            end)
        end
    end

    -- Run all pedestal operations in parallel
    if #tasks > 0 then
        parallel.waitForAll(table.unpack(tasks))
    end
end

-- Helper: clear pedestals (remove items and labels) in parallel
local function clearPedestals()
    if not pedestals then
        logging.writeLog("WARN", "pedestals not initialized, skipping clear")
        return
    end
    -- Clear state tracking
    state.updateState({
        currentOptions = {},
        currentPedestalIndices = {},
        lastSelectedPedestal = nil
    })
    -- Clear all pedestals in parallel
    local tasks = {}
    for i = 1, #PEDESTALS do
        if pedestals[i] then
            table.insert(tasks, function()
                local ok, err = pcall(pedestals[i].setItem, "minecraft:air")
                if not ok then
                    logging.writeLog("WARN", "Pedestal " .. i .. " setItem failed: " .. tostring(err))
                end
                local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
                local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
                if not ok1 then logging.writeLog("WARN", "Pedestal " .. i .. " setItemRendered failed: " .. tostring(err1)) end
                if not ok2 then logging.writeLog("WARN", "Pedestal " .. i .. " setLabelRendered failed: " .. tostring(err2)) end
                os.sleep(0)  -- Yield to allow interleaving
            end)
        end
    end
    if #tasks > 0 then
        parallel.waitForAll(table.unpack(tasks))
    end
end

-- Helper: update pedestals with items and labels
local function setPedestalOptions(options)
    -- options: array of {item=, label=, count=}
    logging.writeLog("INFO", "setPedestalOptions called with " .. #options .. " options")
    if not pedestals then
        logging.writeLog("WARN", "pedestals not initialized, skipping setPedestalOptions")
        return
    end
    for i, opt in ipairs(options) do
        -- logging.writeLog("DEBUG", "  option " .. i .. ": item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
    end
    local indices = centerPedestalIndices(#options)
    -- Update state tracking
    local currentOptions = {}
    local currentPedestalIndices = {}
    for i, idx in ipairs(indices) do
        currentPedestalIndices[idx] = true
        if options[i] then
            currentOptions[idx] = {
                item = options[i].item,
                label = options[i].label,
                count = options[i].count
            }
            -- logging.writeLog("DEBUG", "State tracking: pedestal " .. idx .. " -> count=" .. tostring(options[i].count))
        end
    end
    -- logging.writeLog("DEBUG", "Current pedestal indices: " .. table.concat(indices, ","))
    state.updateState({
        currentOptions = currentOptions,
        currentPedestalIndices = currentPedestalIndices
    })
    -- Update pedestals
    updatePedestals(options)
end

-- Getters for current options (for other modules)
local function getCurrentOptions()
    return state.getState("currentOptions")
end

local function getCurrentPedestalIndices()
    return state.getState("currentPedestalIndices")
end

return {
    init = init,
    setPedestalOptions = setPedestalOptions,
    clearPedestals = clearPedestals,
    setPedestalSelection = setPedestalSelection,
    getCurrentOptions = getCurrentOptions,
    getCurrentPedestalIndices = getCurrentPedestalIndices
}