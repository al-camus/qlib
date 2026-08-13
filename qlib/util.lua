local pkgr = require "qlib.pkgr"
pkgr.startModule(_ENV or getfenv())

local function assertNumber(value, name, level)
    if type(value) ~= "number" then
        error((name or "value") .. " must be a number, got " .. type(value), level or 3)
    end
end

local function assertTable(value, name, level)
    if type(value) ~= "table" then
        error((name or "value") .. " must be a table, got " .. type(value), level or 3)
    end
end

local function formatNumber(value)
    assertNumber(value, "coordinate", 4)
    if value == math.floor(value) then
        return string.format("%.0f", value)
    end
    return tostring(value)
end

local function parseNumber(value, name)
    local number = tonumber(value)
    if number == nil then
        error('Invalid ' .. (name or "number") .. ': "' .. tostring(value) .. '"', 3)
    end
    return number
end

local vector2Names = { "x coordinate", "y coordinate" }
local vector3Names = { "x coordinate", "y coordinate", "z coordinate" }

local function unpackCoordinate(value, count, names, label)
    local parts = splitString(value, ",")
    if #parts ~= count then
        error('Invalid packed ' .. label .. ': "' .. value .. '"', 3)
    end

    if count == 3 then
        return parseNumber(parts[1], names[1]), parseNumber(parts[2], names[2]),
            parseNumber(parts[3], names[3])
    end
    return parseNumber(parts[1], names[1]), parseNumber(parts[2], names[2])
end

inf = math.huge

function cloneTable(tbl)
    assertTable(tbl, "table")

    local clone = {}
    for key, value in pairs(tbl) do
        clone[key] = value
    end
    return clone
end

function splitString(input, separator)
    if type(input) ~= "string" then
        error("input must be a string", 2)
    end

    local result = {}
    if separator == nil then
        for value in input:gmatch("%S+") do
            result[#result + 1] = value
        end
        return result
    end

    if type(separator) ~= "string" then
        error("separator must be a string", 2)
    end
    if separator == "" then
        for index = 1, #input do
            result[index] = input:sub(index, index)
        end
        return result
    end

    local start = 1
    while true do
        local first, last = input:find(separator, start, true)
        if not first then
            result[#result + 1] = input:sub(start)
            return result
        end
        result[#result + 1] = input:sub(start, first - 1)
        start = last + 1
    end
end

function trimString(input)
    if type(input) ~= "string" then
        error("input must be a string", 2)
    end
    return input:match("^%s*(.-)%s*$")
end

function pack3(x, y, z)
    return formatNumber(x or 0) .. "," ..
        formatNumber(y or 0) .. "," ..
        formatNumber(z or 0)
end

function unpack3(value)
    if type(value) ~= "string" then
        error("packed coordinate must be a string", 2)
    end
    return unpackCoordinate(value, 3, vector3Names, "Vector3")
end

function pack2(x, y)
    return formatNumber(x or 0) .. "," .. formatNumber(y or 0)
end

function unpack2(value)
    if type(value) ~= "string" then
        error("packed coordinate must be a string", 2)
    end
    return unpackCoordinate(value, 2, vector2Names, "Vector2")
end

Vector3 = {}
Vector3.__index = Vector3

function Vector3.new(x, y, z)
    if type(x) == "table" then
        x, y, z = x.x, x.y, x.z
    end
    x, y, z = x or 0, y or 0, z or 0

    assertNumber(x, "x", 3)
    assertNumber(y, "y", 3)
    assertNumber(z, "z", 3)
    return setmetatable({ x = x, y = y, z = z }, Vector3)
end

function Vector3.fromString(value)
    return Vector3.new(unpack3(value))
end

function Vector3:__tostring()
    return string.format(
        "{x=%s, y=%s, z=%s}",
        formatNumber(self.x),
        formatNumber(self.y),
        formatNumber(self.z)
    )
end

function Vector3:strXYZ(rotation)
    local xyz = pack3(self.x, self.y, self.z)
    return rotation ~= nil and xyz .. ":" .. tostring(rotation) or xyz
end

function Vector3:__eq(other)
    return type(other) == "table" and
        self.x == other.x and
        self.y == other.y and
        self.z == other.z
end

function Vector3:__add(other)
    return Vector3.new(self.x + other.x, self.y + other.y, self.z + other.z)
end

function Vector3:__sub(other)
    return Vector3.new(self.x - other.x, self.y - other.y, self.z - other.z)
end

function Vector3.__mul(a, b)
    local vector, scalar
    if type(a) == "table" and type(b) == "number" then
        vector, scalar = a, b
    elseif type(a) == "number" and type(b) == "table" then
        vector, scalar = b, a
    else
        error("Vector3 multiplication requires one vector and one number", 2)
    end
    return Vector3.new(vector.x * scalar, vector.y * scalar, vector.z * scalar)
end

local function checkDivisor(scalar)
    if type(scalar) ~= "number" then
        error("scalar must be a number, got " .. type(scalar), 3)
    end
    if scalar == 0 then
        error("cannot divide Vector3 by zero", 3)
    end
end

function Vector3:__div(scalar)
    checkDivisor(scalar)
    return Vector3.new(self.x / scalar, self.y / scalar, self.z / scalar)
end

function Vector3:__unm()
    return Vector3.new(-self.x, -self.y, -self.z)
end

function Vector3:increment(other)
    self.x, self.y, self.z = self.x + other.x, self.y + other.y, self.z + other.z
    return self
end

function Vector3:decrement(other)
    self.x, self.y, self.z = self.x - other.x, self.y - other.y, self.z - other.z
    return self
end

function Vector3:scale(scalar)
    assertNumber(scalar, "scalar", 3)
    self.x, self.y, self.z = self.x * scalar, self.y * scalar, self.z * scalar
    return self
end

function Vector3:inverseScale(scalar)
    checkDivisor(scalar)
    self.x, self.y, self.z = self.x / scalar, self.y / scalar, self.z / scalar
    return self
end

function Vector3:clone(target)
    if target == nil then
        return Vector3.new(self.x, self.y, self.z)
    end

    assertTable(target, "target", 3)
    target.x, target.y, target.z = self.x, self.y, self.z
    if getmetatable(target) == nil then
        setmetatable(target, Vector3)
    end
    return target
end

function Vector3:manhattanDistanceTo(other)
    return math.abs(self.x - other.x) +
        math.abs(self.y - other.y) +
        math.abs(self.z - other.z)
end

function Vector3:distanceTo(other)
    return self:manhattanDistanceTo(other)
end

function Vector3:euclideanDistanceTo(other)
    local x, y, z = self.x - other.x, self.y - other.y, self.z - other.z
    return math.sqrt(x * x + y * y + z * z)
end

function Vector3:rot90()
    return Vector3.new(-self.z, self.y, self.x)
end

function Vector3:rot180()
    return Vector3.new(-self.x, self.y, -self.z)
end

function Vector3:rot270()
    return Vector3.new(self.z, self.y, -self.x)
end

function Vector3:inArea(area)
    assertTable(area, "area", 3)

    local minimum, maximum = area.min, area.max
    local minX, minY, minZ, maxX, maxY, maxZ
    if minimum and maximum then
        minX, minY, minZ = minimum.x, minimum.y, minimum.z
        maxX, maxY, maxZ = maximum.x, maximum.y, maximum.z
    else
        minX, minY, minZ = area.min_x, area.min_y, area.min_z
        maxX, maxY, maxZ = area.max_x, area.max_y, area.max_z
    end

    if minX == nil or minY == nil or minZ == nil or maxX == nil or maxY == nil or maxZ == nil then
        error("area must define min/max coordinates", 2)
    end

    return self.x >= minX and self.x <= maxX and
        self.y >= minY and self.y <= maxY and
        self.z >= minZ and self.z <= maxZ
end

cardinal_vectors = {
    up = Vector3.new(0, 1, 0), down = Vector3.new(0, -1, 0),
    north = Vector3.new(0, 0, -1), south = Vector3.new(0, 0, 1),
    east = Vector3.new(1, 0, 0), west = Vector3.new(-1, 0, 0)
}

horizontal_directions = { "north", "east", "south", "west" }
spatial_directions = { "north", "east", "south", "west", "up", "down" }

local horizontalLookup = { north = true, east = true, south = true, west = true }

direction_aliases = {
    n = "north", s = "south", e = "east", w = "west",
    u = "up", d = "down",
    north = "north", south = "south", east = "east", west = "west", up = "up", down = "down",
    f = "forward", forward = "forward", b = "back", back = "back", backward = "back",
    l = "left", left = "left", r = "right", right = "right"
}

cardinal_left = { north = "west", west = "south", south = "east", east = "north" }
cardinal_right = { north = "east", east = "south", south = "west", west = "north" }
cardinal_reverse = { north = "south", south = "north", east = "west", west = "east" }

local relativeTurns = {
    back = cardinal_reverse,
    left = cardinal_left,
    right = cardinal_right
}

function normalizeDirection(direction)
    if type(direction) ~= "string" then
        return nil
    end
    return direction_aliases[trimString(direction):lower()]
end

function isHorizontalDirection(direction)
    return horizontalLookup[normalizeDirection(direction)] == true
end

function isSpatialDirection(direction)
    return cardinal_vectors[normalizeDirection(direction)] ~= nil
end

function getCardinalVector(direction)
    return cardinal_vectors[normalizeDirection(direction)]
end

local vecToCardinal = {
    ["0,1,0"] = "up", ["0,-1,0"] = "down",
    ["0,0,-1"] = "north", ["0,0,1"] = "south",
    ["1,0,0"] = "east", ["-1,0,0"] = "west"
}

function Vector3:cardinalTo(other)
    return vecToCardinal[(other - self):strXYZ()]
end

function Vector3:getAdjacentPos(direction, rotation)
    direction = normalizeDirection(direction)
    if not direction then
        error("unknown direction", 2)
    end

    local vector = cardinal_vectors[direction]
    if vector then
        return self + vector
    end

    rotation = normalizeDirection(rotation)
    if not horizontalLookup[rotation] then
        error("relative movement requires a valid horizontal rotation", 2)
    end

    local resolved = rotation
    if direction ~= "forward" then
        local turns = relativeTurns[direction]
        resolved = turns and turns[rotation]
    end
    if resolved then
        return self + cardinal_vectors[resolved]
    end

    error('unsupported direction "' .. tostring(direction) .. '"', 2)
end

return pkgr.endModule(getfenv())
