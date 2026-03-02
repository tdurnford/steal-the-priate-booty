local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

-- Load all controllers from the Controllers folder
local ControllersFolder = script.Parent:FindFirstChild("Controllers")

if ControllersFolder then
  for _, controllerModule in ipairs(ControllersFolder:GetChildren()) do
    if controllerModule:IsA("ModuleScript") then
      require(controllerModule)
    end
  end
end

-- Start Knit
Knit.Start()
  :andThen(function()
    print("[Knit] Client started successfully")
  end)
  :catch(function(err)
    warn("[Knit] Client failed to start:", err)
  end)
