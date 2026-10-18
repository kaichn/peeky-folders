#!/usr/bin/env python3
"""Generates Resources/AppIcon.icon (Icon Composer format) for Peeky Folders.

Based on Carl's sketch: a stack of three frosted Liquid Glass folders centred on an azure
gradient, a small heart in its top-left corner, and a few soft curved lines along
the inner left and right edges that hint at the inside of the folder. One hue
family throughout: tinted white glass, deep tonal-blue heart, faint blue lines.

Follows Apple's app icon guidance: few filled shapes with clear edges, a simple
gradient background that makes the white glyph stand out, no hand-drawn shadows
or highlights (the system's Liquid Glass adds those), no hairlines.

Canvas: 1024 x 1024 pt, unmasked and square; the system applies the macOS shape.
Open the result in Icon Composer to fine-tune; this script only seeds it.

Usage: scripts/make-icon-layers.py Resources/AppIcon.icon
"""
import json, os, sys

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.icon"
variant = sys.argv[2] if len(sys.argv) > 2 else "blue"
HEART = {"blue": ("#2F86FF", "#0A55D0"),      # deep tonal azure (default)
         "white": ("#FFFFFF", "#DCEBFF"),
         "red": ("#FF5A4E", "#E8302A")}[variant]
os.makedirs(os.path.join(out, "Assets"), exist_ok=True)

def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            'viewBox="0 0 1024 1024">' + body + "</svg>\n")

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

STACK = [(0, 0), (34, -46), (68, -92)]   # (inset, dy): front, middle, back

def heart(cx, cy, s):
    """A plump, Health-style heart, s wide, centred on (cx, cy)."""
    k = s / 200.0
    def p(x, y):
        return f"{cx + x * k:.1f} {cy + y * k:.1f}"
    d = (f"M{p(0, 80)} "
         f"C{p(-10, 74)} {p(-100, 22)} {p(-100, -30)} "
         f"C{p(-100, -64)} {p(-74, -88)} {p(-46, -88)} "
         f"C{p(-24, -88)} {p(-8, -76)} {p(0, -60)} "
         f"C{p(8, -76)} {p(24, -88)} {p(46, -88)} "
         f"C{p(74, -88)} {p(100, -64)} {p(100, -30)} "
         f"C{p(100, 22)} {p(10, 74)} {p(0, 80)} Z")
    return ('<defs><linearGradient id="h" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{HEART[0]}"/><stop offset="1" stop-color="{HEART[1]}"/>'
            f'</linearGradient></defs><path d="{d}" fill="url(#h)"/>')

def inner_lines():
    """Soft curved strokes along the inner right edge (the heart owns the left)."""
    w = 16
    style = f'fill="none" stroke="#2F7BEA" stroke-width="{w}" stroke-linecap="round"'
    L, Rr = X0 + 46, X1 - 46
    paths = [
        # right edge: a long line that curves into the bottom corner, and a shorter one inside it
        f'M{Rr} {BODY + 92} V{BOT - 92} Q{Rr} {BOT - 46} {Rr - 40} {BOT - 46}',
        f'M{Rr - 52} {BODY + 150} V{BOT - 136}',
    ]
    return "".join(f'<path d="{d}" {style}/>' for d in paths)

layers = {
    "folder": svg(folder(*STACK[0])),
    # Back folders stop just below the top edge of the folder in front of them.
    "folder-2": svg(folder(*STACK[1], cut=BODY + 4)),
    "folder-3": svg(folder(*STACK[2], cut=BODY + STACK[1][1] + 4)),
    "lines": svg(inner_lines()),
    "heart": svg(heart(X0 + 172, BODY + 140, 178)),
}
for name, content in layers.items():
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
    # Light azure at the top to deep blue at the bottom, so the glass has
    # something to refract.
    "fill": {"linear-gradient": ["srgb:0.36078,0.67843,1.00000,1.00000",
                                 "srgb:0.04706,0.36078,0.85490,1.00000"],
             "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 0.75}}},
    "groups": [                                     # first = frontmost
        group("Contents", [layer("heart"), layer("lines", opacity=0.22)], shadow=0.2),
        # Frosted Liquid Glass folder: tinted white, partly translucent.
        group("Folder", [layer("folder", opacity=0.93)], shadow=0.5, translucency=0.3),
        group("Folder 2", [layer("folder-2", opacity=0.7)], shadow=0.4, translucency=0.4),
        group("Folder 3", [layer("folder-3", opacity=0.5)], shadow=0.3, translucency=0.5),
    ],
    "supported-platforms": {"squares": ["macOS"]},
}
json.dump(icon, open(os.path.join(out, "icon.json"), "w"), indent=2)
print("wrote", out)
