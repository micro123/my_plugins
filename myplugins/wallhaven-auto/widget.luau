--!nonstrict
-- Bar widget for Wallhaven Auto-Rotate.
-- Left-click: open info panel. Right-click: force rotate. Middle-click: save to Pictures.

local status = noctalia.state.get("wallhaven_auto_status") or { state = "idle" }
local enabled = noctalia.state.get("wallhaven_auto_enabled") ~= false
local current = noctalia.state.get("wallhaven_auto_current") or {}
local showCountdown = noctalia.getConfig("show_countdown")
local isVertical = barWidget.isVertical()

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function render()
  isVertical = barWidget.isVertical()

  local color = "on_surface"
  if status.state == "searching" or status.state == "downloading" or status.state == "applying" then
    color = "primary"
  elseif status.state == "error" then
    color = "error"
  elseif not enabled then
    color = "on_surface/0.35"
  elseif current.purity == "nsfw" then
    color = "error"
  elseif current.purity == "sketchy" then
    color = "tertiary"
  elseif current.purity == "sfw" then
    color = "primary"
  end

  local container = isVertical and ui.column or ui.row
  local children = {
    ui.glyph({ name = "photo", color = color, size = 16 }),
  }

  if not isVertical and showCountdown then
    local label = ""
    if status.state == "searching" then
      label = noctalia.tr("status.searching")
    elseif status.state == "downloading" then
      label = noctalia.tr("status.downloading")
    elseif status.state == "applying" then
      label = noctalia.tr("status.applying")
    elseif status.state == "error" then
      label = noctalia.tr("status.error")
    elseif not enabled then
      label = noctalia.tr("status.disabled")
    elseif status.remaining_sec then
      local mins = math.floor(status.remaining_sec / 60)
      local secs = status.remaining_sec % 60
      label = string.format("%d:%02d", mins, secs)
    end

    if label ~= "" then
      table.insert(children, ui.label({
        text = label, fontSize = 11, color = color, fontWeight = "bold",
      }))
    end
  end

  barWidget.render(container({ gap = 4, align = "center" }, children))

  local tip = noctalia.tr("widget.title")
  if not enabled then
    tip = tip .. " · " .. noctalia.tr("status.disabled")
  elseif status.current_tag then
    tip = tip .. " · " .. noctalia.tr("widget.tag_label") .. ": " .. status.current_tag
  end
  if status.state == "error" and status.error_message then
    tip = tip .. " · " .. status.error_message
  end
  barWidget.setTooltip(tip)
end

noctalia.state.watch("wallhaven_auto_status", function(v)
  if type(v) == "table" then status = v end
  render()
end)

noctalia.state.watch("wallhaven_auto_enabled", function(v)
  enabled = v ~= false
  render()
end)

noctalia.state.watch("wallhaven_auto_current", function(v)
  if type(v) == "table" then current = v end
end)

function onClick()
  noctalia.togglePanel("tang/wallhaven-auto:info")
end

function onRightClick()
  noctalia.state.set("wallhaven_auto_command", { action = "rotate" })
end

function onMiddleClick()
  local wId = current.id
  if type(wId) ~= "string" or wId == "" then
    noctalia.notifyError(noctalia.tr("notify.save_failed"), noctalia.tr("notify.no_wallpaper"))
    return
  end
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

render()
