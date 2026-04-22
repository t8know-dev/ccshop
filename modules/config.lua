-- modules/config.lua — Enhanced configuration loading and validation
-- Exports: loadConfig(), validateAll(), get(key), getMsg(key)

-- Load original configuration files (define globals)
local function loadConfig()
    -- Already loaded by main script? We'll load anyway; dofile only runs once per chunk.
    dofile("/ccshop/config.lua")
    dofile("/ccshop/items.lua")
end

-- Validate all configuration (moved from shop.lua)
local function validateAll()
    -- 1. Validate peripherals
    local ok, err = validatePeripherals()
    if not ok then
        error("Peripheral validation failed: " .. err)
    end

    -- 2. Every MATERIALS[i].category exists in CATEGORIES labels
    local categoryLabels = {}
    for _, cat in ipairs(CATEGORIES) do
        categoryLabels[cat.label] = true
    end
    for _, mat in ipairs(MATERIALS) do
        if not categoryLabels[mat.category] then
            error("Material '" .. mat.label .. "' references unknown category '" .. mat.category .. "'")
        end
    end

    -- 3. Every MATERIALS[i].minQty exists in the numeric expansion of QUANTITIES
    local quantitySet = {}
    for _, q in ipairs(QUANTITIES) do
        quantitySet[quantityToNumber(q)] = true
    end
    for _, mat in ipairs(MATERIALS) do
        if not quantitySet[mat.minQty] then
            error("Material '" .. mat.label .. "' minQty " .. mat.minQty .. " not in QUANTITIES")
        end
    end

    -- 4. QUANTITIES contains no unknown string values (only "4k", "16k", "32k" allowed as strings)
    for _, q in ipairs(QUANTITIES) do
        if type(q) == "string" then
            if q ~= "4k" and q ~= "16k" and q ~= "32k" then
                error("QUANTITIES contains unknown string value: " .. q)
            end
        elseif type(q) ~= "number" then
            error("QUANTITIES contains non‑numeric, non‑string value: " .. type(q))
        end
    end

    -- 5. basePrice > 0 for all materials
    for _, mat in ipairs(MATERIALS) do
        if mat.basePrice <= 0 then
            error("Material '" .. mat.label .. "' basePrice must be > 0")
        end
    end

    -- 6. At least one category and one material defined
    if #CATEGORIES == 0 then
        error("No categories defined")
    end
    if #MATERIALS == 0 then
        error("No materials defined")
    end

    return true
end

-- Helper to get a configuration value
local function get(key)
    local value = _G[key]
    -- Debug logging for MSG
    if key == "MSG" then
        local logging = _G.logging  -- May not be available
        if logging and logging.writeLog then
            -- pcall(logging.writeLog, "DEBUG", "config.get('MSG') called, value is " .. tostring(value))
        end
    end
    return value
end

-- Helper to get a message string
local function getMsg(key)
    local msgTable = get("MSG")
    return msgTable and msgTable[key]
end

return {
    loadConfig = loadConfig,
    validateAll = validateAll,
    get = get,
    getMsg = getMsg
}