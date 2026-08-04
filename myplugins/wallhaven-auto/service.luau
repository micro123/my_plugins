--!nonstrict
-- Wallhaven Auto-Rotate — headless service.
-- Periodically searches Wallhaven with a random tag, picks a random
-- result (with dedup against recently used IDs), and applies it to all displays.

local API_BASE = "https://wallhaven.cc/api/v1"
local TEMP_DIR_NAME = "wallhaven-auto"
local CHECK_INTERVAL_MS = 1000
local MAX_RETRY_TAGS = 3
local MAX_RECENT_IDS = 50
local SEED_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

noctalia.setUpdateInterval(CHECK_INTERVAL_MS)

-- ── State ───────────────────────────────────────────────────────────

local enabled = true
local rotating = false
local nextAtMs = 0
local lastErrorNotificationDate = ""

-- ── Debug Log ───────────────────────────────────────────────────────

local debugLog = noctalia.getConfig("debug_log") == true
local function logDbg(msg)
  if debugLog then noctalia.log("[wallhaven-auto] " .. msg) end
end

-- ── Helpers ─────────────────────────────────────────────────────────

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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

local function tempDir()
  local cache = noctalia.getenv("XDG_CACHE_HOME")
  if type(cache) == "string" and cache ~= "" then
    return cache .. "/" .. TEMP_DIR_NAME
  end
  return "/tmp/" .. TEMP_DIR_NAME
end

local lastWallpaperPath = ""

-- ── Recently-Used Wallpaper Dedup ────────────────────────────────────

local recentIds = {}     -- set: id → true
local recentOrder = {}   -- ordered list for FIFO eviction

local function recentFilePath()
  local dir = noctalia.pluginDataDir()
  if type(dir) ~= "string" then return nil end
  return dir .. "/recent_ids.json"
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
    table.insert(chars, SEED_CHARS:sub(math.random(1, #SEED_CHARS), math.random(1, #SEED_CHARS)))
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

local function failAndRelease(msg)
  logDbg("FAIL: " .. msg)
  rotating = false
  publishStatus("error", nil, msg)
  local date = os.date("%Y-%m-%d")
  if lastErrorNotificationDate ~= date then
    lastErrorNotificationDate = date
    noctalia.notifyError(noctalia.tr("notify.failed"), msg)
  end
end

local function completeAndRelease(tag, wallpaper, dest, ext)
  logDbg("OK: rotation complete, tag=" .. (tag or "?") .. " dest=" .. dest)
  rotating = false

  -- Clean up old wallpaper file
  if lastWallpaperPath ~= "" and lastWallpaperPath ~= dest then
    noctalia.removeFile(lastWallpaperPath)
  end
  lastWallpaperPath = dest
  local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
  nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
  publishStatus("idle", nil, nil)

  -- Save wallpaper info for panel/widget display
  local wId = (wallpaper and wallpaper.id) and tostring(wallpaper.id) or ""
  local wRes = (wallpaper and wallpaper.resolution) and tostring(wallpaper.resolution) or ""
  local wPurity = (wallpaper and wallpaper.purity) and tostring(wallpaper.purity) or ""
  noctalia.state.set("wallhaven_auto_current", {
    id = wId,
    resolution = wRes,
    purity = wPurity,
    tag = tag or "",
    file_path = dest,
    file_ext = ext,
  })

  -- Build notification with wallpaper info
  local bodyParts = {}
  if tag then table.insert(bodyParts, "Tag: " .. tag) end
  if wRes ~= "" then table.insert(bodyParts, "Resolution: " .. wRes) end
  if wId ~= "" then table.insert(bodyParts, "ID: " .. wId) end
  noctalia.notify(noctalia.tr("notify.applied"), table.concat(bodyParts, " · "))
end

local function rotate(customTag)
  if rotating then logDbg("rotate: already rotating, skip"); return end
  rotating = true

  if customTag and customTag ~= "" then
    logDbg("rotate: custom tag=" .. customTag)
  else
    logDbg("rotate: start, attemptTags=" .. tostring(#(noctalia.getConfig("tags") or {})) .. " tags + nil fallback")
  end

  -- Download + apply
  local function downloadAndApply(wallpaper, tag)
    local imageUrl = wallpaper.path
    if type(imageUrl) ~= "string" or imageUrl == "" then
      failAndRelease("Wallpaper has no image URL")
      return
    end

    local ext = (wallpaper.file_type == "image/png") and "png" or "jpg"
    local wId = tostring(wallpaper.id or "unknown")
    local dest = tempDir() .. "/wallhaven-" .. wId .. "." .. ext

    logDbg("downloadAndApply: downloading " .. dest .. " from " .. imageUrl:sub(1, 80) .. "...")
    publishStatus("downloading", tag)

    noctalia.runAsync("mkdir -p " .. shellQuote(tempDir()), function(mkdirRes)
      if mkdirRes == nil or mkdirRes.exitCode ~= 0 then
        logDbg("downloadAndApply: mkdir failed")
        failAndRelease("Failed to create temp directory")
        return
      end

      local started = noctalia.download(imageUrl, dest, function(ok)
        if not ok then
          logDbg("downloadAndApply: download failed")
          failAndRelease("Download failed")
          return
        end

        logDbg("downloadAndApply: download ok, applying")
        publishStatus("applying", tag)
        noctalia.setWallpaper(dest)
        completeAndRelease(tag, wallpaper, dest, ext)
      end)

      if not started then
        logDbg("downloadAndApply: download not started")
        failAndRelease("Could not start download")
      end
    end)
  end

  -- Search with retry chain
  local function doSearch(attemptTags, index)
    if index > #attemptTags then
      failAndRelease("No wallpapers found for any tag")
      return
    end

    local tag = attemptTags[index]
    local tagLabel = tag or "(no query)"
    logDbg("doSearch: trying tag=" .. tagLabel)
    publishStatus("searching", tag)

    local url = buildSearchUrl(tag)
    noctalia.http({ url = url, headers = httpHeaders() }, function(res)
      if not res.ok then
        logDbg("doSearch: HTTP failed status=" .. tostring(res.status) .. " for tag=" .. tagLabel)
        failAndRelease("Search request failed (HTTP " .. tostring(res.status) .. ")")
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
      markRecent(pick.id)
      downloadAndApply(pick, tag)
    end)
  end

  -- Build attempt list: shuffle tags, take first MAX_RETRY_TAGS, append nil fallback
  local attemptTags = {}
  if customTag and customTag ~= "" then
    -- Custom tag: use it directly, no shuffle, no fallback
    table.insert(attemptTags, customTag)
  else
    local tags = noctalia.getConfig("tags")
    if type(tags) == "table" and #tags > 0 then
      for _, t in ipairs(tags) do table.insert(attemptTags, t) end
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
    table.insert(attemptTags, nil)
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

  if not enabled then return end

  local now = noctalia.nowMs()
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
    noctalia.state.set("wallhaven_auto_enabled", enabled)
    if enabled then
      local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
      nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
      publishStatus("idle", nil, nil)
    else
      publishStatus("idle", nil, nil)
    end
  end
end)

-- ── Config Changes ──────────────────────────────────────────────────

function onConfigChanged()
  debugLog = noctalia.getConfig("debug_log") == true
  logDbg("onConfigChanged")
  if enabled then
    local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
    nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
  end
  publishStatus("idle", nil, nil)
end

-- ── Boot ────────────────────────────────────────────────────────────

loadRecentIds()
noctalia.state.set("wallhaven_auto_enabled", enabled)

-- Only rotate immediately on first-ever load; skip if state + file both intact
local existing = noctalia.state.get("wallhaven_auto_current")
local hasState = type(existing) == "table" and type(existing.id) == "string" and existing.id ~= ""
local fileOk = hasState and type(existing.file_path) == "string"
  and existing.file_path ~= "" and noctalia.fileExists(existing.file_path)
if hasState and fileOk then
  local intervalMin = tonumber(noctalia.getConfig("interval_minutes")) or 30
  nextAtMs = noctalia.nowMs() + intervalMin * 60 * 1000
  publishStatus("idle", nil, nil)
else
  nextAtMs = 0
  publishStatus("idle", nil, nil)
end
