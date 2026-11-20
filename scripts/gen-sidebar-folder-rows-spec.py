"""Writes design/component-reference/sidebar-folder-rows.json for scripts/component-reference: the boring sidebar's
two-line folder thread rows (#26463, Labs "Two-line folder rows"), at rest.

Class strings are copied from apps/web/src/components/sidebar/SidebarThreadRow.tsx:1010-1112, 1266-1330 and
1327-1460, ThreadStatusIndicators.tsx:773-805 and ui/middle-truncate.tsx at the tag in T3_VERSION. Rows sit in a
`data-app-sidebar` box with `bg-sidebar` and 8px padding, as in a SidebarGroup.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-folder-rows-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = os.path.expanduser("~/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons")

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

BOX = '<div data-app-sidebar="" class="bg-sidebar text-sidebar-foreground" style="width:240px;padding:8px">{}</div>'
SURFACE = ("group/sidebar-row relative w-full cursor-pointer overflow-hidden rounded-md text-left outline-none select-none "
           "focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring bg-transparent text-sidebar-foreground hover:bg-sidebar-row-hover")
# `variant !== "slim"`: a folder row's title is `truncate text-foreground`.
TITLE = "min-w-0 flex-1 text-start text-sm transition-opacity motion-reduce:transition-none font-medium truncate text-foreground"
TIME = ('<span class="relative ml-auto flex h-6 min-w-8 shrink-0 items-center justify-end">'
        '<span class="inline-flex justify-end tabular-nums text-secondary-label transition-opacity group-any-hover/sidebar-row:opacity-0">'
        '<span class="text-xs">5m</span></span></span>')

def row(title, meta):
    return ('<li class="list-none"><div role="button" tabindex="0" data-testid="sidebar-row-folder" '
            f'class="{SURFACE} flex flex-col justify-center px-2.5 py-1.5 ps-9">'
            f'<div class="flex h-6 min-w-0 items-center gap-2.5"><span class="{TITLE}" dir="ltr">{title}</span>'
            + ('' if meta else '<span aria-hidden="true" class="inline-flex shrink-0 items-center gap-1"></span>')
            + f'{TIME}</div>{meta}</div></li>')

META = ('<div class="mt-0.5 flex min-w-0 items-center gap-1.5 text-secondary-label text-xs">'
        '<span role="img" class="inline-flex items-center justify-center">' + lucide("folder-git-2", "size-3.5 shrink-0 text-icon-muted") + '</span>'
        '<span class="flex min-w-0 flex-1"><span class="inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap">'
        '<span class="min-w-0 truncate">feature/two-line-rows</span></span></span>'
        '<span aria-hidden="true" class="pointer-events-none ml-auto inline-flex shrink-0 items-center gap-1"></span></div>')

cases = [
    {"name": "two-line", "html": BOX.format(row("Port the two-line rows", META)), "wrapperStyle": "display:block",
     "native": {"title": "Port the two-line rows", "branch": "feature/two-line-rows"}},
    {"name": "two-line.no-meta", "html": BOX.format(row("Scratch idea", "")), "wrapperStyle": "display:block",
     "native": {"title": "Scratch idea"}},
]
out = {"component": "sidebar-folder-rows", "sourceVersion": "v0.1.11-nightly.20261119.4928", "states": ["rest"],
       "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/sidebar-folder-rows.json"), "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
print("sidebar-folder-rows", len(cases), "cases")
