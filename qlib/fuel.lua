-- qlib-release: 2
local pkgr = require "qlib.pkgr"
_ENV = pkgr.startModule(_ENV)

local conf = require "qlib.conf"

if type(turtle) ~= "table" then
    error("qlib.fuel requires the turtle API.", 0)
end

local SLOT_COUNT = 16
local UNLIMITED = math.huge

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(value, maximum))
end

local function configNumber(path, fallback)
    local value = tonumber(conf.get(path, fallback))
    return value ~= nil and value == value and value or fallback
end

local function configPercent(path, fallback)
    return clamp(configNumber(path, fallback), 0, 100)
end

local function finiteNumber(value)
    return type(value) == "number" and value == value and
        value ~= UNLIMITED and value ~= -UNLIMITED
end

local function normalizeSteps(steps)
    steps = steps == nil and 1 or steps

    if not finiteNumber(steps) then
        return nil, "steps must be a finite number"
    elseif steps < 0 then
        return nil, "steps cannot be negative"
    elseif steps % 1 ~= 0 then
        return nil, "steps must be an integer"
    end

    return steps
end

local function normalizeTargetLevel(target)
    if type(target) ~= "number" or target ~= target or target == -UNLIMITED then
        return nil, "target fuel level must be a number"
    elseif target < 0 then
        return nil, "target fuel level cannot be negative"
    end

    return target == UNLIMITED and target or math.ceil(target)
end

local function rawFuel(method)
    local value = turtle[method]()
    if value == "unlimited" then
        return UNLIMITED
    elseif type(value) ~= "number" then
        error("Unexpected turtle fuel " .. method:sub(8):lower() .. ": " .. tostring(value), 0)
    end
    return value
end

local function rawLevel()
    return rawFuel("getFuelLevel")
end

local function rawLimit()
    return rawFuel("getFuelLimit")
end

local function percentFor(levelValue, limitValue)
    if levelValue == UNLIMITED or limitValue == UNLIMITED then
        return 100
    elseif limitValue <= 0 then
        return 0
    end
    return clamp(levelValue / limitValue * 100, 0, 100)
end

local function percentTarget(percentValue, fuelLimit)
    if fuelLimit == UNLIMITED then
        return UNLIMITED
    end
    return math.ceil(fuelLimit * clamp(percentValue, 0, 100) / 100)
end

local function configuredTarget(fuelLimit, fuelReserve, targetPercentValue)
    if fuelLimit == UNLIMITED then
        return UNLIMITED
    end
    return math.min(math.max(
        percentTarget(targetPercentValue, fuelLimit),
        math.min(fuelReserve, fuelLimit)
    ), fuelLimit)
end

local function movementStatus(steps, fuelLevel, fuelReserve)
    local required = fuelReserve + steps
    if fuelLevel >= required then
        return true
    end
    return false, "insufficient fuel: need " .. required .. ", have " .. fuelLevel ..
        " (" .. fuelReserve .. " reserved)"
end

local function lowAt(fuelLevel, fuelLimit, fuelReserve, threshold)
    return fuelLevel ~= UNLIMITED and
        (fuelLevel <= fuelReserve or percentFor(fuelLevel, fuelLimit) <= threshold)
end

local function restoreSelection(selected)
    turtle.select(selected)
end

-- Refuel a slot just enough to reach target. The first item establishes its
-- actual value; the remainder can then be consumed in one operation.
local function consumeFuelSlot(slot, target)
    turtle.select(slot)

    if turtle.getItemCount(slot) <= 0 or not turtle.refuel(0) then
        return 0, 0
    end

    local beforeLevel = rawLevel()
    if beforeLevel == UNLIMITED or beforeLevel >= target then
        return 0, 0
    end

    local beforeCount = turtle.getItemCount(slot)
    if not turtle.refuel(1) then
        return 0, 0
    end

    local afterFirst = rawLevel()
    local used = math.max(beforeCount - turtle.getItemCount(slot), 0)
    if afterFirst == UNLIMITED then
        return UNLIMITED, used
    end

    local perItem = math.max(afterFirst - beforeLevel, 0)
    local remaining = turtle.getItemCount(slot)
    if afterFirst >= target or perItem <= 0 or remaining <= 0 then
        return perItem, used
    end

    local count = math.min(math.ceil((target - afterFirst) / perItem), remaining)
    if count <= 0 then
        return perItem, used
    end

    beforeCount = turtle.getItemCount(slot)
    local secondStart = rawLevel()
    turtle.refuel(count)
    used = used + math.max(beforeCount - turtle.getItemCount(slot), 0)

    local afterSecond = rawLevel()
    if afterSecond == UNLIMITED then
        return UNLIMITED, used
    end

    return perItem + math.max(afterSecond - secondStart, 0), used
end

function isEnabled()
    return conf.get("fuel.enabled", true) ~= false
end

function autoRefuelEnabled()
    return conf.get("fuel.autoRefuel", true) ~= false
end

-- -1 is the default emergency-only policy, 0 disables automatic attempts,
-- and a positive value proactively refuels below that percentage.
function autoRefuelPercent()
    local configured = configNumber("fuel.autoRefuelPercent", -1)
    return configured < 0 and -1 or clamp(configured, 0, 100)
end

function reserve()
    return math.max(math.floor(configNumber("fuel.reserve", 0)), 0)
end

function lowPercent()
    return configPercent("fuel.lowPercent", 20)
end

function targetPercent()
    return configPercent("fuel.targetPercent", 100)
end

function level()
    return rawLevel()
end

function limit()
    return rawLimit()
end

function isUnlimited()
    return rawLevel() == UNLIMITED
end

function percent()
    local fuelLevel = rawLevel()
    return fuelLevel == UNLIMITED and 100 or percentFor(fuelLevel, rawLimit())
end

function usable()
    local fuelLevel = rawLevel()
    return fuelLevel == UNLIMITED and UNLIMITED or math.max(fuelLevel - reserve(), 0)
end

function targetLevel()
    local fuelLimit = rawLimit()
    return configuredTarget(fuelLimit, reserve(), targetPercent())
end

function isLow()
    if not isEnabled() then
        return false
    end

    local fuelLevel = rawLevel()
    if fuelLevel == UNLIMITED then
        return false
    end

    local fuelReserve = reserve()
    if fuelLevel <= fuelReserve then
        return true
    end
    return percentFor(fuelLevel, rawLimit()) <= lowPercent()
end

-- Returns the first inventory slot containing valid turtle fuel and its detail.
function findFuel()
    local selected = turtle.getSelectedSlot()
    local ok, slot, detail = pcall(function()
        for index = 1, SLOT_COUNT do
            if turtle.getItemCount(index) > 0 then
                turtle.select(index)
                if turtle.refuel(0) then
                    return index, turtle.getItemDetail(index)
                end
            end
        end
    end)
    restoreSelection(selected)

    if not ok then
        error(slot, 0)
    end
    return slot, detail
end

function findFuelSlots()
    local selected = turtle.getSelectedSlot()
    local ok, slots = pcall(function()
        local result = {}
        for slot = 1, SLOT_COUNT do
            if turtle.getItemCount(slot) > 0 then
                turtle.select(slot)
                if turtle.refuel(0) then
                    result[#result + 1] = slot
                end
            end
        end
        return result
    end)
    restoreSelection(selected)

    if not ok then
        error(slots, 0)
    end
    return slots
end

-- Attempts to reach an absolute fuel level using fuel items in inventory.
-- Returns true, fuelAdded, itemsUsed or false, reason.
function refuelToLevel(target)
    local normalized, reason = normalizeTargetLevel(target)
    if not normalized then
        return false, reason
    end

    local current = rawLevel()
    if current == UNLIMITED or current >= normalized then
        return true, 0, 0
    end

    local fuelLimit = rawLimit()
    if fuelLimit == UNLIMITED then
        return true, 0, 0
    elseif normalized > fuelLimit then
        return false, "target fuel level exceeds turtle fuel limit"
    end

    local selected = turtle.getSelectedSlot()
    local added, used = 0, 0
    local ok, executionError = pcall(function()
        for slot = 1, SLOT_COUNT do
            if rawLevel() >= normalized then
                break
            elseif turtle.getItemCount(slot) > 0 then
                turtle.select(slot)
                if turtle.refuel(0) then
                    local fuelAdded, itemsUsed = consumeFuelSlot(slot, normalized)
                    if fuelAdded == UNLIMITED then
                        added = UNLIMITED
                    elseif added ~= UNLIMITED then
                        added = added + fuelAdded
                    end
                    used = used + itemsUsed
                end
            end
        end
    end)
    restoreSelection(selected)

    if not ok then
        return false, tostring(executionError)
    elseif rawLevel() >= normalized then
        return true, added, used
    end
    return false, "not enough fuel items available"
end

function refuel(requestedPercent)
    requestedPercent = requestedPercent == nil and targetPercent() or requestedPercent
    if not finiteNumber(requestedPercent) then
        return false, "target percent must be a finite number"
    elseif requestedPercent < 0 or requestedPercent > 100 then
        return false, "target percent must be between 0 and 100"
    end

    if rawLevel() == UNLIMITED then
        return true, 0, 0
    end
    local fuelLimit = rawLimit()

    return refuelToLevel(configuredTarget(fuelLimit, reserve(), requestedPercent))
end

function canMove(steps)
    local normalized, reason = normalizeSteps(steps)
    if not normalized then
        return false, reason
    elseif not isEnabled() then
        return true
    end

    local fuelLevel = rawLevel()
    if fuelLevel == UNLIMITED then
        return true
    end
    return movementStatus(normalized, fuelLevel, reserve())
end

function require(steps)
    local normalized, reason = normalizeSteps(steps)
    if not normalized then
        return false, reason
    elseif not isEnabled() then
        return true
    end

    local fuelLevel = rawLevel()
    if fuelLevel == UNLIMITED then
        return true
    end

    local fuelReserve = reserve()
    local canProceed, failureReason = movementStatus(normalized, fuelLevel, fuelReserve)
    local automaticPercent = autoRefuelPercent()
    local fuelLimit = rawLimit()
    local shouldRefuel = normalized > 0 and autoRefuelEnabled() and (
        (automaticPercent < 0 and not canProceed) or
        (automaticPercent > 0 and percentFor(fuelLevel, fuelLimit) < automaticPercent)
    )

    if shouldRefuel then
        local required = fuelReserve + normalized
        if required > fuelLimit then
            return false, "movement requires " .. required ..
                " fuel including reserve, but fuel limit is " .. fuelLimit
        end

        local target = configuredTarget(fuelLimit, fuelReserve, targetPercent())
        refuelToLevel(math.max(required, target))
        canProceed, failureReason = movementStatus(normalized, rawLevel(), fuelReserve)
    end

    if canProceed then
        return true
    end
    return false, failureReason
end

function getState()
    local fuelLevel = rawLevel()
    local fuelLimit = rawLimit()
    local unlimited = fuelLevel == UNLIMITED
    local fuelReserve = reserve()
    local enabled = isEnabled()
    local lowThreshold = lowPercent()

    return {
        enabled = enabled,
        unlimited = unlimited,
        level = fuelLevel,
        limit = fuelLimit,
        percent = percentFor(fuelLevel, fuelLimit),
        reserve = fuelReserve,
        usable = unlimited and UNLIMITED or math.max(fuelLevel - fuelReserve, 0),
        low = enabled and lowAt(fuelLevel, fuelLimit, fuelReserve, lowThreshold),
        lowPercent = lowThreshold,
        targetPercent = targetPercent(),
        autoRefuel = autoRefuelEnabled(),
        autoRefuelPercent = autoRefuelPercent()
    }
end

return pkgr.endModule(_ENV)
