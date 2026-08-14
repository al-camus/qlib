-- qlib-release: 2
local pkgr = require "qlib.pkgr"
_ENV = pkgr.startModule(_ENV)

local util = require "qlib.util"
local task = require "qlib.task"
local conf = require "qlib.conf"
local fuel = require "qlib.fuel"

if not turtle then
    error("qlib.mvmt requires a turtle", 0)
end

-- Keep direct turtle movement private so task state and fuel policy cannot be bypassed.
local moveRaw = {
    up = turtle.up, down = turtle.down,
    forward = turtle.forward, back = turtle.back,
    left = turtle.turnLeft, right = turtle.turnRight
}
local inspectRaw = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }
local digRaw = { forward = turtle.dig, up = turtle.digUp, down = turtle.digDown }
local attackRaw = { forward = turtle.attack, up = turtle.attackUp, down = turtle.attackDown }
local placeRaw = { forward = turtle.place, up = turtle.placeUp, down = turtle.placeDown }
local moveDirections = { forward = true, back = true, left = true, right = true, up = true, down = true }

local blacklistOverride
local parked = false

PARKED_MESSAGE = "Turtle is parked."

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function configFlag(path, fallback)
    return conf.get(path, fallback) == true
end

local function resolveDigAllowed(value)
    return value == nil and configFlag("movement.defaultDig", false) or value == true
end

local function getConfiguredMaxAttempts()
    local attempts = conf.get("movement.maxRetries", 10)
    return isFiniteNumber(attempts) and math.max(1, math.floor(attempts)) or 10
end

local function normalizeMoveDirection(direction)
    direction = util.normalizeDirection(direction)
    return moveDirections[direction] and direction or nil
end

local function normalizeCardinal(direction)
    direction = util.normalizeDirection(direction)
    return util.isHorizontalDirection(direction) and direction or nil
end

local function requireMovementFuel(steps)
    local success, reason = fuel.require(steps)
    if success then
        return true
    end
    return false, reason or "Insufficient fuel"
end

local function checkpointState()
    if not configFlag("movement.saveEveryMove", true) then
        return true
    end

    local success, reason = task.save()
    if success then
        return true
    end
    return false, reason or "Unable to save task state"
end

local function finishStateChange(context)
    local saved, reason = checkpointState()
    if saved then
        return true
    end
    return true, (context or "State changed") .. ", but state checkpoint failed: " .. tostring(reason)
end

local function logMovement(direction)
    if direction == "up" or direction == "down" then
        task.offsetPosition(util.cardinal_vectors[direction])
    elseif direction == "forward" or direction == "back" then
        local vector = util.cardinal_vectors[task.getRotation()]
        task.offsetPosition(direction == "forward" and vector or -vector)
    elseif direction == "left" or direction == "right" then
        local rotations = direction == "left" and util.cardinal_left or util.cardinal_right
        task.setRotation(rotations[task.getRotation()])
    else
        error('Unable to log unknown movement "' .. tostring(direction) .. '"', 2)
    end
end

local function normalizeBlacklist(source, strict)
    if type(source) ~= "table" then
        if strict then
            error("blacklist must be a table or nil", 3)
        end
        return {}
    end

    local normalized = {}
    for _, value in ipairs(source) do
        if type(value) ~= "string" then
            if strict then
                error("blacklist entries must be strings", 3)
            end
        else
            value = string.lower(util.trimString(value))
            if value ~= "" then
                normalized[#normalized + 1] = value
            end
        end
    end
    return normalized
end

local function effectiveBlacklist()
    return blacklistOverride or normalizeBlacklist(conf.get("movement.digBlacklist", {}))
end

local function isBlacklisted(blockName)
    if type(blockName) ~= "string" then
        return false
    end

    local normalized = string.lower(blockName)
    for _, value in ipairs(effectiveBlacklist()) do
        if normalized:find(value, 1, true) then
            return true, value
        end
    end
    return false
end

function setBlacklist(newBlacklist)
    if newBlacklist == nil then
        blacklistOverride = nil
    else
        blacklistOverride = normalizeBlacklist(newBlacklist, true)
    end
    return true
end

function clearBlacklistOverride()
    blacklistOverride = nil
    return true
end

function getBlacklist()
    return util.cloneTable(effectiveBlacklist())
end

function isUsingBlacklistOverride()
    return blacklistOverride ~= nil
end

function isParked()
    return parked
end

function setParked(value)
    if type(value) ~= "boolean" then
        error("parked must be a boolean, got " .. type(value), 2)
    end

    parked = value
    return true
end

function safeDig(direction)
    direction = util.normalizeDirection(direction or "forward")
    local inspect, dig = inspectRaw[direction], digRaw[direction]
    if not inspect or not dig then
        return false, 'Cannot dig direction "' .. tostring(direction) .. '"'
    end

    local found, block = inspect()
    if not found then
        return true
    end
    if type(block) ~= "table" or type(block.name) ~= "string" then
        return false, "Unable to identify obstructing block"
    end

    local blocked, entry = isBlacklisted(block.name)
    if blocked then
        return false, 'Protected block "' .. block.name .. '" matched blacklist entry "' .. entry .. '"'
    end

    local success, reason = dig()
    if success then
        return true
    end
    return false, reason or ('Unable to dig "' .. block.name .. '"')
end

local function attack(direction)
    local action = configFlag("movement.attackObstructions", true) and attackRaw[direction]
    return action and action() or false
end

local function completeMovement(direction, context)
    logMovement(direction)
    return finishStateChange(context)
end

-- A failed physical move does not consume fuel, so an attack retry needs no new authorization.
local function moveWithAttack(direction)
    local success, reason = moveRaw[direction]()
    if not success and attack(direction) then
        success, reason = moveRaw[direction]()
    end
    return success, reason
end

local function moveTranslation(direction, digAllowed)
    local fuelReady, fuelReason = requireMovementFuel(1)
    if not fuelReady then
        return false, "Unable to move " .. direction .. ": " .. tostring(fuelReason)
    end

    if resolveDigAllowed(digAllowed) then
        local cleared, reason = safeDig(direction)
        if not cleared then
            return false, reason
        end
    end

    local success, reason = moveWithAttack(direction)
    if success then
        return completeMovement(direction, "Movement succeeded")
    end
    return false, reason or "Unable to move " .. direction
end

local function rawTurn(direction, count)
    local completed = 0
    for _ = 1, count or 1 do
        if not moveRaw[direction]() then
            return false, completed
        end
        completed = completed + 1
    end
    return true, completed
end

local function invalidateAfterUnrestoredTurn(message)
    task.invalidateCalibration()
    local _, saveReason = checkpointState()
    return false, message .. (saveReason and " (" .. tostring(saveReason) .. ")" or "")
end

-- ComputerCraft has no digBack/attackBack. Clear a blocked rear square while temporarily facing it.
local function moveBackward(digAllowed)
    digAllowed = resolveDigAllowed(digAllowed)
    local fuelReady, fuelReason = requireMovementFuel(1)
    if not fuelReady then
        return false, "Unable to move backward: " .. tostring(fuelReason)
    end

    local success, reason = moveRaw.back()
    if success then
        return completeMovement("back", "Backward movement succeeded")
    end

    if not digAllowed and not configFlag("movement.attackObstructions", true) then
        return false, reason or "Unable to move backward"
    end

    local turned, completedTurns = rawTurn("right", 2)
    if not turned then
        if not rawTurn("left", completedTurns) then
            return invalidateAfterUnrestoredTurn(
                "Unable to turn around for backward movement; orientation could not be safely restored"
            )
        end
        return false, "Unable to turn around for backward movement"
    end

    local moved, failureReason = false
    if digAllowed then
        local cleared
        cleared, failureReason = safeDig("forward")
        if cleared then
            failureReason = nil
        end
    end
    if not failureReason then
        moved, failureReason = moveWithAttack("forward")
    end

    local restored = rawTurn("right", 2)
    if moved then
        logMovement("back")
    end
    if not restored then
        task.invalidateCalibration()
        local saved, saveReason = checkpointState()
        if moved then
            return true, "Moved backward, but failed to restore orientation; calibration has been invalidated" ..
                (not saved and " and state checkpoint failed: " .. tostring(saveReason) or "")
        end
        return false, "Backward movement failed and orientation could not be restored"
    end
    if not moved then
        return false, failureReason or reason or "Unable to move backward"
    end
    return finishStateChange("Backward movement succeeded")
end

function go(direction, digAllowed)
    local normalized = util.normalizeDirection(direction)
    if not normalized then
        return false, 'Unknown direction "' .. tostring(direction) .. '"'
    end

    if parked and normalized ~= "left" and normalized ~= "right" then
        return false, PARKED_MESSAGE
    end

    if util.isHorizontalDirection(normalized) then
        return goCardinal(normalized, digAllowed)
    end

    local moveDirection = normalizeMoveDirection(normalized)
    if not moveDirection then
        return false, 'Unsupported movement direction "' .. tostring(direction) .. '"'
    end
    if moveDirection == "left" or moveDirection == "right" then
        local success, reason = moveRaw[moveDirection]()
        if not success then
            return false, reason or "Unable to turn " .. moveDirection
        end
        return completeMovement(moveDirection, "Rotation succeeded")
    end
    if moveDirection == "back" then
        return moveBackward(digAllowed)
    end
    return moveTranslation(moveDirection, digAllowed)
end

function up(digAllowed) return go("up", digAllowed) end
function down(digAllowed) return go("down", digAllowed) end
function forward(digAllowed) return go("forward", digAllowed) end
function back(digAllowed) return go("back", digAllowed) end
function left() return go("left") end
function right() return go("right") end

function face(rotation)
    local target = normalizeCardinal(rotation)
    if not target then
        return false, 'Invalid rotation "' .. tostring(rotation) .. '"'
    end
    if not task.isCalibrated() then
        return false, "Cannot face an absolute direction while uncalibrated"
    end

    local current = task.getRotation()
    if current == target then
        return true
    end
    if util.cardinal_right[current] == target then
        return right()
    end
    if util.cardinal_left[current] == target then
        return left()
    end
    if util.cardinal_reverse[current] ~= target then
        return false, "Unable to determine required rotation"
    end

    local success, firstWarning = right()
    if not success then
        return false, firstWarning
    end
    local secondWarning
    success, secondWarning = right()
    if not success then
        return false, secondWarning or "Unable to complete 180 degree turn"
    end
    return true, secondWarning or firstWarning
end

local function resolvePlacementDirection(direction)
    local normalized = util.normalizeDirection(direction)
    if not normalized then
        return nil, 'Unknown placement direction "' .. tostring(direction) .. '"'
    end

    if util.isHorizontalDirection(normalized) then
        if not task.isCalibrated() then
            return nil, "Cannot place in an absolute direction while uncalibrated"
        end

        local current = task.getRotation()
        if normalized == current then
            return "forward"
        elseif util.cardinal_left[current] == normalized then
            return "left"
        elseif util.cardinal_right[current] == normalized then
            return "right"
        elseif util.cardinal_reverse[current] == normalized then
            return "back"
        end
    elseif placeRaw[normalized] or normalized == "left" or normalized == "right" or normalized == "back" then
        return normalized
    end

    return nil, 'Unsupported placement direction "' .. tostring(direction) .. '"'
end

local function resolveDigDirection(direction)
    local normalized = util.normalizeDirection(direction)
    if not normalized then
        return nil, 'Unknown dig direction "' .. tostring(direction) .. '"'
    end

    if util.isHorizontalDirection(normalized) then
        if not task.isCalibrated() then
            return nil, "Cannot dig in an absolute direction while uncalibrated"
        end

        local current = task.getRotation()
        if normalized == current then
            return "forward"
        elseif util.cardinal_left[current] == normalized then
            return "left"
        elseif util.cardinal_right[current] == normalized then
            return "right"
        elseif util.cardinal_reverse[current] == normalized then
            return "back"
        end
    elseif digRaw[normalized] or normalized == "left" or normalized == "right" or normalized == "back" then
        return normalized
    end

    return nil, 'Unsupported dig direction "' .. tostring(direction) .. '"'
end

local interactionTurns = {
    left = { direction = "left", count = 1, restore = "right" },
    right = { direction = "right", count = 1, restore = "left" },
    back = { direction = "right", count = 2, restore = "left" }
}

local function addMessage(messages, message)
    if message and message ~= "" then
        messages[#messages + 1] = tostring(message)
    end
end

function place(direction, text)
    local resolved, resolveError = resolvePlacementDirection(direction)
    if not resolved then
        return false, resolveError
    end

    local placeFunction = placeRaw[resolved]
    if placeFunction then
        local success, reason = placeFunction(text)
        if success then
            return true
        end
        return false, reason or "Unable to place block " .. resolved
    end

    local plan = interactionTurns[resolved]
    local warnings, turnErrors, completedTurns = {}, {}, 0
    for _ = 1, plan.count do
        local turned, message = go(plan.direction)
        if not turned then
            addMessage(turnErrors, message or "Unable to turn " .. plan.direction)
            break
        end
        completedTurns = completedTurns + 1
        addMessage(warnings, message)
    end

    local placed, placeError = false, nil
    if completedTurns == plan.count then
        placed, placeError = placeRaw.forward(text)
        if not placed then
            placeError = placeError or "Unable to place block " .. resolved
        end
    else
        placeError = "Unable to face placement direction"
    end

    local restoreErrors = {}
    for _ = 1, completedTurns do
        local restored, message = go(plan.restore)
        if restored then
            addMessage(warnings, message)
        else
            addMessage(restoreErrors, message or "Unable to turn " .. plan.restore)
            break
        end
    end

    local finalSaveError
    if task.isDirty() then
        local finalSaved
        finalSaved, finalSaveError = task.save()
        if finalSaved then
            finalSaveError = nil
        end
    end

    if #restoreErrors > 0 then
        local restoreMessage = "orientation could not be restored: " .. table.concat(restoreErrors, "; ")
        if finalSaveError then
            restoreMessage = restoreMessage .. "; state save failed: " .. tostring(finalSaveError)
        end
        if placed then
            local messages = { "Block placed, but " .. restoreMessage }
            for _, message in ipairs(warnings) do
                addMessage(messages, message)
            end
            return true, table.concat(messages, "; ")
        end
        local errors = { tostring(placeError) }
        for _, message in ipairs(turnErrors) do
            addMessage(errors, message)
        end
        addMessage(errors, restoreMessage)
        return false, table.concat(errors, "; ")
    elseif not placed then
        local errors = { tostring(placeError) }
        for _, message in ipairs(turnErrors) do
            addMessage(errors, message)
        end
        if finalSaveError then
            addMessage(errors, "state save failed: " .. tostring(finalSaveError))
        end
        return false, table.concat(errors, "; ")
    elseif #warnings > 0 or finalSaveError then
        if finalSaveError then
            addMessage(warnings, "state save failed: " .. tostring(finalSaveError))
        end
        return true, table.concat(warnings, "; ")
    end

    return true
end

function dig(direction)
    local resolved, resolveError = resolveDigDirection(direction)
    if not resolved then
        return false, resolveError
    end

    if digRaw[resolved] then
        return safeDig(resolved)
    end

    local plan = interactionTurns[resolved]
    local warnings, turnErrors, completedTurns = {}, {}, 0

    for _ = 1, plan.count do
        local turned, message = go(plan.direction)
        if not turned then
            addMessage(turnErrors, message or "Unable to turn " .. plan.direction)
            break
        end
        completedTurns = completedTurns + 1
        addMessage(warnings, message)
    end

    local dug, digError = false, nil
    if completedTurns == plan.count then
        dug, digError = safeDig("forward")
        if not dug then
            digError = digError or "Unable to dig block " .. resolved
        end
    else
        digError = "Unable to face dig direction"
    end

    local restoreErrors = {}
    for _ = 1, completedTurns do
        local restored, message = go(plan.restore)
        if restored then
            addMessage(warnings, message)
        else
            addMessage(restoreErrors, message or "Unable to turn " .. plan.restore)
            break
        end
    end

    local finalSaveError
    if task.isDirty() then
        local finalSaved
        finalSaved, finalSaveError = task.save()
        if finalSaved then
            finalSaveError = nil
        end
    end

    if #restoreErrors > 0 then
        local restoreMessage = "orientation could not be restored: " .. table.concat(restoreErrors, "; ")
        if finalSaveError then
            restoreMessage = restoreMessage .. "; state save failed: " .. tostring(finalSaveError)
        end

        if dug then
            local messages = { "Dig completed, but " .. restoreMessage }
            for _, message in ipairs(warnings) do
                addMessage(messages, message)
            end
            return true, table.concat(messages, "; ")
        end

        local errors = { tostring(digError) }
        for _, message in ipairs(turnErrors) do
            addMessage(errors, message)
        end
        addMessage(errors, restoreMessage)
        return false, table.concat(errors, "; ")
    elseif not dug then
        local errors = { tostring(digError) }
        for _, message in ipairs(turnErrors) do
            addMessage(errors, message)
        end
        if finalSaveError then
            addMessage(errors, "state save failed: " .. tostring(finalSaveError))
        end
        return false, table.concat(errors, "; ")
    elseif #warnings > 0 or finalSaveError then
        if finalSaveError then
            addMessage(warnings, "state save failed: " .. tostring(finalSaveError))
        end
        return true, table.concat(warnings, "; ")
    end

    return true
end

function goCardinal(direction, digAllowed)
    local cardinal = normalizeCardinal(direction)
    if not cardinal then
        return false, 'Invalid cardinal direction "' .. tostring(direction) .. '"'
    end

    local faced, warning = face(cardinal)
    if not faced then
        return false, warning
    end
    local success, moveWarning = forward(digAllowed)
    return success, success and (moveWarning or warning) or moveWarning
end

function north(digAllowed) return goCardinal("north", digAllowed) end
function south(digAllowed) return goCardinal("south", digAllowed) end
function east(digAllowed) return goCardinal("east", digAllowed) end
function west(digAllowed) return goCardinal("west", digAllowed) end

function goUntilSuccess(direction, digAllowed, maxAttempts)
    local normalized = util.normalizeDirection(direction)
    if parked and normalized ~= "left" and normalized ~= "right" then
        return false, PARKED_MESSAGE, 0
    end

    maxAttempts = maxAttempts == nil and getConfiguredMaxAttempts() or maxAttempts
    if maxAttempts ~= math.huge then
        if not isFiniteNumber(maxAttempts) then
            error("maxAttempts must be a finite number or math.huge", 2)
        end
        maxAttempts = math.floor(maxAttempts)
        if maxAttempts < 1 then
            error("maxAttempts must be at least 1", 2)
        end
    end

    local attempts, lastReason = 0
    while maxAttempts == math.huge or attempts < maxAttempts do
        attempts = attempts + 1
        local success, message = go(direction, digAllowed)
        if success then
            return true, message, attempts
        end
        lastReason = message
        if maxAttempts == math.huge or attempts < maxAttempts then
            sleep(0)
        end
    end
    return false, lastReason or "Movement attempt limit reached", attempts
end

function goAbsolute(direction, digAllowed, maxAttempts)
    return goUntilSuccess(direction, digAllowed, maxAttempts)
end

local function locate(timeout)
    local ok, x, y, z = pcall(gps.locate, timeout)
    return ok and x and util.Vector3.new(x, y, z) or nil
end

local function findClearCalibrationDirection(digAllowed)
    local completedTurns = 0
    for _ = 1, 4 do
        if not turtle.detect() then
            return true, nil, completedTurns
        end
        if not moveRaw.right() then
            return false, "Unable to turn during calibration", completedTurns
        end
        completedTurns = completedTurns + 1
    end
    if not digAllowed then
        return false, "Unable to find a clear horizontal calibration direction", completedTurns
    end

    for _ = 1, 4 do
        local cleared = safeDig("forward")
        if cleared and not turtle.detect() then
            return true, nil, completedTurns
        end
        if not moveRaw.right() then
            return false, "Unable to turn during calibration", completedTurns
        end
        completedTurns = completedTurns + 1
    end
    return false, "Unable to find a clear horizontal calibration direction", completedTurns
end

local function restoreCalibrationPose(completedTurns, movedForward)
    local problems = {}
    if movedForward then
        local returned, reason = moveRaw.back()
        if not returned then
            problems[#problems + 1] = reason or "unable to return from calibration probe"
        end
    end

    local turnsToRestore = completedTurns % 4
    if turnsToRestore > 0 then
        local restored, restoredTurns = rawTurn("left", turnsToRestore)
        if not restored then
            problems[#problems + 1] = "restored only " .. restoredTurns .. "/" .. turnsToRestore ..
                " calibration turns"
        end
    end

    return #problems == 0, table.concat(problems, "; ")
end

local function withCalibrationCleanup(message, completedTurns, movedForward)
    local restored, restoreError = restoreCalibrationPose(completedTurns, movedForward)
    if restored then
        return message
    end
    return message .. "; cleanup failed: " .. restoreError
end

-- Reserve the outward and return steps before invalidating the existing calibration.
function calibrate(digAllowed, timeout)
    if parked then
        return false, PARKED_MESSAGE
    end

    if not gps or type(gps.locate) ~= "function" then
        return false, "GPS API is unavailable"
    end
    digAllowed = resolveDigAllowed(digAllowed)
    timeout = timeout or conf.get("startup.gpsTimeout", 2)
    if not isFiniteNumber(timeout) or timeout <= 0 then
        return false, "GPS timeout must be a positive number"
    end

    local fuelReady, fuelReason = requireMovementFuel(2)
    if not fuelReady then
        return false, "Unable to safely begin calibration: " .. tostring(fuelReason)
    end
    local priorRelativePosition = task.getRelativePosition()
    task.invalidateCalibration()
    -- Calibration boundaries are safety-critical and must be durable even
    -- when ordinary per-move checkpoints are disabled.
    local saved, saveReason = task.save()
    if not saved then
        return false, "Unable to safely begin calibration: " .. tostring(saveReason)
    end

    local startPosition = locate(timeout)
    if not startPosition then
        return false, "Unable to acquire initial GPS position"
    end
    local directionFound, directionReason, completedTurns = findClearCalibrationDirection(digAllowed)
    if not directionFound then
        return false, withCalibrationCleanup(directionReason, completedTurns, false)
    end

    local moved, moveReason = moveRaw.forward()
    if not moved and attack("forward") then
        moved, moveReason = moveRaw.forward()
    end
    if not moved then
        return false, withCalibrationCleanup(
            moveReason or "Unable to move during calibration",
            completedTurns,
            false
        )
    end

    local newPosition = locate(timeout)
    if not newPosition then
        return false, withCalibrationCleanup(
            "Unable to acquire second GPS position",
            completedTurns,
            true
        )
    end
    local rotation = startPosition:cardinalTo(newPosition)
    if not rotation or not util.isHorizontalDirection(rotation) then
        return false, withCalibrationCleanup(
            "GPS displacement did not produce a valid horizontal direction",
            completedTurns,
            true
        )
    end

    if not task.hasRelativeOrigin() then
        task.setRelativeOrigin(startPosition - priorRelativePosition)
    end
    task.setState(newPosition, rotation, true)
    local calibrationSaved, calibrationSaveReason = task.save()
    local returned, returnWarning = back(false)
    if not task.isCalibrated() then
        local forcedSaved, forcedSaveError = task.save()
        local invalidMessage = returnWarning or "Calibration return left the turtle's orientation uncertain"
        if not forcedSaved then
            invalidMessage = invalidMessage .. "; state save failed: " .. tostring(forcedSaveError)
        end
        return false, invalidMessage
    end
    if not returned then
        local probeSaved, probeSaveError = task.save()
        local warning = "Calibration succeeded at " .. task.getPosition():strXYZ(task.getRotation()) ..
            ", but the turtle could not return to its starting position"
        if not probeSaved then
            warning = warning .. "; calibrated state save failed: " .. tostring(probeSaveError)
        elseif calibrationSaveReason then
            warning = warning .. "; calibrated state checkpoint failed: " .. tostring(calibrationSaveReason)
        end
        return true, warning
    end
    local finalSaved, finalSaveReason = task.save()
    if not finalSaved then
        return true, "Calibration succeeded, but the final state save failed: " .. tostring(finalSaveReason)
    end
    if returnWarning then
        return true, returnWarning
    end
    if not calibrationSaved then
        return true, "Calibration succeeded, but an intermediate state checkpoint failed: " ..
            tostring(calibrationSaveReason)
    end
    return true
end

local routeActions = {
    f = forward, b = back, l = left, r = right,
    u = up, d = down, n = north, s = south, e = east, w = west
}

local function addWarning(warnings, step, message)
    if message then
        warnings[#warnings + 1] = { step = step, message = message }
    end
end

function followRoute(route, digAllowed)
    if type(route) ~= "string" then
        error("route must be a string", 2)
    end

    local stepNumber, warnings = 0, {}
    for routeCharacter in route:gmatch(".") do
        if not routeCharacter:match("%s") then
            stepNumber = stepNumber + 1
            local character = string.lower(routeCharacter)
            local action = routeActions[character]
            if not action then
                return false, 'Invalid route character "' .. character .. '" at step ' .. stepNumber,
                    stepNumber - 1, warnings
            end
            local success, message = action(digAllowed)
            if not success then
                return false, "Route failed at step " .. stepNumber .. " (" .. character .. "): " ..
                    tostring(message or "movement failed"), stepNumber - 1, warnings
            end
            addWarning(warnings, stepNumber, message)
        end
    end
    return true, stepNumber, warnings
end

function followPath(path, offset, digAllowed, maxSteps)
    if type(path) ~= "table" or type(path.next) ~= "function" then
        error("path must provide path:next(position)", 2)
    end
    offset = util.Vector3.new(offset or { x = 0, y = 0, z = 0 })
    if maxSteps == nil then
        local ok, length = pcall(function() return #path end)
        if ok and type(length) == "number" and length > 0 then
            maxSteps = length
        end
    end
    if maxSteps == nil then
        return false, "followPath requires maxSteps when path length is unavailable", 0, {}
    end
    if not isFiniteNumber(maxSteps) then
        error("maxSteps must be a finite number", 2)
    end
    maxSteps = math.floor(maxSteps)
    if maxSteps < 1 then
        return true, 0, {}
    end

    local completed, warnings = 0, {}
    for _ = 1, maxSteps do
        local movement = path:next(task.getPosition() - offset)
        if not movement then
            return true, completed, warnings
        end
        local success, message = go(movement, digAllowed)
        if not success then
            return false, message or "Path movement failed", completed, warnings
        end
        completed = completed + 1
        addWarning(warnings, completed, message)
    end
    return true, completed, warnings
end

function goDownToGround(maxDistance)
    if maxDistance ~= nil then
        if not isFiniteNumber(maxDistance) or maxDistance < 0 then
            error("maxDistance must be a non-negative number or nil", 2)
        end
        maxDistance = math.floor(maxDistance)
    end

    local moved, warnings = 0, {}
    while not turtle.inspectDown() do
        if maxDistance and moved >= maxDistance then
            return false, "Ground not found within maximum distance", moved, warnings
        end
        local success, message = down(false)
        if not success then
            return false, message or "Unable to descend", moved, warnings
        end
        moved = moved + 1
        addWarning(warnings, moved, message)
    end
    return true, moved, warnings
end

function getAdjacentPos(direction)
    return task.getPosition():getAdjacentPos(direction, task.getRotation())
end

return pkgr.endModule(_ENV)
