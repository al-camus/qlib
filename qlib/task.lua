-- qlib-release: 2
local pkgr = require "qlib.pkgr"
_ENV = pkgr.startModule(_ENV)

local util = require "qlib.util"

STATE_VERSION = 2
LEGACY_STATE_VERSION = 1
DEFAULT_STORAGE_PATH = ".rcgpt/task.state"

local pos = util.Vector3.new()
local rot = "north"
local calibrated = false
local relativeOrigin
local storagePath = DEFAULT_STORAGE_PATH
local dirty = false

local function assertString(value, name, level)
    if type(value) ~= "string" or value == "" then
        error((name or "value") .. " must be a non-empty string", level or 3)
    end
end

local function assertBoolean(value, name, level)
    if type(value) ~= "boolean" then
        error((name or "value") .. " must be a boolean, got " .. type(value), level or 3)
    end
end

local function normalizeRotation(direction)
    direction = util.normalizeDirection(direction)
    return util.isHorizontalDirection(direction) and direction or nil
end

local function setRuntimeState(state, changed)
    pos, rot, calibrated = state.pos, state.rot, state.calibrated
    relativeOrigin = state.relativeOrigin
    dirty = changed
end

local function stateSnapshot()
    local snapshot = {
        version = STATE_VERSION,
        pos = { x = pos.x, y = pos.y, z = pos.z },
        rot = rot,
        calibrated = calibrated
    }

    if relativeOrigin then
        snapshot.relativeOrigin = {
            x = relativeOrigin.x,
            y = relativeOrigin.y,
            z = relativeOrigin.z
        }
    end

    return snapshot
end

local function validateVector(value, label)
    if type(value) ~= "table" then
        return nil, label .. " is missing"
    elseif type(value.x) ~= "number" or type(value.y) ~= "number" or type(value.z) ~= "number" then
        return nil, label .. " contains invalid coordinates"
    end

    return util.Vector3.new(value.x, value.y, value.z)
end

local function validateStoredState(state)
    if type(state) ~= "table" then
        return nil, "state is not a table"
    elseif state.version ~= STATE_VERSION and state.version ~= LEGACY_STATE_VERSION then
        return nil, "unsupported task state version: " .. tostring(state.version)
    end

    local newPosition, positionError = validateVector(state.pos, "state position")
    if not newPosition then
        return nil, positionError
    end

    local newRotation = normalizeRotation(state.rot)
    if not newRotation then
        return nil, "state contains invalid rotation: " .. tostring(state.rot)
    elseif type(state.calibrated) ~= "boolean" then
        return nil, "state contains invalid calibration status"
    end

    local newOrigin
    local migrated = state.version == LEGACY_STATE_VERSION
    if state.version == STATE_VERSION and state.relativeOrigin ~= nil then
        local originError
        newOrigin, originError = validateVector(state.relativeOrigin, "state relative origin")
        if not newOrigin then
            return nil, originError
        end
    elseif state.version == STATE_VERSION and state.calibrated then
        -- Repair early version-2 files which omitted the origin. Their current
        -- GPS position is the only safe relative zero available.
        newOrigin = newPosition:clone()
        migrated = true
    elseif state.version == LEGACY_STATE_VERSION and state.calibrated then
        -- Legacy calibrated state only tracked GPS coordinates. Treat the
        -- saved position as relative zero when adding the new origin.
        newOrigin = newPosition:clone()
    elseif state.version == LEGACY_STATE_VERSION then
        -- A legacy uncalibrated position may be either local coordinates or a
        -- stale GPS fix; there is no marker to distinguish them. Reset it to a
        -- safe relative zero before automatic calibration establishes origin.
        newPosition = util.Vector3.new()
    end

    return {
        pos = newPosition,
        rot = newRotation,
        calibrated = state.calibrated,
        relativeOrigin = newOrigin
    }, nil, migrated
end

local function writeFile(path, contents)
    local directory = fs.getDir(path)
    if directory ~= "" and not fs.exists(directory) then
        fs.makeDir(directory)
    end

    local file = fs.open(path, "w")
    if not file then
        return false, 'Unable to open "' .. path .. '" for writing'
    end
    file.write(contents)
    file.close()
    return true
end

local function readStoredState(path)
    if not fs.exists(path) then
        return nil, 'State file "' .. path .. '" does not exist'
    elseif fs.isDir(path) then
        return nil, 'State path "' .. path .. '" is a directory'
    end

    local file = fs.open(path, "r")
    if not file then
        return nil, 'Unable to open "' .. path .. '" for reading'
    end
    local contents = file.readAll()
    file.close()

    local ok, decoded = pcall(textutils.unserialize, contents)
    if not ok or decoded == nil then
        return nil, 'Unable to deserialize state file "' .. path .. '"'
    end
    return validateStoredState(decoded)
end

local function removeIfExists(path)
    if fs.exists(path) then
        fs.delete(path)
    end
end

local function invalidRotationMessage(direction)
    return 'Invalid horizontal rotation "' .. tostring(direction) .. '"'
end

function getStoragePath()
    return storagePath
end

function setStoragePath(path)
    assertString(path, "storage path", 3)
    storagePath = path
    return true
end

function isDirty()
    return dirty
end

function getPosition()
    return pos:clone()
end

function getRelativePosition()
    return relativeOrigin and pos - relativeOrigin or pos:clone()
end

function getRelativeOrigin()
    return relativeOrigin and relativeOrigin:clone() or nil
end

function hasRelativeOrigin()
    return relativeOrigin ~= nil
end

function setRelativeOrigin(origin)
    relativeOrigin = util.Vector3.new(origin)
    dirty = true
    return true
end

function clearRelativeOrigin()
    relativeOrigin = nil
    dirty = true
    return true
end

function setPosition(x, y, z)
    pos = util.Vector3.new(x, y, z)
    dirty = true
    return true
end

function offsetPosition(offset)
    pos:increment(util.Vector3.new(offset))
    dirty = true
    return true
end

function getRotation()
    return rot
end

function setRotation(direction)
    local newRotation = normalizeRotation(direction)
    if not newRotation then
        error(invalidRotationMessage(direction), 2)
    end
    rot, dirty = newRotation, true
    return true
end

function isCalibrated()
    return calibrated
end

function setCalibrated(value)
    assertBoolean(value, "calibrated", 3)
    calibrated, dirty = value, true
    return true
end

function invalidateCalibration()
    calibrated, dirty = false, true
    return true
end

function setState(newPosition, newRotation, newCalibrated)
    local newPos = util.Vector3.new(newPosition)
    local newRot = normalizeRotation(newRotation)
    if not newRot then
        error(invalidRotationMessage(newRotation), 2)
    end
    assertBoolean(newCalibrated, "calibrated", 3)

    pos, rot, calibrated, dirty = newPos, newRot, newCalibrated, true
    return true
end

function getState()
    return {
        pos = pos:clone(),
        rot = rot,
        calibrated = calibrated,
        relativeOrigin = relativeOrigin and relativeOrigin:clone() or nil
    }
end

function reset()
    pos, rot, calibrated = util.Vector3.new(), "north", false
    relativeOrigin, dirty = nil, true
    return true
end

local function saveToPath(targetPath, preserveBackup)
    local targetExists = fs.exists(targetPath)
    if targetExists and fs.isDir(targetPath) then
        return false, 'State path "' .. targetPath .. '" is a directory'
    end

    local serialized = textutils.serialize(stateSnapshot())
    if not serialized then
        return false, "Unable to serialize task state"
    end

    local tempPath, backupPath = targetPath .. ".tmp", targetPath .. ".bak"
    removeIfExists(tempPath)

    local written, writeError = writeFile(tempPath, serialized)
    if not written then
        return false, writeError
    end

    if targetExists and preserveBackup then
        local removed, removeError = pcall(fs.delete, targetPath)
        if not removed then
            fs.delete(tempPath)
            return false, "Unable to replace invalid task state: " .. tostring(removeError)
        end
    elseif targetExists then
        removeIfExists(backupPath)
        local moved, moveError = pcall(fs.move, targetPath, backupPath)
        if not moved then
            fs.delete(tempPath)
            return false, "Unable to create state backup: " .. tostring(moveError)
        end
    end

    local moved, moveError = pcall(fs.move, tempPath, targetPath)
    if not moved then
        if not preserveBackup and fs.exists(backupPath) and not fs.exists(targetPath) then
            pcall(fs.move, backupPath, targetPath)
        end
        removeIfExists(tempPath)
        return false, "Unable to install new task state: " .. tostring(moveError)
    end

    removeIfExists(backupPath)
    dirty = false
    return true
end

function save(path)
    local targetPath = path or storagePath
    assertString(targetPath, "storage path", 3)
    return saveToPath(targetPath, false)
end

function load(path)
    local targetPath = path or storagePath
    assertString(targetPath, "storage path", 3)

    local state, loadError, migrated = readStoredState(targetPath)
    if state then
        setRuntimeState(state, migrated)
        if migrated then
            local saved, saveError = saveToPath(targetPath, false)
            if saved then
                return true, "Migrated task state to version " .. STATE_VERSION
            end
            return true, "Loaded legacy task state; migration save failed: " .. tostring(saveError)
        end
        return true
    end

    local backupState, _, backupMigrated = readStoredState(targetPath .. ".bak")
    if not backupState then
        return false, loadError
    end

    setRuntimeState(backupState, backupMigrated)
    local recovered, recoveryError = saveToPath(targetPath, true)
    if recovered then
        return true, backupMigrated and
            "Recovered and migrated task state from backup" or
            "Recovered task state from backup"
    end

    dirty = true
    return true, "Loaded task state from backup; recovery save failed: " .. tostring(recoveryError)
end

return pkgr.endModule(_ENV)
