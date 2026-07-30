--!nonstrict
-- Waylyrics bar widget — cover · lyric.

noctalia.setUpdateInterval(200)

local hideWhenPaused = noctalia.getConfig("hide_when_paused") == true
local activeColor = noctalia.getConfig("active_color") or "on_surface"
local inactiveColor = noctalia.getConfig("inactive_color") or "on_surface_variant"
local showProgressRing = noctalia.getConfig("show_progress_ring") ~= false
local ringSize = tonumber(noctalia.getConfig("ring_size")) or 24

local lyrics = nil
local playing = false
local position = 0
local cover = nil
local coverRing = nil
local showTranslation = true
local track = nil

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

local function renderCover(children)
  -- Prefer the composited ring image when available and enabled.
  local cr = coverRing
  if showProgressRing and type(cr) == "string" and cr ~= "" and playing then
    children[#children + 1] = ui.image({
      path = cr, width = ringSize, height = ringSize,
    })
  elseif type(cover) == "string" and cover ~= "" then
    children[#children + 1] = ui.image({
      path = cover, width = 16, height = 16, radius = 8, fit = "cover",
    })
  end
end

local function renderPausedCover(children)
  -- Show the last ring (frozen progress) or plain cover when paused.
  local cr = coverRing
  if showProgressRing and type(cr) == "string" and cr ~= "" then
    children[#children + 1] = ui.image({
      path = cr, width = ringSize, height = ringSize,
    })
  elseif type(cover) == "string" and cover ~= "" then
    children[#children + 1] = ui.image({
      path = cover, width = 16, height = 16, radius = 8, fit = "cover",
    })
  end
end

function update()
  lyrics = noctalia.state.get("lyrics")
  position = noctalia.state.get("position") or 0
  playing = noctalia.state.get("playing") == true
  cover = noctalia.state.get("cover")
  coverRing = noctalia.state.get("cover_ring")
  track = noctalia.state.get("track")

  if hideWhenPaused and not playing then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local children = {}

  if playing then
    renderCover(children)
    local line = getLineInfo()
    local lyricText = ""
    if line then
      if showTranslation and line.translation and line.translation ~= "" then
        lyricText = line.translation
      else
        lyricText = line.text or ""
      end
    end
    if lyricText ~= "" then
      children[#children + 1] = ui.label({
        text = lyricText, fontSize = 13, color = activeColor, maxLines = 1,
      })
    else
      local fallback = ""
      if track then
        local artist = track.artist or ""
        local title = track.title or ""
        if artist ~= "" or title ~= "" then
          fallback = artist .. " - " .. title
        end
      end
      if fallback ~= "" then
        children[#children + 1] = ui.label({
          text = fallback, fontSize = 13, color = inactiveColor, maxLines = 1,
        })
      else
        children[#children + 1] = ui.label({
          text = noctalia.tr("cue_text"), fontSize = 13, color = inactiveColor, maxLines = 1,
        })
      end
    end
  else
    renderPausedCover(children)
    local line = getLineInfo()
    if line then
      children[#children + 1] = ui.label({
        text = line.text or "", fontSize = 13, color = inactiveColor, maxLines = 1,
      })
    else
      local fallback = ""
      if track then
        local artist = track.artist or ""
        local title = track.title or ""
        if artist ~= "" or title ~= "" then
          fallback = artist .. " - " .. title
        end
      end
      if fallback ~= "" then
        children[#children + 1] = ui.label({
          text = noctalia.tr("paused") .. ": " .. fallback, fontSize = 13, color = inactiveColor, maxLines = 1,
        })
      else
        children[#children + 1] = ui.label({
          text = noctalia.tr("paused"), fontSize = 13, color = inactiveColor, maxLines = 1,
        })
      end
    end
  end

  barWidget.render(ui.row({ gap = 8, align = "center", onClick = "onOpenPanel" }, children))
end

function onRightClick()
  showTranslation = not showTranslation
end

-- Seed
lyrics = noctalia.state.get("lyrics")
position = noctalia.state.get("position") or 0
playing = noctalia.state.get("playing") == true
cover = noctalia.state.get("cover")
coverRing = noctalia.state.get("cover_ring")
track = noctalia.state.get("track")
update()
