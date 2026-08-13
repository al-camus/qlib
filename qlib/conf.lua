local pkgr = require "qlib.pkgr"
pkgr.startModule(_ENV or getfenv())

local util = require "qlib.util"

CONFIG_VERSION = 1
DEFAULT_STORAGE_PATH = ".rcgpt/conf.cfg"

local coreDefaults = {
    system = { debug = false, autosave = true },
    paths = { taskState = ".rcgpt/task.state", q2do = ".rcgpt/q2do" },
    startup = { loadTaskState = true, autoCalibrate = true, gpsTimeout = 2 },
    gui = {
        terminalOpen = true,
        colors = {
            background = "black", primary = "red", text = "white",
            success = "green", warning = "yellow", error = "red"
        }
    },
    movement = {
        defaultDig = false,
        attackObstructions = true,
        saveEveryMove = true,
        maxRetries = 10,
        digBlacklist = {}
    },
    fuel = {
        enabled = true,
        reserve = 100,
        lowPercent = 20,
        targetPercent = 100,
        autoRefuel = true
    },
    keep = { reservedSlots = 0, autoCompact = true },
    talk = {
        enabled = false,
        protocol = "rcgpt",
        channel = 1717,
        requestTimeout = 5,
        heartbeatInterval = 5
    },
    path = { algorithm = "astar", allowVertical = true, maxSearchNodes = 10000 },
    make = { enabled = true },
    farm = { enabled = true },
    q2do = { enabled = true, sync = false }
}

local storagePath = DEFAULT_STORAGE_PATH
local defaults
local values
local dirty = false

local serializableTypes = {
    ["nil"] = true,
    boolean = true,
    number = true,
    string = true,
    table = true
}

local function deepClone(value, seen)
    local valueType = type(value)
    if not serializableTypes[valueType] then
        error("configuration contains unsupported type: " .. valueType, 3)
    elseif valueType ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        error("configuration tables cannot contain cycles", 3)
    end

    seen[value] = true
    local clone = {}

    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            error("configuration table keys must be strings or numbers", 3)
        end

        clone[deepClone(key, seen)] = deepClone(child, seen)
    end

    seen[value] = nil
    return clone
end

local function deepMerge(base, overlay)
    local result = deepClone(base)

    for key, value in pairs(overlay) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = deepMerge(result[key], value)
        else
            result[key] = deepClone(value)
        end
    end

    return result
end

local function splitPath(path)
    if type(path) ~= "string" then
        error("configuration path must be a string", 3)
    end

    path = util.trimString(path)
    if path == "" then
        return {}
    end

    local parts = util.splitString(path, ".")
    for _, part in ipairs(parts) do
        if part == "" then
            error('invalid configuration path "' .. path .. '"', 3)
        end
    end

    return parts
end

local function getAt(root, parts)
    local current = root

    for _, part in ipairs(parts) do
        if type(current) ~= "table" then
            return nil, false
        end

        local value = rawget(current, part)
        if value == nil then
            return nil, false
        end

        current = value
    end

    return current, true
end

local function setAt(root, parts, value)
    if #parts == 0 then
        error("cannot replace configuration root with set(); use reset() instead", 3)
    end

    local current = root
    for index = 1, #parts - 1 do
        local part = parts[index]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end

    current[parts[#parts]] = value
end

local function validateValue(value, expected, path)
    local expectedType = type(expected)
    if type(value) ~= expectedType then
        return false, '"' .. path .. '" must be ' .. expectedType .. ", got " .. type(value)
    end

    if expectedType == "table" then
        for key, child in pairs(value) do
            local expectedChild = expected[key]

            if expectedChild ~= nil then
                local valid, reason = validateValue(child, expectedChild, path .. "." .. tostring(key))
                if not valid then
                    return false, reason
                end
            else
                -- Unknown table fields are allowed, but must remain serializable.
                local ok, cloneError = pcall(deepClone, child)
                if not ok then
                    return false, tostring(cloneError)
                end
            end
        end
    end

    return true
end

local function mergeStoredValues(defaultTable, storedTable, path)
    path = path or ""

    local result = deepClone(defaultTable)
    for key, storedValue in pairs(storedTable) do
        local keyType = type(key)
        if keyType ~= "string" and keyType ~= "number" then
            return nil, "configuration table keys must be strings or numbers"
        end

        local defaultValue = defaultTable[key]
        local childPath = path == "" and tostring(key) or path .. "." .. tostring(key)

        if defaultValue ~= nil then
            local valid, reason = validateValue(storedValue, defaultValue, childPath)
            if not valid then
                return nil, reason
            end

            if type(defaultValue) == "table" and type(storedValue) == "table" then
                local merged, mergeError = mergeStoredValues(defaultValue, storedValue, childPath)
                if not merged then
                    return nil, mergeError
                end
                result[key] = merged
            else
                result[key] = deepClone(storedValue)
            end
        else
            -- Keep values introduced by newer modules until their defaults register.
            local ok, cloned = pcall(deepClone, storedValue)
            if not ok then
                return nil, 'Invalid configuration value "' .. childPath .. '"'
            end
            result[key] = cloned
        end
    end

    return result
end

local function assertStoragePath(path)
    if type(path) ~= "string" or util.trimString(path) == "" then
        error("storage path must be a non-empty string", 3)
    end
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

local function readFile(path)
    local file = fs.open(path, "r")
    if not file then
        return nil, 'Unable to open "' .. path .. '" for reading'
    end

    local contents = file.readAll()
    file.close()
    return contents
end

local function makeSerializableConfig()
    return { version = CONFIG_VERSION, values = deepClone(values) }
end

local function decodeConfig(path)
    if not fs.exists(path) then
        return nil, 'Configuration file "' .. path .. '" does not exist'
    elseif fs.isDir(path) then
        return nil, 'Configuration path "' .. path .. '" is a directory'
    end

    local contents, readError = readFile(path)
    if not contents then
        return nil, readError
    end

    local ok, decoded = pcall(textutils.unserialize, contents)
    if not ok or type(decoded) ~= "table" then
        return nil, 'Unable to deserialize configuration "' .. path .. '"'
    elseif decoded.version ~= CONFIG_VERSION then
        return nil, "unsupported configuration version: " .. tostring(decoded.version)
    elseif type(decoded.values) ~= "table" then
        return nil, "configuration contains no values table"
    end

    return decoded.values
end

local function replaceContents(target, source)
    for key in pairs(target) do
        target[key] = nil
    end

    for key, value in pairs(source) do
        target[key] = value
    end
end

local function removeIfExists(path)
    if fs.exists(path) then
        fs.delete(path)
    end
end

defaults = deepClone(coreDefaults)
values = deepClone(defaults)

function getStoragePath()
    return storagePath
end

function setStoragePath(path)
    assertStoragePath(path)
    storagePath = path
    return true
end

function isDirty()
    return dirty
end

function has(path)
    local _, exists = getAt(defaults, splitPath(path))
    return exists
end

function get(path, fallback)
    local parts = splitPath(path or "")
    if #parts == 0 then
        return deepClone(values)
    end

    local value, exists = getAt(values, parts)
    if not exists then
        return fallback
    elseif type(value) == "table" then
        return deepClone(value)
    end

    return value
end

function set(path, value)
    local parts = splitPath(path)
    if #parts == 0 then
        error("configuration path cannot be empty", 2)
    end

    local expected, exists = getAt(defaults, parts)
    if not exists then
        error('Unknown configuration option "' .. path .. '"', 2)
    end

    local valid, reason = validateValue(value, expected, path)
    if not valid then
        error(reason, 2)
    end

    setAt(values, parts, deepClone(value))
    dirty = true
    return true
end

function registerDefaults(path, newDefaults)
    if type(newDefaults) ~= "table" then
        error("new defaults must be a table", 2)
    end

    local parts = splitPath(path or "")
    local newValues = deepClone(newDefaults)

    -- Registration extends the schema; existing defaults and values win conflicts.
    if #parts == 0 then
        local mergedDefaults = deepMerge(newValues, defaults)
        local mergedValues = deepMerge(mergedDefaults, values)
        defaults, values = mergedDefaults, mergedValues
        return true
    end

    -- Work on copies so a validation error cannot leave a partially registered path.
    local nextDefaults, nextValues = deepClone(defaults), deepClone(values)
    local currentDefaults, currentValues = nextDefaults, nextValues
    for _, part in ipairs(parts) do
        if currentDefaults[part] == nil then
            currentDefaults[part] = {}
        elseif type(currentDefaults[part]) ~= "table" then
            error('Cannot register defaults beneath non-table option "' .. path .. '"', 2)
        end

        if currentValues[part] == nil then
            currentValues[part] = {}
        elseif type(currentValues[part]) ~= "table" then
            error('Current configuration at "' .. path .. '" is not a table', 2)
        end

        currentDefaults = currentDefaults[part]
        currentValues = currentValues[part]
    end

    local mergedDefaults = deepMerge(newValues, currentDefaults)
    local mergedValues = deepMerge(mergedDefaults, currentValues)
    replaceContents(currentDefaults, mergedDefaults)
    replaceContents(currentValues, mergedValues)
    defaults, values = nextDefaults, nextValues
    return true
end

function getDefaults(path)
    local value, exists = getAt(defaults, splitPath(path or ""))
    if not exists then
        return nil
    end

    return deepClone(value)
end

function reset(path)
    if path == nil or util.trimString(path) == "" then
        values = deepClone(defaults)
        dirty = true
        return true
    end

    local parts = splitPath(path)
    local defaultValue, exists = getAt(defaults, parts)
    if not exists then
        return false, 'Unknown configuration option "' .. path .. '"'
    end

    setAt(values, parts, deepClone(defaultValue))
    dirty = true
    return true
end

function save(path)
    local targetPath = path or storagePath
    assertStoragePath(targetPath)

    local targetExists = fs.exists(targetPath)
    if targetExists and fs.isDir(targetPath) then
        return false, 'Configuration path "' .. targetPath .. '" is a directory'
    end

    local serialized = textutils.serialize(makeSerializableConfig())
    if not serialized then
        return false, "Unable to serialize configuration"
    end

    local tempPath, backupPath = targetPath .. ".tmp", targetPath .. ".bak"

    -- Write the new file before rotating the old one into its backup.
    removeIfExists(tempPath)

    local written, writeError = writeFile(tempPath, serialized)
    if not written then
        return false, writeError
    end

    if targetExists then
        removeIfExists(backupPath)
        local moved, moveError = pcall(fs.move, targetPath, backupPath)
        if not moved then
            fs.delete(tempPath)
            return false, "Unable to create configuration backup: " .. tostring(moveError)
        end
    end

    local moved, moveError = pcall(fs.move, tempPath, targetPath)
    if not moved then
        if fs.exists(backupPath) and not fs.exists(targetPath) then
            pcall(fs.move, backupPath, targetPath)
        end

        removeIfExists(tempPath)

        return false, "Unable to install new configuration: " .. tostring(moveError)
    end

    removeIfExists(backupPath)

    dirty = false
    return true
end

function load(path)
    local targetPath = path or storagePath
    assertStoragePath(targetPath)

    local storedValues, loadError = decodeConfig(targetPath)
    if storedValues then
        local merged, mergeError = mergeStoredValues(defaults, storedValues)
        if not merged then
            return false, mergeError
        end

        values = merged
        dirty = false
        return true
    end

    local backupValues = decodeConfig(targetPath .. ".bak")
    if backupValues then
        local merged, mergeError = mergeStoredValues(defaults, backupValues)
        if not merged then
            return false, mergeError
        end

        values = merged
        dirty = true
        return true, "Loaded configuration from backup"
    end

    return false, loadError
end

function initialize(path)
    if path ~= nil then
        setStoragePath(path)
    end

    if fs.exists(storagePath) or fs.exists(storagePath .. ".bak") then
        return load(storagePath)
    end

    local success, reason = save(storagePath)
    if not success then
        return false, reason
    end

    return true, "Created default configuration"
end

return pkgr.endModule(getfenv())
