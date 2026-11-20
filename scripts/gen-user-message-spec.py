"""Writes design/component-reference/user-message.json for scripts/component-reference: the shapes your
own messages take at Nightly 4928 (TimelineUserMessageRow.tsx), the quote card in a sent message
(AssistantCitationChip.tsx) and the model and effort switch divider (V2LifecycleRow.tsx).

Each case is the row's column (`group @container flex flex-col items-end gap-1`, TimelineUserMessageRow.tsx:903-906)
in a 640px lane. Deviations: the hover actions row (timestamp, copy) is left out, since it is invisible at
rest (ACTIONS_REVEAL_CLASS_NAME, :1138-1139) and only adds empty height; images are solid PNGs so the
native side can draw the same pixels; MessageAuthorHeading is sr-only and left out.

The Markdown root, the pierre file icon, buttons and lucide icons reuse gen-markdown-spec.py's helpers.
Usage: /usr/bin/python3 -I scripts/gen-user-message-spec.py
"""
import base64, glob, html, json, os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

m = {"__file__": os.path.join(ROOT, "scripts/gen-markdown-spec.py")}
exec(load("gen-markdown-spec.py", "main_chunk = "), m)
lucide, button = m["lucide"], m["button"]
MAIN_CHUNK = glob.glob(os.path.join(m["ASSETS"], "main-*.js"))[0]

# UserMessageBody renders ChatMarkdown with className "text-message-foreground user-message-markdown"
# (TimelineUserMessageRow.tsx:1300-1311), which replaces the body color.
MD_ROOT = m["ROOT_CLASS"].replace("text-foreground/[calc(90%+var(--appearance-contrast-boost)/10)]",
                                  "text-message-foreground user-message-markdown")
ROW = "group @container flex flex-col items-end gap-1"
CHIP_INK = "[&_[data-slot=context-chip]]:[--context-chip-message-ink:var(--context-chip-message)]"
MEDIA_EDGE = ("relative after:pointer-events-none after:absolute after:inset-0 after:z-10 after:rounded-[inherit] "
              "after:ring-1 after:ring-inset after:ring-black/9 dark:after:ring-white/12")

def png(rgb, w=4, h=4):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    return "data:image/png;base64," + base64.b64encode(data).decode()

IMAGES = {"wide": ((46, 139, 87), 64, 36), "a": ((70, 110, 200), 4, 4), "b": ((200, 120, 60), 4, 4), "c": ((150, 80, 160), 4, 4)}
def image_src(key):
    rgb, w, h = IMAGES[key]
    return png(rgb, w, h)

def bubble(inner, *, plain=False, joined_top=False, joined_bottom=False):
    """The bubble (TimelineUserMessageRow.tsx:933-945): no fill or padding for media or file cards only."""
    cls = "relative min-w-0 max-w-[80%] rounded-2xl text-message-foreground"
    if joined_top: cls += " rounded-tr-md"
    if joined_bottom: cls += " rounded-br-md"
    cls += " " + CHIP_INK + ("" if plain else " bg-message p-3")
    return f'<div class="{cls}" data-user-message-bubble=""><div dir="ltr">{inner}</div></div>'

def body(text_html):
    """CollapsibleUserMessageBody (:1215-1262) around UserMessageBody's ChatMarkdown."""
    return (f'<div><div><div class="relative" data-user-message-body="true" data-user-message-collapsed="false">'
            f'<div><div class="{MD_ROOT}">{text_html}</div></div></div></div></div>')

def lone_image(corner):
    """A lone image keeps its own shape (:722-760, loneImage)."""
    return (f'<div class="grid max-w-full"><div class="bg-background/70 {MEDIA_EDGE} overflow-hidden rounded-2xl{corner}">'
            f'<button type="button" class="block h-full w-full cursor-zoom-in" aria-label="Preview screenshot.png">'
            f'<img alt="screenshot.png" src="{image_src("wide")}" class="block transform-gpu h-48 w-auto min-w-24 max-w-full object-contain"></button></div></div>')

def collage(keys):
    """Several images share one rounded shape split by hairlines (:722-775, collage with three images)."""
    cells = []
    for index, key in enumerate(keys):
        span = " row-span-2" if len(keys) == 3 and index == 0 else ""
        cells.append(f'<div class="bg-background/70 overflow-hidden bg-background{span}"><button type="button" class="block h-full w-full cursor-zoom-in" aria-label="Preview {key}.png">'
                     f'<img alt="{key}.png" src="{image_src(key)}" class="block transform-gpu size-full object-cover"></button></div>')
    return (f'<div class="grid {MEDIA_EDGE} w-80 max-w-full gap-px overflow-hidden rounded-2xl bg-black/9 dark:bg-white/12 '
            f'auto-rows-[calc(6rem-0.5px)] grid-cols-[3fr_2fr]">{"".join(cells)}</div>')

def file_card(name, detail):
    """UserFileCard (:109-196) for a downloadable file."""
    identity = (f'<span class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-background/60">{m["pierre"]("typescript")}</span>'
                f'<span class="min-w-0 flex-1"><span class="block truncate text-sm font-medium group-hover/file:underline">{html.escape(name)}</span>'
                f'<span class="block text-xs text-muted-foreground tabular-nums">{detail}</span></span>')
    download = button("ghost-muted", "download", f' aria-label="Download {html.escape(name)}"')
    return ('<div class="flex w-64 max-w-full items-center gap-1 rounded-2xl bg-message py-2 ps-2 pe-1 text-message-foreground">'
            '<button type="button" class="group/file focus-visible:ring-ring/70 flex min-w-0 flex-1 cursor-pointer items-center gap-3 rounded-xl text-left focus-visible:ring-2 focus-visible:ring-inset focus-visible:outline-none">'
            f'{identity}</button>{download}</div>')

def quote_card():
    """AssistantCitationEmbed in ResponseCard (AssistantCitationChip.tsx:59-113, 115-150), leading and trailing."""
    return ('<span data-thread-find-ignore=""><span class="block">'
            '<a href="#response" class="block min-w-0 rounded-lg bg-black/10 px-2.5 py-1.5 text-start text-sm text-muted-foreground! no-underline! wrap-break-word hover:bg-black/14 focus-visible:outline-2 focus-visible:outline-ring dark:bg-black/35 dark:hover:bg-black/50">'
            '<span class="line-clamp-2" dir="ltr">…the loader reads the file, then '
            '<mark class="rounded-sm bg-foreground/12 px-0.5 text-foreground">parses the config on every request</mark> before it…</span></a>'
            '<span class="mt-1.5 block whitespace-pre-wrap" dir="ltr">Can we cache this?</span></span></span>')

def divider(label):
    """TimelineSystemDivider (TimelineSystemDivider.tsx) with the ModelSwitchRow label (V2LifecycleRow.tsx:637-660)."""
    return ('<div class="flex min-w-0 items-center gap-2 py-2 text-2xs text-muted-foreground">'
            '<span aria-hidden="true" class="h-px flex-1 bg-border/70"></span>'
            '<span class="min-w-0 rounded-full px-2 py-1 flex flex-wrap items-center justify-center gap-1.5">'
            f'<span class="inline-flex items-baseline gap-1.5 align-baseline font-medium">{html.escape(label)}</span></span>'
            '<span aria-hidden="true" class="h-px flex-1 bg-border/70"></span></div>')

LANE = "display:block;width:640px"
CASES = []
def case(name, html_, native, wrapper=LANE):
    CASES.append({"name": name, "html": html_, "wrapperStyle": wrapper, "native": native})

# Bursts (#27305, #27978): rows grouped with the next sit on pb-1 (MessagesTimeline.tsx:1636-1645) and
# join their facing corners (:933-936).
# One root element: the capture clips to the case's first element.
burst = (f'<div><div class="pb-1"><div class="{ROW}">' + bubble(body("<p>Rename the helper to loadConfig</p>"), joined_bottom=True) + '</div></div>'
         + f'<div><div class="{ROW}">' + bubble(body("<p>and update its callers</p>"), joined_top=True) + '</div></div></div>')
case("burst", burst, {"kind": "burst", "texts": "Rename the helper to loadConfig|and update its callers"})

# Media above the bubble (#27306): the media leads in its own row and the bubble's top corner tightens (:925-936).
above = (f'<div class="{ROW}"><div class="flex max-w-[80%] justify-end">{lone_image(" rounded-br-md")}</div>'
         + bubble(body("<p>The header overlaps here</p>"), joined_top=True) + '</div>')
case("media.above-text", above, {"kind": "media", "images": "wide", "text": "The header overlaps here"})

# An image with no words shows the image, not a placeholder prompt (#26769, #27383, #38558).
case("media.image-only", f'<div class="{ROW}">' + bubble(lone_image(""), plain=True) + '</div>',
     {"kind": "media", "images": "wide", "text": ""})

# The collage (#27306): three images, the first spans both rows.
case("media.collage", f'<div class="{ROW}">' + bubble(collage(["a", "b", "c"]), plain=True) + '</div>',
     {"kind": "media", "images": "a,b,c", "text": ""})

# Files sent without words are cards (#27324).
case("file-card", f'<div class="{ROW}">' + bubble('<div class="flex flex-col items-end gap-1">' + file_card("report.ts", "TS · 12 KB") + '</div>', plain=True) + '</div>',
     {"kind": "file-card", "name": "report.ts", "bytes": "12288"})

# The quote in a sent message is an inset card (#34181), here with the comment that follows it.
case("quote-card", f'<div class="{ROW}">' + bubble(body(f"<p>{quote_card()}</p>")) + '</div>',
     {"kind": "quote", "text": "parses the config on every request", "comment": "Can we cache this?"})

# A same-harness effort change shows only what changed (#28995).
case("model-switch", divider("Medium → High"), {"kind": "model-switch", "label": "Medium → High"})

# Importing main writes the runtime context chip colors and appearance variables; the stored mode keeps a
# dark page dark (useTheme.ts:162-172). It also tints the pierre icons for the theme.
PREPARE = ("(document.querySelectorAll('svg[data-light]').forEach(s => s.style.color = document.documentElement.classList.contains('dark') "
           "? s.dataset.dark : s.dataset.light), localStorage.setItem('t3code:theme-appearance-mode', document.documentElement.classList.contains('dark') ? 'dark' : 'light'), "
           f"import('file://{MAIN_CHUNK}').then(() => new Promise(r => setTimeout(r, 300))).then(() => 'ok'))")
spec = {"component": "user-message", "sourceVersion": "v0.1.11-nightly.20261119.4928",
        "source": "apps/web/src/components/chat/TimelineUserMessageRow.tsx; AssistantCitationChip.tsx; V2LifecycleRow.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/user-message.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("user-message", len(CASES), "cases")
