--[[
	NotificationController.lua
	Handles toast-style notifications for game events.
	Notifications slide in from the right and auto-dismiss after a configurable duration.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Knit = require(Packages:WaitForChild("Knit"))
local Util = require(Shared:WaitForChild("Util"))
local UITheme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UITheme"))

local NotificationController = Knit.CreateController({
  Name = "NotificationController",
})

-- References
local LocalPlayer = Players.LocalPlayer
local ScreenGui = nil
local NotificationContainer = nil

-- Active notifications for stacking
local ActiveNotifications = {}
local MAX_NOTIFICATIONS = 5
local NOTIFICATION_SPACING = 8

-- Default notification size
local NOTIFICATION_SIZE = UDim2.new(0, 280, 0, 50)

--[[
	Repositions all active notifications with smooth animation.
]]
local function repositionNotifications()
  local yOffset = 20
  for i, notification in ipairs(ActiveNotifications) do
    if notification and notification.frame and notification.frame.Parent then
      local targetPosition = UDim2.new(1, -20, 0, yOffset)
      local tween = TweenService:Create(
        notification.frame,
        TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = targetPosition }
      )
      tween:Play()
      yOffset = yOffset + notification.frame.AbsoluteSize.Y + NOTIFICATION_SPACING
    end
  end
end

--[[
	Removes a notification from the active list and repositions others.
	@param notification The notification to remove
]]
local function removeNotification(notification)
  local index = table.find(ActiveNotifications, notification)
  if index then
    table.remove(ActiveNotifications, index)
  end
  repositionNotifications()
end

--[[
	Shows a generic notification.
	@param text The notification text to display
	@param color Optional text color (defaults to UITheme.Colors.TextPrimary)
	@param duration Optional display duration in seconds (defaults to 3)
]]
function NotificationController:ShowNotification(text: string, color: Color3?, duration: number?)
  if not NotificationContainer then
    return
  end

  local displayColor = color or UITheme.Colors.TextPrimary
  local displayDuration = duration or 3

  -- Remove oldest notification if at max
  while #ActiveNotifications >= MAX_NOTIFICATIONS do
    local oldest = table.remove(ActiveNotifications, 1)
    if oldest and oldest.frame then
      oldest.frame:Destroy()
    end
  end

  -- Create notification frame
  local notification = Instance.new("Frame")
  notification.Name = "Notification"
  notification.Size = NOTIFICATION_SIZE
  notification.Position = UDim2.new(1, 100, 0, 20) -- Start off-screen
  notification.AnchorPoint = Vector2.new(1, 0)
  notification.BackgroundColor3 = UITheme.Colors.DarkBackground
  notification.BackgroundTransparency = 0.1
  notification.BorderSizePixel = 0

  local corner = Instance.new("UICorner")
  corner.CornerRadius = UITheme.CornerRadius.Medium
  corner.Parent = notification

  local stroke = Instance.new("UIStroke")
  stroke.Color = displayColor
  stroke.Thickness = 2
  stroke.Transparency = 0
  stroke.Parent = notification

  local padding = Instance.new("UIPadding")
  padding.PaddingLeft = UDim.new(0, 12)
  padding.PaddingRight = UDim.new(0, 12)
  padding.PaddingTop = UDim.new(0, 8)
  padding.PaddingBottom = UDim.new(0, 8)
  padding.Parent = notification

  local textLabel = Instance.new("TextLabel")
  textLabel.Name = "Text"
  textLabel.Size = UDim2.new(1, 0, 1, 0)
  textLabel.BackgroundTransparency = 1
  textLabel.Font = UITheme.Fonts.PRIMARY
  textLabel.TextColor3 = displayColor
  textLabel.TextSize = 14
  textLabel.Text = text
  textLabel.TextXAlignment = Enum.TextXAlignment.Center
  textLabel.TextWrapped = true
  textLabel.Parent = notification

  notification.Parent = NotificationContainer

  -- Track notification
  local notificationData = {
    frame = notification,
    startTime = tick(),
  }
  table.insert(ActiveNotifications, notificationData)
  repositionNotifications()

  -- Animate in
  local slideIn = TweenService:Create(
    notification,
    TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    { Position = UDim2.new(1, -20, 0, 20) }
  )
  slideIn:Play()

  -- Schedule removal
  task.delay(displayDuration, function()
    if notification.Parent then
      -- Animate out
      local slideOut = TweenService:Create(
        notification,
        TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
        { Position = UDim2.new(1, 100, 0, notification.Position.Y.Offset) }
      )
      slideOut:Play()
      slideOut.Completed:Connect(function()
        notification:Destroy()
        removeNotification(notificationData)
      end)
    end
  end)
end

--[[
	Called when Knit initializes.
]]
function NotificationController:KnitInit()
  -- Create ScreenGui for notifications
  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "NotificationGui"
  ScreenGui.ResetOnSpawn = false
  ScreenGui.DisplayOrder = 50
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  -- Create notification container
  NotificationContainer = Instance.new("Frame")
  NotificationContainer.Name = "NotificationContainer"
  NotificationContainer.Size = UDim2.new(1, 0, 1, 0)
  NotificationContainer.Position = UDim2.new(0, 0, 0, 0)
  NotificationContainer.BackgroundTransparency = 1
  NotificationContainer.Parent = ScreenGui

  print("[NotificationController] Initialized")
end

--[[
	Called when Knit starts.
]]
function NotificationController:KnitStart()
  print("[NotificationController] Started")
end

return NotificationController
