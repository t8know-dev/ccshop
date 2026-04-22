-- modules/pedestal.lua — Pedestal rendering and management
-- Exports: init(), setPedestalOptions(), clearPedestals(), setPedestalSelection(),
--          getCurrentOptions(), getCurrentPedestalIndices()

local logging, peripherals, config, state
local pedestals
local PEDESTALS = _G.PEDESTALS or {}
local PARALLEL_RENDERING = _G.PARALLEL_RENDERING or false
local _parallelBusy = false  -- prevent nested parallel.waitForAll calls
local parallel = _G.parallel  -- ensure parallel is available locally

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

-- Helper: update a single pedestal with item and optional label
local function updateSinglePedestal(idx, opt)
    if not pedestals then return end
    if not pedestals[idx] then return end
    local label = opt.count and tostring(opt.count) or opt.label
    if opt.item then
        if label then
            local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
            if not ok then logging.writeLog("WARN", "Pedestal " .. idx .. " setItem with label failed: " .. tostring(err)) end
        else
            local ok, err = pcall(pedestals[idx].setItem, opt.item)
            if not ok then logging.writeLog("WARN", "Pedestal " .. idx .. " setItem failed: " .. tostring(err)) end
        end
        pcall(pedestals[idx].setItemRendered, true)
        if label then
            pcall(pedestals[idx].setLabelRendered, true)
        else
            pcall(pedestals[idx].setLabelRendered, false)
        end
    else
        pcall(pedestals[idx].setItem, "minecraft:air")
        pcall(pedestals[idx].setItemRendered, false)
        pcall(pedestals[idx].setLabelRendered, false)
    end
end

-- Helper: clear a single pedestal
local function clearSinglePedestal(idx)
    -- logging.writeLog("DEBUG", "clearSinglePedestal(" .. idx .. ") started")
    if not pedestals then
        -- logging.writeLog("DEBUG", "clearSinglePedestal: pedestals is nil")
        return
    end
    if not pedestals[idx] then
        -- logging.writeLog("DEBUG", "clearSinglePedestal: pedestals[" .. idx .. "] is nil")
        return
    end
    local ok, err = pcall(pedestals[idx].setItem, "minecraft:air")
    if not ok then
        logging.writeLog("WARN", "Pedestal " .. idx .. " setItem failed: " .. tostring(err))
    else
        -- logging.writeLog("DEBUG", "Pedestal " .. idx .. " setItem succeeded")
    end
    local ok1, err1 = pcall(pedestals[idx].setItemRendered, false)
    local ok2, err2 = pcall(pedestals[idx].setLabelRendered, false)
    if not ok1 then logging.writeLog("WARN", "Pedestal " .. idx .. " setItemRendered failed: " .. tostring(err1)) end
    if not ok2 then logging.writeLog("WARN", "Pedestal " .. idx .. " setLabelRendered failed: " .. tostring(err2)) end
    -- logging.writeLog("DEBUG", "clearSinglePedestal(" .. idx .. ") finished")
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

-- Sequential pedestal update (fallback when parallel rendering is disabled)
local function sequentialPedestalUpdate(options)
    local indices = centerPedestalIndices(#options)
    -- Update used pedestals
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt and pedestals[idx] then
            -- logging.writeLog("DEBUG", "Setting pedestal " .. idx .. " with item=" .. tostring(opt.item) .. " label=" .. tostring(opt.label) .. " count=" .. tostring(opt.count))
            -- Set item with optional label (count takes precedence over label)
            local label = opt.count and tostring(opt.count) or opt.label
            if opt.item then
                if label then
                    -- logging.writeLog("DEBUG", "  setItem: " .. opt.item .. " label: " .. label)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item, label)
                    if not ok then logging.writeLog("WARN", "    setItem with label failed: " .. tostring(err)) end
                else
                    -- logging.writeLog("DEBUG", "  setItem: " .. opt.item)
                    local ok, err = pcall(pedestals[idx].setItem, opt.item)
                    if not ok then logging.writeLog("WARN", "    setItem failed: " .. tostring(err)) end
                end
                local ok2, err2 = pcall(pedestals[idx].setItemRendered, true)
                if not ok2 then logging.writeLog("WARN", "    setItemRendered failed: " .. tostring(err2)) end
                -- Keep label rendering separate (optional)
                if label then
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, true)
                    if not ok3 then logging.writeLog("WARN", "    setLabelRendered failed: " .. tostring(err3)) end
                else
                    local ok3, err3 = pcall(pedestals[idx].setLabelRendered, false)
                    if not ok3 then logging.writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err3)) end
                end
            else
                -- logging.writeLog("DEBUG", "  setItem: nil")
                pcall(pedestals[idx].setItem, "minecraft:air")
                local ok, err = pcall(pedestals[idx].setItemRendered, false)
                if not ok then logging.writeLog("WARN", "    setItemRendered(false) failed: " .. tostring(err)) end
                local ok2, err2 = pcall(pedestals[idx].setLabelRendered, false)
                if not ok2 then logging.writeLog("WARN", "    setLabelRendered(false) failed: " .. tostring(err2)) end
            end
        end
    end
    -- Clear unused pedestals
    for i = 1, #PEDESTALS do
        local used = false
        for _, idx in ipairs(indices) do
            if i == idx then used = true break end
        end
        if not used and pedestals[i] then
            -- logging.writeLog("DEBUG", "Clearing unused pedestal " .. i)
            pcall(pedestals[i].setItem, "minecraft:air")
            local ok1, err1 = pcall(pedestals[i].setItemRendered, false)
            local ok2, err2 = pcall(pedestals[i].setLabelRendered, false)
            if not ok1 then logging.writeLog("WARN", "  setItemRendered(false) failed: " .. tostring(err1)) end
            if not ok2 then logging.writeLog("WARN", "  setLabelRendered(false) failed: " .. tostring(err2)) end
        end
    end
end

-- Parallel version of setPedestalOptions
local function setPedestalOptionsParallel(options)
    -- If parallel rendering disabled, fallback to sequential
    -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: " .. #options .. " options, PARALLEL_RENDERING=" .. tostring(PARALLEL_RENDERING))
    if PARALLEL_RENDERING == false then
        sequentialPedestalUpdate(options)
        return
    end
    -- Same state tracking as original
    local indices = centerPedestalIndices(#options)
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
        end
    end
    -- Update state
    state.updateState({
        currentOptions = currentOptions,
        currentPedestalIndices = currentPedestalIndices
    })

    -- Create tasks for used pedestals
    local updateTasks = {}
    for i, idx in ipairs(indices) do
        local opt = options[i]
        if opt then
            table.insert(updateTasks, function()
                local taskOk, taskErr = pcall(updateSinglePedestal, idx, opt)
                if not taskOk then
                    logging.writeLog("WARN", "updateSinglePedestal(" .. idx .. ") failed: " .. tostring(taskErr))
                end
            end)
        end
    end

    -- Create tasks for unused pedestals
    local clearTasks = {}
    local usedLookup = {}
    for _, idx in ipairs(indices) do usedLookup[idx] = true end
    for i = 1, #PEDESTALS do
        if not usedLookup[i] and pedestals[i] then
            table.insert(clearTasks, function()
                local taskOk, taskErr = pcall(clearSinglePedestal, i)
                if not taskOk then
                    logging.writeLog("WARN", "clearSinglePedestal(" .. i .. ") failed: " .. tostring(taskErr))
                end
            end)
        end
    end

    -- Execute tasks in parallel
    -- logging.writeLog("DEBUG", "Created " .. #updateTasks .. " update tasks, " .. #clearTasks .. " clear tasks")
    local allTasks = {}
    for _, task in ipairs(updateTasks) do table.insert(allTasks, task) end
    for _, task in ipairs(clearTasks) do table.insert(allTasks, task) end

    if #allTasks > 0 then
        -- logging.writeLog("DEBUG", "Executing " .. #allTasks .. " tasks in parallel")
        -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: parallel = " .. tostring(parallel))

        -- Prevent nested parallel.waitForAll calls
        -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: _parallelBusy=" .. tostring(_parallelBusy))
        if _parallelBusy then
            logging.writeLog("WARN", "Parallel busy, falling back to sequential update")
            sequentialPedestalUpdate(options)
            return
        end

        _parallelBusy = true
        local parallelCompleted = false
        local timeout = 2  -- seconds timeout (reduced from 5)

        -- Timeout task
        local timeoutTask = function()
            -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: Timeout task started")
            os.sleep(timeout)
            -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: Timeout task after sleep")
            if not parallelCompleted then
                logging.writeLog("WARN", "Parallel update timeout after " .. timeout .. " seconds, falling back to sequential")
                -- Ensure parallel busy flag is cleared so other operations can continue
                _parallelBusy = false
            end
        end

        -- Main parallel execution task
        local parallelTask = function()
            -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: Parallel task started")
            local ok, err = pcall(parallel.waitForAll, unpack(allTasks))
            -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: parallel.waitForAll returned, ok=" .. tostring(ok) .. ", err=" .. tostring(err))
            parallelCompleted = true
            if not ok then
                logging.writeLog("WARN", "Parallel execution failed: " .. tostring(err) .. ", executing sequentially")
                for _, task in ipairs(allTasks) do
                    local taskOk, taskErr = pcall(task)
                    if not taskOk then
                        logging.writeLog("WARN", "Fallback task failed: " .. tostring(taskErr))
                    end
                end
            else
                -- logging.writeLog("DEBUG", "Parallel pedestal update completed successfully")
            end
        end

        -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: Starting parallel.waitForAny")
        -- Run both tasks in parallel: timeout and parallel execution
        local ok, err = pcall(parallel.waitForAny, timeoutTask, parallelTask)
        -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: parallel.waitForAny returned, ok=" .. tostring(ok) .. ", err=" .. tostring(err))
        if not ok then
            logging.writeLog("WARN", "parallel.waitForAny failed: " .. tostring(err))
            _parallelBusy = false
        else
            _parallelBusy = false
        end
        -- logging.writeLog("DEBUG", "setPedestalOptionsParallel: parallelCompleted = " .. tostring(parallelCompleted))

        -- If parallel didn't complete (timeout triggered), run sequential fallback
        if not parallelCompleted then
            -- logging.writeLog("DEBUG", "Running sequential fallback after timeout")
            sequentialPedestalUpdate(options)
        end
    end
end

-- Helper: clear pedestals (remove items and labels)
local function clearPedestals()
    -- logging.writeLog("DEBUG", "clearPedestals called")
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
    -- Create clear tasks for all pedestals
    local clearTasks = {}
    for i = 1, #PEDESTALS do
        if pedestals[i] then
            -- logging.writeLog("DEBUG", "Clearing pedestal " .. i)
            table.insert(clearTasks, function()
                local taskOk, taskErr = pcall(clearSinglePedestal, i)
                if not taskOk then
                    logging.writeLog("WARN", "clearSinglePedestal(" .. i .. ") failed: " .. tostring(taskErr))
                end
            end)
        end
    end

    -- Execute in parallel with fallback if PARALLEL_RENDERING is enabled
    local parallelRendering = PARALLEL_RENDERING
    -- logging.writeLog("DEBUG", "clearPedestals: PARALLEL_RENDERING = " .. tostring(PARALLEL_RENDERING) .. ", parallelRendering = " .. tostring(parallelRendering))
    if #clearTasks > 0 then
        if parallelRendering == false then
            -- logging.writeLog("DEBUG", "PARALLEL_RENDERING is false, executing " .. #clearTasks .. " clear tasks sequentially")
            for _, task in ipairs(clearTasks) do
                local ok, err = pcall(task)
                if not ok then
                    logging.writeLog("WARN", "Sequential clear task failed: " .. tostring(err))
                end
            end
            -- logging.writeLog("DEBUG", "Sequential clear completed")
        else
            -- logging.writeLog("DEBUG", "Executing " .. #clearTasks .. " clear tasks in parallel")
            -- logging.writeLog("DEBUG", "parallel = " .. tostring(parallel))

            -- Prevent nested parallel.waitForAll calls
            -- logging.writeLog("DEBUG", "clearPedestals: _parallelBusy=" .. tostring(_parallelBusy))
            if _parallelBusy then
                logging.writeLog("WARN", "Parallel busy, falling back to sequential clear")
                for _, task in ipairs(clearTasks) do
                    local ok, err = pcall(task)
                    if not ok then
                        logging.writeLog("WARN", "Sequential clear task failed: " .. tostring(err))
                    end
                end
                -- logging.writeLog("DEBUG", "Sequential clear completed (fallback due to busy)")
                return
            end

            -- logging.writeLog("DEBUG", "clearPedestals: Setting _parallelBusy = true")
            _parallelBusy = true
            -- logging.writeLog("DEBUG", "clearPedestals: _parallelBusy set, clearTasks count = " .. #clearTasks)
            local parallelCompleted = false
            local timeout = 2  -- seconds timeout (reduced from 5)

            -- Timeout task
            local timeoutTask = function()
                -- logging.writeLog("DEBUG", "Timeout task started")
                os.sleep(timeout)
                -- logging.writeLog("DEBUG", "Timeout task after sleep")
                if not parallelCompleted then
                    logging.writeLog("WARN", "Parallel clear timeout after " .. timeout .. " seconds, falling back to sequential")
                    -- Ensure parallel busy flag is cleared so other operations can continue
                    _parallelBusy = false
                    -- logging.writeLog("DEBUG", "Timeout task cleared _parallelBusy flag")
                end
            end

            -- Main parallel execution task
            local parallelTask = function()
                -- logging.writeLog("DEBUG", "Parallel task started")
                local ok, err = pcall(parallel.waitForAll, unpack(clearTasks))
                -- logging.writeLog("DEBUG", "Parallel.waitForAll returned, ok=" .. tostring(ok) .. ", err=" .. tostring(err))
                parallelCompleted = true
                if not ok then
                    logging.writeLog("WARN", "Parallel execution failed: " .. tostring(err) .. ", executing sequentially")
                    for _, task in ipairs(clearTasks) do
                        local taskOk, taskErr = pcall(task)
                        if not taskOk then
                            logging.writeLog("WARN", "Fallback task failed: " .. tostring(taskErr))
                        end
                    end
                else
                    -- logging.writeLog("DEBUG", "Parallel clear completed successfully")
                end
            end

            -- logging.writeLog("DEBUG", "clearPedestals: About to call parallel.waitForAny")
            -- logging.writeLog("DEBUG", "Starting parallel.waitForAny with timeout and parallel tasks")
            -- Run both tasks in parallel: timeout and parallel execution
            local ok, err = pcall(parallel.waitForAny, timeoutTask, parallelTask)
            -- logging.writeLog("DEBUG", "parallel.waitForAny returned, ok=" .. tostring(ok) .. ", err=" .. tostring(err))
            if not ok then
                logging.writeLog("WARN", "parallel.waitForAny failed: " .. tostring(err))
                _parallelBusy = false
            else
                _parallelBusy = false
            end
            -- logging.writeLog("DEBUG", "parallelCompleted = " .. tostring(parallelCompleted))

            -- If parallel didn't complete (timeout triggered), run sequential fallback
            if not parallelCompleted then
                -- logging.writeLog("DEBUG", "Running sequential fallback after timeout")
                for _, task in ipairs(clearTasks) do
                    local taskOk, taskErr = pcall(task)
                    if not taskOk then
                        logging.writeLog("WARN", "Fallback task failed: " .. tostring(taskErr))
                    end
                end
                -- logging.writeLog("DEBUG", "Sequential fallback completed")
            end
        end
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
    -- Update pedestals in parallel
    setPedestalOptionsParallel(options)
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