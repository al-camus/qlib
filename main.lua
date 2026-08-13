local util = require "qlib.util"
local conf = require "qlib.conf"
local task = require "qlib.task"
local fuel = require "qlib.fuel"
local mvmt = require "qlib.mvmt"

local VERSION = "rcGPT v1"
local turtleLabel = os.getComputerLabel() or "Unnamed Turtle"

local COLOR_BACKGROUND = colors.black
local COLOR_PRIMARY = colors.red
local COLOR_TEXT = colors.white
local COLOR_SUCCESS = colors.green
local COLOR_WARNING = colors.yellow
local COLOR_ERROR = colors.red
local COLOR_MUTED = colors.lightGray

local GPS_CHECK_INTERVAL = 1
local GPS_CHECK_TIMEOUT = 0.25
local GPS_MISS_LIMIT = 2

local max = math.max
local min = math.min
local floor = math.floor

local width, height = term.getSize()
local running = true
local digAllowed = false
local fuelDetailsOpen = false
local statusMessage = "Ready."
local statusColor = COLOR_TEXT
local gpsMissCount = 0
local gpsTimer

local function updateTermSize()
    width, height = term.getSize()
end

local function resetColors()
    term.setBackgroundColor(COLOR_BACKGROUND)
    term.setTextColor(COLOR_TEXT)
end

local function clearScreen()
    resetColors()
    term.clear()
    term.setCursorPos(1, 1)
end

local function applyColorConfiguration()
    local function configuredColor(name, fallback)
        local colorName = conf.get("gui.colors." .. name)
        return type(colorName) == "string" and colors[colorName] or fallback
    end

    COLOR_BACKGROUND = configuredColor("background", COLOR_BACKGROUND)
    COLOR_PRIMARY = configuredColor("primary", COLOR_PRIMARY)
    COLOR_TEXT = configuredColor("text", COLOR_TEXT)
    COLOR_SUCCESS = configuredColor("success", COLOR_SUCCESS)
    COLOR_WARNING = configuredColor("warning", COLOR_WARNING)
    COLOR_ERROR = configuredColor("error", COLOR_ERROR)
end

local function trim(value)
    return util.trimString(tostring(value or ""))
end

local function clipText(text, maxWidth)
    text = tostring(text or "")

    if maxWidth <= 0 then
        return ""
    elseif #text <= maxWidth then
        return text
    elseif maxWidth <= 3 then
        return text:sub(1, maxWidth)
    end

    return text:sub(1, maxWidth - 3) .. "..."
end

-- Status messages are kept as returned by their source. The UI only trims
-- and fits them; translating diagnostics here was lossy and duplicated them.
local function fitMessage(message, maxWidth)
    if maxWidth <= 0 then
        return ""
    elseif #message <= maxWidth then
        return message
    elseif maxWidth <= 3 then
        return message:sub(1, maxWidth)
    end

    local shortened = message:sub(1, maxWidth - 2)
    local lastSpace = shortened:match("^.*()%s")

    if lastSpace and lastSpace > 5 then
        shortened = shortened:sub(1, lastSpace - 1)
    end

    return shortened .. ".."
end

local function formatScaled(value, scale, suffix)
    local amount = value / scale
    local whole = floor(amount)

    if amount == whole then
        return tostring(whole) .. suffix
    end

    return string.format("%.1f%s", amount, suffix)
end

local function formatFuelLimit(value)
    if value == math.huge then
        return "unlimited"
    elseif value >= 1000000 then
        return formatScaled(value, 1000000, "M")
    elseif value >= 1000 then
        return formatScaled(value, 1000, "K")
    end

    return tostring(value)
end

local function getLayout()
    updateTermSize()

    local verticalUpRow = min(4, max(height - 9, 2))
    local verticalDownRow = verticalUpRow + 4
    local cardinalStart = max(1, width - 14)

    return {
        moveCenter = max(4, width - 7),
        verticalCenter = max(4, width - 1),
        cardinalStart = cardinalStart,
        leftWidth = max(cardinalStart - 2, 1),
        verticalUpRow = verticalUpRow,
        forwardRow = verticalUpRow + 1,
        turnRow = verticalUpRow + 2,
        backwardRow = verticalUpRow + 3,
        verticalDownRow = verticalDownRow,
        cardinalRow = min(verticalDownRow + 2, height - 3),
        dividerRow = height - 1,
        commandRow = height
    }
end

local function setStatus(message, color)
    statusMessage = trim(message)
    statusColor = color or COLOR_TEXT
end

local function setSuccess(message)
    setStatus(message, COLOR_SUCCESS)
end

local function setWarning(message)
    setStatus(message, COLOR_WARNING)
end

local function setError(message)
    setStatus(message, COLOR_ERROR)
end

local function addHitbox(buttons, x1, y1, x2, y2, action)
    local box = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action }
    buttons[#buttons + 1] = box
    return box
end

local function hit(box, x, y)
    return box and x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2
end

local function writeAt(x, y, text, color, maxWidth)
    if x > width or y < 1 or y > height then
        return ""
    end

    x = max(1, x)
    local available = width - x + 1
    text = clipText(text, min(maxWidth or available, available))

    if text == "" then
        return text
    end

    term.setCursorPos(x, y)
    term.setTextColor(color or COLOR_TEXT)
    term.write(text)
    return text
end

local function addButton(buttons, x, y, label, action, color)
    x = max(1, min(x, width))
    local visible = writeAt(x, y, label, color or COLOR_PRIMARY)
    return addHitbox(buttons, x, y, min(x + #visible - 1, width), y, action)
end

local function addArrowButton(buttons, center, row, glyph, action)
    center = max(1, min(center, width))
    writeAt(center, row, glyph, COLOR_PRIMARY)
    addHitbox(buttons, max(center - 1, 1), row, min(center + 1, width), row, action)
end

local function restartGpsTimer()
    gpsTimer = os.startTimer(GPS_CHECK_INTERVAL)
end

local function gpsAvailable()
    if type(gps) ~= "table" or type(gps.locate) ~= "function" then
        return false
    end

    local ok, x, y, z = pcall(gps.locate, GPS_CHECK_TIMEOUT, false)
    return ok and x ~= nil and y ~= nil and z ~= nil
end

local function verifyGpsCalibration()
    -- Do not probe GPS until a calibration exists to invalidate.
    if not task.isCalibrated() or gpsAvailable() then
        gpsMissCount = 0
        return true
    end

    gpsMissCount = gpsMissCount + 1
    if gpsMissCount < GPS_MISS_LIMIT then
        return true
    end

    gpsMissCount = 0
    task.invalidateCalibration()

    if task.save() then
        setWarning("GPS lost. Recalibrate.")
    else
        setWarning("GPS lost; save failed.")
    end

    return false
end

local function resetAndSave(message)
    task.reset()

    if task.save() then
        return true, message
    end

    return true, message:gsub("%.$", "") .. "; save failed."
end

local function initializeRuntime()
    local configReady, configMessage = conf.initialize()
    if not configReady then
        return false, "Configuration initialization failed: " .. tostring(configMessage)
    end

    applyColorConfiguration()

    task.setStoragePath(conf.get("paths.taskState", ".rcgpt/task.state"))
    digAllowed = conf.get("movement.defaultDig", false) == true

    if conf.get("startup.loadTaskState", true) ~= true then
        task.reset()
        return true, "Fresh state."
    end

    local statePath = task.getStoragePath()
    if not fs.exists(statePath) and not fs.exists(statePath .. ".bak") then
        return resetAndSave("Fresh state.")
    end

    local loaded, loadMessage = task.load()
    if loaded then
        return true, loadMessage or "State loaded."
    end

    return resetAndSave("Invalid state reset.")
end

local function movementAction(direction, count)
    return { type = "move", direction = direction, count = count or 1 }
end

local function faceAction(direction)
    return { type = "face", direction = direction }
end

local function simpleAction(actionType)
    return { type = actionType }
end

local function isAbsoluteDirection(direction)
    return direction == "north" or direction == "east" or direction == "south" or direction == "west"
end

local function isFiniteNumber(count)
    return type(count) == "number" and count == count and count ~= math.huge and count ~= -math.huge
end

local function executeMovement(direction, count)
    count = count or 1
    if not isFiniteNumber(count) then
        return false, "Invalid move count."
    end

    count = floor(count)
    if count < 1 then
        return false, "Invalid move count."
    end

    if isAbsoluteDirection(direction) and not task.isCalibrated() then
        return false, "Calibrate first."
    end

    local finalWarning
    for step = 1, count do
        local success, message = mvmt.go(direction, digAllowed)
        if not success then
            local reason = trim(message or "Move failed.")
            if count == 1 then
                return false, reason
            end

            return false, step .. "/" .. count .. ": " .. reason
        end

        if message then
            finalWarning = trim(message)
        end
    end

    if finalWarning then
        return true, finalWarning, true
    elseif count == 1 then
        return true, "Moved " .. direction .. ".", false
    end

    return true, "Moved " .. direction .. " x" .. count .. ".", false
end

local function reportOperation(success, message, successMessage, errorMessage)
    if not success then
        setError(message or errorMessage)
        return false
    end

    if message then
        setWarning(message)
    else
        setSuccess(successMessage)
    end

    return true
end

local function setDigMode(enabled)
    digAllowed = enabled == true
    setSuccess(digAllowed and "Dig mode enabled." or "Dig mode disabled.")
end

local function executeAction(action)
    if type(action) ~= "table" or type(action.type) ~= "string" then
        setError("Invalid action.")
        return false
    end

    local actionType = action.type

    if actionType == "toggle_fuel_details" then
        fuelDetailsOpen = not fuelDetailsOpen
        return true
    elseif actionType == "move" then
        local success, message, warning = executeMovement(action.direction, action.count)
        if not success then
            setError(message)
            return false
        end

        (warning and setWarning or setSuccess)(message)
        return true
    elseif actionType == "face" then
        if not task.isCalibrated() then
            setError("Calibrate first.")
            return false
        end

        local success, message = mvmt.face(action.direction)
        return reportOperation(success, message, "Facing " .. tostring(action.direction) .. ".", "Rotate failed.")
    elseif actionType == "toggle_dig" then
        setDigMode(not digAllowed)
        return true
    elseif actionType == "set_dig" then
        setDigMode(action.enabled)
        return true
    elseif actionType == "calibrate" then
        if task.isCalibrated() then
            setSuccess("Already calibrated.")
            return true
        end

        local success, message = mvmt.calibrate(digAllowed)
        if success then
            gpsMissCount = 0
        end

        return reportOperation(success, message, "GPS calibrated.", "Calibration failed.")
    elseif actionType == "reset_position" then
        task.setPosition(0, 0, 0)

        if task.save() then
            setSuccess("Relative position reset.")
        else
            setWarning("Relative position reset; save failed.")
        end

        return true
    elseif actionType == "refuel" then
        local success, value1, value2 = fuel.refuel(action.percent)
        if not success then
            setError(value1 or "Refuel failed.")
            return false
        end

        local fuelAdded, itemsUsed = value1 or 0, value2 or 0
        if fuelAdded == math.huge then
            setSuccess("Fuel unlimited.")
        elseif itemsUsed > 0 then
            setSuccess("Refueled +" .. fuelAdded .. ".")
        else
            setSuccess("Fuel already sufficient.")
        end

        return true
    elseif actionType == "save" or actionType == "load" then
        local operation = actionType == "save" and task.save or task.load
        local success, message = operation()
        local label = actionType == "save" and "State saved." or "State loaded."
        local fallback = actionType == "save" and "State save failed." or "State load failed."

        if success and message then
            setWarning(message)
        elseif success then
            setSuccess(label)
        else
            setError(message or fallback)
        end

        return success
    elseif actionType == "status" then
        local fuelState = fuel.getState()
        local fuelText = fuelState.unlimited and "INF" or tostring(fuelState.level)
        setSuccess(task.getPosition():strXYZ() .. " " .. task.getRotation() .. " F:" .. fuelText)
        return true
    elseif actionType == "quit" then
        running = false
        return true
    end

    setError("Unknown action.")
    return false
end

local movementCommands = {
    f = "forward", forward = "forward",
    b = "back", back = "back", backward = "back",
    u = "up", up = "up",
    d = "down", down = "down",
    l = "left", left = "left",
    r = "right", right = "right",
    n = "north", north = "north",
    s = "south", south = "south",
    e = "east", east = "east",
    w = "west", west = "west"
}

local booleanValues = {
    on = true, ["true"] = true, yes = true, ["1"] = true,
    off = false, ["false"] = false, no = false, ["0"] = false
}

local simpleCommands = {
    calibrate = "calibrate", cal = "calibrate",
    save = "save", load = "load",
    status = "status", where = "status",
    help = "help", ["?"] = "help",
    quit = "quit", exit = "quit"
}

local function parseCount(value)
    if value == nil then
        return 1
    end

    local count = tonumber(value)
    if not isFiniteNumber(count) then
        return nil
    end

    count = floor(count)
    return count >= 1 and count or nil
end

local function parseBoolean(value)
    if value == nil then
        return nil
    end

    return booleanValues[string.lower(value)]
end

local function parseCommand(input)
    input = trim(input)
    if input == "" then
        return nil
    end

    local words = util.splitString(input)
    local command = string.lower(words[1] or "")
    local direction = movementCommands[command]

    if direction then
        local count = parseCount(words[2])
        if not count then
            return nil, "Invalid move count."
        end

        return movementAction(direction, count)
    elseif command == "turn" and words[2] then
        local turnDirection = string.lower(words[2])
        if turnDirection == "left" or turnDirection == "right" then
            return movementAction(turnDirection)
        end

        return nil, "Usage: turn left/right"
    elseif command == "face" then
        if not words[2] then
            return nil, "Usage: face <direction>"
        end

        local facing = util.normalizeDirection(words[2])
        if not util.isHorizontalDirection(facing) then
            return nil, "Invalid facing."
        end

        return faceAction(facing)
    elseif command == "dig" then
        local option = words[2] and string.lower(words[2])
        if not option or option == "toggle" then
            return simpleAction("toggle_dig")
        end

        local enabled = parseBoolean(option)
        if enabled == nil then
            return nil, "Usage: dig on/off"
        end

        return { type = "set_dig", enabled = enabled }
    elseif command == "fuel" or command == "refuel" then
        if not words[2] then
            return simpleAction("refuel")
        end

        local percent = tonumber(words[2])
        if not isFiniteNumber(percent) or percent < 0 or percent > 100 then
            return nil, "Usage: refuel 0-100"
        end

        return { type = "refuel", percent = percent }
    end

    local actionType = simpleCommands[command]
    if actionType then
        return simpleAction(actionType)
    end

    return nil, 'Unknown command "' .. command .. '".'
end

local HELP_LINES = {
    "rcGPT v1 Controls", "",
    "W/Up      Forward", "S/Down    Back",
    "A/Left    Turn left", "D/Right   Turn right",
    "Space     Up", "Shift     Down",
    "C         Calibrate", "R         Refuel",
    "Enter     Command", "",
    "(%)       Fuel details", "dig on/off",
    "face north", "forward 5", "status", "quit"
}

local function drawHelpScreen()
    updateTermSize()
    clearScreen()

    for row = 1, min(#HELP_LINES, height - 1) do
        writeAt(1, row, HELP_LINES[row], row == 1 and COLOR_PRIMARY or COLOR_TEXT)
    end

    writeAt(1, height, "Press any key or click.", COLOR_MUTED)
    resetColors()

    while true do
        local event = os.pullEvent()
        if event == "key" or event == "mouse_click" then
            return
        end
    end
end

local function showHelp()
    drawHelpScreen()
    setStatus("Ready.", COLOR_TEXT)
    restartGpsTimer()
end

local function executeCommand(input)
    local action, reason = parseCommand(input)
    if not action then
        if reason then
            setError(reason)
        end

        return
    end

    if action.type == "help" then
        showHelp()
    else
        executeAction(action)
    end
end

local function drawHeader(buttons, fuelState)
    writeAt(1, 1, VERSION, COLOR_PRIMARY)

    local percentText = fuelState.unlimited and "(INF)" or "(" .. floor(fuelState.percent + 0.5) .. "%)"
    local availableWidth = max(width - #VERSION - 1, 0)
    local labelText = clipText(turtleLabel, max(availableWidth - #percentText - 1, 0))
    local rightText = labelText ~= "" and labelText .. " " .. percentText or percentText
    local rightX = max(width - #rightText + 1, 1)
    local percentX = rightX + (labelText ~= "" and #labelText + 1 or 0)

    writeAt(rightX, 1, rightText, COLOR_PRIMARY)
    addHitbox(buttons, percentX, 1, min(percentX + #percentText - 1, width), 1, simpleAction("toggle_fuel_details"))

    if fuelDetailsOpen then
        local detailText = fuelState.unlimited and "unlimited" or
            fuelState.level .. " / " .. formatFuelLimit(fuelState.limit)
        writeAt(max(width - #detailText + 1, 1), 2, detailText, COLOR_PRIMARY)
    end

    resetColors()
end

local COORDINATE_AXES = { "x", "y", "z" }

local function drawState(buttons, layout, calibrated)
    local position = task.getPosition()
    for row, axis in ipairs(COORDINATE_AXES) do
        writeAt(1, row + 2, axis .. ": " .. position[axis], COLOR_PRIMARY, layout.leftWidth)
    end

    writeAt(1, 7, "facing: " .. task.getRotation(), COLOR_PRIMARY, layout.leftWidth)

    if calibrated then
        writeAt(1, 9, "[Calibrated]", COLOR_SUCCESS, layout.leftWidth)
    else
        local label = writeAt(1, 9, "[Calibrate]", COLOR_WARNING, layout.leftWidth)
        addHitbox(buttons, 1, 9, #label, 9, simpleAction("calibrate"))
    end

    local resetLabel = writeAt(1, 10, "[Reset]", COLOR_PRIMARY, layout.leftWidth)
    addHitbox(buttons, 1, 10, #resetLabel, 10, simpleAction("reset_position"))

    resetColors()
end

local function drawMovementControls(buttons, layout)
    addArrowButton(buttons, layout.verticalCenter, layout.verticalUpRow, "^", movementAction("up"))
    addArrowButton(buttons, layout.moveCenter, layout.forwardRow, "^", movementAction("forward"))
    addArrowButton(buttons, layout.moveCenter - 2, layout.turnRow, "<", movementAction("left"))
    addArrowButton(buttons, layout.moveCenter + 2, layout.turnRow, ">", movementAction("right"))
    addArrowButton(buttons, layout.moveCenter, layout.backwardRow, "v", movementAction("back"))
    addArrowButton(buttons, layout.verticalCenter, layout.verticalDownRow, "v", movementAction("down"))
end

local CARDINAL_CONTROLS = {
    { "[N]", "north" }, { "[E]", "east" },
    { "[S]", "south" }, { "[W]", "west" }
}

local function drawCardinalControls(buttons, layout, calibrated)
    local color = calibrated and COLOR_PRIMARY or COLOR_WARNING
    local x = layout.cardinalStart

    for index, definition in ipairs(CARDINAL_CONTROLS) do
        local label, direction = definition[1], definition[2]
        local visible = writeAt(x, layout.cardinalRow, label, color)

        if calibrated and visible ~= "" then
            addHitbox(buttons, x, layout.cardinalRow, x + #visible - 1, layout.cardinalRow, movementAction(direction))
        end

        x = x + #label
        if index < #CARDINAL_CONTROLS then
            writeAt(x, layout.cardinalRow, " ")
            x = x + 1
        end
    end

    resetColors()
end

local function drawUtilityDivider(buttons, layout, fuelState)
    writeAt(1, layout.dividerRow, string.rep("-", width), COLOR_PRIMARY)

    local digBox = addButton(
        buttons,
        1,
        layout.dividerRow,
        "[Dig]",
        simpleAction("toggle_dig"),
        digAllowed and COLOR_SUCCESS or COLOR_PRIMARY
    )
    digBox.x2 = min(digBox.x2 + 1, width)

    local refuelLabel = "[Refuel]"
    local refuelX = max(width - #refuelLabel + 1, 1)
    local refuelUseful = not fuelState.unlimited and fuelState.percent < 100

    if refuelUseful then
        addButton(buttons, refuelX, layout.dividerRow, refuelLabel, simpleAction("refuel"), COLOR_PRIMARY)
    else
        writeAt(refuelX, layout.dividerRow, refuelLabel, COLOR_WARNING)
    end

    resetColors()
end

local function drawPrompt()
    term.setTextColor(COLOR_PRIMARY)
    term.write("> ")
end

local function drawCommandLine(layout)
    term.setCursorPos(1, layout.commandRow)
    term.clearLine()
    drawPrompt()
    term.setTextColor(statusColor)
    term.write(fitMessage(statusMessage, width - 2))
    resetColors()
end

local function drawInterface()
    clearScreen()

    local layout = getLayout()
    local buttons = {}
    local fuelState = fuel.getState()
    local calibrated = task.isCalibrated()

    drawHeader(buttons, fuelState)
    drawState(buttons, layout, calibrated)
    drawMovementControls(buttons, layout)
    drawCardinalControls(buttons, layout, calibrated)
    drawUtilityDivider(buttons, layout, fuelState)
    drawCommandLine(layout)
    addHitbox(buttons, 1, layout.commandRow, width, layout.commandRow, simpleAction("command"))

    resetColors()
    return buttons
end

local function promptCommand()
    local layout = getLayout()
    term.setCursorPos(1, layout.commandRow)
    term.clearLine()
    drawPrompt()
    resetColors()

    term.setCursorBlink(true)
    local input = read()
    term.setCursorBlink(false)

    -- read() consumes timer events, so begin a fresh GPS interval afterwards.
    restartGpsTimer()
    return input
end

local function actionFromMouse(buttons, x, y)
    for _, box in ipairs(buttons) do
        if hit(box, x, y) then
            return box.action
        end
    end
end

local keyMoves = {
    [keys.w] = "forward", [keys.up] = "forward",
    [keys.s] = "back", [keys.down] = "back",
    [keys.a] = "left", [keys.left] = "left",
    [keys.d] = "right", [keys.right] = "right",
    [keys.space] = "up", [keys.pageUp] = "up",
    [keys.leftShift] = "down", [keys.rightShift] = "down", [keys.pageDown] = "down"
}

local function actionFromKey(code)
    local direction = keyMoves[code]
    if direction then
        return movementAction(direction)
    elseif code == keys.c and not task.isCalibrated() then
        return simpleAction("calibrate")
    elseif code == keys.r then
        return simpleAction("refuel")
    elseif code == keys.enter then
        return simpleAction("command")
    elseif code == keys.f1 then
        return simpleAction("help")
    end
end

local function handleAction(action)
    if not action then
        return
    elseif action.type == "command" then
        executeCommand(promptCommand())
    elseif action.type == "help" then
        showHelp()
    else
        executeAction(action)
    end
end

local function main()
    local initialized, message = initializeRuntime()
    if not initialized then
        error(message, 0)
    end

    if message then
        setStatus(message, COLOR_TEXT)
    end

    restartGpsTimer()

    while running do
        local buttons = drawInterface()
        local event, a, b, c = os.pullEvent()

        if event == "timer" and a == gpsTimer then
            verifyGpsCalibration()
            restartGpsTimer()
        elseif event == "mouse_click" then
            handleAction(actionFromMouse(buttons, b, c))
        elseif event == "key" then
            handleAction(actionFromKey(a))
        end
    end
end

local ok, reason = pcall(main)
resetColors()
term.setCursorBlink(false)
term.clear()
term.setCursorPos(1, 1)

if not ok and tostring(reason) ~= "Terminated" then
    term.setTextColor(COLOR_ERROR)
    print("rcGPT crashed:")
    print()
    resetColors()
    print(tostring(reason))
end
