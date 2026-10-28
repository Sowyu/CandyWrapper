"""Writes the popup family specs for scripts/component-reference: menu, select-trigger, select-popup,
combobox-popup, autocomplete-popup, popover and tooltip (design/component-reference/<name>.json).

Popups render statically open: the popup element with its classes, no positioner, and the item
state attributes base-ui would set (data-highlighted, data-checked, data-selected) written in.
Class strings are copied from apps/web/src/components/ui/{menu,select,combobox,autocomplete,popover,tooltip}.tsx
at the tag in T3_VERSION. `native` names a preset that PopupsFidelityTests builds the same way.
Usage: /usr/bin/python3 -I scripts/gen-popups-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"

def icon(name, cls=""):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    c = f' class="lucide lucide-{name} {cls}"'.replace(" \"", "\"")
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"{c} aria-hidden="true">{inner}</svg>')

GLASS_SHADOW = "shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]"

# Menu (menu.tsx)
MENU_POPUP = ("dropdown-glass relative flex origin-(--transform-origin) rounded-lg " + GLASS_SHADOW.split()[0] +
              " outline-none focus:outline-none " + GLASS_SHADOW.split()[1] +
              " [-webkit-app-region:no-drag] min-w-[min(10rem,calc(100vw-2rem))] max-w-[calc(100vw-2rem)]")
MENU_ITEM = "[&>svg]:-mx-0.5 flex min-h-8 cursor-pointer select-none items-center gap-2 rounded-sm px-2 py-1 text-base text-foreground outline-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-inset:ps-8 data-[variant=destructive]:text-destructive-foreground data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&>svg:not([class*='opacity-'])]:opacity-80 [&>svg:not([class*='size-'])]:size-4.5 sm:[&>svg:not([class*='size-'])]:size-4 [&>svg:not([class*='text-'])]:text-muted-foreground data-[variant=destructive]:[&>svg:not([class*='text-'])]:text-current [&>svg]:pointer-events-none [&>svg]:shrink-0"
MENU_CHECK = "grid min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center gap-2 rounded-sm py-1 ps-2 text-base text-foreground outline-none data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0 grid-cols-[1rem_minmax(0,1fr)] pe-4"
CHECK_SVG = '<svg fill="none" height="24" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.75" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M5.252 12.7 10.2 18.63 18.748 5.37"></path></svg>'
MENU_RADIO = "[&_svg]:-mx-0.5 flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base text-foreground outline-none data-checked:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
MENU_LABEL = "px-2 py-1.5 font-medium text-muted-foreground text-xs data-inset:ps-9 sm:data-inset:ps-8"
MENU_SEP = "mx-2 my-1 h-px bg-border"
MENU_SHORTCUT = "ms-auto font-medium font-sans text-secondary-label text-xs tracking-widest"
MENU_SUB = "[&>svg:not(:last-child)]:-mx-0.5 flex min-h-8 cursor-pointer items-center gap-2 rounded-sm px-2 py-1 text-base text-foreground outline-none data-disabled:cursor-not-allowed data-disabled:pointer-events-none data-highlighted:bg-accent data-popup-open:bg-accent data-inset:ps-8 data-highlighted:text-accent-foreground data-popup-open:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg:not([class*='text-'])]:text-muted-foreground [&>svg:not(:last-child):not([class*='opacity-'])]:opacity-80 [&_svg]:pointer-events-none [&>svg]:shrink-0"

# Presets, mirrored in PopupsFidelityTests.menuPreset. (kind, title, icon, shortcut, flags)
PRESETS = {
    "actions": [("item", "New thread", "square-pen", "⌘N", ""), ("item", "Copy path", "copy", "⇧⌘C", ""),
                ("item", "Rename", "pencil", None, ""), ("sep",), ("sub", "Move to", "folder", None, ""),
                ("item", "Archive", "archive", None, "disabled"), ("sep",), ("item", "Delete", "trash-2", None, "destructive")],
    "options": [("label", "Appearance"), ("radio", "System", None, None, "checked"), ("radio", "Light", None, None, ""),
                ("radio", "Dark", None, None, ""), ("sep",), ("label", "View"),
                ("check", "Show sidebar", None, None, "checked"), ("check", "Wrap lines", None, None, "")],
}

def menu_row(entry, highlighted):
    kind = entry[0]
    if kind == "sep":
        return f'<div role="separator" class="{MENU_SEP}" data-slot="menu-separator"></div>'
    if kind == "label":
        return f'<div class="{MENU_LABEL}" data-slot="menu-label">{entry[1]}</div>'
    _, title, ic, shortcut, flags = entry
    hl = ' data-highlighted=""' if highlighted else ""
    dis = ' data-disabled="" aria-disabled="true"' if "disabled" in flags else ""
    if kind == "check":
        checked = "checked" in flags
        ind = f'<span data-slot="menu-checkbox-item-indicator" class="col-start-1">{CHECK_SVG}</span>' if checked else ""
        state = ' data-checked=""' if checked else ' data-unchecked=""'
        return f'<div role="menuitemcheckbox" class="{MENU_CHECK}" data-slot="menu-checkbox-item"{state}{hl}>{ind}<span class="col-start-2">{title}</span></div>'
    if kind == "radio":
        state = ' data-checked=""' if "checked" in flags else ' data-unchecked=""'
        return f'<div role="menuitemradio" class="{MENU_RADIO}" data-slot="menu-radio-item"{state}{hl}><span class="min-w-0 flex-1">{title}</span></div>'
    if kind == "sub":
        open_ = ' data-popup-open=""' if highlighted else ""
        return (f'<div role="menuitem" class="{MENU_SUB}" data-slot="menu-sub-trigger"{hl}{open_}>{icon(ic)}{title}'
                f'{icon("chevron-right", "-me-0.5 ms-auto opacity-80")}</div>')
    variant = "destructive" if "destructive" in flags else "default"
    sc = f'<kbd class="{MENU_SHORTCUT}" data-slot="menu-shortcut">{shortcut}</kbd>' if shortcut else ""
    return (f'<div role="menuitem" class="{MENU_ITEM}" data-density="default" data-slot="menu-item" data-variant="{variant}"{hl}{dis}>'
            f'{icon(ic) if ic else ""}{title}{sc}</div>')

def menu(preset, highlight):
    rows = "".join(menu_row(e, i == highlight) for i, e in enumerate(PRESETS[preset]))
    return f'<div role="menu" class="{MENU_POPUP}" data-slot="menu-popup" data-side="bottom"><div class="max-h-(--available-height) w-full overflow-y-auto p-1">{rows}</div></div>'

specs = {}
cases = []
for preset, highlights in (("actions", [-1, 1, 4, 7]), ("options", [1, 6])):
    for h in highlights:
        cases.append({"name": f"{preset}.h{h}", "html": menu(preset, h), "native": {"preset": preset, "highlight": str(h)}})
specs["menu"] = {"source": "apps/web/src/components/ui/menu.tsx", "states": ["rest"], "cases": cases}

# Select trigger (select.tsx:13-58)
S_BASE = "relative inline-flex cursor-pointer select-none items-center justify-between gap-2 border rounded-lg text-left text-base outline-none transition-[color,box-shadow,background-color] data-disabled:pointer-events-none data-disabled:opacity-64 sm:text-sm [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4"
S_VARIANT = {
    "default": "w-full min-w-36 border-input bg-background not-dark:bg-clip-padding text-foreground shadow-xs/5 ring-ring/24 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-data-disabled:not-focus-visible:not-aria-invalid:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 focus-visible:border-ring focus-visible:ring-[3px] aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:ring-destructive/16 dark:bg-input/32 dark:aria-invalid:ring-destructive/24 dark:not-data-disabled:not-focus-visible:not-aria-invalid:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='text-'])]:text-icon-muted [[data-disabled],:focus-visible,[aria-invalid],[data-pressed]]:shadow-none",
    "ghost": "border-transparent text-secondary-label focus-visible:ring-2 focus-visible:ring-ring data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-foreground",
}
S_SIZE = {"default": "min-h-9 px-[calc(--spacing(3)-1px)] sm:min-h-8",
          "sm": "min-h-8 gap-1.5 px-[calc(--spacing(2.5)-1px)] sm:min-h-7",
          "lg": "min-h-10 px-[calc(--spacing(3)-1px)] sm:min-h-9"}

DP = ' data-placeholder=""'

def select_trigger(variant, size, value, open_=False):
    placeholder = value is None
    v = f'<span class="flex-1 truncate data-placeholder:text-placeholder" data-slot="select-value"{DP if placeholder else ""}>{value or "Choose a model"}</span>'
    chevron = f'<span data-slot="select-icon" class="flex">{icon("chevron-down", "-me-1 size-3.5 opacity-70")}</span>'
    attrs = ' data-pressed="" data-popup-open=""' if open_ else ""
    return f'<button type="button" class="{S_BASE} {S_VARIANT[variant]} {S_SIZE[size]}" data-slot="select-trigger"{attrs}>{v}{chevron}</button>'

cases = []
for variant, size, value, open_ in (("default", "default", "Claude Haiku", False), ("default", "default", None, False),
                                    ("default", "sm", "Claude Haiku", False), ("default", "lg", "Claude Haiku", False),
                                    ("default", "default", "Claude Haiku", True), ("ghost", "default", "Claude Haiku", False)):
    name = f"{variant}.{size}.{'value' if value else 'placeholder'}{'.open' if open_ else ''}"
    cases.append({"name": name, "html": select_trigger(variant, size, value, open_), "wrapperStyle": "display:block;width:200px",
                  "native": {"variant": variant, "size": size, "value": value or "", "open": str(open_).lower()}})
specs["select-trigger"] = {"source": "apps/web/src/components/ui/select.tsx", "states": ["rest", "hover", "focus-visible"], "cases": cases}

# Select popup (select.tsx:130-196)
SEL_ITEM = "flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none data-selected:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
DP, SEL, HL = ' data-placeholder=""', ' data-selected=""', ' data-highlighted=""'
SEL_TEXT = "min-w-0 flex-1 [&_svg:not([class*='text-'])]:text-muted-foreground"
OPTIONS = ["Claude Haiku", "Claude Sonnet", "Claude Opus", "GPT Astra"]

def select_popup(selected, highlight):
    items = "".join(f'<div role="option" class="{SEL_ITEM}" data-slot="select-item"{SEL if i == selected else ""}{HL if i == highlight else ""}>'
                    f'<div class="{SEL_TEXT}" data-slot="select-item-text">{t}</div></div>'
                    for i, t in enumerate(OPTIONS))
    return (f'<div class="origin-(--transform-origin) rounded-lg text-foreground outline-none" data-slot="select-popup" data-side="bottom">'
            f'<div class="dropdown-glass relative h-full rounded-lg {GLASS_SHADOW} min-w-(--anchor-width)">'
            f'<div class="max-h-(--available-height) overflow-y-auto p-1" data-slot="select-list">{items}</div></div></div>')

cases = [{"name": f"s{s}.h{h}", "html": select_popup(s, h), "wrapperStyle": "display:inline-block;--anchor-width:200px;--available-height:600px",
          "native": {"selected": str(s), "highlight": str(h), "anchor": "200"}} for s, h in ((1, -1), (1, 2), (1, 1))]
specs["select-popup"] = {"source": "apps/web/src/components/ui/select.tsx", "states": ["rest"], "cases": cases}

# Combobox and Autocomplete popups (combobox.tsx:162-212, autocomplete.tsx:100-128)
CB_SPAN = "dropdown-glass relative flex max-h-full min-w-(--anchor-width) max-w-(--available-width) origin-(--transform-origin) rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] transition-[scale,opacity] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]"
CB_POPUP = "flex min-w-0 max-h-[min(var(--available-height),23rem)] flex-1 flex-col overflow-hidden text-foreground"
CB_ITEM = "flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none not-data-disabled:hover:bg-foreground/[0.09] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-selected:bg-foreground/[0.06] data-selected:text-foreground data-highlighted:bg-foreground/[0.09] data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-foreground/[0.09] [&[data-highlighted][data-selected]]:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
CB_CONTENT = "flex min-w-0 flex-1 items-center gap-2 [&_svg:not([class*='text-'])]:text-muted-foreground"
AC_SPAN = "relative flex max-h-full min-w-(--anchor-width) max-w-(--available-width) origin-(--transform-origin) rounded-lg border bg-popover not-dark:bg-clip-padding shadow-lg/5 transition-[scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] dark:before:shadow-[0_-1px_--theme(--color-white/6%)]"
AC_POPUP = "flex max-h-[min(var(--available-height),23rem)] flex-1 flex-col text-foreground"
AC_ITEM = "flex min-h-8 cursor-default select-none items-center gap-2 rounded-sm px-2 py-1 text-base outline-none hover:bg-accent data-disabled:pointer-events-none data-selected:bg-accent/50 data-selected:text-foreground data-highlighted:bg-accent data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-accent [&[data-highlighted][data-selected]]:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='text-'])]:text-muted-foreground"
WRAP = "display:inline-block;--anchor-width:200px;--available-width:600px;--available-height:600px"

def list_popup(kind, selected, highlight):
    def attrs(i):
        return (' data-selected=""' if i == selected else "") + (' data-highlighted=""' if i == highlight else "")
    if kind == "combobox":
        items = "".join(f'<div role="option" class="{CB_ITEM}" data-slot="combobox-item"{attrs(i)}><div class="{CB_CONTENT}" data-slot="combobox-item-content">{t}</div></div>' for i, t in enumerate(OPTIONS))
        return (f'<span class="{CB_SPAN}"><div class="{CB_POPUP}" data-slot="combobox-popup" data-side="bottom">'
                f'<div class="not-empty:scroll-py-1 not-empty:px-1 not-empty:py-1" data-slot="combobox-list">{items}</div></div></span>')
    items = "".join(f'<div role="option" class="{AC_ITEM}" data-slot="autocomplete-item"{attrs(i)}>{t}</div>' for i, t in enumerate(OPTIONS))
    return (f'<span class="{AC_SPAN}"><div class="{AC_POPUP}" data-slot="autocomplete-popup" data-side="bottom">'
            f'<div class="not-empty:scroll-py-1 not-empty:p-1" data-slot="autocomplete-list">{items}</div></div></span>')

for kind in ("combobox", "autocomplete"):
    specs[f"{kind}-popup"] = {"source": f"apps/web/src/components/ui/{kind}.tsx", "states": ["rest"],
                              "cases": [{"name": f"s{s}.h{h}", "html": list_popup(kind, s, h), "wrapperStyle": WRAP,
                                         "native": {"selected": str(s), "highlight": str(h), "anchor": "200"}}
                                        for s, h in ((-1, 0), (1, 2), (1, 1))]}

# Popover (popover.tsx:76-129)
P_BASE = "relative flex h-(--popup-height,auto) w-(--popup-width,auto) origin-(--transform-origin) rounded-lg text-popover-foreground outline-none transition-[width,height,scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] has-data-[slot=calendar]:rounded-xl has-data-[slot=calendar]:before:rounded-[calc(var(--radius-xl)-1px)] data-starting-style:scale-98 data-starting-style:opacity-0 dark:before:shadow-[0_-1px_--theme(--color-white/6%)] dropdown-glass " + GLASS_SHADOW
P_VIEWPORT = "relative size-full max-h-(--available-height) overflow-clip px-(--viewport-inline-padding) has-data-[slot=calendar]:p-2 data-instant:transition-none"
P_PAD = {"default": "py-4 [--viewport-inline-padding:--spacing(4)]", "compact": "py-2 [--viewport-inline-padding:--spacing(3)]"}
P_WIDTH = {"auto": "", "md": "w-80 max-w-[calc(100vw-2rem)]"}

def popover(padding, width):
    title = '<h2 class="font-semibold text-sm leading-none" data-slot="popover-title">Share thread</h2>'
    return (f'<div class="{P_BASE} {P_WIDTH[width]}" data-slot="popover-popup" data-side="bottom"><div class="{P_VIEWPORT} {P_PAD[padding]} not-data-transitioning:overflow-y-auto" data-slot="popover-viewport">{title}</div></div>')

specs["popover"] = {"source": "apps/web/src/components/ui/popover.tsx", "states": ["rest"],
                    "cases": [{"name": f"{p}.{w}", "html": popover(p, w), "wrapperStyle": "display:inline-block;--available-height:600px",
                               "native": {"padding": p, "width": w}} for p, w in (("default", "auto"), ("compact", "auto"), ("default", "md"))]}

# Tooltip (tooltip.tsx:105-135)
T_BASE = "relative flex h-(--popup-height,auto) w-(--popup-width,auto) origin-(--transform-origin) text-balance rounded-md text-popover-foreground text-xs transition-[width,height,scale,opacity] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0 data-instant:duration-0 dark:before:shadow-[0_-1px_--theme(--color-white/6%)]"
T_VARIANT = {"default": "border bg-popover not-dark:bg-clip-padding shadow-md/5", "glass": "dropdown-glass shadow-xl shadow-black/25 before:hidden"}
T_TEXT = {"default": "max-w-80 wrap-anywhere whitespace-normal leading-snug", "code": "max-w-120 wrap-anywhere text-left font-mono text-[11px] leading-relaxed"}
T_VIEWPORT = "relative size-full overflow-clip px-(--viewport-inline-padding) py-1 [--viewport-inline-padding:--spacing(2)] data-instant:transition-none"

def tooltip(variant, text):
    surface = T_VARIANT["glass" if variant == "glass" else "default"]
    t = T_TEXT["code" if variant == "code" else "default"]
    return f'<div class="{T_BASE} {surface} {t}" data-slot="tooltip-popup" data-side="top"><div class="{T_VIEWPORT}" data-slot="tooltip-viewport">{text}</div></div>'

specs["tooltip"] = {"source": "apps/web/src/components/ui/tooltip.tsx", "states": ["rest"],
                    "cases": [{"name": v, "html": tooltip(v, t), "native": {"variant": v, "text": t}}
                              for v, t in (("default", "Copy path"), ("glass", "Open in editor"), ("code", "git status --short"))]}

for name, spec in specs.items():
    spec = {"component": name, "source": spec["source"], "states": spec["states"], "themes": ["light", "dark"], "cases": spec["cases"]}
    for c in spec["cases"]:
        c.setdefault("wrapperStyle", "display:inline-block")
    with open(os.path.join(ROOT, "design/component-reference", name + ".json"), "w") as f:
        json.dump(spec, f, indent=1, ensure_ascii=False)
    print(name, len(spec["cases"]), "cases")
