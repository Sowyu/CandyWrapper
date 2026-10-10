"""Writes design/component-reference/browser.json for scripts/component-reference: the built-in
browser's chrome row in the right panel's inline mode (PreviewChromeRow.tsx), the empty state with
and without discovered servers and recent URLs (PreviewEmptyState.tsx, PreviewLocalServerCard.tsx,
PreviewRecentUrlCard.tsx, BrowserMockup.tsx), the unreachable page (PreviewUnreachable.tsx), and
Search project contents (search/ProjectContentSearchDialog.tsx) in the command palette.

Class strings are copied from those files at the tag in T3_VERSION. The search rows use a .txt file,
which Shiki leaves in the theme's foreground, so no grammar is needed on either side.

Usage: /usr/bin/python3 -I scripts/gen-browser-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, stop):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    ns = {"__file__": os.path.join(ROOT, "scripts", name)}
    exec(src[:src.index(stop)], ns)
    return ns

files = load("gen-files-spec.py", "ROWS = [")
button, lucide, entry_icon = files["button"], files["lucide"], files["entry_icon"]
IG_BASE, IG_GHOST, INPUT_SM = (
    "relative inline-flex w-full min-w-0 items-center rounded-[var(--control-radius)] border text-base text-foreground ring-ring/24 transition-shadow sm:text-sm *:[[data-slot=input-control],[data-slot=textarea-control]]:contents",
    "border-transparent bg-transparent shadow-none hover:bg-muted/40 has-[input:focus-visible,textarea:focus-visible]:bg-background",
    "w-full min-w-0 rounded-[inherit] outline-none placeholder:text-placeholder h-7.5 px-[calc(--spacing(2.5)-1px)] leading-7.5 sm:h-6.5 sm:leading-6.5")
tog = load("gen-toggles-spec.py", "for size, title, desc in")
pal = load("gen-command-palette-spec.py", "cases = [")

W = 480

# --- Chrome row ---------------------------------------------------------------------------------
ROW = "flex h-10 min-h-10 shrink-0 items-center gap-1 border-b border-border/60 bg-background px-2 in-data-[preview-panel-mode=inline]:mb-3 in-data-[preview-panel-mode=inline]:h-7 in-data-[preview-panel-mode=inline]:min-h-7 in-data-[preview-panel-mode=inline]:border-b-transparent"
def icon_button(icon, label, disabled=False):
    b = button("ghost", "icon-xs", lucide(icon), label=label)
    return b.replace("<button ", "<button disabled ") if disabled else b
nav = ('<div class="flex items-center gap-0.5" role="group" aria-label="Navigation">'
       + icon_button("arrow-left", "Back") + icon_button("arrow-right", "Forward", disabled=True) + icon_button("refresh-cw", "Refresh") + "</div>")
address = (f'<div class="{IG_BASE} {IG_GHOST} group/address h-7 flex-1" data-slot="input-group" role="group">'
           f'<span data-size="sm" data-slot="input-control"><input class="{INPUT_SM}" data-slot="input" placeholder="Search or enter URL" value="http://localhost:47420/"></span></div>')
chrome = (f'<div data-preview-panel-mode="inline" style="width:{W}px" class="bg-background"><div class="relative"><form class="{ROW}">'
          + nav + address + icon_button("picture-in-picture-2", "Float preview over chat") + icon_button("ellipsis-vertical", "Preview menu")
          + "</form></div></div>")

# --- Empty states -------------------------------------------------------------------------------
E_BASE = "flex min-w-0 flex-1 flex-col items-center justify-center text-balance text-center"
E_DEFAULT = "gap-6 p-6 md:p-12"
empty = (f'<div style="width:{W}px;height:360px" class="flex bg-background"><div data-slot="empty" class="{E_BASE} {E_DEFAULT}">'
         '<div data-slot="empty-header" class="flex max-w-sm flex-col items-center text-center">'
         f'<div class="relative mb-6" data-slot="empty-media" data-variant="icon"><div aria-hidden="true" class="{tog["left"]}"></div>'
         f'<div aria-hidden="true" class="{tog["right"]}"></div><div class="{tog["media"]}">{lucide("globe", "size-4.5 text-muted-foreground")}</div></div>'
         '<div class="font-semibold text-xl" data-slot="empty-title">No preview yet</div>'
         '<div class="text-muted-foreground text-sm [[data-slot=empty-title]+&]:mt-1" data-slot="empty-description">Type a URL above, or run a dev script. Browser-ready localhost servers will show up here automatically.</div>'
         "</div></div></div>")

MOCKUP = ('<div aria-hidden class="relative flex flex-col gap-0.5 overflow-hidden rounded-sm border border-border/60 bg-card p-1 shadow-xs/5 size-7 shrink-0">'
          '<div class="flex gap-0.5"><span class="size-[3px] rounded-full bg-destructive/80"></span><span class="size-[3px] rounded-full bg-warning/80"></span>'
          '<span class="size-[3px] rounded-full bg-success/80"></span></div><div class="mt-[1px] flex flex-1 flex-col gap-0.5">'
          '<span class="h-[2px] w-full rounded-full bg-muted-foreground/30"></span><span class="h-[2px] w-3/5 rounded-full bg-muted-foreground/20"></span></div></div>')
LIST = "flex flex-col divide-y divide-border/60 overflow-hidden rounded-xl border border-border/70 bg-background"
ROW_BTN = "group flex w-full items-center gap-3 px-3 py-3 text-left hover:bg-accent/40"
def server_row(title, detail):
    return (f'<button type="button" class="{ROW_BTN}">{MOCKUP}<div class="flex min-w-0 flex-1 flex-col">'
            f'<span class="truncate text-sm font-medium text-foreground">{title}</span><span class="truncate text-xs text-muted-foreground">{detail}</span></div></button>')
def recent_row(title, detail):
    return ('<div class="group relative flex w-full items-center"><button type="button" class="flex w-full items-center gap-3 px-3 py-3 pr-10 text-left hover:bg-accent/40">'
            f'{MOCKUP}<div class="flex min-w-0 flex-1 flex-col"><span class="truncate text-sm font-medium text-foreground">{title}</span>'
            f'<span class="truncate text-xs text-muted-foreground">{detail}</span></div></button>'
            f'<button type="button" class="absolute right-3 rounded p-1 text-muted-foreground opacity-0">{lucide("x", "size-3.5")}</button></div>')
def section(icon, title, rows, note=None):
    out = (f'<div class="flex flex-col gap-3"><div class="flex items-center gap-2 text-sm text-muted-foreground">{lucide(icon, "size-4 shrink-0")}'
           f'<h2 class="font-medium">{title}</h2></div><div class="{LIST}">{rows}</div>')
    if note: out += f'<p class="px-1 text-xs text-muted-foreground">{note}</p>'
    return out + "</div>"
lists = (f'<div style="width:{W}px;height:520px" class="flex bg-background"><div class="scrollbar-gutter-both flex h-full min-h-0 w-full overflow-y-auto px-5 py-8">'
         '<div class="mx-auto flex w-full max-w-xl flex-col gap-6">'
         + section("history", "Recently used", recent_row("Candy test page", "localhost:47420 · 5m ago") + recent_row("example.com/docs", "2h ago"))
         + section("radio-tower", "Local servers", server_row("Python", "localhost:47420") + server_row("Listening", "localhost:5173"),
                   "Select a live local server to open it in this browser tab.")
         + "</div></div></div>")

# --- Unreachable --------------------------------------------------------------------------------
ERROR_ICON = ('<svg viewBox="0 0 64 64" fill="none" stroke="currentColor" stroke-width="2.5" class="mb-6 size-12 text-muted-foreground/70">'
              '<path d="M16 12 L48 12 L48 52 L16 52 Z"></path><path d="M22 22 L42 22 M22 30 L36 30 M22 38 L40 38" stroke-linecap="round"></path>'
              '<path d="M52 8 L12 56" stroke-linecap="round"></path></svg>')
unreachable = (f'<div style="width:{W}px;height:480px" class="flex bg-background"><div class="scrollbar-gutter-both relative flex h-full min-h-0 w-full overflow-y-auto bg-background">'
               f'<div class="mx-auto flex w-full max-w-xl flex-1 flex-col px-8 py-12 sm:py-16">{ERROR_ICON}'
               '<h1 class="mb-3 text-2xl font-semibold leading-tight text-foreground">This site can&rsquo;t be reached</h1>'
               '<p class="text-sm leading-relaxed text-muted-foreground"><span class="font-semibold text-foreground">localhost:47421</span>: Connection refused.</p>'
               '<div class="mt-8 text-xs uppercase tracking-wide text-muted-foreground/70">ERR_CONNECTION_REFUSED</div>'
               '<div class="mt-auto flex items-center gap-2 pt-8">' + button("outline", "sm", "Details") + '<div class="flex-1"></div>'
               + button("default", "sm", "Reload") + "</div></div></div></div>")

# --- Search project contents --------------------------------------------------------------------
def option(label):
    cls = tog["merge"](f'{tog["T_BASE"]} {tog["T_SIZES"]["segmented"]} {tog["T_VARIANTS"]["segmented"]}')
    return f'<button type="button" data-slot="toggle" aria-pressed="false" class="{cls}"><span class="font-mono">{label}</span></button>'
accessory = ('<div class="absolute inset-e-2.5 top-1/2 flex shrink-0 -translate-y-1/2 items-center gap-0.5 rounded-md border bg-muted/30 p-0.5">'
             + option("Aa") + option('<span class="underline decoration-2 underline-offset-2">ab</span>') + option(".*") + "</div>")
inp = pal["input_row"]("Search in demo-repo", "notes", False)
inp = inp.replace('data-slot="autocomplete-input"', 'data-slot="autocomplete-input" style="padding-inline-end:7.5rem"', 1)
inp = inp[:-len("</div>")] + accessory + "</div>"
CODE = "<style>.code{color:#0a0a0a}.dark .code{color:#fafafa}</style>"
def mark(t): return f'<mark class="rounded-xs bg-primary/25 text-inherit">{t}</mark>'
def match_row(n, html, active=False):
    cls = "flex h-7 w-full min-w-0 items-center gap-3 px-3 text-left font-mono text-xs hover:bg-accent/60" + (" bg-accent text-accent-foreground" if active else "")
    return (f'<button type="button" class="{cls}"><span class="w-10 shrink-0 text-right tabular-nums text-muted-foreground/70">{n}</span>'
            f'<span class="code min-w-0 flex-1 truncate whitespace-pre">{html}</span></button>')
def group(path, name, folder, rows):
    head = (f'<div class="sticky top-0 z-10 flex h-8 items-center gap-2 bg-popover/95 px-3 text-xs backdrop-blur-sm">{entry_icon(path, "size-3.5")}'
            f'<span class="font-medium text-foreground">{name}</span><span class="min-w-0 truncate text-muted-foreground">{folder}</span>'
            f'<span class="ml-auto rounded-full bg-muted px-1.5 py-0.5 tabular-nums text-3xs text-muted-foreground">{len(rows)}</span></div>')
    return f'<section class="pb-2">{head}{"".join(rows)}</section>'
body = ('<div class="flex h-9 shrink-0 items-center border-b px-3 text-xs text-muted-foreground">3 results in 2 files</div>'
        '<div class="min-h-0 flex-1 overflow-hidden"><div class="py-2">'
        + group("docs/notes.txt", "notes.txt", "docs", [match_row(1, f"Release {mark('notes')} for the demo", True),
                                                        match_row(4, f"See the {mark('notes')} folder.")])
        + group("todo.txt", "todo.txt", "", [match_row(2, f"- write {mark('notes')}")])
        + "</div></div>")
def footer():
    def hint(keys, text):
        inner = "".join('<kbd data-slot="kbd" class="' + pal["KBD"] + '">' + k + "</kbd>" for k in keys)
        return f'<kbd data-slot="kbd-group" class="inline-flex items-center gap-1">{inner}<span>{text}</span></kbd>'
    hints = hint([lucide("arrow-up"), lucide("arrow-down")], "Navigate") + hint(["Enter"], "Open file") + hint(["Esc"], "Back")
    return f'<div class="{pal["FOOTER"]}" data-slot="command-footer"><div class="flex items-center gap-3">{hints}</div></div>'
search = (f'<div role="dialog" data-slot="command-dialog-popup" class="{pal["POPUP"]} overflow-hidden h-105">{CODE}{inp}'
          '<div class="relative min-h-0 overflow-hidden rounded-t-xl bg-transparent flex min-h-0 flex-1 flex-col">' + body + "</div>" + footer() + "</div>")

cases = [
    {"name": "chrome", "html": chrome, "native": {"case": "chrome"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "empty", "html": empty, "native": {"case": "empty"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "lists", "html": lists, "native": {"case": "lists"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "unreachable", "html": unreachable, "native": {"case": "unreachable"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "search", "html": search, "native": {"case": "search"}, "wrapperStyle": "display:block;width:576px"},
]
spec = {"component": "browser", "source": "apps/web/src/components/preview/, components/search/ProjectContentSearchDialog.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/browser.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
