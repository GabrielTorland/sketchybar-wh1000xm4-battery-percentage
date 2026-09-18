-- Shows the battery level of the Sony headphones you are currently listening
-- through, and takes up no space at all when you are not wearing them.
--
-- Drop this file into your sketchybar Lua config and require it:
--
--     local headphones = require("items.headphone_battery")
--
-- It returns the item, so it can also be added to an existing bracket.
--
-- The battery is read by the launchd agent that `make install` sets up, not
-- from here: Bluetooth is not available to processes sketchybar spawns, which
-- fail without ever getting a reply. The agent leaves its answer in a file and
-- this widget only ever reads that file, which also keeps the bar off the
-- Bluetooth path entirely.

local sbar = sbar or require("sketchybar")

-- ---------------------------------------------------------------------------
-- Configuration — edit to taste.
-- ---------------------------------------------------------------------------
local config = {
  cache = os.getenv("HOME") .. "/.cache/headphone-battery.json",
  agent = "io.github.gabrieltorland.headphone-battery",

  position = "right",
  update_freq = 60, -- how often to re-read the file, not the headphones
  padding = 5, -- side padding, restored when the item is shown again

  -- SF Symbols "headphones". Written as an escape because the glyph itself
  -- only renders in the system font, and shows as a blank box everywhere else.
  icon = "\u{100448}",
  icon_size = 14.0,
  font = "SF Pro",
  numbers_font = "SF Mono",

  -- Percentages at or below which the colour changes.
  low = 20,
  warn = 35,

  colors = {
    normal = 0xff7f8490,
    warn = 0xfff39660,
    low = 0xfffc5d7c,
    charging = 0xff9ed072,
  },

  -- Set to a colour to give the item its own background, or nil to leave it
  -- bare (useful when adding it to a bracket that already has one).
  background = 0xff363944,
}
-- ---------------------------------------------------------------------------

local headphone_battery = sbar.add("item", "headphone_battery", {
  position = config.position,
  update_freq = config.update_freq,
  icon = {
    string = config.icon,
    font = { family = config.font, size = config.icon_size },
    padding_left = 8,
    padding_right = 4,
  },
  label = {
    font = { family = config.numbers_font },
    padding_right = 8,
  },
  background = config.background and { color = config.background } or nil,
})

-- Collapsing to zero width rather than hiding the item outright is deliberate:
-- sketchybar stops running the update script of an item whose drawing is off,
-- so an item hidden that way would never notice the headphones coming back.
-- Zeroing the paddings matters as much as the width: an item keeps its own
-- padding either side of whatever it draws, so a merely zero-width one still
-- pushes a surrounding bracket out past its contents and into its neighbour.
local function collapse()
  headphone_battery:set({
    width = 0,
    padding_left = 0,
    padding_right = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = { drawing = false },
  })
end

local function apply(result)
  -- sbar.exec hands back a decoded table when the output parses as JSON and
  -- the raw string when it does not, so accept either.
  local percent, charging
  if type(result) == "table" then
    percent = tonumber(result.percent)
    charging = result.charging == true
  elseif type(result) == "string" then
    percent = tonumber(result:match('"percent":%s*(%d+)'))
    charging = result:match('"charging":%s*true') ~= nil
  end

  -- The file is empty whenever the headphones are not what you are listening
  -- through, which is exactly when there is nothing worth showing.
  if not percent then return collapse() end

  local color = config.colors.normal
  if charging then
    color = config.colors.charging
  elseif percent <= config.low then
    color = config.colors.low
  elseif percent <= config.warn then
    color = config.colors.warn
  end

  headphone_battery:set({
    width = "dynamic",
    padding_left = config.padding,
    padding_right = config.padding,
    icon = { drawing = true, color = color },
    label = { drawing = true, string = percent .. "%", color = color },
    background = { drawing = config.background ~= nil },
  })
end

-- The trailing echo is load-bearing: sbar.exec does not call back on empty
-- output, and empty is exactly what the file holds when there is nothing to
-- show, so without it the widget could never learn to hide itself again.
local function read_cache()
  sbar.exec("cat " .. config.cache .. " 2>/dev/null; echo", apply)
end

-- Switching output device is the moment the answer changes, and waiting out
-- the agent's own interval to find out would be a long time to look wrong, so
-- ask it to run now and read the result once it has had time to land.
local function refresh()
  sbar.exec("launchctl kickstart -k gui/$(id -u)/" .. config.agent
            .. " >/dev/null 2>&1; sleep 3; cat " .. config.cache .. " 2>/dev/null; echo", apply)
end

headphone_battery:subscribe("routine", read_cache)
headphone_battery:subscribe("volume_change", refresh)
headphone_battery:subscribe("system_woke", refresh)

read_cache()

return headphone_battery
