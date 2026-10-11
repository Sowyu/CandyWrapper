"""Writes design/component-reference/sidebar-leftovers.json for scripts/component-reference: the sidebar states
WP7.9 added. The empty list's Add project button, the inline rename field, the provider update pill, the thread
hover card and the thread drag ghost.

Class strings are copied from apps/web/src/components/Sidebar.tsx, ThreadHoverCard.tsx, ui/tooltip.tsx,
ui/middle-truncate.tsx, sidebar/SidebarProviderUpdatePill.tsx and chat/ThreadContextDragGhost.tsx at the tag in
T3_VERSION. Sidebar cases sit in a `data-app-sidebar` box with `bg-sidebar` and 8px padding, as in a SidebarGroup;
the hover card and the ghost sit on the page's --background like a portal.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-leftovers-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

COLORS = ["gray", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan",
          "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose"]

def identity(name):
    """projectIdentity.ts for plain ASCII names, as ProjectMonogramView.identity."""
    words = [w for w in "".join(c if c.isalnum() else " " for c in name).split()]
    first = words[0]
    second = next((c for c in first[1:] if c.isdigit()), None) or (words[-1][0] if len(words) > 1 else first[-1])
    index = 0
    for ch in name.lower():
        index = (index * 31 + ord(ch)) % len(COLORS)
    return (first[0] + second).upper()[:2], COLORS[index]

def favicon(name, cls):
    text, color = identity(name)
    return (f'<span aria-hidden="true" class="inline-flex shrink-0 items-center justify-center {cls}">'
            f'<svg viewBox="0 0 16 16" class="size-full overflow-hidden rounded-[25%] font-mono select-none text-{color}-600 dark:text-{color}-400" '
            'style="background-color:color-mix(in srgb, currentColor 14%, transparent)">'
            f'<text x="8" y="10.8" text-anchor="middle" fill="currentColor" class="font-mono" font-size="8.25" font-weight="700" '
            f'textLength="{6 if len(text) == 1 else 12}" lengthAdjust="spacingAndGlyphs" text-rendering="geometricPrecision">{text}</text></svg></span>')

SIDEBAR_BOX = '<div data-app-sidebar="" class="bg-sidebar text-sidebar-foreground" style="width:240px;padding:8px">{}</div>'

# Sidebar.tsx:5554-5569.
NO_PROJECTS = ('<div class="flex flex-col items-center gap-2 px-2 py-6 text-center text-xs text-muted-foreground/60"><span>No projects yet</span>'
               '<button type="button" class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-sidebar-border px-2.5 py-1 text-2xs font-medium text-sidebar-muted-foreground transition-colors hover:bg-sidebar-row-hover hover:text-sidebar-foreground">'
               f'{lucide("plus", "-mx-0.5 size-3")}Add project</button></div>')

# Sidebar.tsx:1650-1663, the field alone at the title's width.
RENAME = ('<input value="Create a file named approval-demo.txt" aria-label="Thread title" style="width:204px;display:block" '
          'class="min-w-0 flex-1 rounded-sm border border-input bg-card px-1 text-sm font-medium text-card-foreground outline-none focus:border-foreground">')

# sidebar/SidebarProviderUpdatePill.tsx:140-205, at the footer's width.
PILL_TONES = {
    "warning": "bg-warning/12 text-warning group-has-[button[data-provider-update-main]:hover]/provider-update:bg-warning/18",
    "error": "bg-destructive/12 text-destructive group-has-[button[data-provider-update-main]:hover]/provider-update:bg-destructive/18",
}
def pill(tone, icon, title, dismissible):
    close = ('<button type="button" aria-label="Dismiss provider update notice" class="relative z-[1] mr-1 flex size-5 shrink-0 cursor-pointer items-center justify-center rounded-md opacity-70 outline-none hover:opacity-100 focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-ring">'
             f'{lucide("x", "size-3.5 shrink-0")}</button>') if dismissible else ""
    return (f'<div class="group/provider-update relative flex min-h-7 w-full shrink-0 items-center overflow-hidden rounded-lg text-2xs leading-4 font-medium transform-gpu will-change-transform {PILL_TONES[tone]} translate-y-0 opacity-100">'
            '<div class="pointer-events-none absolute inset-0 rounded-lg transition-colors"></div>'
            '<button type="button" data-provider-update-main="" class="relative z-[1] flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-left">'
            f'{lucide(icon, "size-3.5 shrink-0")}<span class="min-w-0 wrap-break-word">{title}</span></button>{close}</div>')

# ui/tooltip.tsx TooltipPopup (glass) with ThreadHoverCardPopup and ThreadHoverCard, rows from Sidebar.tsx:488-566.
POPUP = ("relative flex h-(--popup-height,auto) w-(--popup-width,auto) origin-(--transform-origin) text-balance rounded-md text-popover-foreground text-xs "
         "before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] dropdown-glass shadow-xl shadow-black/25 before:hidden "
         "max-w-80 wrap-anywhere whitespace-normal leading-snug text-left")
def card_row(icon_html, text):
    return f'<div class="flex min-w-0 items-center gap-2">{icon_html}<div class="min-w-0 truncate text-foreground/75">{text}</div></div>'
def hover_card(title, rows):
    return (f'<div class="{POPUP}"><div class="relative size-full overflow-clip px-(--viewport-inline-padding) py-1 [--viewport-inline-padding:--spacing(2)]">'
            '<div class="flex min-w-0 max-w-80 flex-col gap-2 px-1 py-2">'
            f'<div class="min-w-0 truncate text-xs leading-tight font-medium text-foreground">{title}</div>'
            f'<div class="grid gap-1.5 pl-0.5 text-xs text-muted-foreground">{"".join(rows)}</div></div></div></div>')
CARD = hover_card("Ship the sidebar virtualization", [
    card_row(favicon("candywrapper", "size-3"), "candywrapper"),
    card_row(lucide("server", "size-3 shrink-0 stroke-muted-foreground"), "This device"),
    '<div class="flex min-w-0 items-center gap-2">' + lucide("git-branch", "size-3 shrink-0 stroke-muted-foreground")
    + '<span class="inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap flex"><span class="min-w-0 truncate">m3-skeleton</span></span></div>',
    card_row(lucide("terminal", "size-3 shrink-0 text-teal-600 dark:text-teal-300/90"), "2 terminal processes running"),
])

# chat/ThreadContextDragGhost.tsx, out of its fixed positioning.
def ghost(title, count):
    more = f'<span class="shrink-0 rounded-full bg-muted px-1.5 text-xs text-secondary-label">+{count - 1}</span>' if count > 1 else ""
    return ('<div aria-hidden="true" class="pointer-events-none flex max-w-72 items-center gap-2 rounded-lg border bg-popover px-3 py-2 text-sm">'
            f'{lucide("messages-square", "size-4 shrink-0 text-secondary-label")}<span class="truncate">{title}</span>{more}</div>')

cases = []
def add(name, html, native, box=True, target=None):
    c = {"name": name, "html": SIDEBAR_BOX.format(html) if box else html, "wrapperStyle": "display:block" if box else "display:inline-block", "native": native}
    if target: c["stateTarget"] = target
    cases.append(c)

add("no-projects", NO_PROJECTS, {"kind": "no-projects"}, target="button")
add("rename", RENAME, {"kind": "rename"}, target="input")
add("pill.warning", pill("warning", "download", "Codex still needs an update", True), {"kind": "pill", "tone": "warning", "title": "Codex still needs an update"})
add("pill.error", pill("error", "triangle-alert", "Claude update failed", True), {"kind": "pill", "tone": "error", "title": "Claude update failed"})
add("hover-card", CARD, {"kind": "hover-card"}, box=False)
add("ghost", ghost("Ship the sidebar virtualization", 1), {"kind": "ghost", "count": "1"}, box=False)
add("ghost.many", ghost("Port the timestamp formatter", 3), {"kind": "ghost", "count": "3"}, box=False)

out = {"component": "sidebar-leftovers", "source": "apps/web/src/components/Sidebar.tsx", "states": ["rest", "hover", "focus-visible"],
       "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/sidebar-leftovers.json"), "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
print("sidebar-leftovers", len(cases), "cases")
