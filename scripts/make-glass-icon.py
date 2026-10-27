#!/usr/bin/env python3
"""Generates App/AppIcon.icon, the layered Liquid Glass app icon (Icon Composer format).

The system renders glass, specular highlights and the default/dark/tinted/clear
appearances from these layers. Run from the repo root:

    python3 scripts/make-glass-icon.py

Then open App/AppIcon.icon in Icon Composer to preview every appearance.
"""
import json
import math
import os
import shutil

OUT = "App/AppIcon.icon"
SIZE = 1024          # Icon Composer canvas, full bleed; the system applies the squircle mask.
CENTER = SIZE / 2
RING_RADIUS = 330    # centerline of the ring
RING_WIDTH = 104
DOT_RADIUS = 118
GAP = 0.04           # visible gap between segments, as a fraction of the circle

# (share of the ring, sRGB hex) — the category colors from CategoryDefinition.defaults.
SEGMENTS = [
    (0.32, "#4F7CFF"),  # code
    (0.17, "#2BB8A4"),  # writing
    (0.20, "#C356F0"),  # design
    (0.14, "#E2B93B"),  # productivity
    (0.11, "#F44336"),  # entertainment
]


def svg(body: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
            f'viewBox="0 0 {SIZE} {SIZE}">{body}</svg>\n')


def point(fraction: float) -> tuple[float, float]:
    # 0 is 12 o'clock, clockwise.
    angle = fraction * 2 * math.pi - math.pi / 2
    return CENTER + RING_RADIUS * math.cos(angle), CENTER + RING_RADIUS * math.sin(angle)


def arc(start: float, end: float, color: str) -> str:
    (x0, y0), (x1, y1) = point(start), point(end)
    large = 1 if end - start > 0.5 else 0
    return svg(f'<path d="M {x0:.2f} {y0:.2f} A {RING_RADIUS} {RING_RADIUS} 0 {large} 1 {x1:.2f} {y1:.2f}" '
               f'fill="none" stroke="{color}" stroke-width="{RING_WIDTH}" stroke-linecap="round"/>')


def srgb(hex_color: str, alpha: float = 1.0) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def main() -> None:
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(f"{OUT}/Assets")

    def write(name: str, content: str) -> str:
        with open(f"{OUT}/Assets/{name}", "w") as f:
            f.write(content)
        return name

    write("track.svg", svg(f'<circle cx="{CENTER}" cy="{CENTER}" r="{RING_RADIUS}" fill="none" '
                           f'stroke="#FFFFFF" stroke-width="{RING_WIDTH}"/>'))
    write("dot.svg", svg(f'<circle cx="{CENTER}" cy="{CENTER}" r="{DOT_RADIUS}" fill="#FFFFFF"/>'))

    # Round caps reach past the path ends, so trim each arc by the cap radius.
    cap = (RING_WIDTH / 2) / (2 * math.pi * RING_RADIUS)
    total = sum(share for share, _ in SEGMENTS)
    available = 1 - GAP * len(SEGMENTS)
    start = GAP / 2
    segment_layers = []
    for index, (share, color) in enumerate(SEGMENTS):
        length = share / total * available
        name = write(f"segment-{index + 1}.svg", arc(start + cap, start + length - cap, color))
        segment_layers.append({"name": f"Segment {index + 1}", "image-name": name, "glass": True})
        start += length + GAP

    icon = {
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb("#2B3270"), srgb("#0B0D1F")]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb("#1A1E45"), srgb("#05060F")]}},
        ],
        "groups": [
            {
                "name": "Focus",
                "layers": [{
                    "name": "Dot",
                    "image-name": "dot.svg",
                    "glass": True,
                    "fill-specializations": [
                        {"value": {"linear-gradient": [srgb("#FFFFFF"), srgb("#D6E0FF")]}},
                    ],
                }],
                "shadow": {"kind": "layer-color", "opacity": 0.6},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.2},
                "lighting": "combined",
            },
            {
                "name": "Ring",
                "layers": segment_layers,
                "shadow": {"kind": "layer-color", "opacity": 0.5},
                "specular": True,
                "translucency": {"enabled": True, "value": 0.35},
                "lighting": "individual",
            },
            {
                "name": "Track",
                "layers": [{"name": "Track", "image-name": "track.svg", "glass": False, "opacity": 0.08}],
                "shadow": {"kind": "none", "opacity": 0},
                "specular": False,
                "translucency": {"enabled": False, "value": 0},
            },
        ],
        "supported-platforms": {"squares": "shared"},
    }
    with open(f"{OUT}/icon.json", "w") as f:
        json.dump(icon, f, indent=2)
        f.write("\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
