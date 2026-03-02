local Util = {}

function Util.clamp(x: number, lo: number, hi: number): number
  if x < lo then
    return lo
  end
  if x > hi then
    return hi
  end
  return x
end

--[[
  Strips trailing zeros from a decimal number string.
  "5.0" -> "5", "5.10" -> "5.1", "5.15" -> "5.15"
  @param str The string to process
  @return String with trailing decimal zeros removed
]]
function Util.stripTrailingZeros(str: string): string
  -- Match number with decimal, strip trailing zeros and orphan decimal point
  return (
    str
      :gsub("(%d+)%.0+(%D)", "%1%2") -- "5.0K" -> "5K"
      :gsub("(%d+%.%d-)0+(%D)", "%1%2") -- "5.10K" -> "5.1K"
      :gsub("(%d+)%.0+$", "%1") -- "5.0" at end -> "5"
      :gsub("(%d+%.%d-)0+$", "%1")
  ) -- "5.10" at end -> "5.1"
end

--[[
  Formats a number with abbreviations (K, M, B, T, Q) and strips trailing zeros.
  @param num The number to format
  @param prefix Optional prefix (default "$")
  @param suffix Optional suffix (default "")
  @return Formatted string
]]
function Util.formatNumber(num: number, prefix: string?, suffix: string?): string
  prefix = prefix or "$"
  suffix = suffix or ""

  local result: string
  if num < 1000 then
    result = string.format("%s%d%s", prefix, num, suffix)
  elseif num < 1000000 then
    result = string.format("%s%.1fK%s", prefix, num / 1000, suffix)
  elseif num < 1000000000 then
    result = string.format("%s%.1fM%s", prefix, num / 1000000, suffix)
  elseif num < 1000000000000 then
    result = string.format("%s%.1fB%s", prefix, num / 1000000000, suffix)
  elseif num < 1000000000000000 then
    result = string.format("%s%.1fT%s", prefix, num / 1000000000000, suffix)
  else
    result = string.format("%s%.1fQ%s", prefix, num / 1000000000000000, suffix)
  end

  return Util.stripTrailingZeros(result)
end

--[[
  Formats money with dollar sign and abbreviations.
  @param num The amount to format
  @return Formatted money string
]]
function Util.formatMoney(num: number): string
  return Util.formatNumber(num, "$", "")
end

--[[
  Formats income rate as $/hr with abbreviations.
  @param moneyPerSecond The money generation rate per second
  @return Formatted string
]]
function Util.formatIncomeRate(moneyPerSecond: number): string
  local perHour = moneyPerSecond * 3600
  return Util.formatNumber(perHour, "$", "/hr")
end

return Util
