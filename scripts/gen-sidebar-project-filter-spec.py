"""Writes design/component-reference/sidebar-project-filter.json for scripts/component-reference: the sidebar's project
filter popup at Nightly 4928 with 5258's leading Add project row (#33057), after pinned projects (#26154) and the aligned row actions (#29639, #29704). Each project
row is the favicon, the label, then `ProjectRowActions`: the settings button, visible on the highlighted row, and the
pin column, which holds `ProjectPinButton` or a `size-6` stand-in (Sidebar.tsx:3120-3190, ProjectComboboxRow.tsx,
ProjectPinButton.tsx:24-73). "All projects" ends in the same stand-in. The popup frame, rows and search field come
from scripts/gen-sidebar-search-spec.py, lucide icons from scripts/gen-run-on-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-project-filter-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-sidebar-search-spec.py")}
exec(load("gen-sidebar-search-spec.py", "cases = []"), g)
r = {"__file__": os.path.join(ROOT, "scripts/gen-run-on-spec.py")}
exec(load("gen-run-on-spec.py", "def machine"), r)
svg, favicon, ITEM, FOLDER, SETTINGS, scope_popup = g["svg"], g["favicon"], g["ITEM"], g["FOLDER"], g["SETTINGS"], g["scope_popup"]
add_project_item = g["add_project_item"]
lucide = r["lucide"]
# button.tsx base + ghost-muted + icon-xs, without the old row's `ml-auto`.
ICON_BUTTON = g["GHOST_MUTED_ICON_XS"].removesuffix(" ml-auto")
STAND_IN = '<span class="size-7 sm:size-6"></span>'

def pin_button(pinned):
    icon = (lucide("pin", "size-3.5 group-hover/pin:hidden") + lucide("pin-off", "hidden size-3.5 group-hover/pin:block")) if pinned \
        else lucide("pin", "size-3.5")
    hide = "" if pinned else " opacity-0 in-data-highlighted:opacity-100 pointer-coarse:opacity-100"
    return (f'<span class="group/pin ml-auto flex{hide}"><button type="button" tabindex="-1" aria-hidden="true" class="{ICON_BUTTON}">'
            f'{icon}</button></span>')

def row(label, project=None, highlighted=False, pinned=False, can_pin=True, selected=False):
    attrs = (' data-selected=""' if selected else "") + (' data-highlighted=""' if highlighted else "")
    icon = favicon(project, "size-4 shrink-0") if project else svg(FOLDER, "size-4 shrink-0")
    if selected:  # `ProjectScopeRowIcon` (as in scripts/gen-sidebar-search-spec.py)
        icon = ('<span class="relative flex shrink-0">' + icon + '<span class="pointer-events-none absolute -right-1 -bottom-1 grid size-3 place-items-center rounded-full bg-primary ring-2 ring-popover">'
                + svg('<path d="M20 6 9 17l-5-5"></path>', 'size-2 text-primary-foreground').replace('stroke-width="2"', 'stroke-width="4"') + '</span></span>')
    if project:
        settings = f'<button type="button" tabindex="-1" aria-hidden="true" class="{ICON_BUTTON}">{svg(SETTINGS, "size-3.5")}</button>'
        actions = (f'<span class="ml-auto flex shrink-0 items-center pointer-coarse:gap-1">'
                   f'<span class="flex pointer-fine:invisible pointer-fine:in-data-highlighted:visible">{settings}</span>'
                   f'{pin_button(pinned) if can_pin else STAND_IN}</span>')
    else:
        actions = '<span class="ml-auto size-7 shrink-0 sm:size-6"></span>'
    return (f'<div role="option" data-slot="combobox-item" class="{ITEM}"{attrs}>'
            '<div class="flex min-w-0 flex-1 items-center gap-2 [&_svg:not([class*=\'text-\'])]:text-muted-foreground" data-slot="combobox-item-content">'
            f'{icon}<span class="min-w-0 truncate text-sm">{label}</span>{actions}</div></div>')

CASES = [
    # Pinned first, then the rest; the highlighted unpinned row shows its settings and its pin.
    ("pinned", [add_project_item(), row("All projects", selected=True), row("candywrapper", "candywrapper", pinned=True), row("demo-repo", "demo-repo", highlighted=True)],
     {"pinned": "candywrapper", "highlighted": "3"}),
    # The pinned row highlighted: settings and the pin together.
    ("pinned-highlighted", [add_project_item(), row("All projects", selected=True), row("candywrapper", "candywrapper", highlighted=True, pinned=True), row("demo-repo", "demo-repo")],
     {"pinned": "candywrapper", "highlighted": "2"}),
    # A server without `projectOrganization`: no pins, the column keeps its room.
    ("no-pins", [add_project_item(), row("All projects", selected=True), row("demo-repo", "demo-repo", highlighted=True, can_pin=False), row("candywrapper", "candywrapper", can_pin=False)],
     {"highlighted": "2", "canPin": "no"}),
]
spec = {"component": "sidebar-project-filter", "source": "apps/web/src/components/Sidebar.tsx",
        "cases": [{"name": n, "html": scope_popup("", rows), "wrapperStyle": "display:inline-block", "native": native} for n, rows, native in CASES],
        "states": ["rest"], "themes": ["light", "dark"]}
with open(os.path.join(ROOT, "design/component-reference/sidebar-project-filter.json"), "w") as out:
    json.dump(spec, out, indent=1, ensure_ascii=False)
print(spec["component"], len(spec["cases"]), "cases")
