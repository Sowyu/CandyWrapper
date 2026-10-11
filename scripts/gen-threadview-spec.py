"""Writes design/component-reference/threadview.json for scripts/component-reference: the thread details
card at its full, compact and essential densities (ThreadDetailsPanel.tsx:100-185, threadDetailsCardLayout.ts:7-14,
GitActionsControl.tsx:1824, OpenInPicker.tsx:388-460) and the context chips inside a sent user message
(MessagesTimeline.tsx:4243-4709, ThreadContextChip.tsx, chat/TerminalContextInlineChip.tsx, contextChipParts.tsx,
ContextChip.tsx): a thread, a terminal excerpt, a file attachment, an image attachment tinted with its picture's
average color, and a folder mention (MarkdownFileLink).

The card markup reuses gen-git-spec.py's helpers; the chip markup reuses gen-markdown-spec.py's chip and pierre
helpers and its icon tint hook. The image chip's picture is a solid 4x4 PNG, so `averageImageColor` gives its
color exactly; the native test loads the same pixels.
Usage: /usr/bin/python3 -I scripts/gen-threadview-spec.py
"""
import base64, html, json, os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-git-spec.py")}
exec(load("gen-git-spec.py", "def toolbar_trigger"), g)
m = {"__file__": os.path.join(ROOT, "scripts/gen-markdown-spec.py")}
exec(load("gen-markdown-spec.py", "diff_rendering = "), m)
lucide, control, panel_label, middle, machine, S = g["lucide"], g["control"], g["panel_label"], g["middle"], g["machine"], g["S"]
ICON, CHEVRON_PANEL = g["ICON"], g["CHEVRON_PANEL"]

# ---------------------------------------------------------------------------------------------- Card

def card(density, open_in=True):
    section = "px-2 pt-2 pb-2.5"
    workspace = ""
    if density == "full":
        run = control("select", '<span class="inline-flex shrink-0 items-center gap-0.5">'
                      f'<span class="inline-flex shrink-0">{machine("mac-mini", ICON)}</span>'
                      f'<span class="inline-flex shrink-0">{lucide("folder", ICON)}</span></span>{panel_label("This Mac")}')
        workspace += f'<div class="flex w-full flex-col">{run}</div>'
    if open_in and density != "essential":
        workspace += (f'<div role="group" aria-label="Open in editor" class="{S["THREAD_DETAILS_PANEL_SPLIT_GROUP_CLASS"]}">'
                      + control("primary", f'{lucide("square-arrow-out-up-right", ICON)}<span class="not-sr-only ml-0 min-w-0 truncate">Open in Finder</span>')
                      + f'<span aria-hidden="true" class="{S["THREAD_DETAILS_PANEL_SPLIT_SEPARATOR_CLASS"]}"></span>'
                      + control("secondary", lucide("chevron-down", CHEVRON_PANEL)) + '</div>')
    branch_btn = control("select", f'{lucide("git-branch", "shrink-0 opacity-70 size-4 text-muted-foreground")}{panel_label(middle("main"))}',
                         "min-w-0 max-w-full active:scale-100")
    split = ""
    if density == "full":
        split = (f'<div role="group" aria-label="Git actions" class="shrink-0 {S["THREAD_DETAILS_PANEL_SPLIT_GROUP_CLASS"]}">'
                 + control("primary", f'{lucide("git-commit-horizontal", ICON)}<span class="not-sr-only ml-0 truncate">Commit</span>')
                 + f'<span aria-hidden="true" class="{S["THREAD_DETAILS_PANEL_SPLIT_SEPARATOR_CLASS"]}"></span>'
                 + control("secondary", lucide("chevron-down", CHEVRON_PANEL)) + '</div>')
    changes = control("row", f'{lucide("file-diff", ICON)}<span class="flex-1 text-left">Changes</span>'
                      '<span class="flex items-center gap-1 font-mono text-2xs tabular-nums"><span class="text-success">+4</span>'
                      '<span class="text-destructive">-0</span></span>')
    separated = " border-t border-border/65" if density == "full" else ""
    return ('<div class="dropdown-glass isolate contain-paint grid max-h-full grid-rows-[minmax(0,1fr)] overflow-hidden rounded-3xl" '
            f'style="width:264px" data-density="{density}"><div><div>'
            f'<section class="{section}"><div class="flex flex-col">{workspace}</div></section>'
            f'<section class="{section}{separated}"><div class="flex flex-col">'
            f'<div class="flex w-full flex-col"><div class="flex min-w-0 w-full flex-col items-stretch"><span class="flex min-w-0">{branch_btn}</span></div></div>'
            f'{split}{changes}</div></section></div></div></div>')

cases = [{"name": f"card.{d}", "html": card(d), "native": {"kind": "card", "density": d}} for d in ["full", "compact", "essential"]]

# ThreadDetailsPrRow.tsx:434-476 once the host answers: passing checks, watched, Merge offered.
META = S["THREAD_DETAILS_PANEL_META_ACTION_CLASS"]
ICON_PART = S["THREAD_DETAILS_PANEL_ICON_ACTION_CLASS"]
CTRL = g["CTRL"]
def meta(children, tone=""):
    return f'<button type="button" class="{CTRL} {META} {tone}">{children}</button>'
pr_row = ('<div style="width:246px"><div class="pb-2">'
          + control("row", f'{lucide("git-pull-request-arrow", "size-4 shrink-0 text-emerald-600 dark:text-emerald-300/90")}'
                    '<span class="min-w-0 flex-1 truncate text-left">Add login redirect</span>')
          + '<div class="-mt-1 flex h-6 min-w-0 items-center gap-0.5 ps-9 pe-1 text-xs text-muted-foreground">'
          '<span class="me-1 shrink-0 tabular-nums">#42</span>'
          + meta(lucide("circle-check", "size-3.5 text-emerald-600 dark:text-emerald-300/90"))
          + f'<button type="button" class="{CTRL} {ICON_PART} group/watch">{lucide("eye", "size-3.5 group-hover/watch:hidden")}</button>'
          '<span class="flex-1"></span>'
          + meta("Merge", "text-primary hover:text-primary")
          + '</div></div></div>')
cases.append({"name": "pr.merge", "html": pr_row, "native": {"kind": "pr"}})

# ---------------------------------------------------------------------------------------------- Chips

BASE = ("inline-flex h-[1.41em] max-w-full items-center gap-[0.33em] rounded-[0.5em] border px-[0.5em] align-middle font-medium "
        "text-[0.86em] leading-none [&_svg]:block [&_svg]:size-[1.17em] [&_svg]:shrink-0 [&_svg]:self-center "
        "[button&,a&,[data-popup-open]&]:cursor-pointer [button&,a&]:transition-colors [button&,a&]:motion-reduce:transition-none "
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground disabled:cursor-default")
ACCENTS = {"thread": "oklch(0.62_0.12_190)", "terminal": "oklch(0.62_0.134_163)", "file": "oklch(0.62_0.136_237)", "image": "oklch(0.62_0.16_16)"}
COMPOUND = ("[--context-chip-border:color-mix(in_oklab,var(--context-chip-accent)_34%,var(--contrast-border))] "
            "[--context-chip-border-hover:color-mix(in_oklab,var(--context-chip-accent)_48%,var(--contrast-border))] "
            "[--context-chip-foreground:color-mix(in_oklab,var(--context-chip-accent)_22%,var(--contrast-foreground))] "
            "border-(--context-chip-border) bg-(--context-chip-accent)/11 text-(--context-chip-foreground) "
            "[button:enabled&,a&]:hover:border-(--context-chip-border-hover) [button:enabled&,a&]:hover:bg-(--context-chip-accent)/17")
LABEL = '<span class="block min-w-0 self-center truncate leading-tight{extra}" data-slot="context-chip-label">{text}</span>'

def context_chip(tag, kind, inner, style=""):
    cls = f"{BASE} [--context-chip-accent:{ACCENTS[kind]}] {COMPOUND}" + (" no-underline" if tag == "a" else "")
    attrs = ' href="#thread"' if tag == "a" else ' type="button"'
    st = f' style="{style}"' if style else ""
    return f'<{tag}{attrs} class="{cls}" data-slot="context-chip"{st}>{inner}</{tag}>'

def label(text, extra=""):
    return LABEL.format(text=html.escape(text), extra=extra)

SIZE = '<span class="shrink-0 text-3xs text-current">{}</span>'

def png(rgb, side=4):
    raw = b"".join(b"\x00" + bytes(rgb) * side for _ in range(side))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(data).decode()

IMAGE_RGB = (46, 139, 87)
CHIPS = {
    "thread": (context_chip("a", "thread", lucide("messages-square", "") + label("Fix login redirect")),
               "[Fix login redirect](t3-context://v1/thread/thread_demo)"),
    "terminal": (context_chip("button", "terminal", lucide("terminal", "") + label("Terminal 1 lines 4-9")),
                 "[Terminal 1 lines 4-9](t3-context://v1/terminal/terminal_demo)"),
    "file": (context_chip("button", "file", m["pierre"]("typescript") + label("report.ts", " max-w-72") + SIZE.format("12 KB")),
             "[report.ts](t3-context://v1/file/file_demo)"),
    "image": (context_chip("button", "image", f'<img alt="" class="size-[1.17em] shrink-0 rounded-sm object-cover" src="{png(IMAGE_RGB)}">'
                           + label("screenshot.png", " max-w-72") + SIZE.format("48 KB"),
                           style=f"--context-chip-accent: rgb({IMAGE_RGB[0]} {IMAGE_RGB[1]} {IMAGE_RGB[2]})"),
              "![screenshot.png](t3-context://v1/image/image_demo)"),
    "folder": (m["chip"]("/tmp/demo-repo", m["FOLDER"], "demo-repo"), "[demo-repo](/tmp/demo-repo)"),
}
# A user bubble's ChatMarkdown: `className="text-foreground"` replaces the 80% body color.
ROOT_CLASS = m["ROOT_CLASS"].replace("text-foreground/[calc(80%+var(--appearance-contrast-boost)/5)]", "text-foreground")
for kind, (chip, source) in CHIPS.items():
    body = f"<p>Look at {chip} please.</p>"
    cases.append({"name": f"chip.{kind}", "html": f'<div class="{ROOT_CLASS}">{body}</div>',
                  "wrapperStyle": "display:block;width:360px;--font-size-code:13px",
                  "native": {"kind": "chip", "chip": kind, "markdown": f"Look at {source} please.", "width": "360",
                             "rgb": ",".join(map(str, IMAGE_RGB))}})

PREPARE = ("(document.querySelectorAll('svg[data-light]').forEach(s => s.style.color = document.documentElement.classList.contains('dark') "
           "? s.dataset.dark : s.dataset.light), 'tinted')")
spec = {"component": "threadview", "source": "apps/web/src/components/chat/ThreadDetailsPanel.tsx; chat/MessagesTimeline.tsx; ContextChip.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/threadview.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
