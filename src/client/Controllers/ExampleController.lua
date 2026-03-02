--[[
	ExampleController
	A template controller demonstrating the Knit controller pattern.
	Delete this file once real controllers are implemented.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ExampleController = Knit.CreateController({
  Name = "ExampleController",
})

-- Called when Knit is starting, before Start
function ExampleController:KnitInit()
  print("[ExampleController] Initializing...")
end

-- Called after all controllers have initialized
function ExampleController:KnitStart()
  print("[ExampleController] Started")

  -- Example: Get a reference to a service
  local ExampleService = Knit.GetService("ExampleService")

  -- Example: Call a server method
  ExampleService:RequestData()
    :andThen(function(data)
      print("[ExampleController] Received from server:", data.message)
    end)
    :catch(function(err)
      warn("[ExampleController] Error:", err)
    end)

  -- Example: Listen to a server signal
  ExampleService.ExampleSignal:Connect(function(message)
    print("[ExampleController] Signal received:", message)
  end)
end

return ExampleController
