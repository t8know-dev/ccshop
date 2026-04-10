-- db.lua — Purchase logging helpers (ndjson format)

local PURCHASES_FILE = "purchases.json"

-- Append one record to purchases.json (ndjson format)
-- record = { timestamp, playerName (nil ok), category, item, qty, price }
function log(record)
  -- Ensure required fields
  if not record.timestamp then record.timestamp = os.epoch("utc") end
  if not record.category or not record.item or not record.qty or not record.price then
    error("db.log: missing required fields")
  end
  local line = textutils.serializeJSON(record)
  local file = io.open(PURCHASES_FILE, "a")
  if not file then
    error("Cannot open purchases file for writing")
  end
  file:write(line, "\n")
  file:close()
end

-- Read all records (returns table of records)
function readAll()
  local records = {}
  local file = io.open(PURCHASES_FILE, "r")
  if not file then return records end  -- file may not exist yet
  for line in file:lines() do
    if line ~= "" then
      local ok, record = pcall(textutils.unserializeJSON, line)
      if ok and record then
        table.insert(records, record)
      else
        print("db.readAll: invalid JSON line: " .. line)
      end
    end
  end
  file:close()
  return records
end

-- Export table
local db = { log = log, readAll = readAll }
return db