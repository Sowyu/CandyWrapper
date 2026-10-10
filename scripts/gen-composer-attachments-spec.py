"""Writes design/component-reference/composer-attachments.json for scripts/component-reference: the
composer's image shelf (ChatComposer.tsx:7062-7230), the expanded image preview
(ExpandedImageDialog.tsx, ZoomableImage.tsx, ui/dialog.tsx variant "media"), the stash menu
(ComposerStashMenu.tsx) and the stash badge (ComposerStashBadge.tsx), all on ComposerBanner.tsx.

Class strings are copied from those files at the tag in T3_VERSION. The test image is
design/component-reference/composer-attachments-fixture.png, written here (no dependencies).
Viewport units in the preview are resolved for a 720x480 window, as the native test uses.
Usage: /usr/bin/python3 -I scripts/gen-composer-attachments-spec.py
"""
import base64, html, json, os, re, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or "/Users/mrm/CandyWrapper-research"
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")

# Button classes and tailwind-merge from gen-button-spec.py (its definitions only).
src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
exec(src[:src.index("def camel")])

def lucide(name, cls=""):
    s = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", s[s.index(">", s.index("<svg")) + 1:s.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

def btn(variant, size, inner, extra="", tag="button"):
    cls = merge(f"{BASE} {VARIANTS[variant]} {SIZES[size]} {extra}")
    return f'<{tag} data-slot="button" class="{cls}">{inner}</{tag}>'

# The fixture: 640x480, four colored quadrants and a white diagonal band.
def fixture_png():
    w, h = 640, 480
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            if abs(x * h - y * w) < 24 * w: c = (250, 250, 250)
            elif x < w // 2: c = (37, 99, 235) if y < h // 2 else (22, 163, 74)
            else: c = (234, 88, 12) if y < h // 2 else (147, 51, 234)
            row += bytes(c)
        rows.append(bytes(row))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
png = fixture_png()
open(os.path.join(ROOT, "design/component-reference/composer-attachments-fixture.png"), "wb").write(png)
IMG = "data:image/png;base64," + base64.b64encode(png).decode()

# MARK: shelf
TILE = "group/attachment shrink-0 snap-start bg-background relative h-16 w-16 overflow-hidden rounded-lg border border-border/80"
def tile(name, progress=None, failed=False):
    strip = (f'<span class="pointer-events-none absolute inset-x-0 bottom-0 bg-background/85 px-1 text-center text-3xs text-foreground">{progress}</span>'
             if progress else "")
    retry = btn("overlay", "icon-xs", lucide("refresh-cw"), "absolute bottom-1 left-1") if failed else ""
    return (f'<div class="{TILE}"><button type="button" class="h-full w-full cursor-zoom-in" aria-label="Preview {name}">'
            f'<img src="{IMG}" alt="{name}" class="h-full w-full object-cover"></button>{strip}{retry}'
            f'<span class="absolute right-1 top-1 flex">{btn("media-close", "icon-xs", lucide("x"))}</span></div>')
shelf = f'<div class="flex max-w-full gap-2 flex-wrap">{tile("a.png")}{tile("b.png", progress="42%")}{tile("c.png", failed=True)}</div>'

# MARK: preview, for a 720x480 window: --media-width 92vw - 96px, --media-height min(86vh, 100vh - 160px)
W, H = 720, 480
media_w, media_h = W * 0.92 - 96, min(H * 0.86, H - 160)
fit = min(1, media_w / 640, media_h / 480)
iw, ih = 640 * fit, 480 * fit
nav = lambda side, icon: btn("media-navigation", "icon", lucide(icon, "size-5"), f"{side}-0 sm:top-1/2 sm:bottom-auto sm:-translate-y-1/2")
preview = (f'<div style="position:relative;width:{W}px;height:{H}px;overflow:hidden">'
           '<div class="absolute inset-0 bg-black/75 backdrop-blur-none"></div>'
           '<div class="absolute inset-0 grid grid-rows-1 place-items-center px-4 py-6">'
           f'<div class="relative flex min-h-0 min-w-0 flex-col items-center overflow-visible" style="width:{W * 0.92}px;--media-width:{media_w}px;--media-height:{media_h}px">'
           + nav("left", "chevron-left") +
           '<div class="relative isolate z-10 max-w-[var(--media-width)]">'
           + btn("media-close", "icon-xs", lucide("x"), "absolute right-0 -top-10 z-20") +
           f'<div class="min-w-0"><div class="max-w-[var(--media-width)] overflow-auto overscroll-contain rounded-lg bg-background shadow-2xl ring-1 ring-border/70 outline-none" style="width:{iw}px;height:{ih}px">'
           f'<img src="{IMG}" alt="" class="block max-w-none select-none" style="width:{iw}px;height:{ih}px"></div></div>'
           '<div class="mt-2 flex max-w-[var(--media-width)] items-center justify-center gap-1.5 text-xs text-white/80"><span class="truncate">screenshot.png (1/2)</span></div>'
           '</div>' + nav("right", "chevron-right") + '</div></div></div>')

# MARK: banner pieces (ComposerBanner.tsx)
SURFACE = ("[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--card))] dark:[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--surface-raised))] "
           "relative isolate border-0 bg-transparent shadow-none [--chat-composer-attached-tint:transparent] "
           "[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--contrast-foreground)_8%,transparent))] dark:[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--color-white)_5%,transparent))] "
           "[--chat-composer-attachment-overlap:calc(1rem+1px)] before:rounded-t-2xl before:mask-t-from-transparent before:mask-t-from-4 before:mask-t-to-black before:mask-t-to-4 "
           "before:pointer-events-none before:absolute before:inset-0 before:-z-1 before:border before:border-(--chat-composer-attached-outline) "
           "before:bg-(--chat-composer-attached-surface)/(--glass-opacity) before:bg-linear-to-b before:from-(--chat-composer-attached-tint) before:to-(--chat-composer-attached-tint) before:backdrop-blur-(--glass-blur) before:backdrop-saturate-(--glass-saturation) "
           "before:shadow-composer dark:before:shadow-composer-dark dark:supports-[(backdrop-filter:blur(1px))_or_(-webkit-backdrop-filter:blur(1px))]:before:bg-composer-seam-above")
ROOT_CLS = ("min-w-0 px-1 py-(--composer-banner-padding-block) after:block after:h-(--chat-composer-attachment-overlap) text-xs/4 "
            "[--composer-banner-icon-column:--spacing(7)] [--composer-banner-padding-block:--spacing(1)] sm:[--composer-banner-icon-column:--spacing(6)]")
ROW = ("group/banner-row grid min-h-(--composer-banner-icon-column) w-full min-w-0 grid-cols-[var(--composer-banner-icon-column)_minmax(0,1fr)_auto] items-center gap-x-1 text-start "
       "[&:is(button)]:cursor-pointer [&:is(button)]:rounded-md")
ICON = "col-start-1 row-start-1 flex w-(--composer-banner-icon-column) min-w-0 flex-none items-center justify-center text-muted-foreground [&>svg]:size-3"
CONTENT = "col-start-2 row-start-1 flex min-w-0 items-center gap-1"
ACTIONS = "col-start-3 row-start-1 flex flex-wrap items-center justify-end gap-1"
COUNT = "inline-flex min-w-(--composer-banner-icon-column,1em) flex-none justify-center font-medium text-muted-foreground tabular-nums"
dismiss = lambda: btn("ghost", "icon-xs", lucide("x", "size-3.5"), "z-10")
toggle = btn("ghost", "icon-xs", lucide("chevron-down", "size-3.5"), "pointer-events-none", tag="span")

def entry_row(snippet, time, highlighted=False, files=0, images=0):
    marks = ""
    if images:
        marks += ('<span class="flex shrink-0 items-center -space-x-1.5">'
                  + "".join(f'<img src="{IMG}" alt="" class="size-4 rounded border border-border/70 object-cover">' for _ in range(images)) + "</span>")
    if files:
        marks += f'<span class="flex shrink-0 items-center gap-1 text-muted-foreground">{lucide("file", "size-3")}{files}</span>'
    hl = " bg-accent text-accent-foreground" if highlighted else ""
    return (f'<li data-composer-banner-row="true" class="{ROW} relative rounded-sm{hl}"><span class="{ICON}">{lucide("file-text")}</span>'
            f'<span class="{CONTENT}"><button type="button" class="min-w-0 flex-1 cursor-pointer truncate text-left text-foreground/80 outline-none">{html.escape(snippet)}</button></span>'
            f'<span class="{ACTIONS}">{marks}<time class="shrink-0 text-muted-foreground tabular-nums">{time}</time>{dismiss()}</span></li>')

def stash_menu(rows, count):
    body = rows or (f'<li data-composer-banner-row="true" class="{ROW} not-has-[>[data-slot=composer-banner-actions]]:grid-cols-[var(--composer-banner-icon-column)_minmax(0,1fr)]">'
                    f'<span class="{ICON}"></span><span class="{CONTENT} text-muted-foreground">Nothing stashed yet. Press ⌘S with a prompt in the composer to stash it.</span></li>')
    return (f'<div class="{SURFACE} {ROOT_CLS} @container">'
            f'<button type="button" class="{ROW}"><span class="{ICON}">{lucide("bookmark")}</span>'
            f'<span class="{CONTENT} text-muted-foreground">Stash</span><span class="{ACTIONS}"><span class="{COUNT}">{count}</span>{toggle}</span></button>'
            f'<div class="relative min-h-0 overflow-hidden h-auto max-h-[384px]"><div class="max-h-[inherit] overflow-auto"><div>'
            f'<ul role="list" class="grid gap-px [&_[data-composer-banner-row]]:min-h-5">{body}</ul></div></div></div></div>')

menu = stash_menu(entry_row("Refactor the upload queue so retries keep their place", "5m ago", highlighted=True, images=2)
                  + entry_row("(1 file)", "2h ago", files=1), 2)
empty = stash_menu("", 0)
badge = (f'<div class="{SURFACE} {ROOT_CLS} [--composer-banner-padding-block:--spacing(1.25)] w-fit max-w-full flex-none">'
         f'<button type="button" class="{ROW} transition-colors duration-200 text-muted-foreground">'
         f'<span class="{ICON}">{lucide("bookmark")}</span><span class="{CONTENT}">Stash</span>'
         f'<span class="{ACTIONS}"><span class="{COUNT} text-muted-foreground">3</span></span></button></div>')

cases = [
    {"name": "shelf", "html": shelf, "native": {"case": "shelf"}, "wrapperStyle": "display:block;width:300px"},
    {"name": "preview", "html": preview, "native": {"case": "preview"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "stash-menu", "html": menu, "native": {"case": "stash-menu"}, "wrapperStyle": "display:block;width:692px"},
    {"name": "stash-empty", "html": empty, "native": {"case": "stash-empty"}, "wrapperStyle": "display:block;width:692px"},
    {"name": "stash-badge", "html": badge, "native": {"case": "stash-badge"}, "wrapperStyle": "display:inline-block"},
]
spec = {"component": "composer-attachments", "source": "apps/web/src/components/chat/ChatComposer.tsx, ExpandedImageDialog.tsx, ComposerStashMenu.tsx, ComposerStashBadge.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/composer-attachments.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
