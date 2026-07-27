--!nonstrict
-- Waylyrics media panel — track info + controls + lyrics.

local track = nil
local lyrics = nil
local playing = false
local position = 0
local cover = nil
local seekLock = false
local shuffle = false

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function formatTime(us)
  local totalSec = math.floor((us or 0) / 1000000)
  return string.format("%d:%02d", math.floor(totalSec / 60), totalSec % 60)
end

local function getCurrentLine()
  if not lyrics or #lyrics == 0 then return nil end
  local posMs = position / 1000
  local idx = 0
  for i = 1, #lyrics do
    if lyrics[i].time <= posMs then idx = i else break end
  end
  return idx > 0 and lyrics[idx] or nil
end

local function render()
  local rows = {}

  -- ── Row 1: cover + track info ──────────────────────────────────
  local left
  if cover and cover ~= "" then
    left = ui.image({ path = cover, width = 100, height = 100, radius = 8, fit = "cover" })
  else
    left = ui.glyph({ name = "music", size = 40, color = "on_surface_variant", opacity = 0.25,
      width = 100, height = 100 })
  end

  local infoCol = {}
  if track then
    infoCol[#infoCol + 1] = ui.label({
      text = track.title or noctalia.tr("no_lyrics"),
      fontSize = 18, fontWeight = "bold", color = "on_surface", maxLines = 2,
    })
    if track.artist and track.artist ~= "" then
      infoCol[#infoCol + 1] = ui.label({
        text = track.artist, fontSize = 14, color = "on_surface_variant", maxLines = 1,
      })
    end
    if track.album and track.album ~= "" then
      infoCol[#infoCol + 1] = ui.label({
        text = track.album, fontSize = 12, color = "on_surface_variant", opacity = 0.6, maxLines = 1,
      })
    end
  else
    infoCol[#infoCol + 1] = ui.label({
      text = noctalia.tr("panel.no_track"), fontSize = 14, color = "on_surface_variant",
    })
  end
  rows[#rows + 1] = ui.row({ gap = 16, align = "start" }, {
    left,
    ui.column({ gap = 6, flexGrow = 1 }, infoCol),
  })

  -- ── Row 2: seek slider ─────────────────────────────────────────
  if track then
    local durationUs = tonumber(track.duration) or 0
    if durationUs > 0 then
      local durationSec = math.floor(durationUs / 1000000)
      local currentSec = clamp(math.floor(position / 1000000), 0, durationSec)
      rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = formatTime(position), fontSize = 11, color = "on_surface_variant" }),
        ui.slider({ min = 0, max = durationSec, step = 1, value = currentSec, flexGrow = 1,
          controlSize = "sm", onChange = function(v) onSeek(v) end }),
        ui.label({ text = formatTime(durationUs), fontSize = 11, color = "on_surface_variant" }),
      })
    end
  end

  -- ── Row 3: playback controls ───────────────────────────────────
  rows[#rows + 1] = ui.row({ gap = 4, justify = "center" }, {
    ui.button({ glyph = "player-skip-back", variant = "ghost", controlSize = "md", onClick = "onPrev",
      tooltip = noctalia.tr("panel.previous") }),
    ui.button({
      glyph = playing and "player-pause" or "player-play", variant = "primary", controlSize = "md",
      onClick = "onPlayPause",
      tooltip = playing and noctalia.tr("panel.pause") or noctalia.tr("panel.play"),
    }),
    ui.button({ glyph = "player-skip-forward", variant = "ghost", controlSize = "md", onClick = "onNext",
      tooltip = noctalia.tr("panel.next") }),
    ui.button({ glyph = "arrows-shuffle", variant = shuffle and "primary" or "ghost",
      controlSize = "md", onClick = "onShuffleToggle",
      tooltip = noctalia.tr("panel.shuffle") }),
  })

  -- ── Row 4: current lyrics ──────────────────────────────────────
  rows[#rows + 1] = ui.separator({ thickness = 1, color = "outline" })

  local line = getCurrentLine()
  if line then
    rows[#rows + 1] = ui.label({
      text = line.text or "", fontSize = 13, color = "on_surface_variant",
      maxLines = 2, textAlign = "center",
    })
    if line.translation and line.translation ~= "" then
      rows[#rows + 1] = ui.label({
        text = line.translation, fontSize = 12, color = "on_surface_variant",
        opacity = 0.6, maxLines = 2, textAlign = "center",
      })
    end
  else
    rows[#rows + 1] = ui.label({
      text = noctalia.tr("cue_text") or "···",
      fontSize = 13, color = "on_surface_variant", opacity = 0.4, textAlign = "center",
    })
  end

  panel.render(ui.column({ gap = 12, padding = 20 }, rows))
end

-- ── Controls ─────────────────────────────────────────────────────

local function playerCtl(action)
  local instance = noctalia.state.get("player_instance") or ""
  local cmd = instance ~= ""
    and ("playerctl --player " .. instance .. " " .. action)
    or ("playerctl " .. action)
  noctalia.runAsync(cmd)
end
function onPlayPause() playerCtl("play-pause") end
function onNext() playerCtl("next") end
function onPrev() playerCtl("previous") end

function onShuffleToggle()
  shuffle = not shuffle
  playerCtl(shuffle and "shuffle on" or "shuffle off")
  render()
end

function onSeek(secStr)
  if seekLock then return end
  local sec = tonumber(secStr)
  if not sec then return end
  local curSec = math.floor(position / 1000000)
  if math.abs(sec - curSec) <= 1 then return end  -- ignore render-driven calls
  seekLock = true
  local instance = noctalia.state.get("player_instance") or ""
  local cmd = instance ~= ""
    and ("playerctl --player " .. instance .. " position " .. sec)
    or ("playerctl position " .. sec)
  noctalia.runAsync(cmd)
  -- release lock after a short delay
  noctalia.runAsync("sleep 0.5", function() seekLock = false end)
end

-- ── State watches ────────────────────────────────────────────────

noctalia.state.watch("track", function(v) track = v; render() end)
noctalia.state.watch("lyrics", function(v) lyrics = v; render() end)
noctalia.state.watch("position", function(v) position = tonumber(v) or 0; render() end)
noctalia.state.watch("playing", function(v) playing = v == true; render() end)
noctalia.state.watch("cover", function(v) if v and v ~= "" then cover = v end; render() end)

function onOpen(_context)
  track = noctalia.state.get("track")
  lyrics = noctalia.state.get("lyrics")
  position = noctalia.state.get("position") or 0
  playing = noctalia.state.get("playing") == true
  local cv = noctalia.state.get("cover")
  if cv and cv ~= "" then cover = cv end
  render()
end

-- Seed
track = noctalia.state.get("track")
lyrics = noctalia.state.get("lyrics")
position = noctalia.state.get("position") or 0
playing = noctalia.state.get("playing") == true
cover = noctalia.state.get("cover")
render()
