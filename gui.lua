  -- Initialize Basalt
  local basalt = require("basalt")

  -- Create a new GUI instance
  local mainGui = basalt.createFrame()

  -- Set up the monitor with 0.5 scale
  mainGui:show()

  Next, let's add the black background and white button:

  -- Add a black background
  mainGui:addLabel("background")
    :setPosition(1, 1)
    :setSize(30, 30)
    :setBackground(colors.black)

  -- Add a white button at the center
  local button = mainGui:addButton()
    :setPosition(15, 14) -- Center position
    :setSize(2, 2)
    :setBackground(colors.white)
    :setForeground(colors.black)
    :setText("^") -- Black arrow pointing down

  -- Set up event handler for button click
  button:onClick(function()
    -- Change screen color to green
    mainGui:setBackground(colors.green)

    -- Wait for 3 seconds
    os.sleep(3)

    -- Revert back to normal background color (black)
    mainGui:setBackground(colors.black)
  end)

  -- Start the Basalt auto-update loop
  basalt.autoUpdate()