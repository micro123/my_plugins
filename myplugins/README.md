# My Plugins

Personal plugin development directory for Noctalia v5.

Each subdirectory is a standalone plugin. See sibling directories for reference implementations:

- `../official-plugins/example/` — Full reference plugin (all entry types)
- `../official-plugins/timer/` — Real-world widget + panel + service
- `../community-plugins/` — Community-contributed plugins

## Creating a New Plugin

```sh
mkdir myplugins/<name>
cp -r official-plugins/example/translations myplugins/<name>/
# Create plugin.toml, *.luau entries, README.md, thumbnail.webp
```
