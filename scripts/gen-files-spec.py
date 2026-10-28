"""Writes design/component-reference/files.json for scripts/component-reference: the right panel's
tab strip (RightPanelTabs.tsx:1097-1262), the surface launcher (`RightPanelEmptyState`), the Files
surface (FileBrowserPanel.tsx:492-573) and a file tab's subheader (FilePreviewPanel.tsx:1225-1300,
FileBreadcrumbs.tsx), all in the panel's inline mode (`data-preview-panel-mode="inline"`).

Class strings are copied from those files at Nightly 3824 (CANDY_T3_SOURCE selects the source tree). The tree is @pierre/trees: its
stylesheet comes from T3's client bundle (the `@layer base` literal in fileTreeExpansion-*.js) with
T3's PIERRE_TREE_UNSAFE_CSS and host variables, in a shadow root like the library's; the row markup
copies the library's sections (`[spacing][icon][content]`, data attributes from the bundle's row
renderer). File icons are T3's sprite symbols (pierre-icons-*.js).

Usage: /usr/bin/python3 -I scripts/gen-files-spec.py
"""
import glob, json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or "/Users/mrm/CandyWrapper-research"
T3 = os.environ.get("CANDY_T3_SOURCE") or os.path.join(RESEARCH, "t3code/apps/web/src")

def source_file(relative):
    """Read the design tag without changing the shared checkout."""
    if os.environ.get("CANDY_T3_SOURCE"):
        return open(os.path.join(os.environ["CANDY_T3_SOURCE"], relative)).read()
    return subprocess.check_output(["git", "-C", os.path.expanduser("~/CandyWrapper-research/t3code"), "show",
        "v0.1.4-nightly.20261028.3824:apps/web/src/" + relative], text=True)
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")
ASSETS = os.path.join(RESEARCH, "t3-client-assets")

src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
ns = {}
exec(src[:src.index("PLUS = (")], ns)
merge = ns["merge"]

def button(variant, size, inner, extra="", label=""):
    cls = merge(f'{ns["BASE"]} {ns["VARIANTS"][variant]} {ns["SIZES"][size]} {extra}')
    return f'<button type="button" data-slot="button" aria-label="{label}" class="{cls}">{inner}</button>'

tsrc = open(os.path.join(ROOT, "scripts/gen-toggles-spec.py")).read()
# The toggles spec's own tailwind-merge (it knows the `data-pressed` group).
tns = {}
exec(tsrc[:tsrc.index("def toggle")], tns)

def toggle(icon, pressed):
    cls = tns["merge"](f'{tns["T_BASE"]} {tns["T_SIZES"]["sm"]} {tns["T_VARIANTS"]["ghost"]} shrink-0')
    attrs = ' data-pressed="" aria-pressed="true"' if pressed else ' aria-pressed="false"'
    return f'<button type="button" data-slot="toggle" data-size="sm" data-variant="ghost"{attrs} class="{cls}">{icon}</button>'

def lucide(name, cls=""):
    s = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", s[s.index(">", s.index("<svg")) + 1:s.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

# T3's sprite: `file-tree-builtin-<token>` symbols and the tree chevron.
sprite = open(glob.glob(os.path.join(ASSETS, "pierre-icons-*.js"))[0], encoding="utf-8").read()
def symbol(sym_id):
    m = re.search(r'<symbol id="' + re.escape(sym_id) + r'" viewBox="([^"]*)">(.*?)</symbol>', sprite, re.S)
    return m.group(1), re.sub(r"\s+", " ", m.group(2)).strip()

# PierreEntryIcon's colors (light, dark) per token.
entry = source_file("components/chat/PierreEntryIcon.tsx")
COLORS = {m.group(1): (m.group(2), m.group(3)) for m in re.finditer(r'(\w+): \["(#[0-9a-f]{6})", "(#[0-9a-f]{6})"\]', entry)}
TOKENS = {"ts": "typescript", "py": "python", "md": "markdown", "txt": "text", "swift": "swift"}

def entry_icon(path, cls="size-3"):
    token = TOKENS.get(path.rsplit(".", 1)[-1], "default")
    box, body = symbol("file-tree-builtin-" + token)
    light, dark = COLORS.get(token, COLORS["default"])
    # Tailwind only has the classes T3 uses, so the theme colors come from a small style rule.
    return (f'<style>.pi-{token}{{color:{light}}}.dark .pi-{token}{{color:{dark}}}</style>'
            f'<svg aria-hidden="true" class="{cls} shrink-0 pi-{token}" viewBox="{box}" fill="currentColor">{body}</svg>')

# --- Pierre tree --------------------------------------------------------------------------------
bundle = open(glob.glob(os.path.join(ASSETS, "fileTreeExpansion-*.js"))[0], encoding="utf-8").read()
def literal(start):
    j, out = start + 1, []
    while bundle[j] != "`":
        if bundle[j] == "\\":
            out.append(bundle[j + 1]); j += 2; continue
        out.append(bundle[j]); j += 1
    return "".join(out)
TREE_CSS = literal(bundle.index("`@layer base {\n  :host {\n    --trees-accent"))
theme = source_file("pierre-tree-theme.ts")
UNSAFE = theme[theme.index("PIERRE_TREE_UNSAFE_CSS = `") + len("PIERRE_TREE_UNSAFE_CSS = `"):]
UNSAFE = UNSAFE[:UNSAFE.index("`;")]
CHEVRON_BOX, CHEVRON = symbol("file-tree-icon-chevron")

def tree_row(path, label, kind, depth, expanded=False):
    spacing = ("" if depth == 0 else '<div data-item-section="spacing">' +
               "".join(f'<div data-item-section="spacing-item"></div>' for _ in range(depth)) + "</div>")
    if kind == "folder":
        icon = f'<svg data-icon-name="file-tree-icon-chevron" data-align-capitals="false" width="16" height="16" viewBox="{CHEVRON_BOX}">{CHEVRON}</svg>'
        attrs = f' data-item-type="folder" aria-expanded="{"true" if expanded else "false"}"'
    else:
        token = TOKENS.get(path.rsplit(".", 1)[-1], "default")
        box, body = symbol("file-tree-builtin-" + token)
        icon = f'<svg data-icon-name="file-tree-builtin-{token}" data-icon-token="{token}" width="16" height="16" viewBox="{box}" fill="currentColor">{body}</svg>'
        attrs = ' data-item-type="file"'
    return (f'<button data-type="item" data-item-path="{path}"{attrs} role="treeitem" tabindex="-1" style="min-height:24px">'
            f'{spacing}<div data-item-section="icon">{icon}</div><div data-item-section="content">{label}</div></button>')

ROWS = [tree_row("scratch/", "scratch", "folder", 0, True), tree_row("scratch/edit.swift", "edit.swift", "file", 1),
        tree_row("scratch/notes.md", "notes.md", "file", 1), tree_row("src/", "src", "folder", 0),
        tree_row("hello.py", "hello.py", "file", 0), tree_row("notes.md", "notes.md", "file", 0),
        tree_row("README.md", "README.md", "file", 0)]
TREE = ('<div role="tree" data-file-tree-virtualized-root="true" data-file-tree-colored-icons="true" style="outline:none;position:relative">'
        '<div data-file-tree-virtualized-scroll="true"><div data-file-tree-virtualized-list="true">' + "".join(ROWS) + "</div></div></div>")
SHADOW = f"<style>{TREE_CSS}</style><style>@layer unsafe {{{UNSAFE}}}</style>{TREE}"

# --- Files surface ------------------------------------------------------------------------------
IG_BASE = "relative inline-flex w-full min-w-0 items-center rounded-[var(--control-radius)] border text-base text-foreground ring-ring/24 transition-shadow sm:text-sm *:[[data-slot=input-control],[data-slot=textarea-control]]:contents"
IG_GHOST = "border-transparent bg-transparent shadow-none hover:bg-muted/40 has-[input:focus-visible,textarea:focus-visible]:bg-background"
INPUT_SM = "w-full min-w-0 rounded-[inherit] outline-none placeholder:text-placeholder h-7.5 px-[calc(--spacing(2.5)-1px)] leading-7.5 sm:h-6.5 sm:leading-6.5"
SEARCH = (f'<div class="{IG_BASE} {IG_GHOST} h-7 min-w-0 flex-1" data-slot="input-group" role="group">'
          f'<span data-size="sm" data-slot="input-control"><input class="{INPUT_SM}" data-slot="input" type="search" placeholder="Search files"></span></div>')
W, H = 480, 236
files = (f'<div data-preview-panel-mode="inline" style="width:{W}px;height:{H}px" class="flex flex-col bg-background">'
         '<div class="flex min-h-0 flex-1 flex-col bg-background">'
         '<div class="flex h-10 min-h-10 shrink-0 items-center gap-1 border-b border-border/60 bg-background px-2 in-data-[preview-panel-mode=inline]:mb-1 in-data-[preview-panel-mode=inline]:h-9 in-data-[preview-panel-mode=inline]:min-h-9 in-data-[preview-panel-mode=inline]:border-b-transparent">'
         + button("ghost", "icon-xs", lucide("refresh-cw"), label="Refresh workspace files") + SEARCH
         + button("ghost", "icon-xs", lucide("chevrons-up-down", "size-3.5"), label="Expand all folders")
         + '</div><div class="min-h-0 flex-1 overflow-hidden" data-tree-host style="color-scheme:inherit;--trees-fg-override:var(--contrast-foreground);--trees-item-height:24px;--trees-density-override:0.8">'
         + f'<template>{SHADOW}</template></div></div></div>')

# --- Tab strip ----------------------------------------------------------------------------------
TAB = "cursor-pointer group/tab flex h-6 max-w-36 shrink-0 items-center gap-0.5 rounded-md pr-2 pl-1.5 text-xs"
def tab(title, icon, active):
    state = "bg-accent text-foreground" if active else "text-muted-foreground hover:bg-accent/60 hover:text-foreground"
    close = ('<button type="button" class="cursor-pointer group/close relative flex size-4 shrink-0 items-center justify-center rounded-sm hover:bg-muted">'
             f'<span class="relative flex size-3 items-center justify-center group-hover/tab:hidden group-focus-visible/close:hidden">{icon}</span>'
             + lucide("x", "hidden size-3 group-hover/tab:block group-focus-visible/close:block") + "</button>")
    return (f'<div data-active-tab="{str(active).lower()}" class="{TAB} {state}">{close}'
            f'<button type="button" class="cursor-pointer flex min-w-0 items-center"><span class="truncate">{title}</span></button></div>')
tabs = (f'<div style="width:{W}px" class="bg-background"><div class="flex shrink-0 items-center gap-1 pl-2 pr-28" style="height:52px">'
        '<div class="min-w-0 flex-1"><div class="flex h-full w-max min-w-full items-center gap-1">'
        + tab("Diff", lucide("file-diff", "size-3 shrink-0"), False) + tab("answer.ts", entry_icon("src/answer.ts"), True)
        + tab("Files", lucide("files", "size-3 shrink-0"), False)
        + button("ghost-muted", "icon-xs", lucide("plus", "size-3.5"), "shrink-0", "Add panel surface")
        + "</div></div></div></div>")

# --- File subheader -----------------------------------------------------------------------------
SUB = "flex h-10 min-h-10 shrink-0 items-center gap-2 border-b border-border/60 bg-background px-3 in-data-[preview-panel-mode=inline]:mb-3 in-data-[preview-panel-mode=inline]:h-7 in-data-[preview-panel-mode=inline]:min-h-7 in-data-[preview-panel-mode=inline]:border-b-transparent"
CHEV = lucide("chevron-right", "mx-1 size-3.5 shrink-0 text-muted-foreground/60")
def crumb(label, current=False, first=False):
    if current:
        inner = f'<span aria-current="page"><span class="block max-w-40 truncate rounded-sm px-0.5 font-medium text-foreground">{label}</span></span>'
    else:
        inner = (f'<button type="button" class="relative block max-w-40 cursor-pointer rounded-sm px-0.5 text-left text-muted-foreground outline-none">'
                 f'<span class="block max-w-40 truncate rounded-sm px-0.5 text-muted-foreground">{label}</span></button>')
    return f'<div class="flex min-w-0 shrink-0 items-center">{"" if first else CHEV}{inner}</div>'
header = (f'<div data-preview-panel-mode="inline" style="width:{W}px" class="flex flex-col bg-background"><div class="{SUB}">'
          '<div class="min-w-0 flex-1"><div class="flex h-full w-max min-w-full items-center text-xs">'
          + crumb("demo-repo", first=True) + crumb("src") + crumb("answer.ts", current=True) + "</div></div>"
          + toggle(lucide("wrap-text", "size-3.5"), True) + toggle(lucide("folder-tree", "size-3.5"), True) + "</div></div>")

# --- Launcher -----------------------------------------------------------------------------------
KBD = "pointer-events-none inline-flex h-5 min-w-5 select-none items-center justify-center gap-1 rounded bg-muted px-1 font-medium font-sans text-muted-foreground text-xs [&_svg:not([class*='size-'])]:size-3"
ACTIONS = [("Browser", "earth", "B", False), ("Terminal", "square-terminal", "T", False), ("Files", "files", "F", True),
           ("Diff", "file-diff", "D", True), ("Pull request", "git-pull-request", "P", False), ("Linked pull requests", "link", "L", False),
           ("Device", "smartphone", "M", False)]
def launcher_row(label, icon, key, available):
    icon_html = f'<span class="relative inline-flex shrink-0">{lucide(icon, "size-4")}</span>'
    body = f'{icon_html}<span class="min-w-0 flex-1 truncate">{label}</span><kbd class="{KBD}" data-slot="kbd">{key}</kbd>'
    if available:
        return (f'<div class="group relative"><button type="button" class="flex h-8 w-full cursor-pointer items-center gap-2.5 '
                f'rounded-(--control-radius) px-2.5 text-left text-sm transition-colors group-hover:bg-accent/60">{body}</button></div>')
    return (f'<div tabindex="0" aria-disabled="true" class="flex h-8 w-full cursor-default items-center gap-2.5 '
            f'rounded-(--control-radius) px-2.5 text-left text-sm opacity-50">{body}</div>')
LH = 400
launcher = (f'<div style="width:{W}px;height:{LH}px" class="flex flex-col bg-background">'
            '<div class="flex min-h-0 flex-1 items-center justify-center overflow-y-auto px-6 outline-none">'
            '<div class="w-full max-w-xs py-6"><h3 class="mb-3 text-center font-medium text-foreground text-sm">Open a surface</h3>'
            '<div class="flex flex-col gap-0.5">' + "".join(launcher_row(*a) for a in ACTIONS) + "</div></div></div></div>")

PREPARE = ("document.querySelectorAll('[data-tree-host]').forEach(h => { const t = h.querySelector('template');"
           " const r = h.attachShadow({mode: 'open'}); r.appendChild(t.content.cloneNode(true)); })")
cases = [
    {"name": "tabs", "html": tabs, "native": {"case": "tabs"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "files", "html": files, "native": {"case": "files"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "file-header", "html": header, "native": {"case": "file-header"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "launcher", "html": launcher, "native": {"case": "launcher"}, "wrapperStyle": f"display:block;width:{W}px"},
]
spec = {"component": "files", "source": "apps/web/src/components/RightPanelTabs.tsx, components/files/",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/files.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
