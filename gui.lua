local basalt = require("basalt")
-- local colors = require("colors") -- use global colors table

-- Find the monitor peripheral and set its scale.
local monitor = peripheral.find("monitor") or error("Monitor not found", 0)
monitor.setTextScale(0.5)

-- Start with a black background.
monitor.setBackgroundColor(colors.black)
monitor.clear()

local W, H = monitor.getSize()
-- Create a BaseFrame that will be drawn on the monitor.
local frame = basalt.createFrame():setTerm(monitor)
frame:setBackground(colors.black)  -- ensure black background for the frame

-- Helper for error handling
local function safeExec(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("Error: " .. tostring(err))
        monitor.setBackgroundColor(colors.red)
        monitor.clear()
        monitor.write(tostring(err))
        os.sleep(3)
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
    end
end
frame.term = monitor

-- Get monitor size and compute button dimensions.
local W, H = monitor.getSize()
local btnW = math.floor(W / 4)
local btnH = math.floor(H / 6)
if btnW < 2 then btnW = 2 end
if btnH < 1 then btnH = 1 end
local btnX = math.floor((W - btnW) / 2) + 1
local btnY = math.floor((H - btnH) / 2) + 1

-- Create a white button with a black down‑arrow.
local arrow = "▼" -- ▼
local button = frame:addButton()
    :setPosition(btnX, btnY)
    :setSize(btnW, btnH)
    :setText(arrow)
    :setBackground(colors.white)
    :setForeground(colors.black)

-- When the button is clicked, flash green for 3 seconds.
button:onClick(function()
    monitor.setBackgroundColor(colors.green)
    monitor.clear()
    os.sleep(3)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
end)

-- Run Basalt’s event loop.
basalt.run()
