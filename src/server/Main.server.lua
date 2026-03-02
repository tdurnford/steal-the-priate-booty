local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

-- Load all services from the Services folder
local Server = ServerScriptService:WaitForChild("Server")
local ServicesFolder = Server:FindFirstChild("Services")

if ServicesFolder then
  for _, serviceModule in ipairs(ServicesFolder:GetChildren()) do
    if serviceModule:IsA("ModuleScript") then
      local success, err = pcall(function()
        require(serviceModule)
      end)
      if success then
        print("[Server] Loaded service:", serviceModule.Name)
      else
        warn("[Server] FAILED to load service:", serviceModule.Name, "-", err)
      end
    end
  end
else
  warn("[Server] Services folder not found!")
end

print("[Server] All services loaded, starting Knit...")

-- Start Knit
Knit.Start()
  :andThen(function()
    print("[Knit] Server started successfully")
  end)
  :catch(function(err)
    warn("[Knit] Server failed to start:", tostring(err))
  end)
