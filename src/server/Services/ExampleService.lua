--[[
	ExampleService
	A template service demonstrating the Knit service pattern.
	Delete this file once real services are implemented.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ExampleService = Knit.CreateService({
  Name = "ExampleService",

  -- Client-exposed methods and events
  Client = {
    -- Signals that can be fired to clients
    ExampleSignal = Knit.CreateSignal(),
  },
})

-- Called when Knit is starting, before Start
function ExampleService:KnitInit()
  print("[ExampleService] Initializing...")
end

-- Called after all services have initialized
function ExampleService:KnitStart()
  print("[ExampleService] Started")
end

-- Example server method
function ExampleService:DoSomething(message: string): string
  return "Server received: " .. message
end

-- Example client-callable method
function ExampleService.Client:RequestData(player: Player): { message: string }
  print("[ExampleService] Data requested by", player.Name)
  return { message = "Hello from server!" }
end

return ExampleService
