-- items.lua — Shop categories, materials, quantities, prices

-- Categories
CATEGORIES = {
  { label = "Metals",   item = "minecraft:iron_ingot" },
  { label = "Crystals", item = "ae2:certus_quartz_crystal" },
  { label = "Redstone", item = "minecraft:redstone" },
  { label = "Dyes",     item = "minecraft:blue_dye" },
}

-- Materials
MATERIALS = {
  {
    label    = "Iron Ingot",
    item     = "minecraft:iron_ingot",
    category = "Metals",       -- must match a CATEGORIES label exactly
    minQty   = 64,             -- first quantity option shown; must be in QUANTITIES
    basePrice = 10,            -- price in spurs for minQty units
  },
  {
    label    = "Gold Ingot",
    item     = "minecraft:gold_ingot",
    category = "Metals",
    minQty   = 32,
    basePrice = 20,
  },
  {
    label    = "Certus Quartz Crystal",
    item     = "ae2:certus_quartz_crystal",
    category = "Crystals",
    minQty   = 64,
    basePrice = 5,
  },
  {
    label    = "Redstone",
    item     = "minecraft:redstone",
    category = "Redstone",
    minQty   = 256,
    basePrice = 2,
  },
  {
    label    = "Lapis Lazuli",
    item     = "minecraft:lapis_lazuli",
    category = "Dyes",
    minQty   = 64,
    basePrice = 8,
  },
}

-- Quantity tiers (ordered smallest → largest)
-- Allowed values: 1, 8, 32, 64, 256, 512, 1024, "4k", "16k", "32k"
-- "4k" = 4096, "16k" = 16384, "32k" = 32768
QUANTITIES = { 1, 8, 32, 64, 256, 512, 1024, "4k", "16k", "32k" }

-- Helper: convert quantity entry to numeric value
function quantityToNumber(qty)
  if type(qty) == "number" then return qty end
  if qty == "4k" then return 4096
  elseif qty == "16k" then return 16384
  elseif qty == "32k" then return 32768
  else error("Unknown quantity string: " .. tostring(qty)) end
end

-- Helper: get numeric quantities list
function numericQuantities()
  local nums = {}
  for _, q in ipairs(QUANTITIES) do
    table.insert(nums, quantityToNumber(q))
  end
  return nums
end

-- Helper: find index of a quantity in QUANTITIES (by numeric value)
function findQuantityIndex(num)
  for i, q in ipairs(QUANTITIES) do
    if quantityToNumber(q) == num then return i end
  end
  return nil
end

-- Currency conversion
-- 1 Spur = 1 spur
-- 1 Bevel = 8 spurs
-- 1 Sprocket = 16 spurs
-- 1 Cog = 64 spurs
-- 1 Crown = 8 cogs = 512 spurs
-- 1 Sun = 64 cogs = 4096 spurs

CURRENCY_UNITS = {
    { name = "sun", value = 4096 },
    { name = "crown", value = 512 },
    { name = "cog", value = 64 },
    { name = "sprocket", value = 16 },
    { name = "bevel", value = 8 },
    { name = "spur", value = 1 },
}

-- Convert spurs amount to coin string representation
-- Example: 160 -> "2 sprockets, 2 cogs"
--          2048 -> "4 crowns"
function spursToCoins(spurs)
    local result = {}
    for _, unit in ipairs(CURRENCY_UNITS) do
        if spurs >= unit.value then
            local count = math.floor(spurs / unit.value)
            table.insert(result, count .. " " .. unit.name .. (count > 1 and "s" or ""))
            spurs = spurs % unit.value
        end
    end
    -- Reverse to show smallest units first (as in example)
    local reversed = {}
    for i = #result, 1, -1 do
        table.insert(reversed, result[i])
    end
    return table.concat(reversed, ", ")
end