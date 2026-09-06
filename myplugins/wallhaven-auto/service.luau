--!nonstrict
-- Wallhaven Auto-Rotate — headless service.
-- Periodically searches Wallhaven with a random tag, picks a random
-- result (with dedup against recently used IDs), and applies it to all displays.

local API_BASE = "https://wallhaven.cc/api/v1"
local CHECK_INTERVAL_MS = 1000
local MAX_RETRY_TAGS = 3
local MAX_RECENT_IDS = 50
local ROTATION_TIMEOUT_MS = 60000
local RETRY_DELAYS_MS = { 60000, 300000, 900000, 1800000 }
local SEED_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

noctalia.setUpdateInterval(CHECK_INTERVAL_MS)

-- ── State ───────────────────────────────────────────────────────────

local enabled = true
local rotating = false
local rotationGeneration = 0
local rotationStartedMs = 0
local consecutiveFailures = 0
local nextAtMs = 0
local lastErrorNotificationDate = ""
local activeWallpaperAlias = ""

-- ── Debug Log ───────────────────────────────────────────────────────

local debugLog = noctalia.getConfig("debug_log") == true
local function logDbg(msg)
  if debugLog then noctalia.log("[wallhaven-auto] " .. msg) end
end

-- ── Helpers ─────────────────────────────────────────────────────────

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function apiKey()
  local key = noctalia.getConfig("api_key")
  if type(key) == "string" and key ~= "" then return key end
  return ""
end

local function nsfwAllowed()
  return apiKey() ~= ""
end

local function buildCategories()
  local g = noctalia.getConfig("category_general") ~= false and "1" or "0"
  local a = noctalia.getConfig("category_anime") ~= false and "1" or "0"
  local p = noctalia.getConfig("category_people") ~= false and "1" or "0"
  local result = g .. a .. p
  if result == "000" then return "100" end
  return result
end

local function buildPurity()
  local sfw = noctalia.getConfig("purity_sfw") ~= false and "1" or "0"
  local sketchy = noctalia.getConfig("purity_sketchy") ~= false and "1" or "0"
  local nsfw = (noctalia.getConfig("purity_nsfw") ~= false and nsfwAllowed()) and "1" or "0"
  local result = sfw .. sketchy .. nsfw
  if result == "000" then return "100" end
  return result
end

local function httpHeaders()
  local headers = { "Accept: application/json" }
  local key = apiKey()
  if key ~= "" then table.insert(headers, "X-API-Key: " .. key) end
  return headers
end

local function wallpaperDir()
  local dir = noctalia.pluginDataDir()
  if type(dir) == "string" and dir ~= "" then
    return dir .. "/wallpapers"
  end
  return nil
end

local function wallpaperAliasDir()
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  if type(runtimeDir) == "string" and runtimeDir ~= "" then
    local dir = runtimeDir .. "/noctalia-wallhaven-auto"
    if noctalia.mkdirAll(dir) then return dir end
  end

  local user = tostring(noctalia.getenv("USER") or "user"):gsub("[^a-zA-Z0-9._-]", "-")
  local dir = "/tmp/noctalia-wallhaven-auto-" .. user
  if noctalia.mkdirAll(dir) then return dir end
  return nil
end

-- ── Recently-Used Wallpaper Dedup ────────────────────────────────────

local recentIds = {}     -- set: id → true
local recentOrder = {}   -- ordered list for FIFO eviction

local function recentFilePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" then return nil end
  return dir .. "/recent_ids.json"
end

local function enabledFilePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" then return nil end
  return dir .. "/enabled.json"
end

local function currentFilePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" then return nil end
  return dir .. "/current.json"
end

local function loadEnabled()
  local path = enabledFilePath()
  if not path then return end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" then return end
  local decoded = noctalia.json.decode(content)
  if type(decoded) == "boolean" then enabled = decoded end
end

local function saveEnabled()
  local path = enabledFilePath()
  if not path then return end
  local encoded = noctalia.json.encode(enabled)
  if not encoded or not noctalia.writeFile(path, encoded) then
    logDbg("failed to persist enabled state")
  end
end

local function loadCurrent()
  local path = currentFilePath()
  if not path then return nil end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" then return nil end
  local decoded = noctalia.json.decode(content)
  if type(decoded) ~= "table" then return nil end
  return decoded
end

local function saveCurrent(current)
  local path = currentFilePath()
  if not path then return end
  local encoded = noctalia.json.encode(current)
  if not encoded or not noctalia.writeFile(path, encoded) then
    logDbg("failed to persist current wallpaper")
  end
end

local function currentFileExists(current)
  return type(current) == "table"
    and type(current.file_path) == "string"
    and current.file_path ~= ""
    and noctalia.fileExists(current.file_path)
end

local function wallpaperExtension(current)
  local ext = tostring(current.file_ext or current.file_path:match("%.([a-zA-Z0-9]+)$") or "jpg")
    :lower():gsub("[^a-z0-9]", "")
  if ext == "" then return "jpg" end
  return ext
end

local function cleanupWallpaperDir(keepPath)
  local dir = wallpaperDir()
  if not dir then return end
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then return end

  for _, name in ipairs(entries) do
    local path = dir .. "/" .. name
    if path ~= keepPath then
      local info = noctalia.fileInfo(path)
      if info and not info.isDir then noctalia.removeFile(path) end
    end
  end
end

local function cleanupAliasDir(dir, keepAlias)
  local entries = noctalia.listDir(dir)
  if type(entries) ~= "table" then return end

  for _, name in ipairs(entries) do
    local path = dir .. "/" .. name
    if path ~= keepAlias then
      local info = noctalia.fileInfo(path)
      if info and not info.isDir then noctalia.removeFile(path) end
    end
  end
end

local function moveCurrentToPersistentStorage(current)
  if not currentFileExists(current) then return nil end

  local dir = wallpaperDir()
  if not dir then return current end
  if not noctalia.mkdirAll(dir) then return current end

  local ext = wallpaperExtension(current)
  local destination = dir .. "/wallpaper." .. ext
  if current.file_path == destination then
    cleanupWallpaperDir(destination)
    return current
  end

  noctalia.removeFile(destination)
  local moved = noctalia.renameFile(current.file_path, destination)
  if not moved then
    -- renameFile can fail when /tmp and the data directory are on different
    -- filesystems. Luau strings are binary-safe, so fall back to copying.
    local bytes = noctalia.readFile(current.file_path)
    if type(bytes) ~= "string" or not noctalia.writeFile(destination, bytes) then
      logDbg("failed to migrate wallpaper from " .. current.file_path)
      return current
    end
    noctalia.removeFile(current.file_path)
  end

  current.file_path = destination
  current.file_ext = ext
  saveCurrent(current)
  cleanupWallpaperDir(destination)
  logDbg("migrated wallpaper to " .. destination)
  return current
end

local function promoteDownload(stagingPath, destination)
  local backupPath = destination .. ".previous"
  local hadPrevious = noctalia.fileExists(destination)

  noctalia.removeFile(backupPath)
  if hadPrevious and not noctalia.renameFile(destination, backupPath) then
    return false
  end

  if not noctalia.renameFile(stagingPath, destination) then
    if hadPrevious then noctalia.renameFile(backupPath, destination) end
    return false
  end

  if hadPrevious then noctalia.removeFile(backupPath) end
  return true
end

local function applyWallpaper(path, wallpaperId, onApplied)
  -- The real image intentionally keeps a stable name to bound storage. Give
  -- Noctalia a unique, existing symlink so its texture cache sees a new source
  -- while persistence and "Save to Pictures" keep using the canonical path.
  local dir = wallpaperAliasDir()
  if not dir then
    if onApplied then onApplied(false) end
    return
  end

  local id = tostring(wallpaperId or "unknown"):gsub("[^a-zA-Z0-9._-]", "-")
  local ext = path:match("%.([a-zA-Z0-9]+)$") or "jpg"
  local alias = dir .. "/.wallpaper-source-" .. id .. "-" .. tostring(noctalia.nowMs()) .. "." .. ext
  noctalia.removeFile(alias)

  local command = "ln -s " .. shellQuote(path) .. " " .. shellQuote(alias)
  local started = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 or not noctalia.fileExists(alias) then
      noctalia.removeFile(alias)
      logDbg("failed to create wallpaper source alias")
      if onApplied then onApplied(false) end
      return
    end

    local previousAlias = activeWallpaperAlias
    activeWallpaperAlias = alias
    noctalia.setWallpaper(alias)
    cleanupWallpaperDir(path)
    cleanupAliasDir(dir, alias)
    if previousAlias ~= "" and previousAlias ~= alias then noctalia.removeFile(previousAlias) end
    logDbg("applied wallpaper through " .. alias)
    if onApplied then onApplied(true) end
  end, 5000)

  if not started then
    logDbg("could not start wallpaper source alias creation")
    if onApplied then onApplied(false) end
  end
end

local function loadRecentIds()
  local path = recentFilePath()
  if not path then return end
  local content = noctalia.readFile(path)
  if type(content) ~= "string" then return end
  local decoded = noctalia.json.decode(content)
  if type(decoded) ~= "table" then return end
  for _, id in ipairs(decoded) do
    if type(id) == "string" and not recentIds[id] then
      recentIds[id] = true
      table.insert(recentOrder, id)
    end
  end
  -- Trim if persisted list exceeds max
  while #recentOrder > MAX_RECENT_IDS do
    recentIds[table.remove(recentOrder, 1)] = nil
  end
  logDbg("loaded " .. tostring(#recentOrder) .. " recent IDs")
end

local function saveRecentIds()
  local path = recentFilePath()
  if not path then return end
  local ok = noctalia.writeFile(path, noctalia.json.encode(recentOrder))
  if not ok then logDbg("failed to persist recent IDs") end
end

local function markRecent(id)
  local idStr = tostring(id)
  if recentIds[idStr] then return end  -- already tracked
  recentIds[idStr] = true
  table.insert(recentOrder, idStr)
  while #recentOrder > MAX_RECENT_IDS do
    recentIds[table.remove(recentOrder, 1)] = nil
  end
  saveRecentIds()
end

-- ── URL Builder ─────────────────────────────────────────────────────

local function generateSeed()
  local chars = {}
  for _ = 1, 6 do
    local index = math.random(1, #SEED_CHARS)
    table.insert(chars, SEED_CHARS:sub(index, index))
  end
  return table.concat(chars)
end

local function buildSearchUrl(tag)
  local params = {
    "categories=" .. buildCategories(),
    "purity=" .. buildPurity(),
    "sorting=random",
    "order=desc",
    "page=1",
    "seed=" .. generateSeed(),
  }

  local atleast = noctalia.getConfig("resolution_atleast")
  if type(atleast) == "string" and atleast ~= "" then
    table.insert(params, "atleast=" .. atleast)
  end

  local ratio = noctalia.getConfig("ratio")
  if type(ratio) == "string" and ratio ~= "any" then
    table.insert(params, "ratios=" .. ratio)
  end

  if tag ~= nil then
    table.insert(params, "q=" .. noctalia.string.urlEncode(tag))
  end

  return API_BASE .. "/search?" .. table.concat(params, "&")
end

-- ── Status Publisher ────────────────────────────────────────────────

local function publishStatus(state, tag, errMsg)
  local s = { state = state }
  if nextAtMs > 0 then s.next_at_ms = nextAtMs end
  if tag ~= nil then s.current_tag = tag end
  if errMsg ~= nil then s.error_message = errMsg end
  noctalia.state.set("wallhaven_auto_status", s)
end

-- ── Rotation ────────────────────────────────────────────────────────

local function rotationIsCurrent(generation)
  return rotating and generation == rotationGeneration
end

local function failAndRelease(msg, generation)
  if generation and not rotationIsCurrent(generation) then return end
  logDbg("FAIL: " .. msg)
  rotating = false
  rotationStartedMs = 0
  consecutiveFailures = consecutiveFailures + 1
  local retryIndex = math.min(consecutiveFailures, #RETRY_DELAYS_MS)
  nextAtMs = noctalia.nowMs() + RETRY_DELAYS_MS[retryIndex]
  publishStatus("error", nil, msg)
  local date = os.date("%Y-%m-%d")
  if lastErrorNotificationDate ~= date then
    lastErrorNotificationDate = date
    noctalia.notifyError(noctalia.tr("notify.failed"), msg)
  end
end

local function completeAndRelease(tag, wallpaper, dest, ext, generation)
  if not rotationIsCurrent(generation) then return end
  logDbg("OK: rotation complete, tag=" .. (tag or "?") .. " dest=" .. dest)
  rotating = false
  rotationStartedMs = 0
  consecutiveFailures = 0

  markRecent(wallpaper and wallpaper.id or "unknown")
  local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
  nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
  publishStatus("idle", nil, nil)

  -- Save wallpaper info for panel/widget display
  local wId = (wallpaper and wallpaper.id) and tostring(wallpaper.id) or ""
  local wRes = (wallpaper and wallpaper.resolution) and tostring(wallpaper.resolution) or ""
  local wPurity = (wallpaper and wallpaper.purity) and tostring(wallpaper.purity) or ""
  local current = {
    id = wId,
    resolution = wRes,
    purity = wPurity,
    tag = tag or "",
    file_path = dest,
    file_ext = ext,
  }
  noctalia.state.set("wallhaven_auto_current", current)
  saveCurrent(current)
  cleanupWallpaperDir(dest)

  -- Build notification with wallpaper info
  local bodyParts = {}
  if tag then table.insert(bodyParts, "Tag: " .. tag) end
  if wRes ~= "" then table.insert(bodyParts, "Resolution: " .. wRes) end
  if wId ~= "" then table.insert(bodyParts, "ID: " .. wId) end
  noctalia.notify(noctalia.tr("notify.applied"), table.concat(bodyParts, " · "))
end

local function rotate(customTag)
  if rotating then logDbg("rotate: already rotating, skip"); return end
  rotationGeneration = rotationGeneration + 1
  local generation = rotationGeneration
  rotating = true
  rotationStartedMs = noctalia.nowMs()

  if customTag and customTag ~= "" then
    logDbg("rotate: custom tag=" .. customTag)
  else
    logDbg("rotate: start, attemptTags=" .. tostring(#(noctalia.getConfig("tags") or {})) .. " tags + nil fallback")
  end

  -- Download + apply
  local function downloadAndApply(wallpaper, tag)
    if not rotationIsCurrent(generation) then return end
    local imageUrl = wallpaper.path
    if type(imageUrl) ~= "string" or imageUrl == "" then
      failAndRelease("Wallpaper has no image URL", generation)
      return
    end

    local ext = (wallpaper.file_type == "image/png") and "png" or "jpg"
    local targetDir = wallpaperDir()
    if not targetDir then
      failAndRelease("Persistent plugin data directory is unavailable", generation)
      return
    end
    local dest = targetDir .. "/wallpaper." .. ext
    local stagingPath = targetDir .. "/wallpaper.download-" .. tostring(generation) .. "." .. ext

    logDbg("downloadAndApply: downloading " .. stagingPath .. " from " .. imageUrl:sub(1, 80) .. "...")
    publishStatus("downloading", tag)

    local dirOk = noctalia.mkdirAll(targetDir)
    if not dirOk then
      logDbg("downloadAndApply: mkdir failed")
      failAndRelease("Failed to create persistent wallpaper directory", generation)
      return
    end

    noctalia.removeFile(stagingPath)
    local started = noctalia.download(imageUrl, stagingPath, function(ok)
      if not rotationIsCurrent(generation) then
        noctalia.removeFile(stagingPath)
        return
      end
      if not ok then
        noctalia.removeFile(stagingPath)
        logDbg("downloadAndApply: download failed")
        failAndRelease("Download failed", generation)
        return
      end

      if not promoteDownload(stagingPath, dest) then
        noctalia.removeFile(stagingPath)
        failAndRelease("Failed to replace cached wallpaper", generation)
        return
      end

      logDbg("downloadAndApply: download promoted to " .. dest .. ", applying")
      publishStatus("applying", tag)
      applyWallpaper(dest, wallpaper.id, function(applied)
        if not rotationIsCurrent(generation) then return end
        if not applied then
          failAndRelease("Failed to prepare wallpaper for display", generation)
          return
        end
        completeAndRelease(tag, wallpaper, dest, ext, generation)
      end)
    end)

    if not started then
      logDbg("downloadAndApply: download not started")
      failAndRelease("Could not start download", generation)
    end
  end

  -- Search with retry chain
  local function doSearch(attemptTags, index)
    if not rotationIsCurrent(generation) then return end
    if index > #attemptTags then
      failAndRelease("No wallpapers found for any tag", generation)
      return
    end

    local tag = attemptTags[index].tag
    local tagLabel = tag or "(no query)"
    logDbg("doSearch: trying tag=" .. tagLabel)
    publishStatus("searching", tag)
    noctalia.notify(
      noctalia.tr("notify.searching"),
      noctalia.tr("widget.tag_label") .. ": " .. (tag or noctalia.tr("notify.no_query"))
    )

    local url = buildSearchUrl(tag)
    noctalia.http({ url = url, headers = httpHeaders() }, function(res)
      if not rotationIsCurrent(generation) then return end
      if not res.ok then
        logDbg("doSearch: HTTP failed status=" .. tostring(res.status) .. " for tag=" .. tagLabel)
        failAndRelease("Search request failed (HTTP " .. tostring(res.status) .. ")", generation)
        return
      end

      local decoded = noctalia.json.decode(res.body)
      if type(decoded) ~= "table" or type(decoded.data) ~= "table" or #decoded.data == 0 then
        logDbg("doSearch: no results for tag=" .. tagLabel .. ", trying next")
        doSearch(attemptTags, index + 1)
        return
      end

      logDbg("doSearch: found " .. tostring(#decoded.data) .. " results for tag=" .. tagLabel)

      -- Build a candidate list, excluding recently-used IDs
      local candidates = {}
      for _, item in ipairs(decoded.data) do
        if not recentIds[tostring(item.id)] then
          table.insert(candidates, item)
        end
      end
      -- If everything was recently used, fall back to the full list
      if #candidates == 0 then
        logDbg("doSearch: all results are recent, using full list")
        candidates = decoded.data
      else
        logDbg("doSearch: " .. tostring(#candidates) .. " non-recent candidates out of " .. tostring(#decoded.data))
      end

      -- Pick a random wallpaper from the candidates
      local pick = candidates[math.random(1, #candidates)]
      logDbg("doSearch: picked id=" .. tostring(pick.id))
      downloadAndApply(pick, tag)
    end)
  end

  -- Build attempt list: shuffle tags, take first MAX_RETRY_TAGS, append nil fallback
  local attemptTags = {}
  if customTag and customTag ~= "" then
    -- Custom tag: use it directly, no shuffle, no fallback
    table.insert(attemptTags, { tag = customTag })
  else
    local tags = noctalia.getConfig("tags")
    if type(tags) == "table" and #tags > 0 then
      for _, t in ipairs(tags) do table.insert(attemptTags, { tag = t }) end
      -- Fisher-Yates shuffle
      for i = #attemptTags, 2, -1 do
        local j = math.random(i)
        attemptTags[i], attemptTags[j] = attemptTags[j], attemptTags[i]
      end
      while #attemptTags > MAX_RETRY_TAGS do
        table.remove(attemptTags)
      end
    end
    -- nil sentinel: no-query fallback
    table.insert(attemptTags, { tag = nil })
  end

  doSearch(attemptTags, 1)
end

-- ── Update Loop ─────────────────────────────────────────────────────

function update()
  -- Publish remaining time every tick so panel countdown stays live
  local s = noctalia.state.get("wallhaven_auto_status") or {}
  if enabled and nextAtMs > 0 then
    s.next_at_ms = nextAtMs
    s.remaining_sec = math.max(0, math.floor((nextAtMs - noctalia.nowMs()) / 1000))
  else
    s.remaining_sec = nil
  end
  noctalia.state.set("wallhaven_auto_status", s)

  local now = noctalia.nowMs()
  if rotating and rotationStartedMs > 0 and now - rotationStartedMs > ROTATION_TIMEOUT_MS then
    failAndRelease("Rotation timed out", rotationGeneration)
  end

  if not enabled then return end

  if nextAtMs == 0 or now >= nextAtMs then
    rotate()
  end
end

-- ── Commands ────────────────────────────────────────────────────────

noctalia.state.watch("wallhaven_auto_command", function(cmd)
  if type(cmd) ~= "table" then return end

  if cmd.action == "rotate" then
    -- Force immediate rotation, optionally with a custom tag
    logDbg("command: rotate" .. (cmd.tag and (" tag=" .. cmd.tag) or ""))
    nextAtMs = 0
    rotate(cmd.tag)
  elseif cmd.action == "toggle" then
    logDbg("command: toggle -> " .. tostring(not enabled))
    enabled = not enabled
    saveEnabled()
    noctalia.state.set("wallhaven_auto_enabled", enabled)
    if enabled then
      local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
      nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
      publishStatus("idle", nil, nil)
    else
      if rotating then
        rotationGeneration = rotationGeneration + 1
        rotating = false
        rotationStartedMs = 0
      end
      publishStatus("idle", nil, nil)
    end
  end
end)

function onIpc(event, payload)
  if event == "rotate" then
    local tag = nil
    if type(payload) == "string" then
      local trimmed = noctalia.string.trim(payload)
      if trimmed ~= "" then tag = trimmed end
    end
    logDbg("ipc: rotate" .. (tag and (" tag=" .. tag) or ""))
    nextAtMs = 0
    rotate(tag)
  elseif event == "toggle" then
    logDbg("ipc: toggle")
    noctalia.state.set("wallhaven_auto_command", { action = "toggle" })
  end
end

-- ── Config Changes ──────────────────────────────────────────────────

function onConfigChanged()
  debugLog = noctalia.getConfig("debug_log") == true
  logDbg("onConfigChanged")
  if enabled and not rotating then
    local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
    nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
    publishStatus("idle", nil, nil)
  elseif not rotating then
    publishStatus("idle", nil, nil)
  end
end

-- ── Boot ────────────────────────────────────────────────────────────

loadRecentIds()
loadEnabled()
noctalia.state.set("wallhaven_auto_enabled", enabled)

-- Runtime state is not preserved across shell restarts, so fall back to the
-- persisted metadata and re-apply the last wallpaper even when auto-rotation
-- is disabled.
local existing = noctalia.state.get("wallhaven_auto_current")
if not currentFileExists(existing) then
  existing = loadCurrent()
end

if currentFileExists(existing) then
  existing = moveCurrentToPersistentStorage(existing)
  noctalia.state.set("wallhaven_auto_current", existing)
  saveCurrent(existing)
  applyWallpaper(existing.file_path, existing.id, function(applied)
    if applied then
      logDbg("restored wallpaper from " .. existing.file_path)
    else
      logDbg("failed to restore wallpaper from " .. existing.file_path)
    end
  end)
  if enabled then
    local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
    nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
  else
    nextAtMs = 0
  end
  publishStatus("idle", nil, nil)
else
  nextAtMs = 0
  publishStatus("idle", nil, nil)
end
