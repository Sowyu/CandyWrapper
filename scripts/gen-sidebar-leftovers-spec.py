# Reference stylesheet and component primitives: T3 Nightly 3814.
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
LUCIDE = os.path.expanduser("~/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons")

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

# sidebar/SidebarThreadRow.tsx:660-673 (4928, ThreadRenameInput), the field alone at the title's width.
RENAME = ('<input value="Create a file named approval-demo.txt" aria-label="Thread title" style="width:204px;display:block" '
          'class="-mx-1 min-w-0 flex-1 rounded-sm bg-card px-1 text-sm font-medium text-card-foreground outline-none ring-1 ring-inset ring-input focus:ring-foreground">')

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
# The thread hover card is a glass TooltipPopup (tooltip.tsx:136-156 at 4928).
POPUP = ("relative flex origin-(--transform-origin) rounded-md text-popover-foreground text-xs "
         "before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] dropdown-glass shadow-xl shadow-black/25 before:hidden "
         "max-w-80 wrap-anywhere whitespace-normal leading-snug text-left")
def card_row(icon_html, text):
    return f'<div class="flex min-w-0 items-center gap-2">{icon_html}<div class="min-w-0 truncate text-foreground/75">{text}</div></div>'
def hover_card(title, rows):
    return (f'<div class="{POPUP}"><div class="min-w-0 px-2 py-1" data-slot="tooltip-viewport">'
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

# A regenerating title at rest (SidebarThreadRow.tsx:1080-1112 at 4928): text-muted-foreground under an
# ActivityShimmerOverlay (chat/TimelineRowParts.tsx:46-65) whose live-activity-focus band rests left of the title
# (index.css:587-660), so the resting frame is the plain muted title.
GLIMMER = ('<div class="flex h-7 items-center"><span class="min-w-0 flex-1 text-start text-sm transition-opacity motion-reduce:transition-none font-medium relative truncate text-muted-foreground" dir="ltr">'
           'Regenerating the sidebar title'
           '<span aria-hidden="true" class="live-activity-focus pointer-events-none absolute inset-y-0 select-none"><span class="live-activity-focus-counter block">'
           '<span class="live-activity-focus-aligned block text-foreground truncate">Regenerating the sidebar title</span></span></span></span></div>')
add("title-glimmer", GLIMMER, {"kind": "glimmer", "title": "Regenerating the sidebar title"})

# The issue badge on a thread row (SidebarThreadRow.tsx:1167-1211 at 5258, #42275): a ThreadLinkBadge
# (ThreadStatusIndicators.tsx:509-543) in a default InlineButton (ui/button.tsx:103-120), the circle-dot IssueGlyph
# (issue/issuePresentation.tsx:12) and the key without its "#", both in the tone, before the detail loads.
INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring disabled:pointer-events-none disabled:opacity-64 "
          "text-foreground")
def issue_badge(label, icon, tone):
    return (f'<button type="button" data-slot="inline-button" class="{INLINE}" aria-label="{label}">'
            f'<span class="contents font-normal text-xs tabular-nums {tone}">' + lucide(icon, "size-3 shrink-0")
            + '<span class="max-w-16 truncate">128</span></span></button>')
add("issue-badge", f'<div class="flex h-7 items-center">{issue_badge("Issue #128: Sidebar badge", "circle-dot", "text-muted-foreground")}</div>',
    {"kind": "issue-badge", "key": "#128"})
# Once `issues.detail` answers, glyph and key take the state's icon and tone (issuePresentation.tsx:33-53, pullRequestIcons.tsx:34-55).
for state, icon, tone in [("open", "circle-dot", "text-emerald-600 dark:text-emerald-300/90"),
                          ("completed", "circle-check", "text-violet-600 dark:text-violet-300/90")]:
    add(f"issue-badge.{state}", f'<div class="flex h-7 items-center">{issue_badge(f"Issue #128: Sidebar badge, {state}", icon, tone)}</div>',
        {"kind": "issue-badge", "key": "#128", "state": state})

# SidebarProjectFolderHeader.tsx:65-109 (#21039): open and folded rows.
for expanded in [True, False]:
    meta = '' if expanded else '<span class="size-1.5 shrink-0 rounded-full bg-warning"></span><span class="shrink-0 text-xs tabular-nums text-sidebar-muted-foreground">3</span>'
    html = ('<div class="group/project-folder relative list-none"><button type="button" class="flex h-8 w-full cursor-pointer items-center gap-2.5 rounded-(--control-radius) px-(--sidebar-row-content-inset) text-left outline-none hover:bg-sidebar-row-hover focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring">'
            + favicon('candywrapper', 'size-4 shrink-0') + '<span class="min-w-0 flex-1 truncate text-sm font-medium text-sidebar-foreground/90">candywrapper</span>' + meta
            + lucide('chevron-down', 'size-3 shrink-0 text-sidebar-muted-foreground transition-transform' + ('' if expanded else ' -rotate-90')) + '</button></div>')
    add('folder.' + ('open' if expanded else 'closed'), html, {'kind': 'folder', 'expanded': str(expanded).lower()})

out = {"component": "sidebar-leftovers", "source": "apps/web/src/components/Sidebar.tsx", "states": ["rest", "hover", "focus-visible"],
       "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/sidebar-leftovers.json"), "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
print("sidebar-leftovers", len(cases), "cases")
