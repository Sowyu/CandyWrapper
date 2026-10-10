"""Writes the sidebar batch specs for scripts/component-reference: sidebar-menu-button, sidebar-menu-sub,
command-item and hue-slider (design/component-reference/<name>.json).

Class strings are copied from apps/web/src/components/ui/{sidebar,command,autocomplete,color-picker}.tsx at the
tag in T3_VERSION, merged by hand where tailwind-merge drops a class (noted inline).
Sidebar cases sit in a `data-app-sidebar` box with `bg-sidebar` and 8px padding, as in a SidebarGroup.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-spec.py
"""
import json, os

def svg(inner):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{inner}</svg>')

FOLDER = svg('<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path>')

# sidebar.tsx:662-683. `ring-ring` is dropped for the outline variant (ring-sidebar-border comes later).
MB_BASE = "peer/menu-button flex w-full cursor-pointer items-center gap-[var(--sidebar-control-gap)] overflow-hidden text-left outline-hidden {ring} transition-[width,height,padding] hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 data-[active=true]:bg-sidebar-row-selected data-[active=true]:font-medium data-[active=true]:text-sidebar-foreground data-[state=open]:hover:bg-sidebar-row-hover data-[state=open]:hover:text-sidebar-foreground group-data-[collapsible=icon]:size-8! group-data-[collapsible=icon]:p-[var(--sidebar-content-inset)]! [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-[var(--sidebar-icon-color)] hover:[&>svg]:text-sidebar-foreground active:[&>svg]:text-sidebar-foreground data-[active=true]:[&>svg]:text-sidebar-foreground"
MB_SIZE = {
    "default": "h-8 rounded-[var(--control-radius)] px-[var(--sidebar-row-content-inset)] py-1.5 text-sm",
    "icon": "size-8 justify-center rounded-[var(--control-radius)] p-0",
    "lg": "h-12 rounded-lg p-2 text-sm group-data-[collapsible=icon]:p-0!",
    "sm": "h-7 rounded-lg p-2 text-xs",
}
MB_VARIANT = {"default": "font-medium text-sidebar-muted-foreground/80", "outline": "bg-sidebar-control-surface ring-1 ring-sidebar-border"}
SIDEBAR_BOX = '<div data-app-sidebar="" class="bg-sidebar text-sidebar-foreground" style="width:240px;padding:8px">{}</div>'

def menu_button(size, variant, title, active=False):
    base = MB_BASE.format(ring="" if variant == "outline" else "ring-ring")
    if size == "icon": base = base.replace(" w-full ", " ")  # tailwind-merge: size-8 drops w-full
    cls = " ".join([base, MB_SIZE[size], MB_VARIANT[variant]])
    label = "" if size == "icon" else f"<span>{title}</span>"
    act = ' data-active="true"' if active else ' data-active="false"'
    return f'<button type="button" data-sidebar="menu-button" data-slot="sidebar-menu-button" data-size="{size}"{act} class="{cls}">{FOLDER}{label}</button>'

specs = {}
cases = []
for name, size, variant, active in (("default", "default", "default", False), ("selected", "default", "default", True),
                                    ("sm", "sm", "default", False), ("lg", "lg", "default", False),
                                    ("icon", "icon", "default", False), ("outline", "default", "outline", False)):
    cases.append({"name": name, "html": SIDEBAR_BOX.format(menu_button(size, variant, "demo-repo", active)),
                  "wrapperStyle": "display:block", "stateTarget": "button",
                  "native": {"size": size, "variant": variant, "active": str(active).lower(), "title": "demo-repo"}})
specs["sidebar-menu-button"] = {"source": "apps/web/src/components/ui/sidebar.tsx", "states": ["rest", "hover", "active", "focus-visible", "disabled"], "cases": cases}

# sidebar.tsx:738-794
SUB = "mx-3.5 flex min-w-0 translate-x-px flex-col gap-1 border-sidebar-border border-l px-2.5 py-0.5 group-data-[collapsible=icon]:hidden"
SUB_BTN = "-translate-x-px flex h-7 min-w-0 cursor-pointer items-center gap-2 overflow-hidden rounded-lg px-2 text-sidebar-foreground outline-hidden ring-ring hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-sidebar-muted-foreground data-[active=true]:bg-sidebar-row-selected data-[active=true]:text-sidebar-foreground text-sm group-data-[collapsible=icon]:hidden"
def sub_list(active):
    items = "".join(f'<li class="group/menu-sub-item relative"><a data-active="{str(i == active).lower()}" data-size="md" class="{SUB_BTN}">{FOLDER}<span>{t}</span></a></li>'
                    for i, t in enumerate(["Settings", "Archive"]))
    return SIDEBAR_BOX.format(f'<ul class="{SUB}">{items}</ul>')
specs["sidebar-menu-sub"] = {"source": "apps/web/src/components/ui/sidebar.tsx", "states": ["rest"],
                             "cases": [{"name": "second-active", "html": sub_list(1), "wrapperStyle": "display:block", "native": {"active": "1"}}]}

# CommandItem (command.tsx:183-202) on AutocompleteItem (autocomplete.tsx:127). The palette passes `active`,
# so tailwind-merge keeps `py-1.5` and the active fill. Placed in a 560px panel on the dialog's --background.
ITEM = "flex min-h-8 select-none items-center gap-2 rounded-sm px-2 text-base outline-none data-disabled:pointer-events-none data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='text-'])]:text-muted-foreground py-1.5 cursor-pointer hover:bg-transparent hover:text-inherit"
SHORTCUT = "ms-auto font-medium font-sans text-secondary-label text-xs tracking-widest"
def command_item(active, shortcut):
    cls = ITEM + (" bg-accent! text-accent-foreground!" if active else "")
    sc = f'<kbd class="{SHORTCUT}">{shortcut}</kbd>' if shortcut else ""
    title = '<span class="flex min-w-0 flex-1 items-center gap-1.5 text-sm text-foreground"><span class="truncate">New thread</span></span>'
    icon = FOLDER.replace('aria-hidden="true"', 'class="size-4 text-icon-muted" aria-hidden="true"')  # ITEM_ICON_CLASS (CommandPalette.logic.ts)
    return f'<div role="option" data-slot="command-item" class="{cls}">{icon}{title}{sc}</div>'
cases = []
for active in (False, True):
    for sc in ("", "⇧⌘O"):
        cases.append({"name": f"{'active' if active else 'idle'}{'.shortcut' if sc else ''}", "html": command_item(active, sc),
                      "wrapperStyle": "display:block;width:542px",
                      "native": {"active": str(active).lower(), "shortcut": sc, "title": "New thread", "icon": "folder"}})
specs["command-item"] = {"source": "apps/web/src/components/ui/command.tsx", "states": ["rest"], "cases": cases}

# color-picker.tsx:203-220
HUE = ('<div role="slider" tabindex="0" class="relative flex h-6 cursor-pointer touch-none items-center rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-popover">'
       '<div class="h-2.5 w-full rounded-full bg-[linear-gradient(to_right,#f00,#ff0,#0f0,#0ff,#00f,#f0f,#f00)] shadow-[inset_0_0_0_1px_rgb(0_0_0_/_12%)]"></div>'
       '<div class="pointer-events-none absolute top-1/2 size-4 -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white shadow-[0_0_0_1px_rgb(0_0_0/0.4)]" style="left:calc({h}/360 * (100% - 1rem) + 0.5rem);background-color:hsl({h} 100% 50%)"></div></div>')
specs["hue-slider"] = {"source": "apps/web/src/components/ui/color-picker.tsx", "states": ["rest", "focus-visible"],
                       "cases": [{"name": f"h{h}", "html": HUE.format(h=h), "wrapperStyle": "display:block;width:224px", "native": {"hue": str(h)}} for h in (0, 210)]}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for name, spec in specs.items():
    out = {"component": name, "source": spec["source"], "states": spec["states"], "themes": ["light", "dark"], "cases": spec["cases"]}
    with open(os.path.join(root, f"design/component-reference/{name}.json"), "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(name, len(spec["cases"]), "cases")
