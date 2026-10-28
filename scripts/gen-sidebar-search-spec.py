"""Writes design/component-reference/sidebar-search.json for scripts/component-reference: the sidebar's search
result rows, draft rows, status lines and the project scope popup.

Class strings are copied from apps/web/src/components/Sidebar.tsx, ThreadSearchMatch.tsx, ProjectMonogram.tsx and
ui/combobox.tsx, ui/input.tsx at the tag in T3_VERSION. Row cases sit in a `data-app-sidebar` box with `bg-sidebar`
and 8px padding, as in a SidebarGroup; the popup sits on the page's --background like a portal.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-search-spec.py
"""
import json, os

def svg(inner, cls=""):
    c = f' class="{cls}"' if cls else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"{c}>{inner}</svg>')

SQUARE_PEN = ('<path d="M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path>'
              '<path d="M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z"></path>')
X = '<path d="M18 6 6 18"></path><path d="m6 6 12 12"></path>'
SEARCH = '<path d="m21 21-4.34-4.34"></path><circle cx="11" cy="11" r="8"></circle>'
FOLDER = '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path>'
SETTINGS = ('<path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 '
            '2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 '
            '2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"></path><circle cx="12" cy="12" r="3"></circle>')

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

def favicon(name, cls="size-4 shrink-0"):
    text, color = identity(name)
    return (f'<span aria-hidden="true" class="inline-flex size-4 shrink-0 items-center justify-center {cls}">'
            f'<svg viewBox="0 0 16 16" class="size-full overflow-hidden rounded-[25%] font-mono select-none text-{color}-600 dark:text-{color}-400" '
            'style="background-color:color-mix(in srgb, currentColor 14%, transparent)">'
            f'<text x="8" y="10.8" text-anchor="middle" fill="currentColor" class="font-mono" font-size="8.25" font-weight="700" '
            f'textLength="{6 if len(text) == 1 else 12}" lengthAdjust="spacingAndGlyphs" text-rendering="geometricPrecision">{text}</text></svg></span>')

SIDEBAR_BOX = '<div data-app-sidebar="" class="bg-sidebar text-sidebar-foreground" style="width:240px;padding:8px">{}</div>'

# Sidebar.tsx:2316-2365 (SidebarSearchResultRow) with ThreadSearchMatch.tsx:51-66.
def search_row(title, time, highlighted=False, match=None):
    cls = "flex min-h-9 w-full cursor-pointer items-center gap-2.5 rounded-md px-2.5 py-1 text-left text-sm outline-none " + (
        "bg-sidebar-row-active text-sidebar-foreground" if highlighted
        else "text-sidebar-muted-foreground/75 hover:bg-sidebar-row-hover hover:text-sidebar-foreground")
    excerpt = ""
    if match:
        source, before, hit, after = match
        tag = ('<span class="text-info-foreground">You:</span>' if source == "user"
               else '<span class="text-success-foreground">Agent:</span>')
        excerpt = (f'<span class="truncate text-xs text-muted-foreground/85">{tag} {before}'
                   f'<mark class="bg-transparent font-semibold text-foreground">{hit}</mark>{after}</span>')
    return (f'<ul class="flex flex-col gap-px"><li role="presentation" class="list-none"><button type="button" role="option" class="{cls}">'
            f'{favicon("demo-repo")}<span class="flex min-w-0 flex-1 flex-col"><span class="flex min-w-0 items-center gap-2.5">'
            f'<span class="min-w-0 flex-1 truncate">{title}</span>'
            f'<span class="shrink-0 text-xs text-muted-foreground/55 tabular-nums">{time}</span></span>{excerpt}</span></button></li></ul>')

# Sidebar.tsx:900-948 (SidebarDraftRow) and 1059-1063 (divider).
def draft_row(project, preview, active=False, divider=False):
    surface = "bg-sidebar-row-active" if active else "bg-warning/4 hover:bg-warning/8"
    row = (f'<li class="list-none py-0.5"><div role="button" tabindex="0" data-testid="sidebar-draft-row" '
           f'class="group/sidebar-row relative w-full cursor-pointer overflow-hidden rounded-md text-left text-sidebar-foreground outline-none select-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring {surface}">'
           f'<span class="sr-only">{preview}</span>'
           '<div class="relative z-10 h-[4.875rem] px-(--sidebar-row-content-inset) py-(--sidebar-content-inset)">'
           '<div class="flex h-5 min-w-0 items-center gap-1.5">'
           f'{svg(SQUARE_PEN, "size-3 shrink-0 text-warning-foreground")}{favicon(project)}'
           f'<span class="min-w-0 flex-1 truncate text-xs font-medium text-secondary-label">{project}</span>'
           '<span class="ml-auto flex h-5 min-w-5 shrink-0 items-center justify-end">'
           '<button type="button" aria-label="Discard draft" class="pointer-events-none inline-flex cursor-pointer items-center rounded-md bg-transparent px-1 text-muted-foreground opacity-0 transition-opacity hover:text-foreground focus-visible:pointer-events-auto focus-visible:opacity-100 group-hover/sidebar-row:pointer-events-auto group-hover/sidebar-row:opacity-100">'
           f'{svg(X, "size-3")}</button></span></div>'
           f'<div aria-hidden="true" class="mt-0.5 truncate text-sm font-medium text-foreground/90">{preview}</div></div></div></li>')
    div = '<li aria-hidden="true" data-testid="sidebar-draft-divider" class="mx-2.5 my-1.5 h-px list-none bg-sidebar-border/60"></li>' if divider else ""
    return f'<ul class="flex flex-col gap-px">{row}{div}</ul>'

def status(text, search):
    if search:
        return f'<p role="status" class="px-2 py-6 text-center text-xs text-sidebar-muted-foreground">{text}</p>'
    return f'<div class="flex flex-col items-center gap-2 px-2 py-6 text-center text-xs text-muted-foreground/60">{text}</div>'

# The scope popup (Sidebar.tsx:5035-5120) built from combobox.tsx:109-237 and input.tsx, at a fixed 200px width.
ITEM = "flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none not-data-disabled:hover:bg-foreground/[0.09] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-selected:bg-foreground/[0.06] data-selected:text-foreground data-highlighted:bg-foreground/[0.09] data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-foreground/[0.09] [&[data-highlighted][data-selected]]:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
# button.tsx base + ghost-muted + icon-xs (as in scripts/gen-button-spec.py), then the row's `ml-auto`.
GHOST_MUTED_ICON_XS = ("[--control-icon-color:currentColor] [&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 whitespace-nowrap rounded-[var(--control-radius)] border font-medium text-base outline-none transition-[box-shadow,scale] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background sm:text-sm [&_svg:not([class*='text-'])]:text-[var(--control-icon-color)] [&_svg]:pointer-events-none [&_svg]:shrink-0 "
                       "border-transparent text-muted-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-foreground "
                       "size-7 sm:size-6 not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-4 sm:not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-3.5 ml-auto")
INPUT = "h-7.5 w-full min-w-0 rounded-[inherit] px-[calc(--spacing(2.5)-1px)] leading-7.5 outline-none placeholder:text-placeholder sm:h-6.5 sm:leading-6.5 [transition:background-color_5000000s_ease-in-out_0s]"

def scope_item(label, project=None, selected=False, highlighted=False):
    attrs = (' data-selected=""' if selected else "") + (' data-highlighted=""' if highlighted else "")
    icon = favicon(project, "size-4 shrink-0") if project else svg(FOLDER, "size-4 shrink-0")
    if selected:
        icon = ('<span class="relative flex shrink-0">' + icon + '<span class="pointer-events-none absolute -right-1 -bottom-1 grid size-3 place-items-center rounded-full bg-primary ring-2 ring-popover">'
                + svg('<path d="M20 6 9 17l-5-5"></path>', 'size-2 text-primary-foreground').replace('stroke-width="2"', 'stroke-width="4"') + '</span></span>')
    settings = (f'<button type="button" tabindex="-1" aria-hidden="true" class="{GHOST_MUTED_ICON_XS}">{svg(SETTINGS, "size-3.5")}</button>'
                if project else "")
    return (f'<div role="option" data-slot="combobox-item" class="{ITEM}"{attrs}>'
            '<div class="flex min-w-0 flex-1 items-center gap-2 [&_svg:not([class*=\'text-\'])]:text-muted-foreground" data-slot="combobox-item-content">'
            f'{icon}<span class="min-w-0 flex-1 truncate text-sm">{label}</span>{settings}</div></div>')

def scope_popup(query, items):
    search = ('<div class="min-w-0 shrink-0 px-3 pt-2.5"><div class="relative -translate-y-px border-b border-border/70 pb-1.5 transition-colors focus-within:border-ring">'
              f'{svg(SEARCH, "pointer-events-none absolute top-1.5 left-0 size-4 shrink-0 text-muted-foreground/55")}'
              '<div class="relative not-has-[>*.w-full]:w-fit w-full text-foreground has-disabled:opacity-64 [&_input]:h-6.5 [&_input]:ps-5 [&_input]:font-sans [&_input]:leading-6.5">'
              '<span class="rounded-none bg-transparent text-sm" data-size="sm" data-slot="input-control">'
              f'<input class="{INPUT}" data-slot="input" placeholder="Search projects..." value="{query}"></span></div></div></div>')
    body = "".join(items) if items else ""
    lst = (f'<div class="not-empty:scroll-py-1 not-empty:px-1 not-empty:py-1" data-slot="combobox-list">{body}</div>' if items
           else '<div class="not-empty:p-2 text-center text-base text-muted-foreground sm:text-sm" data-slot="combobox-empty">No matching projects.</div>')
    return ('<span class="dropdown-glass relative flex max-h-full origin-(--transform-origin) rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)] max-w-[min(18rem,var(--available-width))] overflow-hidden" style="width:200px">'
            f'<div class="flex min-w-0 max-h-[min(var(--available-height),23rem)] flex-1 flex-col overflow-hidden text-foreground" data-slot="combobox-popup">{search}{lst}</div></span>')

cases = []
def add(name, html, native, box=True, target=None):
    c = {"name": name, "html": SIDEBAR_BOX.format(html) if box else html, "wrapperStyle": "display:block" if box else "display:inline-block", "native": native}
    if target: c["stateTarget"] = target
    cases.append(c)

add("result", search_row("Reply with markdown containing a table", "18m"), {"kind": "result", "title": "Reply with markdown containing a table", "time": "18m"}, target="button")
add("result.highlighted", search_row("Reply with markdown containing a table", "18m", highlighted=True),
    {"kind": "result", "title": "Reply with markdown containing a table", "time": "18m", "highlighted": "true"})
add("result.user-match", search_row("Plan a migration", "16m", match=("user", "move the ", "zero trust", " policies")),
    {"kind": "result", "title": "Plan a migration", "time": "16m", "source": "user", "snippet": "move the zero trust policies", "query": "zero trust"}, target="button")
add("result.agent-match", search_row("Write a story", "2m", highlighted=True, match=("assistant", "The ", "lighthouse", " keeper climbed")),
    {"kind": "result", "title": "Write a story", "time": "2m", "source": "assistant", "snippet": "The lighthouse keeper climbed",
     "query": "lighthouse", "highlighted": "true"})
add("draft", draft_row("demo-repo", "Add a dark mode toggle to the settings page", divider=True),
    {"kind": "draft", "project": "demo-repo", "preview": "Add a dark mode toggle to the settings page", "divider": "true"}, target="[data-testid=sidebar-draft-row]")
add("draft.active", draft_row("demo-repo", "Add a dark mode toggle", active=True),
    {"kind": "draft", "project": "demo-repo", "preview": "Add a dark mode toggle", "active": "true"})
add("status.search", status("No threads found", True), {"kind": "status", "text": "No threads found", "search": "true"})
add("status.empty", status("No threads in demo-repo yet", False), {"kind": "status", "text": "No threads in demo-repo yet"})
add("scope.all", scope_popup("", [scope_item("All projects", selected=True), scope_item("demo-repo", "demo-repo", highlighted=True),
                                  scope_item("candywrapper", "candywrapper")]),
    {"kind": "scope", "query": "", "selected": "", "highlighted": "1"}, box=False)
add("scope.empty", scope_popup("zzz", []), {"kind": "scope", "query": "zzz", "selected": ""}, box=False)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = {"component": "sidebar-search", "source": "apps/web/src/components/Sidebar.tsx", "states": ["rest", "hover"],
       "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(root, "design/component-reference/sidebar-search.json"), "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
print("sidebar-search", len(cases), "cases")
