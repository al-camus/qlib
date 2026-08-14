-- qlib-release: 2
local pkgr = require "qlib.pkgr"
 
local outputFile = (...) or "rcGPT.lua"
 
print("rcGPT Packager")
print("--------------")
print("Output: " .. outputFile)
print()
 
local success, fileCount = pkgr.pack(".", outputFile)
 
if success then
    print()
    print("Packed " .. fileCount .. " file" .. (fileCount == 1 and "" or "s") .. ".")
end
 
