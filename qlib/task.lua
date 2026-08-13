local pkgr = require "qlib.pkgr"
pkgr.startModule(_ENV or getfenv())

local util = require "qlib.util"

STATE_VERSION = 1
DEFAULT_STORAGE_PATH = ".rcgpt/task.state"

local pos = util.Vector3.new()
local rot = "north"
local calibrated = false
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
    dirty = changed
end

local function stateSnapshot()
    return {
        version = STATE_VERSION,
        pos = { x = pos.x, y = pos.y, z = pos.z },
        rot = rot,
        calibrated = calibrated
    }
end

local function validateStoredState(state)
    if type(state) ~= "table" then
        return nil, "state is not a table"
    elseif state.version ~= STATE_VERSION then
        return nil, "unsupported task state version: " .. tostring(state.version)
    elseif type(state.pos) ~= "table" then
        return nil, "state position is missing"
    elseif type(state.pos.x) ~= "number" or type(state.pos.y) ~= "number" or type(state.pos.z) ~= "number" then
        return nil, "state position contains invalid coordinates"
    end

    local newRotation = normalizeRotation(state.rot)
    if not newRotation then
        return nil, "state contains invalid rotation: " .. tostring(state.rot)
    elseif type(state.calibrated) ~= "boolean" then
        return nil, "state contains invalid calibration status"
    end

    return {
        pos = util.Vector3.new(state.pos.x, state.pos.y, state.pos.z),
        rot = newRotation,
        calibrated = state.calibrated
    }
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
    return { pos = pos:clone(), rot = rot, calibrated = calibrated }
end

function reset()
    pos, rot, calibrated, dirty = util.Vector3.new(), "north", false, true
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

    local state, loadError = readStoredState(targetPath)
    if state then
        setRuntimeState(state, false)
        return true
    end

    local backupState = readStoredState(targetPath .. ".bak")
    if not backupState then
        return false, loadError
    end

    setRuntimeState(backupState, false)
    if saveToPath(targetPath, true) then
        return true, "Recovered task state from backup"
    end

    dirty = false
    return true, "Loaded task state from backup"
end

return pkgr.endModule(getfenv())
