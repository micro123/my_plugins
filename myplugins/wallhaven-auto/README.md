# Wallhaven Auto-Rotate

Automatically rotates your desktop wallpaper using the [Wallhaven](https://wallhaven.cc) API. Each rotation picks a random tag from your configured list, searches Wallhaven with random sorting, downloads the first result, and applies it to all displays.

## Features

- **Automatic rotation** — configurable interval (min 15 minutes)
- **Restart persistence** — restores the last wallpaper after Noctalia restarts, even when automatic rotation is disabled
- **Bounded storage** — keeps a single cached image named `wallpaper.<ext>` instead of accumulating files
- **Manual trigger** — click the bar widget for an instant wallpaper change
- **Tag-based search** — maintain a list of tags; one is randomly chosen each rotation
- **Content filters** — toggle categories (General/Anime/People) and purity (SFW/Sketchy/NSFW) via switch settings
- **Resolution & ratio filters** — set minimum resolution and aspect ratio
- **Optional API key** — for higher rate limits and NSFW access

## Entries

| Entry | Type | Description |
|---|---|---|
| `tang/wallhaven-auto:service` | Service | Background rotation engine |
| `tang/wallhaven-auto:wallhaven-auto` | Widget | Bar widget with countdown; click to rotate |
| `tang/wallhaven-auto:toggle` | Shortcut | Control-center tile to toggle auto-rotation |

## Requirements

- `ln` — creates a lightweight, unique temporary wallpaper source link so Noctalia reloads the fixed-name cache file

## Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `api_key` | string | `""` | Optional Wallhaven API key |
| `interval_minutes` | int | `30` | Rotation interval (15–1440) |
| `tags` | string list | `nature, landscape, city, abstract, space` | Search tags |
| `category_general` | bool | `true` | Include General category |
| `category_anime` | bool | `true` | Include Anime category |
| `category_people` | bool | `true` | Include People category |
| `purity_sfw` | bool | `true` | Include SFW content |
| `purity_sketchy` | bool | `false` | Include Sketchy content |
| `purity_nsfw` | bool | `false` | Include NSFW content (requires API key) |
| `resolution_min_width` | int | `1920` | Minimum width in pixels |
| `resolution_min_height` | int | `1080` | Minimum height in pixels |
| `ratio` | select | `Any` | Aspect ratio filter |
| `show_countdown` | bool | `true` | Show countdown in bar widget |

## How It Works

1. The service ticks every second, checking if the interval has elapsed.
2. On rotation, it shuffles your tag list and tries up to 3 random tags.
3. It searches Wallhaven with `sorting=random`, your filters, and the selected tag.
4. The first result is downloaded to the plugin data directory and atomically promoted to `wallpaper.<ext>` before being applied via `noctalia.setWallpaper()`.
5. If all tags return empty, it falls back to an unfiltered search.
6. Errors are notified once per day to avoid spam.
7. The current wallpaper metadata (including its Wallhaven ID) is persisted and the wallpaper is re-applied when the service starts.
8. Stale and interrupted-download files are removed so the wallpaper cache contains only the current image at rest.
9. A lightweight unique symlink is created under `$XDG_RUNTIME_DIR` (or `/tmp` as a fallback) when applying the fixed cache path, forcing Noctalia to reload replaced image data without duplicating the image.

## NSFW Access

Wallhaven requires an API key to access NSFW content via the API. Set your key in the `api_key` setting to unlock `purity_nsfw`. Sketchy content does **not** require an API key.

## IPC

```sh
# Trigger an immediate rotation
noctalia msg plugin tang/wallhaven-auto:service all rotate

# Toggle auto-rotation
noctalia msg plugin tang/wallhaven-auto:service all toggle
```
