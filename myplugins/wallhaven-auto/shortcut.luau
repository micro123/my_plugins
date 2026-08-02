--!nonstrict
-- Control-center shortcut for Wallhaven Auto-Rotate.
-- Toggles auto-rotation on/off.

local enabled = noctalia.state.get("wallhaven_auto_enabled") ~= false

local function render()
  shortcut.setLabel(noctalia.tr("shortcut.label"))
  shortcut.setIcon("photo")
  shortcut.setActive(enabled)
  shortcut.setEnabled(true)
end

noctalia.state.watch("wallhaven_auto_enabled", function(v)
  enabled = v ~= false
  render()
end)

function update()
  render()
end

function onClick()
  noctalia.state.set("wallhaven_auto_command", { action = "toggle" })
end

render()
