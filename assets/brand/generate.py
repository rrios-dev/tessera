#!/usr/bin/env python3
"""Generates Tessera's brand assets from one definition.

The mark: three tiles whose gaps draw a T (proposal A, 2026-09-30). The wordmark: "tessera" in
Geist Medium (SIL OFL 1.1, © Vercel), lowercase, tracking -0.045 em, converted to outlines so no
asset depends on the font being installed.

usage: generate.py <path to Geist-Medium.ttf>
Writes the SVGs next to this file; `make-icons.sh` rasterises them into AppIcon.icns and PNGs.
"""
import os, sys
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
INK, PAPER = "#0a0a0a", "#ffffff"

# The mark on a 100-unit grid: it spans 22…78 (56 units), gaps of 6, corner radius 2.
TILES = [(22, 22, 56, 17), (22, 45, 25, 33), (53, 45, 25, 33)]
RADIUS = 2


def tiles(color, scale=1.0, dx=0.0, dy=0.0):
    return "".join(
        f'<rect x="{dx + x * scale:.2f}" y="{dy + y * scale:.2f}" width="{w * scale:.2f}" height="{h * scale:.2f}" '
        f'rx="{RADIUS * scale:.2f}" fill="{color}"/>'
        for x, y, w, h in TILES
    )


def svg(width, height, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}" height="{height:g}" viewBox="0 0 {width:g} {height:g}" '
            f'role="img"><title>{title}</title>{body}</svg>\n')


def write(name, content):
    with open(os.path.join(HERE, name), "w") as handle:
        handle.write(content)
    print("wrote", name)


def wordmark_path(font_path, size):
    """'tessera' outlined at `size` px, baseline at y = 0. Returns (path d, width, ascent)."""
    font = TTFont(font_path)
    glyph_set, cmap = font.getGlyphSet(), font.getBestCmap()
    upm = font["head"].unitsPerEm
    scale = size / upm
    tracking = -0.045 * upm
    pen = SVGPathPen(glyph_set, ntos=lambda n: f"{n:.2f}".rstrip("0").rstrip("."))
    x = 0.0
    names = [cmap[ord(c)] for c in "tessera"]
    for index, name in enumerate(names):
        # Flip y: font units grow upwards, SVG grows downwards.
        glyph_set[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x * scale, 0)))
        x += glyph_set[name].width + (tracking if index < len(names) - 1 else 0)
    ascent = font["hhea"].ascent * scale
    descent = -font["hhea"].descent * scale
    cap = getattr(font["OS/2"], "sCapHeight", 0) * scale
    return pen.getCommands(), x * scale, ascent, descent, cap


def main():
    font_path = sys.argv[1]

    # Mark alone, on a transparent square with the grid's own margin removed.
    for name, color in (("mark.svg", INK), ("mark-white.svg", PAPER)):
        write(name, svg(56, 56, tiles(color, 1, -22, -22), "Tessera"))

    # App icon on Apple's macOS grid: 1024 canvas, 824 body at 100, continuous corner ~185.
    body = 824
    # A hairline edge keeps a black icon from dissolving into a dark Dock or window.
    edge = f'<rect x="104" y="104" width="{body - 8}" height="{body - 8}" rx="181" fill="none" stroke="#ffffff" stroke-opacity="0.14" stroke-width="8"/>'
    icon = f'<rect x="100" y="100" width="{body}" height="{body}" rx="185" fill="{INK}"/>' + edge + tiles(PAPER, body / 100, 100, 100)
    write("app-icon.svg", svg(1024, 1024, icon, "Tessera"))
    icon_light = f'<rect x="100" y="100" width="{body}" height="{body}" rx="185" fill="{PAPER}"/>' + tiles(INK, body / 100, 100, 100)
    write("app-icon-light.svg", svg(1024, 1024, icon_light, "Tessera"))

    # Wordmark, and the lockup: mark 1.133 × the type size, centred on the text's line box,
    # a gap of 0.4 × the type size (the proportions approved in the proposal).
    size = 100
    d, width, ascent, descent, cap = wordmark_path(font_path, size)
    height = ascent + descent
    for name, color in (("wordmark.svg", INK), ("wordmark-white.svg", PAPER)):
        write(name, svg(width, height, f'<path d="{d}" fill="{color}" transform="translate(0 {ascent:.2f})"/>', "tessera"))

    mark = 1.133 * size
    gap = 0.4 * size
    total_h = max(height, mark)
    line_mid = total_h / 2
    baseline = line_mid + (ascent - descent) / 2
    mark_top = line_mid - mark / 2
    lock_w = mark + gap + width
    for name, fg in (("lockup.svg", INK), ("lockup-white.svg", PAPER)):
        body = tiles(fg, mark / 56, -22 * mark / 56, mark_top - 22 * mark / 56)
        body += f'<path d="{d}" fill="{fg}" transform="translate({mark + gap:.2f} {baseline:.2f})"/>'
        write(name, svg(lock_w, total_h, body, "tessera"))
    # Lockups on their own backgrounds, with clear space of one mark height around them.
    pad = mark
    for name, bg, fg in (("lockup-on-dark.svg", INK, PAPER), ("lockup-on-light.svg", PAPER, INK)):
        body = f'<rect width="{lock_w + 2 * pad:.2f}" height="{total_h + 2 * pad:.2f}" fill="{bg}"/>'
        body += tiles(fg, mark / 56, pad - 22 * mark / 56, pad + mark_top - 22 * mark / 56)
        body += f'<path d="{d}" fill="{fg}" transform="translate({pad + mark + gap:.2f} {pad + baseline:.2f})"/>'
        write(name, svg(lock_w + 2 * pad, total_h + 2 * pad, body, "tessera"))


if __name__ == "__main__":
    main()
