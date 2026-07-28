#!/usr/bin/env python3
"""Composite a circular progress ring onto a cover image for the bar widget.

Usage: python3 cover_ring.py <cover_path> <progress> <fg_color> <bg_color> <output_path>
  progress:  float 0.0–1.0
  fg_color:  '#RRGGBB' or '#RRGGBBAA' — played / progress arc
  bg_color:  '#RRGGBB' or '#RRGGBBAA' — unplayed track ring
  output:    path to write the composited PNG

Output (stdout): {"ok": true} on success, {"ok": false, "error": "..."} on failure.
"""

import sys
import json
import math


def parse_hex_color(hex_str):
    """Parse '#RRGGBB' or '#RRGGBBAA' into (R, G, B, A) 0-255."""
    value = (hex_str or "").strip().lstrip("#")
    if len(value) == 6:
        return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), 255)
    if len(value) == 8:
        return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), int(value[6:8], 16))
    return (255, 255, 255, 255)


def draw_progress_ring(cover_path, progress, fg_color_hex, bg_color_hex, output_path):
    """Open cover, composite ring, save to output_path. Returns (ok, error)."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return False, "pillow_missing"

    CANVAS = 100
    CENTER = (50, 50)
    COVER_RADIUS = 28        # cover circle radius (28@100→6.7@24)
    RING_INNER = 32          # 4px gap @100 → ~1px @24 display
    RING_OUTER = 44          # 12px thick @100 → ~3px @24 display
    RING_WIDTH = RING_OUTER - RING_INNER

    progress = max(0.0, min(1.0, progress))

    try:
        cover = Image.open(cover_path).convert("RGBA")
    except Exception as exc:
        return False, "cannot open cover: " + str(exc)

    # Scale cover to fill the inner circle, center-cropped to square
    cover_size = COVER_RADIUS * 2  # 56x56
    cover = cover.resize((cover_size, cover_size), Image.LANCZOS)

    # Create a circular mask for the cover
    mask = Image.new("L", (cover_size, cover_size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, cover_size - 1, cover_size - 1), fill=255)

    # Create the output canvas (transparent)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    # Paste the cover centered with circular mask
    cover_x = CENTER[0] - COVER_RADIUS
    cover_y = CENTER[1] - COVER_RADIUS
    canvas.paste(cover, (cover_x, cover_y), mask)

    # Parse ring colors
    fr, fg, fb, fa = parse_hex_color(fg_color_hex)
    br, bg, bb, ba = parse_hex_color(bg_color_hex)

    draw = ImageDraw.Draw(canvas)

    # Background ring track: full circle, unplayed portion
    if ba > 0:
        bg_track = (br, bg, bb, ba)
        bbox = (
            CENTER[0] - RING_OUTER, CENTER[1] - RING_OUTER,
            CENTER[0] + RING_OUTER - 1, CENTER[1] + RING_OUTER - 1,
        )
        draw.arc(bbox, 0, 360, fill=bg_track, width=RING_WIDTH)

    # Foreground progress arc: clockwise from 12 o'clock
    if progress > 0.001:
        fg_track = (fr, fg, fb, fa)
        # Pillow arc: 0° = 3 o'clock, clockwise.
        # We want 0 progress at 12 o'clock (-90°), clockwise.
        start_angle = -90
        sweep = 360.0 * progress
        end_angle = start_angle + sweep
        if sweep >= 359.5:
            # Draw full circle for 100%
            end_angle = start_angle + 359.9
        bbox = (
            CENTER[0] - RING_OUTER, CENTER[1] - RING_OUTER,
            CENTER[0] + RING_OUTER - 1, CENTER[1] + RING_OUTER - 1,
        )
        draw.arc(bbox, start_angle, end_angle, fill=fg_track, width=RING_WIDTH)

    try:
        canvas.save(output_path, "PNG")
    except Exception as exc:
        return False, "cannot save output: " + str(exc)

    return True, None


def main():
    if len(sys.argv) != 6:
        print(json.dumps({"ok": False, "error": "usage: cover_ring.py <cover> <progress> <fg_color> <bg_color> <output>"}))
        return

    cover = sys.argv[1]
    try:
        progress = float(sys.argv[2])
    except (ValueError, TypeError):
        print(json.dumps({"ok": False, "error": "invalid progress value"}))
        return
    fg_color = sys.argv[3]
    bg_color = sys.argv[4]
    output = sys.argv[5]

    ok, error = draw_progress_ring(cover, progress, fg_color, bg_color, output)
    print(json.dumps({"ok": ok, "error": error}, ensure_ascii=False))


if __name__ == "__main__":
    main()
