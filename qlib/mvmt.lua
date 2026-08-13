local pkgr = require "qlib.pkgr"
pkgr.startModule(_ENV or getfenv())

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
local moveDirections = { forward = true, back = true, left = true, right = true, up = true, down = true }

local blacklistOverride

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
    return success, success and nil or reason or "Insufficient fuel"
end

local function checkpointState()
    if not configFlag("movement.saveEveryMove", true) then
        return true
    end

    local success, reason = task.save()
    return success, success and nil or reason or "Unable to save task state"
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
    for _ = 1, 4 do
        if not turtle.detect() then
            return true
        end
        if not moveRaw.right() then
            return false, "Unable to turn during calibration"
        end
    end
    if not digAllowed then
        return false, "Unable to find a clear horizontal calibration direction"
    end

    for _ = 1, 4 do
        local cleared = safeDig("forward")
        if cleared and not turtle.detect() then
            return true
        end
        if not moveRaw.right() then
            return false, "Unable to turn during calibration"
        end
    end
    return false, "Unable to find a clear horizontal calibration direction"
end

-- Reserve the outward and return steps before invalidating the existing calibration.
function calibrate(digAllowed, timeout)
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
    task.invalidateCalibration()
    local saved, saveReason = checkpointState()
    if not saved then
        return false, "Unable to safely begin calibration: " .. tostring(saveReason)
    end

    local startPosition = locate(timeout)
    if not startPosition then
        return false, "Unable to acquire initial GPS position"
    end
    local directionFound, directionReason = findClearCalibrationDirection(digAllowed)
    if not directionFound then
        return false, directionReason
    end

    local moved, moveReason = moveRaw.forward()
    if not moved and attack("forward") then
        moved, moveReason = moveRaw.forward()
    end
    if not moved then
        return false, moveReason or "Unable to move during calibration"
    end

    local newPosition = locate(timeout)
    if not newPosition then
        moveRaw.back()
        return false, "Unable to acquire second GPS position"
    end
    local rotation = startPosition:cardinalTo(newPosition)
    if not rotation or not util.isHorizontalDirection(rotation) then
        moveRaw.back()
        return false, "GPS displacement did not produce a valid horizontal direction"
    end

    task.setState(newPosition, rotation, true)
    local calibrationSaved, calibrationSaveReason = checkpointState()
    local returned, returnWarning = back(false)
    if not returned then
        local warning = "Calibration succeeded at " .. task.getPosition():strXYZ(task.getRotation()) ..
            ", but the turtle could not return to its starting position"
        if calibrationSaveReason then
            warning = warning .. "; calibrated state checkpoint failed: " .. tostring(calibrationSaveReason)
        end
        return true, warning
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
    for character in route:gmatch(".") do
        if not character:match("%s") then
            stepNumber = stepNumber + 1
            character = string.lower(character)
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

return pkgr.endModule(getfenv())
