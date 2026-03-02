--!strict
--[[
	Build script that merges the base place (with map/workspace content) 
	with Rojo-built scripts and packages.
	
	Usage: lune run scripts/build
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local BASE_PLACE = "places/base.rbxlx"
local ROJO_PROJECT = "default.project.json"
local OUTPUT_FILE = "build/Game.rbxlx"

-- Ensure build directory exists
if not fs.isDir("build") then
	fs.writeDir("build")
end

-- Step 1: Build scripts/packages with Rojo to a temporary file
print("Building scripts with Rojo...")
local rojoResult = process.exec("rojo", { "build", ROJO_PROJECT, "-o", "build/scripts.rbxlx" })
if not rojoResult.ok then
	print("Rojo build failed:")
	print(rojoResult.stderr)
	process.exit(1)
end
print("✓ Rojo build complete")

-- Step 2: Load the base place (contains map, workspace, etc.)
print("Loading base place...")
local basePlaceData = fs.readFile(BASE_PLACE)
local basePlace = roblox.deserializePlace(basePlaceData)
print("✓ Base place loaded")

-- Step 3: Load the Rojo-built scripts
print("Loading Rojo scripts...")
local scriptsData = fs.readFile("build/scripts.rbxlx")
local scriptsPlace = roblox.deserializePlace(scriptsData)
print("✓ Scripts loaded")

-- Step 4: Merge - copy services from scripts place into base place
-- Strategy: Add Rojo content to base place, preserving existing base content
local servicesToMerge = {
	"ReplicatedStorage",
	"ServerScriptService",
	"StarterPlayer",
	"TestService",
}

-- Recursive function to merge folders, preserving base content
local function mergeInto(source: roblox.Instance, target: roblox.Instance)
	for _, child in source:GetChildren() do
		local existing = target:FindFirstChild(child.Name)
		if existing then
			-- If both are folders, recursively merge their contents
			if existing.ClassName == "Folder" and child.ClassName == "Folder" then
				mergeInto(child, existing)
			else
				-- Replace existing with new (Rojo version takes precedence for scripts)
				existing:Destroy()
				child.Parent = target
			end
		else
			-- No conflict, just add it
			child.Parent = target
		end
	end
end

for _, serviceName in servicesToMerge do
	local sourceService = scriptsPlace:FindFirstChild(serviceName)
	local targetService = basePlace:FindFirstChild(serviceName)

	if sourceService then
		if not targetService then
			-- Create the service if it doesn't exist in base
			targetService = roblox.Instance.new(serviceName)
			targetService.Parent = basePlace
		end

		-- Merge children from source into target, preserving existing content
		mergeInto(sourceService, targetService)
		print(`✓ Merged {serviceName}`)
	end
end

-- Step 5: Save the merged place
print("Saving merged place...")
local outputData = roblox.serializePlace(basePlace)
fs.writeFile(OUTPUT_FILE, outputData)
print(`✓ Saved to {OUTPUT_FILE}`)

-- Clean up temporary file
fs.removeFile("build/scripts.rbxlx")

print("\n🎉 Build complete!")
