-- qlib-release: 2
local util = require "qlib.util"
local conf = require "qlib.conf"
local task = require "qlib.task"
local fuel = require "qlib.fuel"
local mvmt = require "qlib.mvmt"

local VERSION = "rcGPT v1.3"

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
-- CC:Tweaked rounds trilaterated GPS fixes to hundredths. A quarter-block
-- tolerance absorbs that noise while still rejecting every real block move.
local GPS_POSITION_TOLERANCE = 0.25

local max = math.max
local min = math.min
local floor = math.floor

local width, height = term.getSize()
local running = true
local digAllowed = false
local fuelDetailsOpen = false
local showComputerId = false
local showRelativeCoordinates = false
local placeArmed = false
local digArmed = false
local pendingAutoCalibration = false
local statusMessage = "Ready."
local statusColor = COLOR_TEXT
local gpsMissCount = 0
local gpsTimer
local openShellWindow
local turtleSafetyActive = false
local turtleSafetyOriginals = {}
local turtleSafetyWrappers = {}

-- Programs opened by multishell inherit CraftOS's global turtle API table.
-- Park is a translation/attack lock, not a complete interaction lock:
-- turning, digging, and placing remain available while parked.
local TURTLE_SAFETY_ACTIONS = {
    "forward", "back", "up", "down",
    "attack", "attackUp", "attackDown"
}

local function guardedTurtleAction(nativeAction)
    return function(...)
        if turtleSafetyActive and mvmt.isParked() then
            return false, mvmt.PARKED_MESSAGE or "Turtle is parked."
        end
        return nativeAction(...)
    end
end

local function installTurtleSafetyGate()
    if turtleSafetyActive or type(turtle) ~= "table" then
        return
    end

    for _, name in ipairs(TURTLE_SAFETY_ACTIONS) do
        local nativeAction = turtle[name]
        if type(nativeAction) == "function" then
            local wrapper = guardedTurtleAction(nativeAction)
            turtleSafetyOriginals[name] = nativeAction
            turtleSafetyWrappers[name] = wrapper
            turtle[name] = wrapper
        end
    end
    turtleSafetyActive = true
end

local function restoreTurtleSafetyGate()
    turtleSafetyActive = false
    if type(turtle) ~= "table" then
        return
    end

    for name, nativeAction in pairs(turtleSafetyOriginals) do
        -- Do not overwrite a later program's intentional replacement.
        if turtle[name] == turtleSafetyWrappers[name] then
            turtle[name] = nativeAction
        end
    end
end

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

-- The status bar is intentionally one line. Common diagnostics are
-- normalized before this final width-safe fit.
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

local function compactStatusMessage(message)
    message = trim(message)
    local lower = string.lower(message)

    -- Translate verbose low-level diagnostics into short UI messages. Full
    -- module return values remain unchanged; only the one-line status bar is
    -- normalized here.
    if lower:find("not enough fuel items available", 1, true) then
        message = "No fuel items available."
    elseif lower:find("insufficient fuel", 1, true) then
        message = "Not enough fuel."
    elseif lower:find("unable to safely begin calibration", 1, true) and
        lower:find("fuel", 1, true) then
        message = "Not enough fuel to calibrate."
    elseif lower:find("no wireless modem", 1, true) or
        lower:find("wireless modem unavailable", 1, true) then
        message = "No modem; using relative coordinates."
    elseif lower:find("no gps signal", 1, true) or
        lower:find("gps signal lost", 1, true) then
        message = "No GPS; using relative coordinates."
    elseif lower:find("unable to acquire initial gps position", 1, true) then
        message = "No GPS signal."
    elseif lower:find("unable to acquire second gps position", 1, true) then
        message = "GPS lost during calibration."
    elseif lower:find("automatic calibration retry", 1, true) and
        lower:find("calibration restored", 1, true) then
        message = "GPS calibration restored."
    elseif lower:find("stored position does not match gps", 1, true) and
        lower:find("calibration restored", 1, true) then
        message = "GPS mismatch; calibration restored."
    elseif lower:find("cannot place in an absolute direction while uncalibrated", 1, true) then
        message = "Calibrate before cardinal placement."
    elseif lower:find("cannot dig in an absolute direction while uncalibrated", 1, true) then
        message = "Calibrate before cardinal digging."
    elseif lower:find("cannot face an absolute direction while uncalibrated", 1, true) then
        message = "Calibrate before cardinal movement."
    elseif lower:find("protected block", 1, true) and
        lower:find("blacklist", 1, true) then
        message = "Protected block; dig blocked."
    elseif lower:find("unable to identify obstructing block", 1, true) then
        message = "Could not identify block."
    elseif lower:find("state checkpoint failed", 1, true) or
        lower:find("state save failed", 1, true) then
        message = "State save failed."
    elseif lower:find("command windows require multishell", 1, true) then
        message = "Multishell required."
    elseif lower:find("unable to open command window", 1, true) then
        message = "Could not open command window."
    elseif lower:find("unable to focus command window", 1, true) then
        message = "Could not focus command window."
    end

    -- Module diagnostics are not always sentence-cased. Keep the UI
    -- grammatically consistent regardless of their source.
    message = message:gsub("^%l", string.upper)
    return message
end

local function setStatus(message, color)
    statusMessage = compactStatusMessage(message)
    if statusMessage ~= "" and not statusMessage:match("[%.!?]$") then
        statusMessage = statusMessage .. "."
    end
    statusColor = color or COLOR_TEXT
end

local function setSuccess(message)
    -- Successful command output is ordinary text. COLOR_SUCCESS remains an
    -- accent for persistent state such as the calibrated indicator.
    setStatus(message, COLOR_TEXT)
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

local function addArrowButton(buttons, center, row, glyph, action, color)
    center = max(1, min(center, width))
    writeAt(center, row, glyph, color or COLOR_PRIMARY)
    addHitbox(buttons, max(center - 1, 1), row, min(center + 1, width), row, action)
end

local function restartGpsTimer()
    if gpsTimer and type(os.cancelTimer) == "function" then
        pcall(os.cancelTimer, gpsTimer)
    end
    gpsTimer = os.startTimer(GPS_CHECK_INTERVAL)
end

local function hasWirelessModem()
    if type(peripheral) ~= "table" or type(peripheral.getNames) ~= "function" then
        return false
    end

    for _, name in ipairs(peripheral.getNames()) do
        local isModem = false

        if type(peripheral.hasType) == "function" then
            local ok, result = pcall(peripheral.hasType, name, "modem")
            isModem = ok and result == true
        elseif type(peripheral.getType) == "function" then
            local ok, result = pcall(peripheral.getType, name)
            isModem = ok and result == "modem"
        end

        if isModem and type(peripheral.wrap) == "function" then
            local ok, modem = pcall(peripheral.wrap, name)
            if ok and type(modem) == "table" and type(modem.isWireless) == "function" then
                local wirelessOk, wireless = pcall(modem.isWireless)
                if wirelessOk and wireless == true then
                    return true
                end
            end
        end
    end

    return false
end

local function locateGps(timeout)
    if not hasWirelessModem() or type(gps) ~= "table" or type(gps.locate) ~= "function" then
        return nil
    end

    local ok, x, y, z = pcall(gps.locate, timeout, false)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end

    return util.Vector3.new(x, y, z)
end

local function positionsMatch(first, second)
    return math.abs(first.x - second.x) <= GPS_POSITION_TOLERANCE and
        math.abs(first.y - second.y) <= GPS_POSITION_TOLERANCE and
        math.abs(first.z - second.z) <= GPS_POSITION_TOLERANCE
end

local function invalidateGpsCalibration(message)
    local wasCalibrated = task.isCalibrated()

    if wasCalibrated then
        task.invalidateCalibration()
    end

    -- When GPS cannot be trusted, never continue presenting the saved
    -- absolute position as though it were current. Fall back to the relative
    -- frame until calibration succeeds again.
    showRelativeCoordinates = true
    gpsMissCount = 0
    pendingAutoCalibration = conf.get("startup.autoCalibrate", true) == true

    if wasCalibrated then
        local saved, saveReason = task.save()
        if not saved then
            return false, message .. "; unable to save invalid calibration: " ..
                tostring(saveReason), true
        end
    end

    return false, message, true
end

local function recoverCalibration(context)
    if not hasWirelessModem() then
        return invalidateGpsCalibration(
            context .. "; no wireless modem detected; using relative coordinates."
        )
    end

    if task.isCalibrated() then
        task.invalidateCalibration()
        showRelativeCoordinates = true

        local saved, saveReason = task.save()
        if not saved then
            pendingAutoCalibration = conf.get("startup.autoCalibrate", true) == true
            return false, context .. "; unable to save invalid calibration: " ..
                tostring(saveReason), true
        end
    else
        showRelativeCoordinates = true
    end

    if conf.get("startup.autoCalibrate", true) ~= true then
        pendingAutoCalibration = false
        return false, context .. ". Recalibrate.", true
    elseif mvmt.isParked() then
        pendingAutoCalibration = true
        return false, context .. "; automatic calibration pending while parked.", true
    end

    local success, message = mvmt.calibrate(digAllowed)
    pendingAutoCalibration = not success
    gpsMissCount = 0

    if not success then
        showRelativeCoordinates = true
        return false, context .. "; automatic calibration failed: " ..
            trim(message or "Calibration failed."), true
    end

    showRelativeCoordinates = false

    if message then
        return true, context .. "; " .. trim(message), true
    end

    return true, context .. "; calibration restored.", false
end

local function verifyGpsCalibration()
    -- Losing the modem invalidates absolute position immediately. Do not keep
    -- presenting a stale GPS coordinate as calibrated.
    if not hasWirelessModem() then
        if task.isCalibrated() then
            local _, message = invalidateGpsCalibration(
                "Wireless modem unavailable; using relative coordinates."
            )
            setWarning(message)
        else
            showRelativeCoordinates = true
            gpsMissCount = 0
            pendingAutoCalibration = conf.get("startup.autoCalibrate", true) == true
        end
        return true
    end

    -- If calibration is already invalid, wait for an actual GPS fix before
    -- retrying calibration. This avoids repeatedly attempting calibration
    -- while GPS hosts are simply out of range.
    if not task.isCalibrated() then
        showRelativeCoordinates = true
        gpsMissCount = 0

        if pendingAutoCalibration and not mvmt.isParked() then
            local gpsPosition = locateGps(GPS_CHECK_TIMEOUT)
            if gpsPosition then
                local success, message, warning = recoverCalibration("Automatic calibration retry")
                if success and not warning then
                    setSuccess(message)
                else
                    setWarning(message)
                end
                return success
            end
        end

        return true
    end

    local gpsPosition = locateGps(GPS_CHECK_TIMEOUT)
    if gpsPosition then
        if positionsMatch(gpsPosition, task.getPosition()) then
            gpsMissCount = 0
            return true
        end

        -- A valid fix outside the tolerance is a confirmed mismatch. This is
        -- the broken/replaced-turtle case: invalidate and recalibrate now.
        local success, message, warning = recoverCalibration("GPS position changed")
        if success and not warning then
            setSuccess(message)
        else
            setWarning(message)
        end
        return success
    end

    gpsMissCount = gpsMissCount + 1
    if gpsMissCount < GPS_MISS_LIMIT then
        return true
    end

    local _, message = invalidateGpsCalibration(
        "GPS signal lost; using relative coordinates. Automatic calibration pending."
    )
    setWarning(message)
    return true
end

local function resetAndSave(message)
    task.reset()

    if task.save() then
        return true, message
    end

    return true, message:gsub("%.$", "") .. "; save failed."
end

local function validateLoadedCalibration()
    local autoCalibrate = conf.get("startup.autoCalibrate", true) == true

    if not hasWirelessModem() then
        local _, message = invalidateGpsCalibration(
            "No wireless modem detected; using relative coordinates."
        )
        pendingAutoCalibration = autoCalibrate
        return message
    end

    -- A modem alone is not enough. Require a real fix before trusting any
    -- saved absolute coordinates from the previous run.
    local gpsPosition = locateGps(conf.get("startup.gpsTimeout", 2))
    if not gpsPosition then
        local _, message = invalidateGpsCalibration(
            "No GPS signal received; using relative coordinates."
        )
        pendingAutoCalibration = autoCalibrate
        return message
    end

    if not task.isCalibrated() then
        showRelativeCoordinates = true

        if not autoCalibrate then
            pendingAutoCalibration = false
            return "GPS fix available, but the turtle is uncalibrated."
        elseif mvmt.isParked() then
            pendingAutoCalibration = true
            return "GPS fix available; automatic calibration pending while parked."
        end

        local success, message = mvmt.calibrate(digAllowed)
        restartGpsTimer()
        gpsMissCount = 0
        pendingAutoCalibration = not success

        if success then
            showRelativeCoordinates = false
            return message and "Calibration restored; " .. trim(message) or "Calibration restored."
        end

        showRelativeCoordinates = true
        return "Automatic calibration failed: " .. trim(message or "Calibration failed.")
    end

    if positionsMatch(gpsPosition, task.getPosition()) then
        pendingAutoCalibration = false
        showRelativeCoordinates = false
        return nil
    end

    local _, message = recoverCalibration("Stored position does not match GPS")
    return message
end

local function combineStatusMessages(first, second)
    first, second = trim(first), trim(second)
    if first == "" then return second end
    if second == "" then return first end
    return first:gsub("[%.!?]$", "") .. "; " .. second
end

local function startupMessageIsWarning(message)
    message = string.lower(tostring(message or ""))
    return message:find("failed", 1, true) ~= nil or
        message:find("backup", 1, true) ~= nil or
        message:find("recalibrate", 1, true) ~= nil or
        message:find("no wireless modem", 1, true) ~= nil or
        message:find("no gps signal", 1, true) ~= nil or
        message:find("uncalibrated", 1, true) ~= nil
end

local function initializeRuntime()
    local configReady, configMessage = conf.initialize()
    if not configReady then
        return false, "Configuration initialization failed: " .. tostring(configMessage)
    end

    local function withConfigMessage(message)
        return combineStatusMessages(configMessage, message)
    end

    applyColorConfiguration()

    task.setStoragePath(conf.get("paths.taskState", ".rcgpt/task.state"))
    digAllowed = conf.get("movement.defaultDig", false) == true

    if conf.get("startup.loadTaskState", true) ~= true then
        task.reset()
        return true, withConfigMessage(combineStatusMessages("Fresh state.", validateLoadedCalibration()))
    end

    local statePath = task.getStoragePath()
    if not fs.exists(statePath) and not fs.exists(statePath .. ".bak") then
        local success, message = resetAndSave("Fresh state.")
        if success then
            message = combineStatusMessages(message, validateLoadedCalibration())
        end
        return success, withConfigMessage(message)
    end

    local loaded, loadMessage = task.load()
    if loaded then
        local calibrationMessage = validateLoadedCalibration()
        local loadStatus = combineStatusMessages(loadMessage, calibrationMessage)
        return true, withConfigMessage(loadStatus ~= "" and loadStatus or "State loaded.")
    end

    local success, message = resetAndSave("Invalid state reset.")
    if success then
        message = combineStatusMessages(message, validateLoadedCalibration())
    end
    return success, withConfigMessage(message)
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
        local verb = (direction == "left" or direction == "right") and "Turned" or "Moved"
        return true, verb .. " " .. direction .. ".", false
    end

    local verb = (direction == "left" or direction == "right") and "Turned" or "Moved"
    return true, verb .. " " .. direction .. " x" .. count .. ".", false
end

local function reportOperation(success, message, successMessage, errorMessage)
    if not success then
        setWarning(message or errorMessage)
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
    setSuccess(digAllowed and "AllowDig enabled." or "AllowDig disabled.")
end

local function setParkMode(enabled)
    mvmt.setParked(enabled == true)
    if enabled then
        placeArmed = false
        digArmed = false
        setSuccess("Turtle parked.")
        return true
    end

    if pendingAutoCalibration then
        local success, message, warning = recoverCalibration("Stored position mismatch remains")
        restartGpsTimer()
        if success and not warning then
            setSuccess(message)
        else
            setWarning(message)
        end
        return success
    end

    setSuccess("Turtle unparked.")
    return true
end

local function actionBlockedWhileParked(action)
    if not mvmt.isParked() then
        return false
    end

    if action.type == "calibrate" then
        return true
    end

    if action.type == "move" then
        return action.direction ~= "left" and action.direction ~= "right"
    end

    return false
end

local function executeAction(action)
    if type(action) ~= "table" or type(action.type) ~= "string" then
        setError("Invalid action.")
        return false
    end

    local actionType = action.type

    if actionBlockedWhileParked(action) then
        placeArmed = false
        digArmed = false
        setWarning(mvmt.PARKED_MESSAGE or "Turtle is parked.")
        return false
    end

    if actionType == "toggle_fuel_details" then
        fuelDetailsOpen = not fuelDetailsOpen
        return true
    elseif actionType == "toggle_identity" then
        showComputerId = not showComputerId
        setSuccess(showComputerId and "Showing turtle ID." or "Showing turtle label.")
        return true
    elseif actionType == "toggle_coordinates" then
        if not task.isCalibrated() then
            setWarning("Calibrate first.")
            return false
        end

        showRelativeCoordinates = not showRelativeCoordinates
        setSuccess(showRelativeCoordinates and "Showing relative coordinates." or "Showing GPS coordinates.")
        return true
    elseif actionType == "move" then
        local success, message, warning = executeMovement(action.direction, action.count)
        if not success then
            setWarning(message)
            return false
        end

        if warning then
            setWarning(message)
        else
            setSuccess(message)
        end
        return true
    elseif actionType == "face" then
        if not task.isCalibrated() then
            setWarning("Calibrate first.")
            return false
        end

        local success, message = mvmt.face(action.direction)
        return reportOperation(success, message, "Facing " .. tostring(action.direction) .. ".", "Rotate failed.")
    elseif actionType == "toggle_allow_dig" then
        setDigMode(not digAllowed)
        return true
    elseif actionType == "set_allow_dig" then
        setDigMode(action.enabled)
        return true
    elseif actionType == "toggle_park" then
        return setParkMode(not mvmt.isParked())
    elseif actionType == "set_park" then
        return setParkMode(action.enabled)
    elseif actionType == "toggle_place" then
        placeArmed = not placeArmed
        if placeArmed then
            digArmed = false
        end
        setSuccess(placeArmed and "Place armed; press a direction." or "Place cancelled.")
        return true
    elseif actionType == "toggle_dig" then
        digArmed = not digArmed
        if digArmed then
            placeArmed = false
        end
        setSuccess(digArmed and "Dig armed; press a direction." or "Dig cancelled.")
        return true
    elseif actionType == "place" then
        placeArmed = false
        local success, message = mvmt.place(action.direction)
        return reportOperation(
            success,
            message,
            "Placed block " .. tostring(action.direction) .. ".",
            "Placement failed."
        )
    elseif actionType == "dig" then
        digArmed = false
        local success, message = mvmt.dig(action.direction)
        return reportOperation(
            success,
            message,
            "Dug block " .. tostring(action.direction) .. ".",
            "Dig failed."
        )
    elseif actionType == "calibrate" then
        if task.isCalibrated() then
            setSuccess("Already calibrated.")
            return true
        end

        local success, message = mvmt.calibrate(digAllowed)
        -- gps.locate consumes timer events internally, including our periodic
        -- check timer, so every calibration attempt needs a fresh interval.
        restartGpsTimer()
        if success then
            gpsMissCount = 0
            pendingAutoCalibration = false
            showRelativeCoordinates = false
        else
            showRelativeCoordinates = true
        end

        return reportOperation(success, message, "GPS calibrated.", "Calibration failed.")
    elseif actionType == "reset_position" then
        task.setPosition(0, 0, 0)
        task.clearRelativeOrigin()
        task.invalidateCalibration()
        pendingAutoCalibration = false
        showRelativeCoordinates = false

        if task.save() then
            setSuccess("Position reset. Recalibrate.")
        else
            setWarning("Position reset; save failed.")
        end

        return true
    elseif actionType == "refuel" then
        local success, value1 = fuel.refuel(action.percent)
        if not success then
            setWarning(value1 or "Refuel failed.")
            return false
        end

        local fuelAdded = value1 or 0
        if fuelAdded == math.huge then
            setSuccess("Fuel unlimited.")
        elseif fuelAdded > 0 then
            setSuccess("Refueled +" .. fuelAdded .. ".")
        else
            setSuccess("Fuel already sufficient.")
        end

        return true
    elseif actionType == "config" then
        local configPath = conf.getStoragePath()
        if configPath:sub(1, 1) ~= "/" then
            configPath = "/" .. configPath
        end
        return openShellWindow("edit " .. configPath, "Config editor", true)
    elseif actionType == "save" or actionType == "load" then
        local operation = actionType == "save" and task.save or task.load
        local success, message = operation()
        local label = actionType == "save" and "State saved." or "State loaded."
        local fallback = actionType == "save" and "State save failed." or "State load failed."

        if success and actionType == "load" then
            message = combineStatusMessages(message, validateLoadedCalibration())
            restartGpsTimer()
        end

        if success and message then
            setWarning(message)
        elseif success then
            setSuccess(label)
        else
            setWarning(message or fallback)
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
    config = "config",
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
    elseif input:sub(1, 1) == "!" then
        local shellInput = trim(input:sub(2))
        if shellInput == "" then
            return nil, "Usage: !<command>"
        end
        return nil, nil, shellInput
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
    elseif command == "turn" then
        if words[2] then
            local turnDirection = string.lower(words[2])
            if turnDirection == "left" or turnDirection == "right" then
                return movementAction(turnDirection)
            end
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

        -- Keep the old "dig on/off" command as a compatibility alias for
        -- AllowDig, while directional arguments perform an immediate dig.
        local enabled = parseBoolean(option)
        if enabled ~= nil then
            return { type = "set_allow_dig", enabled = enabled }
        end

        local digDirection = movementCommands[option]
        if digDirection then
            return { type = "dig", direction = digDirection }
        end

        return nil, "Usage: dig <direction> or dig on/off"
    elseif command == "allowdig" or command == "autodig" then
        local option = words[2] and string.lower(words[2])
        if not option or option == "toggle" then
            return simpleAction("toggle_allow_dig")
        end

        local enabled = parseBoolean(option)
        if enabled == nil then
            return nil, "Usage: allowdig on/off"
        end

        return { type = "set_allow_dig", enabled = enabled }
    elseif command == "park" then
        local option = words[2] and string.lower(words[2])
        if not option or option == "toggle" then
            return simpleAction("toggle_park")
        end

        local enabled = parseBoolean(option)
        if enabled == nil then
            return nil, "Usage: park on/off"
        end

        return { type = "set_park", enabled = enabled }
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

    return nil, nil, true
end

local MOVEMENT_HELP = {
    "W / Up - Forward",
    "S / Down - Back",
    "A / Left - Turn left",
    "D / Right - Turn right",
    "Space / PgUp - Up",
    "Shift / PgDn - Down",
    "[AllowDig] / O - Dig while moving",
    "[Park] / P - Prevents movement"
}

local ACTION_HELP = {
    "[Dig] / X - Dig in direction",
    "[Place] / F - Place in direction",
    "[Refuel] / R - Attempt refuel",
    "[Calibrate] / C - Calibrate GPS",
    "[Reset] - Reset position"
}

local OTHER_HELP = {
    "[rcGPT] / H - Help menu",
    "[Config] / I - Edit config",
    "[%] - Show fuel amount",
    "[>] / Enter - Command-line interface",
    ""
}

local function drawHelpScreen()
    updateTermSize()

    local lines = {
        { text = "Movement", color = COLOR_PRIMARY }
    }

    for _, line in ipairs(MOVEMENT_HELP) do
        lines[#lines + 1] = { text = line, color = COLOR_TEXT }
    end

    lines[#lines + 1] = { text = "", color = COLOR_TEXT }
    lines[#lines + 1] = { text = "Actions", color = COLOR_PRIMARY }

    for _, line in ipairs(ACTION_HELP) do
        lines[#lines + 1] = { text = line, color = COLOR_TEXT }
    end

    lines[#lines + 1] = { text = "", color = COLOR_TEXT }
    lines[#lines + 1] = { text = "Other functions", color = COLOR_PRIMARY }

    for _, line in ipairs(OTHER_HELP) do
        lines[#lines + 1] = { text = line, color = COLOR_TEXT }
    end

    local contentStartRow = 3
    local visibleRows = max(height - contentStartRow, 1)
    local maxOffset = max(#lines - visibleRows, 0)
    local offset = 0

    local function writeCentered(row, text, color)
        if text == "" then
            return
        end

        local visible = clipText(text, width)
        local x = max(floor((width - #visible) / 2) + 1, 1)
        writeAt(x, row, visible, color)
    end

    local function drawPage()
        clearScreen()
        writeAt(1, 1, VERSION .. " Controls", COLOR_PRIMARY)

        for displayIndex = 1, visibleRows do
            local line = lines[displayIndex + offset]
            if line then
                writeCentered(contentStartRow + displayIndex - 1, line.text, line.color)
            end
        end

        local footer = maxOffset > 0 and "Scroll; any other key exits." or "Press any key or click."
        writeCentered(height, footer, COLOR_MUTED)
        resetColors()
    end

    drawPage()

    while true do
        local event, value = os.pullEvent()
        local nextOffset = offset

        if event == "mouse_scroll" then
            nextOffset = min(max(offset + value, 0), maxOffset)
        elseif event == "key" and (value == keys.down or value == keys.pageDown) then
            nextOffset = min(offset + 1, maxOffset)
        elseif event == "key" and (value == keys.up or value == keys.pageUp) then
            nextOffset = max(offset - 1, 0)
        elseif event == "key" or event == "mouse_click" then
            return
        end

        if nextOffset ~= offset then
            offset = nextOffset
            drawPage()
        end
    end
end

local function showHelp()
    drawHelpScreen()
    setStatus("Ready.", COLOR_TEXT)
    restartGpsTimer()
end

openShellWindow = function(input, description, allowedWhileParked)
    if mvmt.isParked() and not allowedWhileParked then
        setWarning("Parked; command windows disabled.")
        return false
    elseif type(shell.openTab) ~= "function" or type(shell.switchTab) ~= "function" then
        setWarning("Command windows require multishell.")
        return false
    end

    local opened, tabId = pcall(shell.openTab, input)
    if not opened then
        setWarning("Unable to open command window: " .. tostring(tabId))
        return false
    elseif type(tabId) ~= "number" then
        setWarning("Unable to open command window.")
        return false
    end

    -- Multishell IDs may change after a yield, so focus the new tab
    -- immediately after it is created.
    local switchCalled, switched = pcall(shell.switchTab, tabId)
    if not switchCalled or switched == false then
        setWarning("Unable to focus command window: " .. tostring(switched))
        return false
    end

    setSuccess((description or "Command") .. " opened in a new window.")
    restartGpsTimer()
    return true
end

local function executeCommand(input)
    local action, reason, runInShell = parseCommand(input)
    if not action then
        if runInShell then
            openShellWindow(type(runInShell) == "string" and runInShell or input)
        elseif reason then
            setWarning(reason)
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
    local versionText = writeAt(1, 1, VERSION, COLOR_PRIMARY)
    if versionText ~= "" then
        addHitbox(
            buttons,
            1,
            1,
            #versionText,
            1,
            simpleAction("help")
        )
    end

    local percentText = fuelState.unlimited and "(INF)" or "(" .. floor(fuelState.percent + 0.5) .. "%)"
    local availableWidth = max(width - #VERSION - 1, 0)
    local identityText = showComputerId and "id: " .. os.getComputerID() or
        os.getComputerLabel() or "Unnamed Turtle"
    local labelText = clipText(identityText, max(availableWidth - #percentText - 1, 0))
    local rightText = labelText ~= "" and labelText .. " " .. percentText or percentText
    local rightX = max(width - #rightText + 1, 1)
    local percentX = rightX + (labelText ~= "" and #labelText + 1 or 0)

    writeAt(rightX, 1, rightText, COLOR_PRIMARY)
    if labelText ~= "" then
        addHitbox(
            buttons,
            rightX,
            1,
            min(rightX + #labelText - 1, width),
            1,
            simpleAction("toggle_identity")
        )
    end
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
    local position = showRelativeCoordinates and task.getRelativePosition() or task.getPosition()

    -- Row 2 stays blank to visually separate the header from turtle state.
    for row, axis in ipairs(COORDINATE_AXES) do
        local y = row + 2
        local visible = writeAt(1, y, axis .. ": " .. position[axis], COLOR_PRIMARY, layout.leftWidth)
        if calibrated and visible ~= "" then
            addHitbox(buttons, 1, y, #visible, y, simpleAction("toggle_coordinates"))
        end
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

local function directionalAction(direction)
    if placeArmed then
        return { type = "place", direction = direction }
    elseif digArmed then
        return { type = "dig", direction = direction }
    end
    return movementAction(direction)
end

local function drawMovementControls(buttons, layout)
    local color = (placeArmed or digArmed) and COLOR_SUCCESS or COLOR_PRIMARY

    -- Pull the separate vertical controls inward toward the D-pad. This leaves
    -- a full row between [AllowDig] and the upper vertical arrow.
    local verticalUpRow = min(layout.verticalUpRow + 1, layout.turnRow)
    local verticalDownRow = max(layout.verticalDownRow - 1, layout.turnRow)

    addArrowButton(buttons, layout.verticalCenter, verticalUpRow, "^", directionalAction("up"), color)
    addArrowButton(buttons, layout.moveCenter, layout.forwardRow, "^", directionalAction("forward"), color)
    addArrowButton(buttons, layout.moveCenter - 2, layout.turnRow, "<", directionalAction("left"), color)
    addArrowButton(buttons, layout.moveCenter + 2, layout.turnRow, ">", directionalAction("right"), color)
    addArrowButton(buttons, layout.moveCenter, layout.backwardRow, "v", directionalAction("back"), color)
    addArrowButton(buttons, layout.verticalCenter, verticalDownRow, "v", directionalAction("down"), color)
end

local CARDINAL_CONTROLS = {
    { "[N]", "north" }, { "[E]", "east" },
    { "[S]", "south" }, { "[W]", "west" }
}

local function drawCardinalControls(buttons, layout, calibrated)
    local armed = placeArmed or digArmed
    local color = calibrated and (armed and COLOR_SUCCESS or COLOR_PRIMARY) or COLOR_WARNING
    local x = layout.cardinalStart

    for index, definition in ipairs(CARDINAL_CONTROLS) do
        local label, direction = definition[1], definition[2]
        local visible = writeAt(x, layout.cardinalRow, label, color)

        if calibrated and visible ~= "" then
            addHitbox(buttons, x, layout.cardinalRow, x + #visible - 1, layout.cardinalRow, directionalAction(direction))
        end

        x = x + #label
        if index < #CARDINAL_CONTROLS then
            writeAt(x, layout.cardinalRow, " ")
            x = x + 1
        end
    end

    resetColors()
end

local function drawParkControl(buttons, layout)
    local parkLabel = "[Park]"
    local parkX = max(1, layout.cardinalStart - 2)
    local row = max(2, layout.verticalUpRow - 1)

    addButton(
        buttons,
        parkX,
        row,
        parkLabel,
        simpleAction("toggle_park"),
        mvmt.isParked() and COLOR_SUCCESS or COLOR_PRIMARY
    )

    local allowDigX = parkX + #parkLabel + 1
    if allowDigX <= width then
        addButton(
            buttons,
            allowDigX,
            row,
            "[AllowDig]",
            simpleAction("toggle_allow_dig"),
            digAllowed and COLOR_SUCCESS or COLOR_PRIMARY
        )
    end
end

local function drawUtilityDivider(buttons, layout, fuelState)
    writeAt(1, layout.dividerRow, string.rep("-", width), COLOR_PRIMARY)

    local digLabel = "[Dig]"
    local placeLabel = "[Place]"
    local configLabel = "[Config]"
    local refuelLabel = "[Refuel]"
    local totalLabelWidth = #digLabel + #placeLabel + #configLabel + #refuelLabel
    local freeSpace = width - totalLabelWidth

    local digX = 1
    local placeX
    local configX
    local refuelX = max(width - #refuelLabel + 1, 1)

    if freeSpace >= 0 then
        -- Divide unused columns into three nearly equal gaps while keeping
        -- [Dig] flush left and [Refuel] flush right.
        local baseGap = floor(freeSpace / 3)
        local remainder = freeSpace % 3
        local gap1, gap2, gap3 = baseGap, baseGap, baseGap

        if remainder == 1 then
            gap2 = gap2 + 1
        elseif remainder == 2 then
            gap1 = gap1 + 1
            gap3 = gap3 + 1
        end

        placeX = digX + #digLabel + gap1
        configX = placeX + #placeLabel + gap2
        refuelX = configX + #configLabel + gap3
    else
        -- Extremely narrow terminals cannot fit all four labels. Keep the
        -- outside controls anchored and fit the middle controls when possible.
        placeX = digX + #digLabel
        configX = refuelX - #configLabel
    end

    addButton(
        buttons,
        digX,
        layout.dividerRow,
        digLabel,
        simpleAction("toggle_dig"),
        digArmed and COLOR_SUCCESS or COLOR_PRIMARY
    )

    if placeX + #placeLabel - 1 < configX then
        addButton(
            buttons,
            placeX,
            layout.dividerRow,
            placeLabel,
            simpleAction("toggle_place"),
            placeArmed and COLOR_SUCCESS or COLOR_PRIMARY
        )
    end

    if configX > placeX + #placeLabel - 1 then
        addButton(
            buttons,
            configX,
            layout.dividerRow,
            configLabel,
            simpleAction("config"),
            COLOR_PRIMARY
        )
    end

    local refuelUseful = not fuelState.unlimited and fuelState.percent < 100
    if refuelUseful then
        addButton(buttons, refuelX, layout.dividerRow, refuelLabel, simpleAction("refuel"), COLOR_PRIMARY)
    else
        writeAt(refuelX, layout.dividerRow, refuelLabel, COLOR_WARNING)
    end

    resetColors()
end

local function drawPrompt()
    term.setTextColor(colors.red)
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
    drawParkControl(buttons, layout)
    drawCardinalControls(buttons, layout, calibrated)
    drawUtilityDivider(buttons, layout, fuelState)
    drawCommandLine(layout)
    addHitbox(buttons, 1, layout.commandRow, min(2, width), layout.commandRow, simpleAction("command"))

    resetColors()
    return buttons
end

local function promptCommand()
    local layout = getLayout()
    term.setCursorPos(1, layout.commandRow)
    term.clearLine()
    drawPrompt()
    resetColors()

    local input, cancelled
    term.setCursorBlink(true)
    parallel.waitForAny(
        function()
            input = read()
        end,
        function()
            while true do
                local _, _, x, y = os.pullEvent("mouse_click")
                local currentLayout = getLayout()
                if y == currentLayout.commandRow and x <= 2 then
                    cancelled = true
                    return
                end
            end
        end,
        function()
            os.pullEvent("term_resize")
            cancelled = true
        end
    )
    term.setCursorBlink(false)

    -- read() consumes timer events, so begin a fresh GPS interval afterwards.
    restartGpsTimer()
    return cancelled and "" or input or ""
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
    elseif code == keys.c then
        return simpleAction("calibrate")
    elseif code == keys.f then
        return simpleAction("toggle_place")
    elseif code == keys.x then
        return simpleAction("toggle_dig")
    elseif code == keys.o then
        return simpleAction("toggle_allow_dig")
    elseif code == keys.p then
        return simpleAction("toggle_park")
    elseif code == keys.i then
        return simpleAction("config")
    elseif code == keys.r then
        return simpleAction("refuel")
    elseif code == keys.enter then
        return simpleAction("command")
    elseif code == keys.h then
        return simpleAction("help")
    end
end

local function handleAction(action, source)
    if not action then
        return
    end

    if source == "key" and action.type == "move" then
        if placeArmed then
            action = { type = "place", direction = action.direction }
        elseif digArmed then
            action = { type = "dig", direction = action.direction }
        end
    end

    if placeArmed and action.type ~= "place" and action.type ~= "toggle_place" then
        placeArmed = false
    end
    if digArmed and action.type ~= "dig" and action.type ~= "toggle_dig" then
        digArmed = false
    end

    if action.type == "command" then
        executeCommand(promptCommand())
    elseif action.type == "help" then
        showHelp()
    else
        executeAction(action)
    end
end

local function interfaceIsFocused()
    if type(multishell) ~= "table" or
        type(multishell.getCurrent) ~= "function" or
        type(multishell.getFocus) ~= "function" then
        return true
    end

    local currentOk, current = pcall(multishell.getCurrent)
    local focusOk, focus = pcall(multishell.getFocus)
    return not currentOk or not focusOk or current == focus
end

local function main()
    installTurtleSafetyGate()

    local initialized, message = initializeRuntime()
    if not initialized then
        error(message, 0)
    end

    if message then
        if startupMessageIsWarning(message) then
            setWarning(message)
        else
            setStatus(message, COLOR_TEXT)
        end
    end

    restartGpsTimer()

    while running do
        local buttons = drawInterface()
        local event, a, b, c = os.pullEvent()

        if event == "timer" and a == gpsTimer then
            if interfaceIsFocused() then
                verifyGpsCalibration()
            end
            restartGpsTimer()
        elseif event == "mouse_click" then
            handleAction(actionFromMouse(buttons, b, c), "mouse")
        elseif event == "key" then
            handleAction(actionFromKey(a), "key")
        elseif event == "term_resize" then
            updateTermSize()
        end
    end
end

local ok, reason = pcall(main)
restoreTurtleSafetyGate()
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
