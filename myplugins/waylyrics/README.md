# Waylyrics

Desktop floating lyrics with karaoke highlighting for Noctalia v5.
MPRIS-powered, Waylyrics-style experience — shows synchronized lyrics
as a floating desktop tile with smooth per-character animation.

Forked and extended from the community [Lyrics](https://github.com/noctalia-dev/community-plugins) plugin by h465855hgg.

## Features

- **Desktop widget** — Floating lyrics overlay with per-frame karaoke highlighting
- **Bar widget** — Compact bar companion with click-to-toggle track info
- **10+ lyric sources** — LRCLIB, NetEase, QQ Music, Spotify, Apple Music, Kugou, and more
- **Character-level karaoke** — Smooth color gradient across each character as the song plays
- **Bilingual display** — Original lyrics + translation/romanization
- **MPRIS auto-detection** — Works with any player that implements MPRIS (Spotify, Feishin, mpv, Firefox, etc.)
- **Lyrics candidate picker** — Choose from multiple LRCLIB matches via panel
- **IPC support** — External tools can push lyrics via `push-lrc`, `push-json`, and `push-state` events
- **Cover art caching** — Album art downloaded and cached locally

## Requirements

- `playerctl` — MPRIS metadata polling
- `python3` — Lyric source adapters
- `cp`, `chmod` — Standard Unix tools

```sh
# Arch
sudo pacman -S playerctl python3

# Ubuntu/Debian
sudo apt install playerctl python3

# Fedora
sudo dnf install playerctl python3
```

## Entries

| Entry | Type | ID | Description |
|---|---|---|---|
| Desktop Widget | `desktop_widget` | `desktop` | Floating lyrics overlay — the main feature |
| Bar Widget | `widget` | `lyrics` | Compact bar capsule with now-playing |
| Service | `service` | `service` | Background MPRIS poller + lyrics fetcher (required) |
| Panel | `panel` | `selector` | LRCLIB candidate picker |
| Shortcut | `shortcut` | `open_selector` | Keyboard shortcut to open the selector |

## Setup

1. Copy `myplugins/waylyrics/` to your Noctalia plugins directory
2. Enable the plugin in Noctalia Settings → Plugins
3. Add the **desktop widget** from the tile picker (right-click desktop → Add Widget)
4. Position and size the tile on your desktop
5. Optionally, add the **bar widget** from the Add-widget picker
6. Play music in any MPRIS-compatible player — lyrics appear automatically

## Settings

### Desktop Widget
| Setting | Default | Description |
|---|---|---|
| Font size | 36 | Primary lyrics text size |
| Translation font size | 18 | Translation/subtitle text size |
| Active text color | primary | Color for sung characters |
| Inactive text color | on_surface_variant | Color for unsung text |
| Translation color | on_surface_variant | Color for translation text |
| Show next line | on | Dim preview of the upcoming line |
| Visible lines | 5 | Context lines around the active line |

### Plugin-level (shared)
| Setting | Default | Description |
|---|---|---|
| Lyrics source | Auto | Which service to fetch from |
| Translation language | zh-Hans | Language for translated lyrics |
| Show translation | on | Toggle translation display |
| Karaoke highlighting | on | Character-level color animation |
| Lyrics offset (ms) | 0 | Manual sync adjustment |
| Poll interval (ms) | 500 | MPRIS polling frequency |

## IPC

External tools can push lyrics to the service:

```sh
# Push raw LRC text
noctalia msg plugin tang/waylyrics:service all push-lrc "[00:15.00]Hello world"

# Push full state JSON
noctalia msg plugin tang/waylyrics:service all push-json '{"lyrics":"[00:15.00]Hello","playing":true,"position":15000000}'

# Clear lyrics
noctalia msg plugin tang/waylyrics:service all clear
```

## Credits

- Original community plugin: [h465855hgg/lyrics](https://github.com/noctalia-dev/community-plugins)
- Inspired by [Waylyrics](https://github.com/waylyrics/waylyrics) — the furry way to show desktop lyrics
- Lyric sources: LRCLIB, NetEase Cloud Music, QQ Music, Kugou, Qishui, SPlayer, Apple Music, Spotify, Musixmatch

## License

MIT
