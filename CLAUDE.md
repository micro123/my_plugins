# Noctalia v5 Plugin Development

This workspace is for developing plugins for [Noctalia](https://noctalia.dev) v5.

> **Docs:** https://docs.noctalia.dev/v5/plugins/development/
>
> The plugin system is currently in **beta** — APIs may still change before v5 is stable.

## Directory Layout

| Directory | Purpose | Editable |
|---|---|---|
| `official-plugins/` | Official plugins (submodule, `noctalia-dev/official-plugins`) | ❌ Reference only |
| `community-plugins/` | Community plugins (submodule, `noctalia-dev/community-plugins`) | ❌ Reference only |
| `myplugins/` | **Your plugin development directory** | ✅ |

## Plugin Structure

```
myplugins/<name>/
├── plugin.toml        # Manifest: identity + entries + settings schema
├── *.luau             # Entry scripts — one per [[widget]], [[service]], etc.
├── translations/
│   └── en.json        # i18n bundles (flattened, dotted keys)
├── README.md          # Plugin documentation
├── thumbnail.webp     # Thumbnail image (for catalog)
└── data.txt           # Any files your scripts read at runtime
```

Each entry runs in its own isolated Luau VM, off the UI thread, with per-call time budgets.

---

## Manifest (`plugin.toml`)

### Root Fields

```toml
id = "me/hello"           # "<author>/<plugin>" — globally unique
name = "Hello"            # Display name
version = "1.0.0"
plugin_api = 3            # REQUIRED — oldest plugin API level required
author = "me"
license = "MIT"           # Optional; defaults to MIT
deprecated = false        # Optional; soft status marker
icon = "puzzle"           # Optional; Tabler icon name
description = "A friendly greeter."
tags = ["demo"]           # Optional; for catalog search
dependencies = ["slurp"]  # Optional; external tools users must install
```

`name` and `plugin_api` are required. Noctalia v5 supports plugin APIs **3 through 16**.

### Entry Types

| Kind | Description |
|---|---|
| `[[widget]]` | Bar widget — ticks + handles clicks/IPC |
| `[[shortcut]]` | Control-center toggle tile |
| `[[launcher_provider]]` | Answers launcher queries behind a prefix |
| `[[desktop_widget]]` | Desktop tile; declares UI as a `ui.*` tree |
| `[[panel]]` | Pop-up surface; `ui.*` tree, opened by id |
| `[[service]]` | Headless background loop — feeds other entries |

Entries are addressed as `<author>/<plugin>:<entry-id>`.

```toml
[[widget]]
id = "hello"
entry = "widget.luau"

  [[widget.setting]]
  key = "label"
  type = "string"
  label_key = "settings.label.label"
  description_key = "settings.label.description"
  default = "Hello"

[[service]]
id = "ticker"
entry = "ticker.luau"
```

### Widget Gesture Defaults (plugin_api ≥ 14)

```toml
[widget.actions]
right = "media toggle"
scroll_up = "volume-up"
```

A binding takes precedence over the script callback. Middle click has a built-in binding to open settings — declare `middle = "none"` to free it for `onMiddleClick`.

### Settings Schema

Two scopes:
- **Plugin-level** — `[[setting]]` at manifest root. Shared by all entries, edited in Settings → Plugins.
- **Entry-level** — `[[<entry>.setting]]` under a `[[widget]]` or `[[panel]]`. Widget settings are edited with the bar widget; panel settings also appear in Settings → Plugins.

When both declare the same key, the entry value wins for that entry.

| Field | Notes |
|---|---|
| `key` | **Required**; the config key |
| `type` | `string`, `string_list`, `string_map` (api≥6), `bool`, `int`, `double`, `select`, `file`, `folder`, `glyph`, `color` |
| `label_key` | **Required**; translation key for the label |
| `description_key` | Optional; translation key for description |
| `default` | Seeded value (must match the type); `string_map` default is a TOML table |
| `min` / `max` | For `int` / `double` |
| `options` | For `select`: array of `{ value, label_key }` |
| `extensions` | For `file`: array like `[".toml", ".json"]` |
| `visible_when` | `{ key = "other_key", values = ["true"] }` — conditional visibility |
| `advanced` | Hide behind "show advanced" toggle |

Label/description fields must be translation keys — literal `label`/`description` are rejected.

### Panel Manifest Options

```toml
[[panel]]
id = "my-panel"
entry = "panel.luau"
width = 420              # logical px or "fill"
height = 410             # logical px or "fill"
placement = "floating"   # attached | floating (default)
position = "center"      # auto, center, or screen anchor
open_near_click = false
dismiss_on_outside_click = true   # api ≥ 8; set false for auth prompts
keyboard_focus = "on_demand"      # api ≥ 10; on_demand | exclusive | none
persistent = false                # api ≥ 11; stays open when another panel opens
capture_keys = ["space", "ctrl+r"] # api ≥ 13; raw key chords delivered to onKey
```

Host-injected settings (not declared as `[[panel.setting]]`):
- `placement` → `<entry>_placement`
- `position` → `<entry>_position`
- `open_near_click` → `<entry>_open_near_click`

### Launcher Provider Manifest

```toml
[[launcher_provider]]
id = "finder"
entry = "finder.luau"
prefix = "ex"               # Trigger word (do not include /)
glyph = "list-search"       # Default result icon
include_in_global_search = false
debounce_ms = 0             # Wait after last keystroke before onQuery
```

---

## Entry Scripts — Lifecycle Functions

Each entry kind supports specific global lifecycle functions:

| Function | Widget | Shortcut | Launcher | Desktop | Panel | Service |
|---|---|---|---|---|---|---|
| `update()` | ✓ | ✓ | | ✓ | | ✓ |
| `onClick()` / `onRightClick()` | ✓ | ✓ | | | | |
| `onMiddleClick()` | ✓ | | | | | |
| `onScroll(axis, steps, startsGesture)` | ✓ | | | | | |
| `onQuery(text)` | | | ✓ | | | |
| `onActivate(id)` | | | ✓ | | | |
| `onOpen(context)` / `onClose()` | | | | | ✓ | |
| `onKey(chord, pressed)` | | | | | ✓ | |
| `onFrameTick(deltaMs)` | | | | ✓ | | |
| `onIpc(event, payload)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `onConfigChanged()` | | | | | | ✓ |
| `onExit(signal)` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

The top level of the script runs once at load — set up state and register `noctalia.state.watch` handlers there.

### Scroll Handling

```luau
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" then return end
  -- steps: negative = up/left, positive = down/right
  -- startsGesture: true only on first step of a gesture (use for stepping through lists)
end
```

### Service `onConfigChanged()`

If a service defines `onConfigChanged()`, settings update in-place without restart. If absent, the service runtime restarts on config changes.

---

## Declarative UI (`ui.*`)

Desktop widgets, panels, and bar widgets can describe their UI as a `ui.*` tree — Noctalia diffs each render and updates native controls in place.

### Namespaces

- **`desktopWidget.*`** — `render(tree)`, `setWantsSecondTicks(bool)`, `setNeedsFrameTick(bool)`
- **`panel.*`** — `render(tree)`, `close()`, `setWantsSecondTicks(bool)`
- **`barWidget.render(tree)`** — Replaces imperative `setText`/`setGlyph`; call once then the tree owns the capsule

### Shared `ui.*` Controls

| Constructor | Key Props |
|---|---|
| `ui.column` / `ui.row` | `gap`, `padding`, `paddingH`, `paddingV`, `align` (start/center/end/stretch), `justify`, `fill`, `radius`, `border`, `borderWidth`, `minWidth`, `minHeight`, `onClick`, `onHover` |
| `ui.scroll` | Same layout props as column + `fill`, `radius`, `border`, `borderWidth` |
| `ui.label` | `text`, `fontSize`, `color`, `fontWeight` (thin…heavy), `fontFamily`, `baseline`, `maxWidth`, `maxLines`, `textAlign` |
| `ui.glyph` | `name` (Tabler/Nerd-Font), `size`, `color` |
| `ui.image` | `path` (plugin-relative, `~`, or absolute), `width`, `height`, `radius`, `fit` (contain/cover/stretch), `border`, `onClick`, `onHover` |
| `ui.box` | `fill`, `radius`, `border`, `borderWidth`, `softness`, `width`, `height`, `onClick`, `onHover` |
| `ui.separator` | `thickness`, `color`, `spacing`, `orientation` (auto/horizontal/vertical) |
| `ui.spacer` | Flexible filler (`flexGrow`) |
| `ui.progress` | `progress` (0–1), `fill`, `track`, `radius`, `width`, `height` |
| `ui.button` | `text`, `glyph`, `fontSize`, `glyphSize`, `variant` (default/primary/secondary/destructive/outline/ghost), `contentAlign`, `controlSize` (sm/md/lg), `tooltip`, `enabled`, `selected`, `onClick`, `onRightClick`, `onHover` |
| `ui.graph` | `values`/`values2` (0–1 arrays), `color`/`color2`, `lineWidth`, `fillOpacity`, `width`, `height` |
| `ui.toggle` | `checked` (bool), `enabled`, `onChange` |
| `ui.slider` | `min`, `max`, `step`, `value`, `controlSize`, `enabled`, `onChange`, `onDragEnd` |
| `ui.select` | `options` (string array), `selectedIndex`, `placeholder`, `controlSize`, `enabled`, `width`, `height`, `onChange` |
| `ui.input` | `value` (initial only), `placeholder`, `fontSize`, `controlSize`, `password` (bool), `multiline` (bool), `focus` (bool), `enabled`, `onChange`, `onSubmit` |

Every control also accepts: `width`, `height`, `flexGrow`, `opacity`, `visible`.

**Colors** are palette role tokens (`primary`, `on_surface`, …), tokens with alpha (`primary/0.6`), or hex (`#rrggbb` / `#rrggbbaa`).

**Callbacks** take either a function (api ≥ 9, captures scope) or a global function name string. `onChange` receives the value as a string.

**Bar widget constraints:** Container clips to bar thickness — keep tree one control tall. Branch on `barWidget.isVertical()` (column for side bar, row for horizontal). No keyboard controls (`ui.input`, `ui.select`, `ui.scroll` are skipped). Inline controls consume their own clicks; widget-level `onClick` still fires on the rest of the capsule.

**Desktop widget:** Position is host-owned — user places/sizes/rotates the tile. Call `setWantsSecondTicks(true)` for second-boundary ticks; `setNeedsFrameTick(true)` for per-frame animation via `onFrameTick(deltaMs)`.

### Drag and Drop (Panels only, api ≥ 5)

| Constructor | Props |
|---|---|
| `ui.dragSource` | `dragType` (required string), `payload` (required, opaque), `enabled`, `tooltip`, `previewAncestor` (0–8), `liftFromLayout` (bool) |
| `ui.dropZone` | `accepts` (required array of drag types), `value` (required, opaque), `onDrop` (required callback), `direction` (column/row), `enabled`, `expandOnDrag` (bool), `hitSlop` (number) |

`onDrop(payload, value)` fires on a completed drop. Sortable lists: place thin `expandOnDrag` + `hitSlop` insertion zones before each row and one after the last.

---

## Runtime API (`noctalia.*`)

### Settings & Runtime

| Method | Returns | Description |
|---|---|---|
| `noctalia.setUpdateInterval(ms)` | — | Tick interval; <16ms is clamped |
| `noctalia.log(msg)` | — | Write to Noctalia's log |
| `noctalia.isDarkMode()` | bool | Active theme mode is dark |
| `noctalia.focusedOutputName()` | string\|nil | Focused output's connector name |
| `noctalia.getConfig(key)` | value\|nil | Declared setting; undeclared key warns + returns nil |

### Outputs, Wallpaper & Panels

| Method | Returns | Description |
|---|---|---|
| `noctalia.outputs()` | array | `{ name, description, width, height, x, y, scale, focused }` |
| `noctalia.setWallpaperEnabled(connector, enabled)` | — | Runtime-only; clears on restart |
| `noctalia.setWallpaper(path)` | — | Apply + persist wallpaper on all outputs |
| `noctalia.setWallpaper(connector, path)` | — | Apply + persist on one output |
| `noctalia.wallpaperDirectory()` | string\|nil | Resolved wallpaper folder for current theme |
| `noctalia.togglePanel("author/plugin:panel")` | — | Open or close a panel by full entry id |
| `noctalia.openSettings()` | — | Open settings at this plugin's page (api ≥ 15) |

### Dialogs

| Method | Returns | Description |
|---|---|---|
| `noctalia.openColorPicker(initialColor, onClose)` | bool | `#RRGGBB` initial; callback receives canonical hex or nil (cancelled) |

### App Icons

| Method | Returns | Description |
|---|---|---|
| `noctalia.appIconPath(appId, sizePx?)` | string\|nil | Resolve app id → icon path; same lookup as taskbar |

### Time, Notifications & Clipboard

| Method | Returns | Description |
|---|---|---|
| `noctalia.formatTime(pattern)` | string | Same tokens as Noctalia clock settings |
| `noctalia.formatTime(pattern, unixSeconds)` | string | Format a specific timestamp |
| `noctalia.nowMs()` | number | Wall-clock ms since Unix epoch (api ≥ 12) |
| `noctalia.notify(title, body?)` | — | Informational notification |
| `noctalia.notifyError(title, body?)` | — | Error notification |
| `noctalia.copyToClipboard(text, mime)` | bool | Copy with MIME type (e.g. `"text/plain"`) |
| `noctalia.clipboardText()` | string\|nil | Latest text clipboard content |

### System Stats

| Method | Returns | Description | API |
|---|---|---|---|
| `noctalia.systemStats()` | table\|nil | CPU/ram/swap/gpu/net/load snapshot | ≥ 12 |
| `noctalia.cpuCores()` | array\|nil | Per-core CPU usage % | ≥ 12 |
| `noctalia.diskMounts()` | array | Physical block-device filesystems | ≥ 16 |
| `noctalia.diskStats(path)` | table\|nil | Disk usage for a path | ≥ 16 |

`systemStats()` fields: `sampledAtMs`, `cpu.{usagePercent, tempC}`, `ram.{usagePercent, usedMb, totalMb}`, `swap.{usedMb, totalMb}`, `gpu.{tempC, usagePercent, vramUsedBytes, vramTotalBytes}`, `net.{rxBytesPerSec, txBytesPerSec, interfaces}`, `loadAvg` (1/5/15 min). Absent sensors are `nil`, not 0.

### Subprocesses & Environment

| Method | Returns | Description |
|---|---|---|
| `noctalia.runAsync(cmd)` | bool | Detached shell command, no output captured |
| `noctalia.runAsync(cmd, cb)` | bool | With output capture; `cb({exitCode, stdout, stderr, ...})` |
| `noctalia.runStream(cmd, onLine)` | bool | Long-lived process; `onLine(line)` per stdout line |
| `noctalia.runInTerminal(cmd)` | bool | Start in a terminal window |
| `noctalia.commandExists(name)` | bool | Check if executable on PATH |
| `noctalia.processMatches(cb, ...needles)` | bool | Async check running processes |
| `noctalia.flatpakAppInstalled(id)` | bool | Check Flatpak app |
| `noctalia.portalAvailable()` | bool | Desktop portal available |
| `noctalia.getenv(name)` | string\|nil | Read env var |
| `noctalia.expandPath(path)` | string | Expand `~/Pictures` → absolute |

### Filesystem

| Method | Returns | Description |
|---|---|---|
| `noctalia.readFile(path)` | string \| nil, err | Read file as bytes |
| `noctalia.writeFile(path, content)` | bool, err? | Write/replace file |
| `noctalia.mkdirAll(path)` | bool, err? | Create dir + parents |
| `noctalia.removeFile(path)` | bool, err? | Delete file (refuses directories) |
| `noctalia.renameFile(from, to)` | bool, err? | Rename/move |
| `noctalia.fileExists(path)` | bool | Check existence |
| `noctalia.fileInfo(path)` | table \| nil, err | `{ size, mtime, isDir }` |
| `noctalia.listDir(path)` | array \| nil, err | List filenames |
| `noctalia.pluginDir()` | string\|nil | Plugin's runtime directory |
| `noctalia.pluginDataDir()` | string\|nil, err | Persistent data dir (survives updates); created on demand |
| `noctalia.loadFont(path)` | string\|nil, err | Register font → returns family name |

Paths: `~` expands to `$HOME`, absolute as-is, relative resolves against plugin dir. Plugins are trusted — no sandboxing.

**Persist data with `pluginDataDir()`** — do not persist inside `pluginDir()` (runtime copy lost on update).

### HTTP & Downloads

| Method | Returns | Description |
|---|---|---|
| `noctalia.http(request, cb)` | bool | Async HTTP; `request = { url, method, body, headers, basic_username, basic_password, follow_redirects, allow_insecure_tls }` |
| `noctalia.httpStream(request, onLine, onClose)` | handle\|nil | Streaming HTTP (api ≥ 4); returns `{ stop = fn }` |
| `noctalia.download(url, dest, cb)` | bool | Download to file; `cb(ok)` |

`allow_insecure_tls` requires api ≥ 7.

### Translations & Data Helpers

| Method | Returns | Description |
|---|---|---|
| `noctalia.tr(key)` | string | Lookup from `translations/<lang>.json` |
| `noctalia.tr(key, subst)` | string | With `{name}` placeholder replacement |
| `noctalia.trp(key, count)` | string | Plural: prefers `<key>.one`/`.other` |
| `noctalia.trp(key, count, subst)` | string | Plural + substitutions; `{count}` available |
| `noctalia.json.decode(str)` | value \| nil, err | Parse JSON → Luau |
| `noctalia.json.encode(value)` | string \| nil, err | Compact JSON |
| `noctalia.json.encode(value, true)` | string \| nil, err | Pretty JSON |
| `noctalia.string.trim(str)` | string | Trim whitespace |
| `noctalia.string.urlEncode(str)` | string | Percent-encode |
| `noctalia.string.urlDecode(str)` | string | Decode percent-encoded |
| `noctalia.fuzzyScore(pattern, text)` | number\|nil | Native fuzzy match; nil = no match |

### Plugin State (Inter-Entry)

| Method | Returns | Description |
|---|---|---|
| `noctalia.state.set(key, value)` | — | Publish plain value (copied across VMs) |
| `noctalia.state.get(key)` | value\|nil | Read latest value |
| `noctalia.state.watch(key, fn)` | — | `fn(value)` on every change |

Values are copied — must be plain data (strings, numbers, booleans, tables of those). In-memory only; cleared on stop.

### `barWidget.*` — Imperative API

`setText` · `setGlyph` · `setImage` · `setTooltip` · `clearTooltip` · `setFont(family, baseline?)` · `setColor` · `setGlyphColor` · `setVisible` · `isVertical()` · `outputName()` · `render(tree)`

Baseline modes: `"text"` (default), `"textFixedHeight"`, `"inkCentered"`, `"pictographic"`.

### `shortcut.*` — Control-Center Tile

`setLabel(text)` · `setIcon(on [, off])` · `setActive(bool)` · `setEnabled(bool)`

### `launcher.*` — Launcher Provider

`setResults(query, results)` — echo query from `onQuery`; empty list clears.
`setQuery(query)` — replace launcher input (drill-in); include prefix to stay routed.

Results table: `{ id, title, subtitle?, glyph?, icon?, badge?, query?, score? }`. Ordered by score (descending), then insertion order.

---

## Plugin API Versions

| API | Noctalia | Introduced |
|---|---|---|
| 3 | v5.0.0-beta.3 | Mandatory `plugin_api` declaration |
| 4 | v5.0.0-beta.4 | `noctalia.httpStream()` |
| 5 | v5.0.0-beta.4 | `ui.dragSource()` / `ui.dropZone()` |
| 6 | v5.0.0-beta.4 | `string_map` setting type |
| 7 | v5.0.0-beta.4 | `allow_insecure_tls` HTTP option |
| 8 | v5.0.0-beta.4 | `dismiss_on_outside_click` panel option |
| 9 | v5.0.0-beta.5 | Luau closures in UI callback props |
| 10 | v5.0.0-beta.5 | `keyboard_focus` panel option |
| 11 | v5.0.0-beta.5 | `persistent` panel option |
| 12 | v5.0.0-beta.5 | `systemStats()`, `cpuCores()`, `nowMs()` |
| 13 | v5.0.0-beta.5 | `capture_keys` + `onKey` callback |
| 14 | v5.0.0-beta.5 | `[widget.actions]` gesture defaults |
| 15 | Unreleased | `noctalia.openSettings()` |
| 16 | Unreleased | Per-interface net rates, sample timestamps, disk mount/stat APIs |

Pick the **oldest** level that covers everything your plugin needs.

---

## Local Development

Drop your plugin under `$XDG_DATA_HOME/noctalia/plugins/<plugin>/` (or add a path source pointing at your dev directory), then enable it once.

- **`.luau` edits hot-reload automatically.**
- **Manifest changes** are picked up on next config reload.

### IPC Testing

```sh
# Bar widget — target focused output, a connector, a bar name, or all:
noctalia msg plugin me/hello:hello focused greet "hi there"

# Service — singleton, address with `all`:
noctalia msg plugin me/hello:ticker all refresh

# Panel — toggle by full entry id:
noctalia msg panel-toggle me/hello:panel
```

Targets: `focused`, `<connector>` or `<connector>:<bar-name>`, or `all`.

---

## Publishing

Distribute from a **source repo** — one repo holds many plugins, each in a subdirectory matching the id part after `/` (so `me/hello` → `hello/`).

Add a `catalog.toml` at the repo root:

```toml
[[plugin]]
id = "me/hello"
name = "Hello"
version = "1.0.0"
author = "me"
license = "MIT"
icon = "puzzle"
description = "A friendly greeter."
deprecated = false
plugin_api = 3
tags = ["demo"]
dependencies = ["slurp"]
```

Catalog rows require `id`, `name`, and a positive integer `plugin_api`.

### Backward-Compatible Releases

When you raise `plugin_api`, add `[[plugin.release]]` rows for older Noctalia versions:

```toml
[[plugin.release]]
plugin_api = 3
version = "1.4.0"
rev = "5082ed5f85e795513b8485e4cedc66d5a2c816ff"
```

Users on older Noctalia get the newest compatible revision. Use the `update-catalog.py` script (from official/community repos) to auto-generate these from git history.

### Getting Into the Store

Open a PR against [community-plugins](https://github.com/noctalia-dev/community-plugins). Requirements: `plugin.toml`, entry scripts, `README.md`, `thumbnail.webp`, `translations/en.json`. CI validates and regenerates the catalog on merge.

`official-plugins` is core-team only and does not accept third-party plugins.

---

## Plugin ID Convention

- Official: `noctalia/<name>`
- Community: `<author>/<name>`
- Personal: `<your-namespace>/<name>`

## Key References

| Resource | Path |
|---|---|
| Type definitions | `official-plugins/noctalia.d.luau` |
| Full reference plugin | `official-plugins/example/` (widget + service + shortcut + launcher + panel + DnD) |
| Real-world widget+panel+service | `official-plugins/timer/` |
| Declarative bar widget | `official-plugins/example/declarative.luau` |
| Panel with interactive controls | `official-plugins/example/panel.luau` |
| Drag and drop | `official-plugins/example/dnd.luau` |
| Community examples | `community-plugins/` |
| Online docs | https://docs.noctalia.dev/v5/plugins/development/ |

## Luau Config

All plugins use `--!nonstrict` mode. The `.luaurc` in `myplugins/` sets:
- `languageMode: "nonstrict"`
- `FunctionUnused` lint disabled (unused handlers like `update()` are normal)
