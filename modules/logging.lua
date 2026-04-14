-- modules/logging.lua — Logging utilities for CC:Tweaked shop
-- Exports: writeLog(level, msg)

-- Note: Requires LOG_LEVEL global defined in config.lua
local LOG_FILE = "/ccshop/shop_debug.log"
local LOG_LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
local CURRENT_LOG_LEVEL = LOG_LEVELS[LOG_LEVEL] or LOG_LEVELS.INFO

local function writeLog(level, msg)
    -- Support old signature: single argument defaults to INFO
    if msg == nil then
        msg = level
        level = "INFO"
    end
    if LOG_LEVELS[level] < CURRENT_LOG_LEVEL then return end

    local t = os.date("*t")
    local ts = string.format("[%04d-%02d-%02d %02d:%02d:%02d]",
        t.year, t.month, t.day, t.hour, t.min, t.sec)
    local line = ts .. " [" .. level .. "] " .. msg
    local prev
    local ok1, err1 = pcall(function() prev = term.redirect(term.native()) end)
    if ok1 and prev then
        print(line)
        pcall(term.redirect, prev)
    else
        -- Fallback: just print to current terminal
        print(line)
    end
    local f = fs.open(LOG_FILE, "a")
    if f then
        f.writeLine(line)
        f.close()
    end
end

return {
    writeLog = writeLog
}