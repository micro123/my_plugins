--!nonstrict
-- Waylyrics bar widget — cover · artist - title · lyric.

noctalia.setUpdateInterval(200)

local hideWhenPaused = noctalia.getConfig("hide_when_paused") == true
local activeColor = noctalia.getConfig("active_color") or "on_surface"
local inactiveColor = noctalia.getConfig("inactive_color") or "on_surface_variant"

local track = nil
local lyrics = nil
local playing = false
local position = 0
local cover = nil
local showTranslation = false

local function getLineInfo()
  if not lyrics or #lyrics == 0 or not playing then return nil end
  local posMs = position / 1000
  local idx = 0
  for i = 1, #lyrics do
    if lyrics[i].time <= posMs then idx = i else break end
  end
  if idx == 0 then return nil end
  return lyrics[idx]
end

function onOpenPanel()
  noctalia.togglePanel("tang/waylyrics:media")
end

function update()
  track = noctalia.state.get("track")
  lyrics = noctalia.state.get("lyrics")
  position = noctalia.state.get("position") or 0
  playing = noctalia.state.get("playing") == true
  cover = noctalia.state.get("cover")

  if hideWhenPaused and not playing then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local line = getLineInfo()
  local lyricText = ""
  if line then
    if showTranslation and line.translation and line.translation ~= "" then
      lyricText = line.translation
    else
      lyricText = line.text or ""
    end
  end

  local artist = track and track.artist or ""
  local title = track and track.title or ""
  local head = ""
  if artist ~= "" and title ~= "" then
    head = artist .. " - " .. title
  elseif title ~= "" then
    head = title
  elseif artist ~= "" then
    head = artist
  end

  local children = {}

  if cover and cover ~= "" then
    children[#children + 1] = ui.image({
      path = cover, width = 16, height = 16, radius = 8, fit = "cover",
    })
  end

  if head ~= "" then
    children[#children + 1] = ui.label({
      text = head, fontSize = 13, color = "primary", maxLines = 1,
    })
  end

  if lyricText ~= "" then
    children[#children + 1] = ui.label({
      text = lyricText, fontSize = 13, color = "tertiary", maxLines = 1,
    })
  end

  barWidget.render(ui.row({ gap = 8, align = "center", onClick = "onOpenPanel" }, children))
end

function onRightClick()
  showTranslation = not showTranslation
end

-- Seed
track = noctalia.state.get("track")
lyrics = noctalia.state.get("lyrics")
position = noctalia.state.get("position") or 0
playing = noctalia.state.get("playing") == true
cover = noctalia.state.get("cover")
update()
