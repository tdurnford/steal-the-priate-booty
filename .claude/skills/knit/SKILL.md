---
name: knit
description: >
  How to write Knit services (server) and controllers (client) for client-server
  communication in this Roblox Luau project. Use this skill whenever you need to
  create a new service or controller, add a client-callable method, create signals
  for server-to-client events, or modify how the client and server communicate.
  Also use it when the user mentions Knit, RemoteEvents, RemoteFunctions,
  client-server RPC, or asks to "expose" something to the client or "call" the server.
---

# Knit Client-Server Communication

This project uses **Knit 1.6.0** (`sleitnick/knit@1.6.0`) as the networking layer between client and server. Knit replaces raw RemoteEvents/RemoteFunctions with a structured service/controller pattern that auto-generates the networking plumbing.

## How Knit works

Knit has two sides: **Services** run on the server, **Controllers** run on the client. Services can expose methods and signals to the client through a `Client` table. Controllers consume those services. All cross-boundary calls return Promises (via `evaera/promise@4.0.0`).

The bootstrap scripts (`Main.server.lua` and `Main.client.lua`) auto-discover and `require()` every module in the Services/Controllers folders, then call `Knit.Start()`. You never need to touch the bootstrap — just drop a new file in the right folder and it gets picked up.

## Project layout

```
src/
  server/
    Main.server.lua           -- Auto-loads all services, calls Knit.Start()
    Services/
      XxxService.lua          -- One file per service
  client/
    Main.client.lua           -- Auto-loads all controllers, calls Knit.Start()
    Controllers/
      XxxController.lua       -- One file per controller
  shared/
    Types.lua                 -- Shared type definitions
    ...Config.lua             -- Shared configuration modules
```

## Creating a Service (server-side)

Every service follows this structure. The `Client` table defines what the client can see — methods and signals.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local MyService = Knit.CreateService({
  Name = "MyService",
  Client = {
    -- Signals the server can fire to clients
    SomethingHappened = Knit.CreateSignal(),
  },
})

-- Lazy-loaded references to other services (set in KnitStart)
local DataService = nil

-- ============================================================
-- Lifecycle
-- ============================================================

function MyService:KnitInit()
  print("[MyService] Initializing...")
end

function MyService:KnitStart()
  -- Safe to reference other services here
  DataService = Knit.GetService("DataService")
  print("[MyService] Started")
end

-- ============================================================
-- Server-only methods (not callable from client)
-- ============================================================

function MyService:DoInternalWork(player: Player)
  -- Only other services can call this
end

-- Private helpers start with underscore
function MyService:_helperMethod()
end

-- ============================================================
-- Client-callable methods
-- ============================================================

-- Knit automatically injects `player` as the first argument.
-- The client never passes it — Knit does.
function MyService.Client:GetSomething(player: Player): string
  return self.Server:DoInternalWork(player)
end

function MyService.Client:DoAction(player: Player, actionId: string): (boolean, string?)
  -- Return tuples work fine
  return self.Server:_processAction(player, actionId)
end

return MyService
```

### Key rules for services

- **File naming**: `XxxService.lua` in `src/server/Services/`
- **`self.Server`**: Inside `Client:Method()`, use `self.Server` to call the service's own server methods. This is how you bridge from the client-facing method to internal logic.
- **Player injection**: Every `Client:Method` receives `player: Player` as its first argument automatically. The client never sends it.
- **Signals go in the Client table**: `Knit.CreateSignal()` creates a signal the server can fire to clients.
- **Server-side signals** (for cross-service communication) use GoodSignal directly:
  ```lua
  local Signal = require(Packages:WaitForChild("GoodSignal"))
  MyService.SomeInternalEvent = Signal.new()
  ```
- **Lazy-load other services** with pcall when you're not sure they exist:
  ```lua
  if not DataService then
    local ok, svc = pcall(function()
      return Knit.GetService("DataService")
    end)
    if ok then DataService = svc end
  end
  ```
  Or load them directly in `KnitStart()` when you know they'll be there.

### Firing signals

```lua
-- To one player:
self.Client.SomethingHappened:Fire(player, data)

-- To all players:
self.Client.SomethingHappened:FireAll(data)
```

`:Fire()` takes the target player as the first argument. `:FireAll()` does not — it broadcasts to everyone.

## Creating a Controller (client-side)

Controllers are simpler — they consume services, they don't expose anything to the server.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local MyController = Knit.CreateController({
  Name = "MyController",
})

-- Service references (set in KnitStart)
local MyService = nil
local DataService = nil

-- Controller references
local OtherController = nil

function MyController:KnitInit()
  print("[MyController] Initializing...")
end

function MyController:KnitStart()
  -- Get service proxies (only available after KnitStart)
  MyService = Knit.GetService("MyService")
  DataService = Knit.GetService("DataService")

  -- Get other controllers
  OtherController = Knit.GetController("OtherController")

  -- Call a server method (returns a Promise)
  MyService:GetSomething()
    :andThen(function(result)
      print("[MyController] Got:", result)
    end)
    :catch(function(err)
      warn("[MyController] Error:", err)
    end)

  -- Listen for signals from the server
  MyService.SomethingHappened:Connect(function(data)
    print("[MyController] Server says:", data)
  end)
end

-- Public methods other controllers can call
function MyController:IsDoingSomething(): boolean
  return false
end

return MyController
```

### Key rules for controllers

- **File naming**: `XxxController.lua` in `src/client/Controllers/`
- **No `Client` table**: Controllers don't have one. The server cannot call the client.
- **`Knit.GetService()`** returns a proxy object. Calling methods on it sends an RPC to the server and returns a **Promise**.
- **`Knit.GetController()`** returns a direct reference to another controller (local, no networking).
- **Promise handling**: Always use `:andThen()` and `:catch()`. Use `:expect()` only when you need synchronous unwrapping and understand it will error on failure.

## Promise patterns

Every client-to-server call returns a Promise:

```lua
-- Standard pattern
Service:Method(arg1, arg2)
  :andThen(function(result)
    -- Handle success
  end)
  :catch(function(err)
    warn("[ControllerName] Error:", err)
  end)

-- Multiple return values (tuple from server)
Service:DoAction(actionId)
  :andThen(function(success, errorMessage)
    if success then
      -- ...
    else
      warn("Failed:", errorMessage)
    end
  end)
  :catch(function(err)
    warn("RPC error:", err)
  end)

-- Synchronous unwrap (blocks, throws on failure — use sparingly)
local result = Service:Method():expect()
```

## Adding a new feature end-to-end

Here's the typical flow when adding a feature that needs client-server communication:

1. **Create or modify the Service** — add server logic, expose `Client:Method()`, add signals if the server needs to push data to clients
2. **Create or modify the Controller** — get the service via `Knit.GetService()`, call methods, listen to signals
3. **No bootstrap changes needed** — the auto-discovery handles it

## Conventions this project follows

- Print/warn with service/controller name prefix: `print("[MyService] message")`
- Use `Types` module from `src/shared/` for type annotations on data structures
- Config constants go in a local table at the top of the file (e.g., `local MY_CONFIG = { ... }`)
- State tracking uses typed dictionaries: `local PlayerStates: { [Player]: StateType } = {}`
- Clean up player state in `Players.PlayerRemoving` connections
- Comments use `--[[ block ]]` style for function docs, `--` for inline
