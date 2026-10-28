"""Writes the batch B specs for scripts/component-reference: toggle, toggle-group, switch, checkbox,
radio, alert, empty and collapsible-section-header (design/component-reference/<name>.json).

Class strings are copied from apps/web/src/components/ui/*.tsx at the tag in T3_VERSION.
merge() is a small tailwind-merge: a later class drops an earlier one with the same modifiers
in the same conflict group. It covers the groups that occur in these components only.
Markup copies what Base UI renders: data-checked / data-unchecked / data-pressed / data-disabled
as attributes, so states that are attributes become separate cases.
Usage: /usr/bin/python3 -I scripts/gen-toggles-spec.py
"""
import json, os, re

FONT_SIZES = {"xs", "sm", "base", "lg", "xl", "2xl", "3xl", "[11px]", "2xs", "3xs"}

def split_mods(cls):
    parts, depth, cur = [], 0, ""
    for ch in cls:
        if ch == "[": depth += 1
        elif ch == "]": depth -= 1
        if ch == ":" and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    return parts, cur

def group(util):
    m = re.match(r"^\[(--[\w-]+):", util)
    if m: return m.group(1)
    if util in ("relative", "absolute"): return "position"
    if util.startswith("text-"):
        return "font-size" if util[5:] in FONT_SIZES else "text-color"
    if util.startswith("bg-clip"): return "bg-clip"
    if util.startswith("bg-"): return "bg-color"
    if util.startswith("rounded"): return "rounded"
    if util.startswith("gap-"): return "gap"
    if util.startswith("size-"): return "size"
    if util.startswith("px-"): return "px"
    if util.startswith("py-"): return "py"
    if util.startswith("h-"): return "h"
    if util.startswith("min-w-"): return "min-w"
    if util.startswith("translate-x-"): return "translate-x"
    if util.startswith("opacity-"): return "opacity"
    if util in ("font-normal", "font-medium", "font-semibold"): return "font-weight"
    if util == "shadow-none" or re.match(r"^shadow-(xs|sm|md|\[)", util): return "shadow"
    if util.startswith("transition"): return "transition"
    if re.match(r"^ring-\d+$", util): return "ring-width"
    if util.startswith("ring-offset-"): return "ring-offset-w" if re.match(r"^ring-offset-\d+$", util) else "ring-offset-color"
    if util.startswith("ring-"): return "ring-color"
    return None

def merge(classes):
    seen, out = set(), []
    for cls in reversed(classes.split()):
        mods, util = split_mods(cls)
        g = group(util)
        if g:
            key = (tuple(mods), g)
            if key in seen: continue
            seen.add(key)
        out.append(cls)
    return " ".join(reversed(out))

def svg(inner, cls="", stroke=2):
    c = f' class="{cls}"' if cls else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"{c} aria-hidden="true">{inner}</svg>')

PLUS = svg('<path d="M5 12h14"></path><path d="M12 5v14"></path>')
CIRCLE_ALERT = svg('<circle cx="12" cy="12" r="10"></circle><line x1="12" x2="12" y1="8" y2="12"></line><line x1="12" x2="12.01" y1="16" y2="16"></line>')
INBOX = svg('<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>')

def camel(name):
    head, *rest = name.split("-")
    return head + "".join(p.capitalize() for p in rest)

specs = {}

# 1. Toggle (toggle.tsx:9-35)
T_BASE = "[&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer select-none items-center justify-center gap-2 whitespace-nowrap rounded-lg border font-medium text-base text-foreground outline-none transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 aria-disabled:opacity-64 data-pressed:bg-input/64 data-pressed:text-accent-foreground sm:text-sm [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
T_SIZES = {
    "compact": "h-7 min-w-7 rounded-md px-[calc(--spacing(1)-1px)] text-xs before:rounded-[calc(var(--radius-md)-1px)] [&_svg:not([class*='size-'])]:size-3.5",
    "default": "h-9 min-w-9 px-[calc(--spacing(2)-1px)] sm:h-8 sm:min-w-8",
    "lg": "h-10 min-w-10 px-[calc(--spacing(2.5)-1px)] sm:h-9 sm:min-w-9",
    "segmented": "h-6 min-w-0 rounded-md px-2.5 text-xs before:rounded-[calc(var(--radius-md)-1px)]",
    "sm": "h-8 min-w-8 px-[calc(--spacing(1.5)-1px)] sm:h-7 sm:min-w-7",
    "xs": "h-7 min-w-7 px-[calc(--spacing(1)-1px)] sm:h-6 sm:min-w-6 rounded-md",
}
T_VARIANTS = {
    "default": "border-transparent",
    "pill": "border-transparent rounded-full px-3 font-normal text-muted-foreground data-pressed:text-foreground",
    "ghost": "border-transparent text-foreground shadow-none [:disabled,:active,[data-pressed]]:shadow-none before:shadow-none data-pressed:bg-accent data-pressed:text-accent-foreground disabled:opacity-100 disabled:text-muted-foreground disabled:[&_svg]:opacity-100",
    "outline": "border-input bg-background not-dark:bg-clip-padding shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:data-pressed:bg-input dark:hover:bg-input/64 dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] dark:not-disabled:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/2%)] [:disabled,:active,[data-pressed]]:shadow-none",
    "segmented": "border-transparent text-muted-foreground shadow-none transition-colors before:shadow-none hover:bg-background/55 hover:text-foreground data-pressed:bg-background data-pressed:text-foreground data-pressed:shadow-xs/10 dark:hover:bg-input/32 dark:data-pressed:bg-input/72",
}

def toggle(variant, size, title, pressed, icon=True):
    cls = merge(f"{T_BASE} {T_SIZES[size]} {T_VARIANTS[variant]}")
    attrs = ' data-pressed="" aria-pressed="true"' if pressed else ' aria-pressed="false"'
    return (f'<button type="button" data-slot="toggle" data-size="{size}" data-variant="{variant}"{attrs} class="{cls}">'
            f'{PLUS if icon else ""}{title}</button>')

cases = []
for v in T_VARIANTS:
    size = "segmented" if v == "segmented" else "default"
    for pressed in (False, True):
        name = f"{v}.{'on' if pressed else 'off'}"
        cases.append({"name": name, "html": toggle(v, size, v, pressed),
                      "native": {"variant": v, "size": size, "title": v, "icon": "plus", "pressed": str(pressed).lower()}})
for s in ("sm", "xs", "lg", "compact"):
    cases.append({"name": f"outline.{s}", "html": toggle("outline", s, "", False),
                  "native": {"variant": "outline", "size": s, "title": "", "icon": "plus", "pressed": "false"}})
specs["toggle"] = {"source": "apps/web/src/components/ui/toggle.tsx",
                   "states": ["rest", "hover", "active", "focus-visible", "disabled"], "cases": cases}

# 2. ToggleGroup (toggle-group.tsx:27-39)
G_ALWAYS = "flex w-fit *:focus-visible:z-10 dark:*:[[data-slot=separator]:has(+[data-slot=toggle]:hover)]:before:bg-input/64 dark:*:[[data-slot=separator]:has(+[data-slot=toggle][data-pressed])]:before:bg-input dark:*:[[data-slot=toggle]:hover+[data-slot=separator]]:before:bg-input/64 dark:*:[[data-slot=toggle][data-pressed]+[data-slot=separator]]:before:bg-input *:pointer-coarse:after:min-w-auto"
G_VARIANT = {"segmented": "gap-0.5 rounded-lg bg-input/40 p-0.5", "default": "gap-0.5"}
cases = []
for v, items, size in (("segmented", ["Unified", "Split", "Raw"], "segmented"), ("default", ["Bold", "Italic"], "default")):
    html = "".join(toggle(v, size, t, i == 0, icon=(v == "default")) for i, t in enumerate(items))
    cases.append({"name": v, "html": f'<div data-slot="toggle-group" data-size="{size}" data-variant="{v}" role="group" class="{G_ALWAYS} {G_VARIANT[v]}">{html}</div>',
                  "native": {"variant": v, "items": ",".join(items)}})
specs["toggle-group"] = {"source": "apps/web/src/components/ui/toggle-group.tsx", "states": ["rest"], "cases": cases}

# 3. Switch (switch.tsx:21-40)
S_ROOT = "inline-flex h-[calc(var(--thumb-size)+2px)] w-[calc(var(--thumb-size)*2-2px)] shrink-0 cursor-pointer items-center rounded-full p-[2px] outline-none transition-[background-color,box-shadow] duration-200 focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-checked:bg-primary data-unchecked:bg-input data-disabled:cursor-not-allowed data-disabled:opacity-64 data-[mixed]:bg-input"
S_SIZES = {"sm": "[--thumb-size:--spacing(4)] sm:[--thumb-size:--spacing(3.5)]",
           "default": "[--thumb-size:--spacing(5)] sm:[--thumb-size:--spacing(4)]"}
S_THUMB = "pointer-events-none block size-[calc(var(--thumb-size)-2px)] shrink-0 origin-left in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:not-data-disabled:scale-x-110 in-[[role=switch]:active,[data-slot=label]:active,[data-slot=field-label]:active]:rounded-[var(--thumb-size)/calc(var(--thumb-size)*1.1)] rounded-(--thumb-size) bg-background shadow-sm/5 dark:data-unchecked:bg-muted-foreground will-change-transform [transition:translate_.15s,border-radius_.15s,scale_.1s_.1s,transform-origin_.15s] data-checked:origin-right data-checked:translate-x-[calc(var(--thumb-size)-4px)]"
S_MIXED = "translate-x-[calc((var(--thumb-size)-4px)/2)] opacity-70 data-checked:translate-x-[calc((var(--thumb-size)-4px)/2)]"

def switch(size, value, disabled):
    st = ' data-checked=""' if value in ("on", "mixed") else ' data-unchecked=""'
    st += ' data-disabled=""' if disabled else ""
    mixed = value == "mixed"
    thumb = merge(f"{S_THUMB} {S_MIXED}") if mixed else S_THUMB
    mixed_attr = ' data-mixed=""' if mixed else ""
    return (f'<span role="switch" tabindex="0" aria-checked="{"mixed" if mixed else str(value == "on").lower()}" data-slot="switch" data-size="{size}"'
            f'{mixed_attr}{st} class="{S_ROOT} {S_SIZES[size]}">'
            f'<span data-slot="switch-thumb"{st} class="{thumb}"></span></span>')

cases = []
for size in ("default", "sm"):
    for value in ("off", "on", "mixed"):
        cases.append({"name": f"{size}.{value}", "html": switch(size, value, False), "native": {"size": size, "value": value}})
    for value in ("off", "on"):
        cases.append({"name": f"{size}.{value}.disabled", "html": switch(size, value, True), "native": {"size": size, "value": value, "disabled": "true"}})
specs["switch"] = {"source": "apps/web/src/components/ui/switch.tsx", "states": ["rest", "active", "focus-visible"], "cases": cases}

# 4. Checkbox (checkbox.tsx:11-54) and 5. Radio (radio-group.tsx:22-30)
C_ROOT = 'relative inline-flex size-4.5 shrink-0 items-center justify-center rounded-[.25rem] border border-input bg-background not-dark:bg-clip-padding shadow-xs/5 outline-none transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[3px] not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-ring aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:outline-destructive/48 data-disabled:opacity-64 sm:size-4 dark:not-data-checked:bg-input/32 dark:focus-visible:aria-invalid:outline-destructive/24 dark:not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [[data-disabled],[data-checked],[aria-invalid]]:shadow-none'
C_IND = '-inset-px absolute flex items-center justify-center rounded-[.25rem] text-primary-foreground data-unchecked:hidden data-checked:bg-primary data-indeterminate:text-foreground in-[[data-slot=checkbox]:focus-visible]:inset-shadow-[0_0_0_3px_var(--background)] in-[[data-slot=checkbox]:focus-visible]:outline-2 in-[[data-slot=checkbox]:focus-visible]:outline-solid in-[[data-slot=checkbox]:focus-visible]:-outline-offset-2 in-[[data-slot=checkbox]:focus-visible]:outline-inherit'
R_ROOT = 'relative inline-flex size-4.5 shrink-0 items-center justify-center rounded-full border border-input bg-background not-dark:bg-clip-padding shadow-xs/5 outline-none transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-full not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-ring aria-invalid:border-destructive/36 focus-visible:aria-invalid:border-destructive/64 focus-visible:aria-invalid:outline-destructive/48 data-disabled:opacity-64 sm:size-4 dark:not-data-checked:bg-input/32 dark:focus-visible:aria-invalid:outline-destructive/24 dark:not-data-disabled:not-data-checked:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [[data-disabled],[data-checked],[aria-invalid]]:shadow-none'
R_IND = '-inset-px absolute flex size-4.5 items-center justify-center rounded-full before:size-2 before:rounded-full before:bg-primary-foreground data-unchecked:hidden data-checked:bg-primary sm:size-4 sm:before:size-1.5 in-[[data-slot=radio]:focus-visible]:inset-shadow-[0_0_0_3px_var(--background)] in-[[data-slot=radio]:focus-visible]:outline-2 in-[[data-slot=radio]:focus-visible]:outline-solid in-[[data-slot=radio]:focus-visible]:-outline-offset-2 in-[[data-slot=radio]:focus-visible]:outline-inherit'
CHECK = svg('<path d="M5.252 12.7 10.2 18.63 18.748 5.37"></path>', "size-3.5 sm:size-3", 3)
DASH = svg('<path d="M5.252 12h13.496"></path>', "size-3.5 sm:size-3", 3)

def choice(kind, value, disabled=False, invalid=False):
    st = {"on": ' data-checked=""', "off": ' data-unchecked=""', "mixed": ' data-indeterminate=""'}[value]
    st += ' data-disabled=""' if disabled else ""
    inv = ' aria-invalid="true"' if invalid else ""
    if kind == "checkbox":
        ind = "" if value == "off" else f'<span data-slot="checkbox-indicator"{st} class="{C_IND}">{DASH if value == "mixed" else CHECK}</span>'
        root = C_ROOT
    else:
        ind = "" if value == "off" else f'<span data-slot="radio-indicator"{st} class="{R_IND}"></span>'
        root = R_ROOT
    return f'<span role="{kind}" tabindex="0" data-slot="{kind}"{st}{inv} class="{root}">{ind}</span>'

for kind, values in (("checkbox", ("off", "on", "mixed")), ("radio", ("off", "on"))):
    cases = []
    for value in values:
        cases.append({"name": value, "html": choice(kind, value), "native": {"value": value}})
        cases.append({"name": f"{value}.disabled", "html": choice(kind, value, disabled=True), "native": {"value": value, "disabled": "true"}})
    cases.append({"name": "off.invalid", "html": choice(kind, "off", invalid=True), "native": {"value": "off", "invalid": "true"}})
    specs[kind] = {"source": f"apps/web/src/components/ui/{'checkbox' if kind == 'checkbox' else 'radio-group'}.tsx",
                   "states": ["rest", "focus-visible"], "cases": cases}

# 7. Alert (alert.tsx:7-30, 89-143)
A_BASE = "relative rounded-xl border px-3.5 py-3 text-card-foreground text-sm"
A_VARIANTS = {
    "default": "bg-transparent dark:bg-input/32 [&_svg]:text-muted-foreground",
    "sidebar": "rounded-lg border-sidebar-border bg-sidebar-control-surface px-2 py-1.5 text-[11px] leading-4 [&_[data-slot=alert-description]]:block [&_[data-slot=alert-description]]:text-sidebar-muted-foreground",
    "error": "border-error/32 bg-error-surface text-error-foreground [&_[data-slot=alert-description]]:text-error-foreground/80 [&_svg]:text-error",
    "info": "border-info/32 bg-info/4 [&_svg]:text-info",
    "success": "border-success/32 bg-success/4 [&_svg]:text-success",
    "warning": "border-warning/32 bg-warning-surface text-warning-foreground [&_[data-slot=alert-description]]:text-warning-foreground/80 [&_svg]:text-warning",
}
cases = []
LONG_TITLE = "Your session expired while the agent was still running"
LONG_DESC = "Reconnect to keep streaming. Anything the agent wrote while you were away is saved on the server and appears once the thread syncs again."
for v, title, desc in [(v, "Heads up", "Something needs your attention.") for v in A_VARIANTS] + [
        ("default", LONG_TITLE, LONG_DESC), ("sidebar", LONG_TITLE, LONG_DESC), ("error", LONG_TITLE, LONG_DESC)]:
    cls = merge(f"{A_BASE} {A_VARIANTS[v]}")
    html = (f'<div data-slot="alert" data-variant="{v}" role="alert" class="{cls}"><div class="flex gap-2 items-center">'
            f'<div class="flex shrink-0 items-center justify-center size-4 [&>svg]:size-full">{CIRCLE_ALERT}</div>'
            f'<div class="flex min-w-0 flex-1 flex-col gap-0.5"><div class="font-medium" data-slot="alert-title">{title}</div>'
            f'<div class="flex flex-col gap-2.5 text-muted-foreground" data-slot="alert-description">{desc}</div></div></div></div>')
    cases.append({"name": v if title == "Heads up" else f"{v}.wrap", "html": html, "wrapperStyle": "display:block;width:360px",
                  "native": {"variant": v, "title": title, "description": desc, "icon": "circleAlert", "width": "360"}})
# controlAlignment="first-line" (alert.tsx:88-104): row items-start, icon in a one-line box.
for v in ["default", "error"]:
    cls = merge(f"{A_BASE} {A_VARIANTS[v]}")
    html = (f'<div data-slot="alert" data-variant="{v}" role="alert" class="{cls}"><div class="flex gap-2 items-start">'
            f'<div class="flex shrink-0 items-center justify-center h-lh w-4 [&>svg]:size-4">{CIRCLE_ALERT}</div>'
            f'<div class="flex min-w-0 flex-1 flex-col gap-0.5"><div class="font-medium" data-slot="alert-title">{LONG_TITLE}</div>'
            f'<div class="flex flex-col gap-2.5 text-muted-foreground" data-slot="alert-description">{LONG_DESC}</div></div></div></div>')
    cases.append({"name": f"{v}.firstline", "html": html, "wrapperStyle": "display:block;width:360px",
                  "native": {"variant": v, "title": LONG_TITLE, "description": LONG_DESC, "icon": "circleAlert", "width": "360",
                             "controlAlignment": "firstLine"}})
specs["alert"] = {"source": "apps/web/src/components/ui/alert.tsx", "states": ["rest"], "cases": cases}

# 13. Empty (empty.tsx)
E_BASE = "flex min-w-0 flex-1 flex-col items-center justify-center text-balance text-center"
E_SIZES = {
    "compact": "min-h-64 gap-4 p-6 md:p-10 [&_[data-slot=empty-media]]:mb-0 [&_[data-slot=empty-title]]:text-[1.0625rem] [&_[data-slot=empty-title]]:leading-6 [&_[data-slot=empty-description]]:text-[0.8125rem] [&_[data-slot=empty-description]]:leading-[1.125rem]",
    "default": "gap-6 p-6 md:p-12",
}
M_BASE = "flex shrink-0 items-center justify-center [&_svg]:pointer-events-none [&_svg]:shrink-0"
M_ICON = "relative flex size-9 shrink-0 items-center justify-center rounded-md border bg-card not-dark:bg-clip-padding text-foreground shadow-sm/5 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-md)-1px)] before:shadow-[0_1px_--theme(--color-black/4%)] dark:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='size-'])]:size-4.5"
media = merge(f"{M_BASE} {M_ICON}")
left = merge(f"{M_BASE} {M_ICON} -translate-x-0.5 -rotate-10 pointer-events-none absolute bottom-px origin-bottom-left scale-84 shadow-none")
right = merge(f"{M_BASE} {M_ICON} pointer-events-none absolute bottom-px origin-bottom-right translate-x-0.5 rotate-10 scale-84 shadow-none")
cases = []
for size, title, desc in [(z, "No threads yet", "Start a conversation to see it here.") for z in E_SIZES] + [
        ("default", "Nothing matches the filters you picked for this project", "Clear a filter or search all projects. Archived threads stay hidden until you turn on the archive toggle in settings."),
        ("compact", "No threads yet", "Start a conversation with the agent and every reply, tool call and diff shows up in this list.")]:
    html = (f'<div data-slot="empty" class="{E_BASE} {E_SIZES[size]}"><div data-slot="empty-header" class="flex max-w-sm flex-col items-center text-center">'
            f'<div class="relative mb-6" data-slot="empty-media" data-variant="icon"><div aria-hidden="true" class="{left}"></div>'
            f'<div aria-hidden="true" class="{right}"></div><div class="{media}">{INBOX}</div></div>'
            f'<div class="font-semibold text-xl" data-slot="empty-title">{title}</div>'
            f'<div class="text-muted-foreground text-sm [&>a:hover]:text-primary [&>a]:underline [&>a]:underline-offset-4 [[data-slot=empty-title]+&]:mt-1 [[data-slot=empty-description]+&]:mt-1" data-slot="empty-description">{desc}</div>'
            f'</div></div>')
    cases.append({"name": size if title == "No threads yet" and desc.startswith("Start a conversation to") else f"{size}.wrap", "html": html, "wrapperStyle": "display:flex;width:400px",
                  "native": {"size": size, "title": title, "description": desc, "icon": "inbox", "width": "400"}})
specs["empty"] = {"source": "apps/web/src/components/ui/empty.tsx", "states": ["rest"], "cases": cases}

# 17. CollapsibleSectionHeader (collapsible-section-header.tsx)
TONES = {
    "muted": ("text-sidebar-muted-foreground", "bg-sidebar-border/50"),
    "info": ("text-sidebar-muted-foreground", "bg-sidebar-border/50"),
    "emphasized": ("text-sidebar-foreground/80", "bg-sidebar-foreground/25"),
    "accent": ("text-primary", "bg-primary/50"),
}
H_BTN = "flex h-8 w-full cursor-pointer items-center gap-2 rounded-md px-2 text-left text-xs font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring/70"
CHEVRON = '<path d="m6 9 6 6 6-6"></path>'
cases = []
for tone, (label, line) in TONES.items():
    for expanded in (False, True):
        chev = svg(CHEVRON, "size-3 shrink-0 transition-transform" + ("" if expanded else " -rotate-90"))
        html = (f'<button type="button" aria-expanded="{str(expanded).lower()}" class="{merge(H_BTN + " " + label)}">'
                f'<span class="shrink-0">Projects</span><span aria-hidden="true" class="h-px min-w-2 flex-1 {line}"></span>{chev}</button>')
        cases.append({"name": f"{tone}.{'open' if expanded else 'closed'}", "html": html, "wrapperStyle": "display:block;width:240px",
                      "native": {"tone": tone, "expanded": str(expanded).lower(), "title": "Projects", "width": "240"}})
specs["collapsible-section-header"] = {"source": "apps/web/src/components/ui/collapsible-section-header.tsx",
                                        "states": ["rest", "focus-visible"], "cases": cases}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for name, spec in specs.items():
    out = {"component": name, "source": spec["source"], "states": spec["states"], "themes": ["light", "dark"], "cases": spec["cases"]}
    with open(os.path.join(root, f"design/component-reference/{name}.json"), "w") as f:
        json.dump(out, f, indent=1)
    print(name, len(spec["cases"]), "cases")
