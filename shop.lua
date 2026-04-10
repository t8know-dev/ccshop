local basalt = require("basalt")

local PEDESTALS = {
    { name = "display_pedestal_12", item = "minecraft:bricks",             label = "Bricks",             color = colors.red       },
    { name = "display_pedestal_10", item = "minecraft:stone_bricks",       label = "Stone Bricks",       color = colors.lightGray },
    { name = "display_pedestal_11", item = "minecraft:mossy_stone_bricks", label = "Mossy Stone Bricks", color = colors.green     },
}

-- O(1) lookup by peripheral name or item ID
local pedByName   = {}
local pedByItemId = {}

for _, p in ipairs(PEDESTALS) do
    local dev = peripheral.wrap(p.name)
    if not dev then error("Pedestal not found: " .. p.name, 0) end
    dev.setItem(p.item, p.label)
    dev.setItemRendered(true)
    dev.setLabelRendered(true)
    p.dev      = dev
    p.selected = false
    pedByName[p.name]   = p
    pedByItemId[p.item] = p
end

local monitor = peripheral.find("monitor")
if not monitor then error("Monitor not found", 0) end
monitor.setTextScale(0.5)

local relay = peripheral.wrap("redstone_relay_37")
local RELAY_SIDE = "front" -- note block on front face
local function playNote()
    if not relay then
        print("Note: redstone relay not found")
        return
    end
    local ok, err = pcall(relay.setOutput, RELAY_SIDE, true)
    if not ok then
        print("Note: failed to activate relay: " .. tostring(err))
        return
    end
    os.sleep(0.1)
    local ok2, err2 = pcall(relay.setOutput, RELAY_SIDE, false)
    if not ok2 then
        print("Note: failed to deactivate relay: " .. tostring(err2))
    end
end

local W = monitor.getSize()

-- Static UI layout
local frame = basalt.createFrame()
    :setTerm(monitor)
    :setBackground(colors.black)

frame:addLabel():setPosition(1,1):setSize(W,1)
    :setText(" \7 SHOP - SELECT AN ITEM \7")
    :setBackground(colors.gray):setForeground(colors.white)

frame:addLabel():setPosition(1,2):setSize(W,1)
    :setText(" Left / Right click a pedestal to select")
    :setBackground(colors.black):setForeground(colors.gray)

frame:addLabel():setPosition(1,4):setSize(W,1)
    :setText(" AVAILABLE ITEMS:")
    :setBackground(colors.black):setForeground(colors.lightGray)

local listLabels = {}
for i, p in ipairs(PEDESTALS) do
    listLabels[i] = frame:addLabel()
        :setPosition(1, 4+i):setSize(W,1)
        :setText("  " .. i .. ". " .. p.label)
        :setBackground(colors.black):setForeground(colors.white)
end

local selY = 4 + #PEDESTALS + 2

frame:addLabel():setPosition(1, selY-1):setSize(W,1)
    :setText(string.rep("\140", W))
    :setBackground(colors.black):setForeground(colors.gray)

frame:addLabel():setPosition(1, selY):setSize(W,1)
    :setText(" SELECTED ITEM:")
    :setBackground(colors.black):setForeground(colors.lightGray)

-- Dynamic section — updated on each click
local ui = {
    name  = frame:addLabel():setPosition(1,selY+1):setSize(W,1):setText("  (nothing selected)"):setBackground(colors.black):setForeground(colors.gray),
    id    = frame:addLabel():setPosition(1,selY+2):setSize(W,1):setText(""):setBackground(colors.black):setForeground(colors.gray),
    count = frame:addLabel():setPosition(1,selY+3):setSize(W,1):setText(""):setBackground(colors.black):setForeground(colors.gray),
    click = frame:addLabel():setPosition(1,selY+4):setSize(W,1):setText(""):setBackground(colors.black):setForeground(colors.gray),
}

local function setPedestalLabel(p, selected)
    local label = selected and ("[ " .. p.label .. " ]") or p.label
    local ok, err = pcall(p.dev.setItem, p.item, label)
    if not ok then print("Pedestal label error: " .. tostring(err)) end
    p.selected = selected
end

local function refreshList(activeName)
    for i, p in ipairs(PEDESTALS) do
        if p.name == activeName then
            listLabels[i]:setText("  \16 " .. p.label):setBackground(colors.gray):setForeground(colors.white)
        else
            listLabels[i]:setText("  " .. i .. ". " .. p.label):setBackground(colors.black):setForeground(colors.white)
        end
    end
end

local lastSelected = nil

local function onPedestalClick(event, _, arg2)
    local itemId  = type(arg2) == "table" and arg2.name or nil
    local pedData = itemId and pedByItemId[itemId]

    if not pedData then
        -- Item on pedestal not in PEDESTALS table
        ui.name :setText("  (unknown pedestal)"):setForeground(colors.orange)
        ui.id   :setText("  id: " .. tostring(itemId)):setForeground(colors.gray)
        ui.count:setText(""):setForeground(colors.gray)
        ui.click:setText(""):setForeground(colors.gray)
        os.queueEvent("basalt_redraw")
        return
    end

    -- Deselect previous
    if lastSelected and lastSelected ~= pedData.name then
        setPedestalLabel(pedByName[lastSelected], false)
    end

    setPedestalLabel(pedData, true)
    lastSelected = pedData.name

    local isLeft = event == "pedestal_left_click"
    ui.name :setText("  \187 " .. (arg2.displayName or pedData.label)):setForeground(pedData.color)
    ui.id   :setText("  id: " .. itemId):setForeground(colors.gray)
    ui.count:setText("  stack: " .. (arg2.count or 0) .. "x"):setForeground(colors.gray)
    ui.click:setText("  " .. (isLeft and "LMB - selected" or "RMB - preview")):setForeground(isLeft and colors.lime or colors.cyan)

    refreshList(pedData.name)
    playNote()
    os.queueEvent("basalt_redraw")
end

local function eventLoop()
    while true do
        local data  = table.pack(os.pullEvent())
        local event = data[1]
        if event == "pedestal_left_click" or event == "pedestal_right_click" then
            local ok, err = pcall(onPedestalClick, event, data[2], data[3])
            if not ok then print("Click handler error: " .. tostring(err)) end
        end
    end
end

local ok, err = pcall(parallel.waitForAny,
    function() basalt.run() end,
    eventLoop
)
if not ok then print("Fatal: " .. tostring(err)) end
