#!/usr/bin/env python3
"""Generates Resources/AppIcon.icon (Icon Composer format) for Peeky Folders.

Based on Carl's sketch: a frosted Liquid Glass folder, with two more fanned out behind it, centred on the Big Sur
Finder-blue gradient, a small heart in its top-left corner, and a few soft curved lines along
the inner left and right edges that hint at the inside of the folder. One hue
family throughout: tinted white glass, with the heart and lines etched into it in the same
translucent blue.

Follows Apple's app icon guidance: few filled shapes with clear edges, a simple
gradient background that makes the white glyph stand out, no hand-drawn shadows
or highlights (the system's Liquid Glass adds those), no hairlines.

Canvas: 1024 x 1024 pt, unmasked and square; the system applies the macOS shape.
Open the result in Icon Composer to fine-tune; this script only seeds it.

Usage: scripts/make-icon-layers.py Resources/AppIcon.icon
"""
import json, os, sys

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.icon"
variant = sys.argv[2] if len(sys.argv) > 2 else "glass"
bg = sys.argv[3] if len(sys.argv) > 3 else "bigsur"
# Backgrounds: today's Finder blue (sampled: #00C1FF to #00A4FF) or Big Sur's deeper one.
BG = {"finder": ["srgb:0.00000,0.76078,1.00000,1.00000", "srgb:0.00000,0.61569,1.00000,1.00000"],
      "bigsur": ["srgb:0.13333,0.72157,0.97255,1.00000", "srgb:0.06667,0.43922,0.90196,1.00000"]}[bg]
LINE = "#1C1E21" if variant == "black" else "#2F7BEA"
HEART_OPACITY = 0.3 if variant == "glass" else 1.0   # the glass heart matches the lines
HEART = {"glass": ("#2F7BEA", "#2F7BEA"),    # same as the lines: etched into the glass (default)
         "grey": ("#B4BCC7", "#7E8896"),
         "black": ("#3A3D42", "#16181B"),
         "blue": ("#2F86FF", "#0A55D0"),
         "white": ("#FFFFFF", "#DCEBFF"),
         "red": ("#FF5A4E", "#E8302A")}[variant]
os.makedirs(os.path.join(out, "Assets"), exist_ok=True)

SCALE, LIFT = 1.12, 36       # enlarge the whole motif about the centre, then lift it a little

def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">'
            f'<g transform="translate(512 {512 - LIFT}) scale({SCALE}) translate(-512 -512)">'
            + body + "</g></svg>\n")

# Folder: one white silhouette, tab on the left.
X0, X1 = 202, 822
TOP, BODY, BOT = 352, 386, 776        # tab top, body top, bottom
R = 52                                # one corner radius throughout
TAB_W = 176

def folder(inset=0, dy=0, cut=None):
    """One folder silhouette; inset narrows it, dy moves it up (negative) for the stack.
    cut ends it with a flat bottom at that y, so a back folder doesn't show through
    the glass of the one in front."""
    x0, x1, t, body, bot = X0 + inset, X1 - inset, TOP + dy, BODY + dy, BOT + dy
    top = (f'M{x0 + R} {t} H{x0 + TAB_W - 26} '
           f'C{x0 + TAB_W + 6} {t} {x0 + TAB_W + 18} {t + 6} {x0 + TAB_W + 30} {t + 18} '
           f'L{x0 + TAB_W + 40} {body} H{x1 - R} Q{x1} {body} {x1} {body + R} ')
    if cut is None:
        rest = (f'V{bot - R} Q{x1} {bot} {x1 - R} {bot} H{x0 + R} Q{x0} {bot} {x0} {bot - R} ')
    else:
        rest = f'V{cut} H{x0} '
    return (f'<path d="{top}{rest}V{t + R} Q{x0} {t} {x0 + R} {t} Z" '
            'fill="#EAF3FF"/>')   # soft, blue-tinted white

# The back folders fan out behind the front one like cards (a remote nod to the
# Photos icon): same folder, rotated about a point below the stack.
FAN = [(-8, "folder-3"), (8, "folder-2")]          # degrees, layer
PIVOT = (512, BOT + 40)

def fanned(angle):
    return f'<g transform="rotate({angle} {PIVOT[0]} {PIVOT[1]})">{folder()}</g>'

def heart(cx, cy, s):
    """A Health-style heart: full round lobes, a clean notch, straight-ish sides and
    a softly rounded point. Drawn 208 wide by 188 tall, scaled so s is the width."""
    path = ("M0 -52 C-10 -78 -30 -92 -54 -92 C-84 -92 -104 -68 -104 -38 "
            "C-104 6 -64 46 -8 90 Q0 96 8 90 C64 46 104 6 104 -38 "
            "C104 -68 84 -92 54 -92 C30 -92 10 -78 0 -52 Z")
    k = s / 208
    return ('<defs><linearGradient id="h" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{HEART[0]}"/><stop offset="1" stop-color="{HEART[1]}"/>'
            f'</linearGradient></defs>'
            f'<path d="{path}" fill="url(#h)" transform="translate({cx} {cy}) scale({k:.4f})"/>')

def inner_lines():
    """Soft curved strokes along the inner right edge (the heart owns the left)."""
    w = 16
    style = f'fill="none" stroke="{LINE}" stroke-width="{w}" stroke-linecap="round"'
    L, Rr = X0 + 46, X1 - 46
    paths = [
        # right edge: a long line that curves into the bottom corner, and a shorter one inside it
        f'M{Rr} {BODY + 92} V{BOT - 92} Q{Rr} {BOT - 46} {Rr - 40} {BOT - 46}',
        f'M{Rr - 52} {BODY + 150} V{BOT - 136}',
    ]
    return "".join(f'<path d="{d}" {style}/>' for d in paths)

layers = {
    "folder": svg(folder()),
    **{name: svg(fanned(angle)) for angle, name in FAN},
    "lines": svg(inner_lines()),
    "heart": svg(heart(X0 + 172, BODY + 140, 170)),
}
for name, content in layers.items():  # noqa
    open(os.path.join(out, "Assets", name + ".svg"), "w").write(content)

def layer(name, opacity=1.0, glass=True):
    return {"image-name": name + ".svg", "name": name, "opacity": opacity,
            "glass": glass, "position": {"scale": 1, "translation-in-points": [0, 0]}}

def group(name, layers, shadow=0.5, translucency=0.0):
    return {"name": name, "layers": layers,
            "shadow": {"kind": "neutral", "opacity": shadow},
            "translucency": {"enabled": translucency > 0, "value": translucency},
            "specular": True}

icon = {
    "fill": {"linear-gradient": BG,
             "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}},
    "groups": [                                     # first = frontmost
        group("Contents", [layer("heart", opacity=HEART_OPACITY), layer("lines", opacity=0.22)], shadow=0.2),
        # Frosted Liquid Glass folder: tinted white, partly translucent.
        group("Folder", [layer("folder")], shadow=0.5, translucency=0.08),
        group("Fan", [layer("folder-2", opacity=0.65), layer("folder-3", opacity=0.45)],
              shadow=0.3, translucency=0.5),
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
json.dump(icon, open(os.path.join(out, "icon.json"), "w"), indent=2)
print("wrote", out)
