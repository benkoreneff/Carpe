#!/usr/bin/env python3
"""Draws Carpe's app icon and menu bar glyph.

    python3 scripts/make-icons.py        (needs Pillow: pip install pillow)

Writes:
    Carpe/Assets.xcassets/AppIcon.appiconset   the ten PNG sizes macOS asks for
    Carpe/Assets.xcassets/MenuBarIcon.imageset a template SVG for the menu bar
    design/carpe-icon.svg                      vector master of the app icon

The mark is a sun rising behind a horizon: a disc cut off by an arc. (A whole
dot above the arc read as a head on shoulders.) The app icon puts it on
a white rounded square in the standard macOS proportions (an 824 px body on a
1024 px canvas, with the usual soft shadow). The smallest sizes use a slightly
heavier drawing so the arc survives at 16 px.
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Carpe" / "Assets.xcassets"
DESIGN = ROOT / "design"

INK = (11, 11, 13)          # horizon
SUN = (255, 138, 31)        # #FF8A1F
TOP = (255, 255, 255)       # body gradient, top
BOTTOM = (238, 240, 243)    # body gradient, bottom

CANVAS, BODY, MARGIN, RADIUS = 1024, 824, 100, 185.4

# The mark, in units where the icon body is 100 x 100. The sun sits behind the
# horizon: whatever part of its disc comes within `gap` of the line is cut away.
ARC_RADIUS, ARC_HALF_CHORD = 58.0, 29.0
WEIGHTS = {
    "regular": dict(sun_y=48.0, sun_r=13.3, arc_y=62.8, stroke=5.2, gap=4.1),
    "medium": dict(sun_y=48.0, sun_r=13.5, arc_y=62.8, stroke=5.8, gap=4.4),
    "bold": dict(sun_y=47.6, sun_r=13.8, arc_y=63.2, stroke=6.8, gap=5.2),
}

# The menu bar glyph, in a 24-unit box. Same drawing as the regular weight.
GLYPH = dict(cx=12, sun_y=12.4, sun_r=4.6, arc_y=17.5, arc_r=20, half_chord=10, stroke=1.8, gap=1.4)

# (file name, pixels, weight) for the mac app icon set.
SIZES = [
    ("icon_16x16.png", 16, "bold"),
    ("icon_16x16@2x.png", 32, "bold"),
    ("icon_32x32.png", 32, "bold"),
    ("icon_32x32@2x.png", 64, "medium"),
    ("icon_128x128.png", 128, "regular"),
    ("icon_128x128@2x.png", 256, "regular"),
    ("icon_256x256.png", 256, "regular"),
    ("icon_256x256@2x.png", 512, "regular"),
    ("icon_512x512.png", 512, "regular"),
    ("icon_512x512@2x.png", 1024, "regular"),
]


# --- Geometry ---------------------------------------------------------------

def squircle_segments(x0, y0, x1, y1, r):
    """The continuous-corner rounded rectangle Apple uses for icons, as a list
    of ("L", point) and ("C", c1, c2, point) segments after a starting point."""
    a, b, c, d, e, f, g = 1.528665, 1.08849296, 0.86840694, 0.63149379, 0.07491139, 0.37282383, 0.16905956

    def tr(u, v): return (x1 - u * r, y0 + v * r)
    def br(u, v): return (x1 - u * r, y1 - v * r)
    def bl(u, v): return (x0 + u * r, y1 - v * r)
    def tl(u, v): return (x0 + u * r, y0 + v * r)

    start = tl(a, 0)
    segments = [
        ("L", tr(a, 0)),
        ("C", tr(b, 0), tr(c, 0), tr(d, e)),
        ("C", tr(f, g), tr(g, f), tr(e, d)),
        ("C", tr(0, c), tr(0, b), tr(0, a)),
        ("L", br(0, a)),
        ("C", br(0, b), br(0, c), br(e, d)),
        ("C", br(g, f), br(f, g), br(d, e)),
        ("C", br(c, 0), br(b, 0), br(a, 0)),
        ("L", bl(a, 0)),
        ("C", bl(b, 0), bl(c, 0), bl(d, e)),
        ("C", bl(f, g), bl(g, f), bl(e, d)),
        ("C", bl(0, c), bl(0, b), bl(0, a)),
        ("L", tl(0, a)),
        ("C", tl(0, b), tl(0, c), tl(e, d)),
        ("C", tl(g, f), tl(f, g), tl(d, e)),
        ("C", tl(c, 0), tl(b, 0), tl(a, 0)),
    ]
    return start, segments


def flatten(start, segments, steps=48):
    points, here = [start], start
    for segment in segments:
        if segment[0] == "L":
            points.append(segment[1])
        else:
            _, c1, c2, end = segment
            for i in range(1, steps + 1):
                t = i / steps
                m = 1 - t
                points.append((
                    m**3 * here[0] + 3 * m * m * t * c1[0] + 3 * m * t * t * c2[0] + t**3 * end[0],
                    m**3 * here[1] + 3 * m * m * t * c1[1] + 3 * m * t * t * c2[1] + t**3 * end[1],
                ))
        here = segment[-1]
    return points


def arc_frame(cx, end_y, radius, half_chord):
    """Centre and end angles of an arc that bulges upward between two points
    half_chord either side of cx, both at end_y."""
    drop = math.sqrt(radius**2 - half_chord**2)
    cy = end_y + drop
    return cy, math.atan2(-drop, -half_chord), math.atan2(-drop, half_chord)


def arc_outline(cx, end_y, radius, half_chord, half_width, steps=96):
    """The stroked arc with round caps, as a polygon."""
    cy, left, right = arc_frame(cx, end_y, radius, half_chord)

    def sweep(ox, oy, r, start, end):
        return [(ox + r * math.cos(start + (end - start) * i / steps),
                 oy + r * math.sin(start + (end - start) * i / steps)) for i in range(steps + 1)]

    rx, ry = cx + radius * math.cos(right), cy + radius * math.sin(right)
    lx, ly = cx + radius * math.cos(left), cy + radius * math.sin(left)
    return (sweep(cx, cy, radius + half_width, left, right)
            + sweep(rx, ry, half_width, right, right + math.pi)
            + sweep(cx, cy, radius - half_width, right, left)
            + sweep(lx, ly, half_width, left + math.pi, left + 2 * math.pi))


def arc_path(cx, end_y, radius, half_chord, half_width):
    """The same outline as an SVG path, using true arcs."""
    cy, left, right = arc_frame(cx, end_y, radius, half_chord)

    def at(r, angle): return f"{cx + r * math.cos(angle):.3f} {cy + r * math.sin(angle):.3f}"

    outer, inner, h = radius + half_width, radius - half_width, half_width
    return (f"M{at(outer, left)} A{outer:.3f} {outer:.3f} 0 0 1 {at(outer, right)} "
            f"A{h:.3f} {h:.3f} 0 0 1 {at(inner, right)} "
            f"A{inner:.3f} {inner:.3f} 0 0 0 {at(inner, left)} "
            f"A{h:.3f} {h:.3f} 0 0 1 {at(outer, left)} Z")


def sun_frame(cx, sun_y, sun_r, arc_end_y, arc_radius, half_chord, clearance):
    """Where the sun's disc meets the circle that keeps it `clearance` away
    from the middle of the horizon line. Returns the horizon circle's centre y,
    the radius of that cut, and the offsets (down, sideways) of the two meeting
    points from the sun's centre."""
    arc_cy, _, _ = arc_frame(cx, arc_end_y, arc_radius, half_chord)
    cut = arc_radius + clearance
    d = arc_cy - sun_y
    down = (d * d + sun_r**2 - cut**2) / (2 * d)
    return arc_cy, cut, down, math.sqrt(sun_r**2 - down * down)


def sun_outline(cx, sun_y, sun_r, arc_end_y, arc_radius, half_chord, clearance, steps=128):
    """The visible part of the sun, as a polygon: over the top of the disc,
    then back along the cut."""
    arc_cy, cut, down, side = sun_frame(cx, sun_y, sun_r, arc_end_y, arc_radius, half_chord, clearance)
    start = math.atan2(down, -side) % (2 * math.pi)
    end = math.atan2(down, side) % (2 * math.pi)
    if end < start:
        end += 2 * math.pi
    right = math.atan2(sun_y + down - arc_cy, side)
    left = math.atan2(sun_y + down - arc_cy, -side)
    top = [(cx + sun_r * math.cos(start + (end - start) * i / steps),
            sun_y + sun_r * math.sin(start + (end - start) * i / steps)) for i in range(steps + 1)]
    bottom = [(cx + cut * math.cos(right + (left - right) * i / steps),
               arc_cy + cut * math.sin(right + (left - right) * i / steps)) for i in range(steps + 1)]
    return top + bottom


def sun_path(cx, sun_y, sun_r, arc_end_y, arc_radius, half_chord, clearance):
    """The same shape as an SVG path."""
    _, cut, down, side = sun_frame(cx, sun_y, sun_r, arc_end_y, arc_radius, half_chord, clearance)
    y = sun_y + down
    return (f"M{cx - side:.3f} {y:.3f} A{sun_r:.3f} {sun_r:.3f} 0 {1 if down > 0 else 0} 1 {cx + side:.3f} {y:.3f} "
            f"A{cut:.3f} {cut:.3f} 0 0 0 {cx - side:.3f} {y:.3f} Z")


# --- App icon ---------------------------------------------------------------

def render(weight, supersample=4):
    """One 1024-point icon drawn at supersample times the size."""
    w = WEIGHTS[weight]
    s = supersample
    n = CANVAS * s
    unit = BODY / 100 * s           # one mark unit in pixels
    origin = MARGIN * s

    start, segments = squircle_segments(MARGIN, MARGIN, MARGIN + BODY, MARGIN + BODY, RADIUS)
    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).polygon([(x * s, y * s) for x, y in flatten(start, segments)], fill=255)

    shadow = Image.new("L", (n, n), 0)
    shadow.paste(mask, (0, 10 * s))
    shadow = shadow.filter(ImageFilter.GaussianBlur(5 * s)).point(lambda v: int(v * 0.3))
    icon = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    icon.putalpha(shadow)

    ramp = Image.linear_gradient("L").resize((n, BODY * s))
    body = Image.new("RGB", (n, n), TOP)
    body.paste(Image.composite(Image.new("RGB", ramp.size, BOTTOM), Image.new("RGB", ramp.size, TOP), ramp), (0, origin))

    draw = ImageDraw.Draw(body)
    cx = origin + 50 * unit
    draw.polygon(sun_outline(cx, origin + w["sun_y"] * unit, w["sun_r"] * unit, origin + w["arc_y"] * unit,
                             ARC_RADIUS * unit, ARC_HALF_CHORD * unit, (w["stroke"] / 2 + w["gap"]) * unit), fill=SUN)
    draw.polygon(arc_outline(cx, origin + w["arc_y"] * unit, ARC_RADIUS * unit,
                             ARC_HALF_CHORD * unit, w["stroke"] / 2 * unit), fill=INK)

    icon.paste(body, (0, 0), mask)
    return icon


def write_app_icon():
    out = ASSETS / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    masters = {}
    images = []
    for name, pixels, weight in SIZES:
        if weight not in masters:
            masters[weight] = render(weight).convert("RGBa")   # premultiplied, so edges stay clean
        masters[weight].resize((pixels, pixels), Image.LANCZOS).convert("RGBA").save(out / name, optimize=True)
        points = name.split("_")[1].split(".")[0].split("@")[0]
        images.append({"filename": name, "idiom": "mac", "scale": "2x" if "@2x" in name else "1x", "size": points})
    write_json(out / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})


# --- Menu bar glyph ---------------------------------------------------------

def write_menu_bar_icon():
    out = ASSETS / "MenuBarIcon.imageset"
    out.mkdir(parents=True, exist_ok=True)
    # A 24-unit drawing shown at 18 points. Black on transparent: macOS tints it.
    g = GLYPH
    sun = sun_path(g["cx"], g["sun_y"], g["sun_r"], g["arc_y"], g["arc_r"], g["half_chord"], g["stroke"] / 2 + g["gap"])
    path = arc_path(g["cx"], g["arc_y"], g["arc_r"], g["half_chord"], g["stroke"] / 2)
    (out / "menubar.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24">\n'
        f'  <path d="{sun}" fill="#000000"/>\n'
        f'  <path d="{path}" fill="#000000"/>\n'
        '</svg>\n')
    write_json(out / "Contents.json", {
        "images": [{"filename": "menubar.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    })


# --- Vector master ----------------------------------------------------------

def write_master_svg():
    DESIGN.mkdir(exist_ok=True)
    w = WEIGHTS["regular"]
    unit = BODY / 100
    start, segments = squircle_segments(MARGIN, MARGIN, MARGIN + BODY, MARGIN + BODY, RADIUS)

    def p(point): return f"{point[0]:.2f} {point[1]:.2f}"

    body = f"M{p(start)} " + " ".join(
        f"L{p(seg[1])}" if seg[0] == "L" else f"C{p(seg[1])} {p(seg[2])} {p(seg[3])}" for seg in segments) + " Z"
    cx = MARGIN + 50 * unit
    arc = arc_path(cx, MARGIN + w["arc_y"] * unit, ARC_RADIUS * unit, ARC_HALF_CHORD * unit, w["stroke"] / 2 * unit)
    sun = sun_path(cx, MARGIN + w["sun_y"] * unit, w["sun_r"] * unit, MARGIN + w["arc_y"] * unit,
                   ARC_RADIUS * unit, ARC_HALF_CHORD * unit, (w["stroke"] / 2 + w["gap"]) * unit)
    (DESIGN / "carpe-icon.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">\n'
        '  <defs>\n'
        f'    <linearGradient id="body" x1="0" y1="{MARGIN}" x2="0" y2="{MARGIN + BODY}" gradientUnits="userSpaceOnUse">\n'
        '      <stop offset="0" stop-color="#FFFFFF"/>\n'
        '      <stop offset="1" stop-color="#EEF0F3"/>\n'
        '    </linearGradient>\n'
        '    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">\n'
        '      <feDropShadow dx="0" dy="10" stdDeviation="5" flood-color="#000000" flood-opacity="0.3"/>\n'
        '    </filter>\n'
        '  </defs>\n'
        f'  <path d="{body}" fill="url(#body)" filter="url(#shadow)"/>\n'
        f'  <path d="{sun}" fill="#FF8A1F"/>\n'
        f'  <path d="{arc}" fill="#0B0B0D"/>\n'
        '</svg>\n')


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


if __name__ == "__main__":
    ASSETS.mkdir(parents=True, exist_ok=True)
    write_json(ASSETS / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    write_app_icon()
    write_menu_bar_icon()
    write_master_svg()
    print(f"Wrote {ASSETS.relative_to(ROOT)} and {DESIGN.relative_to(ROOT)}/carpe-icon.svg")
