"""Writes design/component-reference/viewed-images.json for scripts/component-reference: the images a tool group
opened, below the group (ViewedImagesTimelineRow, apps/web/src/components/chat/TimelineWorkEntryRow.tsx:250-282 at
Nightly 4928). Each image is a ChatMarkdownAssetImage with maxHeightRem 10 and no known size, so ChatMarkdownImage
draws the settled <img> with the workspace frame and a 10rem max height (chat/ChatMarkdownMedia.tsx:30-35, 87-90,
223-244, 440-447, 476-492). The pictures are generated here as small PNGs; the native test decodes the same bytes.
Usage: /usr/bin/python3 -I scripts/gen-viewed-images-spec.py
"""
import base64, json, os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def png(width, height, color, stripe):
    """A solid picture with a stripe on its left quarter, so a mirrored or cropped draw shows."""
    rows = b""
    for _ in range(height):
        row = b"".join(bytes(stripe if x < width // 4 else color) for x in range(width))
        rows += b"\x00" + row
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))

IMAGES = [("screens/home.png", png(320, 200, (46, 139, 87), (240, 200, 60))),
          ("screens/icon.png", png(120, 90, (70, 110, 200), (220, 80, 80)))]
IMG = ("h-auto w-auto object-contain max-h-[30rem] max-w-[min(100%,30rem)] inline-block! rounded-lg border border-border/40 "
       "cursor-zoom-in")

def row():
    images = "".join(f'<img alt="{os.path.basename(path)}" src="data:image/png;base64,{base64.b64encode(data).decode()}" '
                     f'decoding="sync" draggable="false" class="{IMG}" style="max-height:10rem">' for path, data in IMAGES)
    return f'<div class="flex flex-wrap items-start gap-2 px-0.5" data-image-gallery style="width:640px">{images}</div>'

spec = {"component": "viewed-images", "sourceVersion": "v0.1.11-nightly.20261119.4928",
        "source": "apps/web/src/components/chat/TimelineWorkEntryRow.tsx; chat/ChatMarkdownMedia.tsx",
        "states": ["rest"], "themes": ["light", "dark"],
        "cases": [{"name": "row", "html": row(), "wrapperStyle": "display:block",
                   "native": {"kind": "viewed-images", "paths": ",".join(path for path, _ in IMAGES)}}]}
with open(os.path.join(ROOT, "design/component-reference/viewed-images.json"), "w") as f:
    json.dump(spec, f, indent=1)
print("viewed-images", len(spec["cases"]), "cases")
