"""Writes design/component-reference/button.json, the Button cases for scripts/component-reference.

Class strings are copied from apps/web/src/components/ui/button.tsx at the tag in T3_VERSION.
cva joins base, variant, size; then cn() runs tailwind-merge, which drops an earlier class
when a later one sets the same property under the same modifiers. merge() below covers the
conflict groups that occur in Button, not tailwind-merge in general.
Usage: /usr/bin/python3 -I scripts/gen-button-spec.py
"""
import json, os, re

BASE = "[--control-icon-color:currentColor] [&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 whitespace-nowrap rounded-[var(--control-radius)] border font-medium text-base outline-none transition-[box-shadow,scale] [&:active:not([aria-haspopup])]:scale-[0.97] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 aria-disabled:cursor-not-allowed aria-disabled:opacity-64 sm:text-sm [&_svg:not([class*='text-'])]:text-[var(--control-icon-color)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"

SIZES = {
    "compact": "h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-xs before:rounded-[calc(var(--radius-md)-1px)] [&_svg:not([class*='size-'])]:size-3.5",
    "default": "h-9 px-[calc(--spacing(3)-1px)] sm:h-8",
    "icon": "size-9 sm:size-8",
    "icon-lg": "size-10 sm:size-9",
    "icon-micro": "size-5 rounded-sm p-0 before:rounded-[calc(var(--radius-sm)-1px)] [&_svg:not([class*='size-'])]:size-3",
    "icon-tiny": "size-4 p-0 [&_svg:not([class*='size-'])]:size-3",
    "icon-sm": "size-8 sm:size-7",
    "icon-xl": "size-11 sm:size-10 [&_svg:not([class*='size-'])]:size-5 sm:[&_svg:not([class*='size-'])]:size-4.5",
    "icon-xs": "size-7 sm:size-6 not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-4 sm:not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-3.5",
    "lg": "h-10 px-[calc(--spacing(3.5)-1px)] sm:h-9",
    "micro": "h-5 gap-1 rounded-sm px-[calc(--spacing(1.5)-1px)] text-[11px] before:rounded-[calc(var(--radius-sm)-1px)] sm:text-[11px] [&_svg:not([class*='size-'])]:size-3 sm:[&_svg:not([class*='size-'])]:size-3",
    "sm": "h-8 gap-1.5 px-[calc(--spacing(2.5)-1px)] sm:h-7",
    "xl": "h-11 px-[calc(--spacing(4)-1px)] text-lg sm:h-10 sm:text-base [&_svg:not([class*='size-'])]:size-5 sm:[&_svg:not([class*='size-'])]:size-4.5",
    "xs": "h-7 gap-1 px-[calc(--spacing(2)-1px)] text-sm sm:h-6 sm:text-xs [&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5",
}

VARIANTS = {
    "default": "not-disabled:inset-shadow-[0_1px_--theme(--color-white/16%)] border-primary bg-primary text-primary-foreground shadow-primary/24 shadow-xs [:active,[data-pressed]]:inset-shadow-[0_1px_--theme(--color-black/8%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-primary/90",
    "destructive": "not-disabled:inset-shadow-[0_1px_--theme(--color-white/16%)] border-destructive bg-destructive text-white shadow-destructive/24 shadow-xs [:active,[data-pressed]]:inset-shadow-[0_1px_--theme(--color-black/8%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-destructive/90",
    "destructive-outline": "border-input bg-popover not-dark:bg-clip-padding text-destructive-foreground shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-disabled:before:shadow-[0_-1px_--theme(--color-white/2%)] dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:border-destructive/32 [:hover,[data-pressed]]:bg-destructive/4",
    "ghost": "[--control-icon-color:var(--contrast-muted-foreground)] border-transparent text-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent",
    "ghost-muted": "[--control-icon-color:currentColor] border-transparent text-muted-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-foreground",
    "ghost-destructive": "[--control-icon-color:currentColor] border-transparent text-muted-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent [:hover,[data-pressed]]:text-destructive",
    "glass": "surface-glass [--control-icon-color:var(--contrast-muted-foreground)] rounded-full border-border/60 text-foreground shadow-sm before:rounded-full [:hover,[data-pressed]]:border-border",
    "link": "border-transparent underline-offset-4 [:hover,[data-pressed]]:underline",
    "media-close": "[--control-icon-color:currentColor] border-transparent bg-black/65 text-white shadow-sm ring-1 ring-white/20 [:hover,[data-pressed]]:bg-black/80 focus-visible:ring-white",
    "media-navigation": "[--control-icon-color:currentColor] absolute top-1/2 z-20 -translate-y-1/2 border-transparent text-white/90 [:hover,[data-pressed]]:bg-white/10 [:hover,[data-pressed]]:text-white focus-visible:ring-white focus-visible:ring-offset-transparent",
    "outline": "[--control-icon-color:var(--contrast-muted-foreground)] border-input bg-popover not-dark:bg-clip-padding text-foreground shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-disabled:before:shadow-[0_-1px_--theme(--color-white/2%)] dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:bg-accent/50 dark:[:hover,[data-pressed]]:bg-input/64",
    "overlay": "border-transparent bg-black/70 text-white/65 [:hover,[data-pressed]]:bg-black/90",
    "secondary": "border-transparent bg-secondary text-secondary-foreground [:active,[data-pressed]]:bg-secondary/80 [:hover,[data-pressed]]:bg-secondary/90",
    "warning-outline": "border-warning/32 bg-warning-surface text-warning-foreground shadow-xs/5 [:disabled,:active,[data-pressed]]:shadow-none [:hover,[data-pressed]]:border-warning/40 [:hover,[data-pressed]]:bg-warning/16 dark:[:hover,[data-pressed]]:bg-warning/24",
}

FONT_SIZES = {"xs", "sm", "base", "lg", "xl", "[11px]"}

def split_mods(cls):
    """Splits on ':' outside brackets: 'sm:[&_svg]:size-4' -> (['sm', '[&_svg]'], 'size-4')."""
    parts, depth, cur = [], 0, ""
    for ch in cls:
        if ch == "[": depth += 1
        elif ch == "]": depth -= 1
        if ch == ":" and depth == 0:
            parts.append(cur); cur = ""
        else:
            cur += ch
    return parts, cur + "" if not parts else cur

def group(util):
    """Conflict group of a utility, or None when it conflicts with nothing in Button."""
    m = re.match(r"^\[(--[\w-]+):", util)
    if m: return m.group(1)
    if util in ("relative", "absolute"): return "position"
    if util.startswith("text-"):
        return "font-size" if util[5:] in FONT_SIZES else "text-color"
    if util.startswith("rounded"): return "rounded"
    if util.startswith("gap-"): return "gap"
    if util.startswith("size-"): return "size"
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

PLUS = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" '
        'class="lucide lucide-plus" aria-hidden="true"><path d="M5 12h14"></path><path d="M12 5v14"></path></svg>')

def button(variant, size, title):
    cls = merge(f"{BASE} {VARIANTS[variant]} {SIZES[size]}")
    return f'<button type="button" data-slot="button" class="{cls}">{PLUS}{title}</button>'

def camel(name):
    head, *rest = name.split("-")
    return head + "".join(p.capitalize() for p in rest)

cases = []
for v in VARIANTS:
    case = {"name": f"{v}.sm", "html": button(v, "sm", v),
            "native": {"variant": camel(v), "size": "sm", "title": v, "icon": "plus"}}
    if v == "media-navigation":
        # It is `absolute top-1/2 -translate-y-1/2`, so it needs a positioned parent with a height.
        case["wrapperStyle"] = "position:relative;display:inline-block;width:200px;height:28px"
    cases.append(case)
for s in SIZES:
    if s == "sm": continue
    title = "" if s.startswith("icon") else s
    cases.append({"name": f"outline.{s}", "html": button("outline", s, title),
                  "native": {"variant": "outline", "size": camel(s), "title": title, "icon": "plus"}})

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = {"component": "button",
        "source": "apps/web/src/components/ui/button.tsx",
        "states": ["rest", "hover", "active", "focus-visible", "disabled"],
        "themes": ["light", "dark"],
        "cases": cases}
with open(os.path.join(root, "design/component-reference/button.json"), "w") as f:
    json.dump(spec, f, indent=1)
print(len(cases), "cases")
