--[[
	Types.lua
	Central type definitions for the game template.
	Contains shared types for player data and settings.
]]

--[[
	Player settings and preferences.
	- musicEnabled: Whether background music is on
	- sfxEnabled: Whether sound effects are on
	- showOtherPlayers: Whether to render other players
]]
export type Settings = {
  musicEnabled: boolean,
  sfxEnabled: boolean,
  showOtherPlayers: boolean,
}

--[[
	Main player data schema for ProfileService persistence.
	- money: Currency balance
	- settings: Player preferences
	- joinedAt: First join timestamp
	- lastPlayedAt: Most recent session timestamp
]]
export type PlayerData = {
  money: number,
  settings: Settings,
  joinedAt: number,
  lastPlayedAt: number,
}

local Types = {}

-- Default data template for new players
Types.DEFAULT_PLAYER_DATA = {
  money = 0,
  settings = {
    musicEnabled = true,
    sfxEnabled = true,
    showOtherPlayers = true,
  },
  joinedAt = 0,
  lastPlayedAt = 0,
}

--[[
	Deep copies player data for safe manipulation.
	@param data Source player data
	@return Deep copy of the data
]]
function Types.deepCopyPlayerData(data: PlayerData): PlayerData
  return {
    money = data.money,
    settings = {
      musicEnabled = data.settings.musicEnabled,
      sfxEnabled = data.settings.sfxEnabled,
      showOtherPlayers = data.settings.showOtherPlayers,
    },
    joinedAt = data.joinedAt,
    lastPlayedAt = data.lastPlayedAt,
  }
end

return Types
