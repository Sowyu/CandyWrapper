#!/usr/bin/env python3
"""Generate FileIcons.generated.swift: the @pierre/trees "complete" file icon set that T3's
changed files card and file trees draw (PierreEntryIcon.tsx, pierre-icons.ts).

The icons and the name and extension tables only exist in the installed T3 client bundle
(`client/assets/pierre-icons-*.js`), so this reads that file. Read only.

Usage: scripts/gen-file-icons.py [--bundle FILE] [--t3 DIR] [--out FILE]
"""
import argparse, glob, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
version = open(os.path.join(ROOT, "T3_VERSION")).read().strip().lstrip("v")
ap = argparse.ArgumentParser()
ap.add_argument("--bundle", default=(glob.glob(os.path.expanduser(
    f"~/.t3/runtime/versions/{version}/client/assets/pierre-icons-*.js")) or [None])[0])
ap.add_argument("--t3", default=os.path.expanduser("~/CandyWrapper-research/t3code"))
ap.add_argument("--out", default=os.path.join(ROOT, "Packages/CandyKit/Sources/Features/Diff/FileIcons.generated.swift"))
args = ap.parse_args()
src = open(args.bundle, encoding="utf-8").read()


def table(first):
    """The `x={key:`value`,...}` object literal from the minified bundle whose first entry starts
    with `first`. Minified names change between releases; the first keys have not."""
    start = re.search(r"[A-Za-z0-9_$]+=\{" + re.escape(first), src).end() - len(first)
    end = src.index("}", start)
    out = {}
    for m in re.finditer(r'(?:"([^"]+)"|([A-Za-z0-9_$]+)):`([^`]*)`', src[start:end]):
        out[m.group(1) or m.group(2)] = m.group(3)
    return out


# The resolver (`xe` in the bundle): file name table, then for each extension suffix the
# complete set's overrides, then the extension table; else `default`.
by_name, by_ext, overrides = table('".babelrc":'), table('"7z":'), table("jsx:`react`")
symbols = {}
colors = {}

# T3's own icons (pierre-icons.ts T3_FILE_ICON_SPRITE): the filled Pierre VS Code icons of #42493 that carry
# their `light-dark` color on the symbol, and the 24px Lucide and brand icons whose one color sits on a
# path or group (`style="fill: light-dark(...)"`, `stroke="#..."`, or DOCUMENT_ICON_COLORS for documents).
# A `currentColor` symbol keeps the default tint. Stroked shapes draw like Lucide at their stroke width.
pierre = open(os.path.join(args.t3, "apps/web/src/pierre-icons.ts"), encoding="utf-8").read()
document_colors = {k: (a, b) for k, a, b in re.findall(
    r'"(t3-file-icon-[a-z-]+)": "light-dark\(#([0-9a-f]{6}), #([0-9a-f]{6})\)"', pierre)}


def attrs_of(tag):
    return dict(re.findall(r'([\w-]+)="([^"]*)"', tag))


for m in re.finditer(r'<symbol id="(t3-file-icon-[a-z-]+)" viewBox="([^"]*)"([^>]*)>(.*?)</symbol>', pierre, re.S):
    name, box, extra, body = m.groups()
    own = re.search(r"light-dark\(#([0-9a-f]{6}), #([0-9a-f]{6})\)", extra)
    if own:
        colors[name] = own.groups()
    elif name in document_colors:
        colors[name] = document_colors[name]
    elif c := re.search(r"light-dark\(#([0-9a-f]{6}), #([0-9a-f]{6})\)", body):
        colors[name] = c.groups()
    elif c := re.search(r'(?:stroke|fill)="#([0-9a-f]{6})"', body):
        colors[name] = (c.group(1), c.group(1))
    group = re.search(r"<g([^>]*)>", body)
    group_attrs = attrs_of(group.group(1)) if group else {}
    elements = []
    for shape in re.finditer(r"<(path|rect)([^>]*)/?>", body):
        kind, a = shape.group(1), {**group_attrs, **attrs_of(shape.group(2))}
        stroked = a.get("fill") == "none"
        paint = {"opacity": float(a.get("opacity", "1")), "even": a.get("fill-rule") == "evenodd", "stroke": stroked,
                 "width": float(a.get("stroke-width", "1")), "cap": a.get("stroke-linecap", "butt"), "join": a.get("stroke-linejoin", "miter")}
        if kind == "path":
            geometry = ("path", a["d"])
        else:
            rx = float(a.get("rx", "0"))
            geometry = ("rect", (float(a.get("x", "0")), float(a.get("y", "0")), float(a["width"]), float(a["height"]), rx, float(a.get("ry", rx))))
        elements.append((geometry, paint))
    symbols[name] = (box, elements)


def t3_table(var):
    """`var: { "key": "icon", ... }` inside T3_PIERRE_ICONS, keeping the entries whose icon exists here."""
    start = pierre.index(var + ": {", pierre.index("T3_PIERRE_ICONS"))
    end = pierre.index("\n  },", start)
    out = {}
    for k1, k2, icon in re.findall(r'(?:"([^"]+)"|([A-Za-z0-9_]+)): "([^"]+)"', pierre[start:end]):
        out[k1 or k2] = icon[len("file-tree-builtin-"):] if icon.startswith("file-tree-builtin-") else icon
    return out


# T3's tables win over the built-in ones; a `test.ts` suffix is tried before `ts`.
t3_names, t3_exts = t3_table("byFileName"), t3_table("byFileExtension")
# `VIDEO_FILE_EXTENSIONS.map(...)` spreads packages/shared/src/video.ts's keys into the extension table.
video = open(os.path.join(args.t3, "packages/shared/src/video.ts"), encoding="utf-8").read()
for ext in re.findall(r'\["([a-z0-9]+)", "video/', video):
    t3_exts.setdefault(ext, "t3-file-icon-video")

for m in re.finditer(r'<symbol id="file-tree-builtin-([a-z0-9]+)" viewBox="([^"]*)">(.*?)</symbol>', src, re.S):
    name, box, body = m.groups()
    elements = []
    for p in re.finditer(r"<path([^>]*)/?>", body):
        attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', p.group(1)))
        opacity = float(attrs.get("opacity", "1"))
        even = attrs.get("fill-rule") == "evenodd"
        # nextjs fills one path with a gradient of currentColor; a flat fill is close enough.
        elements.append((("path", attrs["d"]), {"opacity": opacity, "even": even, "stroke": False}))
    symbols[name] = (box, elements)

known = lambda icon: icon in symbols
by_name.update({k: v for k, v in t3_names.items() if known(v)})
overrides.update({k: v for k, v in t3_exts.items() if known(v)})

# ICON_COLORS (PierreEntryIcon.tsx): light and dark per token.
entry = open(os.path.join(args.t3, "apps/web/src/components/chat/PierreEntryIcon.tsx"), encoding="utf-8").read()
for m in re.finditer(r'(\w+): \["#([0-9a-f]{6})", "#([0-9a-f]{6})"\]', entry):
    colors[m.group(1)] = (m.group(2), m.group(3))


def lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


lines = [
    "// GENERATED by scripts/gen-file-icons.py from T3's client bundle (@pierre/trees file icons). Do not edit.",
    "import DesignSystem",
    "",
    "enum FileIcons {",
    "    static let symbols: [String: IconDefinition] = [",
]
for name in sorted(symbols):
    box, elements = symbols[name]
    x, y, w, h = box.split()
    lines.append(f"        {lit(name)}: IconDefinition(viewBox: IconViewBox(x: {x}, y: {y}, width: {w}, height: {h}), elements: [")
    for (kind, geometry), paint in elements:
        shape = f".path(d: {lit(geometry)})" if kind == "path" else ".rect(x: {}, y: {}, w: {}, h: {}, rx: {}, ry: {})".format(*geometry)
        if paint["stroke"]:
            style = (f"IconPaint(stroke: .current, strokeWidth: {paint['width']}, opacity: {paint['opacity']}, "
                     f"lineCap: .{paint['cap']}, lineJoin: .{paint['join']})")
        else:
            style = f"IconPaint(fill: .current, opacity: {paint['opacity']}, evenOdd: {'true' if paint['even'] else 'false'})"
        lines.append(f"            IconElement({shape}, {style}),")
    lines.append("        ]),")
lines.append("    ]")
for var, data in (("byFileName", by_name), ("byExtension", by_ext), ("completeOverrides", overrides)):
    lines.append(f"    static let {var}: [String: String] = [")
    for k in sorted(data):
        lines.append(f"        {lit(k)}: {lit(data[k])},")
    lines.append("    ]")
lines.append("    /// Light and dark sRGB, 0xRRGGBB.")
lines.append("    static let colors: [String: (UInt32, UInt32)] = [")
for k in sorted(colors):
    lines.append(f"        {lit(k)}: (0x{colors[k][0]}, 0x{colors[k][1]}),")
lines.append("    ]")
lines.append("}")
open(args.out, "w").write("\n".join(lines) + "\n")
print(f"{len(symbols)} icons, {len(by_name)} names, {len(by_ext)} extensions -> {args.out}")
