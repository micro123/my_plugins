--!nonstrict
-- Info panel for Wallhaven Auto-Rotate.
-- Shows current wallpaper info, status, and controls.

local status = noctalia.state.get("wallhaven_auto_status") or { state = "idle" }
local enabled = noctalia.state.get("wallhaven_auto_enabled") ~= false
local current = noctalia.state.get("wallhaven_auto_current") or {}

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function render()
  local rows = {}

  -- Title
  rows[#rows + 1] = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr("widget.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
  })

  -- Thumbnail
  local thumbPath = current.file_path
  if type(thumbPath) == "string" and thumbPath ~= "" and noctalia.fileExists(thumbPath) then
    rows[#rows + 1] = ui.image({
      path = thumbPath, width = 280, height = 175, radius = 8, fit = "cover",
    })
  end

  -- Status
  local statusText = noctalia.tr("status.idle")
  local statusColor = "on_surface_variant"
  if status.state == "searching" then
    statusText = noctalia.tr("status.searching"); statusColor = "primary"
  elseif status.state == "downloading" then
    statusText = noctalia.tr("status.downloading"); statusColor = "primary"
  elseif status.state == "applying" then
    statusText = noctalia.tr("status.applying"); statusColor = "primary"
  elseif status.state == "error" then
    statusText = noctalia.tr("status.error"); statusColor = "error"
  elseif not enabled then
    statusText = noctalia.tr("status.disabled"); statusColor = "on_surface/0.35"
  end

  rows[#rows + 1] = ui.row({ gap = 6, align = "center" }, {
    ui.label({ text = noctalia.tr("panel.status") .. ":", fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = statusText, fontSize = 12, color = statusColor, fontWeight = "bold" }),
  })

  -- Auto-rotation toggle
  rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.toggle({ checked = enabled, onChange = "onToggleAuto" }),
    ui.label({ text = noctalia.tr("panel.auto_rotate"), fontSize = 12, color = "on_surface" }),
  })

  -- Custom tag (one-shot, cleared after use)
  local customTag = noctalia.state.get("wallhaven_auto_custom_tag") or ""
  rows[#rows + 1] = ui.input({
    placeholder = noctalia.tr("panel.custom_tag_placeholder"),
    value = customTag,
    fontSize = 12,
    controlSize = "sm",
    onChange = "onCustomTagChange",
    onSubmit = "onCustomTagSubmit",
  })

  -- Countdown (always present to avoid layout jump)
  local countdownText = ""
  if not enabled then
    countdownText = noctalia.tr("status.disabled")
  elseif status.remaining_sec then
    local mins = math.floor(status.remaining_sec / 60)
    local secs = status.remaining_sec % 60
    countdownText = noctalia.tr("panel.next_rotation") .. ": " .. string.format("%d:%02d", mins, secs)
  else
    countdownText = " "
  end
  rows[#rows + 1] = ui.label({
    text = countdownText, fontSize = 11, color = "on_surface_variant", maxLines = 1,
  })

  -- Current wallpaper info
  rows[#rows + 1] = ui.separator({ thickness = 1, color = "outline" })

  local wId = current.id
  local hasWallpaper = type(wId) == "string" and wId ~= ""
  local wallhavenUrl = hasWallpaper and ("https://wallhaven.cc/w/" .. wId) or ""

  rows[#rows + 1] = ui.row({ align = "center", justify = "space_between" }, {
    ui.label({
      text = noctalia.tr("panel.current_wallpaper"), fontSize = 13, fontWeight = "bold", color = "on_surface",
    }),
    ui.row({ gap = 2, visible = hasWallpaper }, {
      ui.button({ glyph = "external-link", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.open"),
        onClick = function() noctalia.runAsync("xdg-open " .. wallhavenUrl) end }),
      ui.button({ glyph = "copy", variant = "ghost", controlSize = "sm",
        tooltip = noctalia.tr("panel.copy_link"),
        onClick = function() noctalia.copyToClipboard(wallhavenUrl, "text/plain") end }),
    }),
  })

  if hasWallpaper then
    rows[#rows + 1] = ui.column({ gap = 4 }, {
      ui.label({ text = "ID: " .. wId, fontSize = 12, color = "on_surface_variant" }),
      ui.row({ gap = 8 }, {
        ui.label({
          text = noctalia.tr("panel.resolution") .. ": " .. (current.resolution or "?"),
          fontSize = 12, color = "on_surface_variant",
        }),
        ui.label({
          text = (current.purity or ""):upper(),
          fontSize = 11, color = current.purity == "nsfw" and "error" or (current.purity == "sketchy" and "tertiary" or "primary"),
          fontWeight = "bold",
        }),
      }),
      ui.label({
        text = noctalia.tr("widget.tag_label") .. ": " .. (current.tag or ""),
        fontSize = 12, color = "on_surface_variant",
      }),
    })
  else
    rows[#rows + 1] = ui.column({ gap = 4, height = 52 }, {
      ui.label({
        text = noctalia.tr("panel.no_wallpaper"), fontSize = 12, color = "on_surface_variant", opacity = 0.5,
      }),
    })
  end

  -- Controls
  rows[#rows + 1] = ui.separator({ thickness = 1, color = "outline" })
  rows[#rows + 1] = ui.row({ gap = 8, justify = "center" }, {
    ui.button({ text = noctalia.tr("panel.rotate_now"), variant = "primary", onClick = "onRotate",
      enabled = status.state == "idle" or status.state == "error" }),
    ui.button({ text = noctalia.tr("panel.save"), variant = "outline", onClick = "onSave",
      enabled = type(wId) == "string" and wId ~= "" }),
  })

  panel.render(ui.column({ gap = 12, padding = 20 }, rows))
end

function onOpen(_context)
  status = noctalia.state.get("wallhaven_auto_status") or { state = "idle" }
  enabled = noctalia.state.get("wallhaven_auto_enabled") ~= false
  current = noctalia.state.get("wallhaven_auto_current") or {}
  render()
end

function onClose() end

function onToggleAuto(_checked)
  noctalia.state.set("wallhaven_auto_command", { action = "toggle" })
end

function onRotate()
  local tag = noctalia.state.get("wallhaven_auto_custom_tag")
  local cmd = { action = "rotate" }
  if type(tag) == "string" and tag ~= "" then cmd.tag = tag end
  noctalia.state.set("wallhaven_auto_command", cmd)
  noctalia.state.set("wallhaven_auto_custom_tag", "")  -- clear after use
end

function onCustomTagChange(value)
  noctalia.state.set("wallhaven_auto_custom_tag", noctalia.string.trim(value))
end

function onCustomTagSubmit(value)
  noctalia.state.set("wallhaven_auto_custom_tag", noctalia.string.trim(value))
  onRotate()
end

function onSave()
  local wId = current.id
  if type(wId) ~= "string" or wId == "" then return end
  local src = current.file_path
  if type(src) ~= "string" or src == "" or not noctalia.fileExists(src) then
    noctalia.notifyError(noctalia.tr("notify.save_failed"), noctalia.tr("notify.no_file"))
    return
  end
  local ext = current.file_ext
  if type(ext) ~= "string" or ext == "" then ext = "jpg" end
  local picturesDir = noctalia.expandPath("~/Pictures")
  if not noctalia.mkdirAll(picturesDir) then
    noctalia.notifyError(noctalia.tr("notify.save_failed"), picturesDir)
    return
  end
  local dest = picturesDir .. "/Wallhaven-" .. wId .. "." .. ext
  noctalia.runAsync("cp " .. shellQuote(src) .. " " .. shellQuote(dest), function(r)
    if r.exitCode == 0 then
      noctalia.notify(noctalia.tr("notify.saved"), dest)
    else
      noctalia.notifyError(noctalia.tr("notify.save_failed"), dest)
    end
  end)
end

noctalia.state.watch("wallhaven_auto_status", function(v)
  if type(v) == "table" then status = v; render() end
end)

noctalia.state.watch("wallhaven_auto_enabled", function(v)
  enabled = v ~= false; render()
end)

noctalia.state.watch("wallhaven_auto_current", function(v)
  if type(v) == "table" then current = v; render() end
end)

render()
