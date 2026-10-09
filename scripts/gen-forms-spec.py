"""Writes the batch A specs for scripts/component-reference: input, textarea, input-group, label,
kbd, badge, separator, skeleton, spinner (design/component-reference/<component>.json).

Class strings are copied from apps/web/src/components/ui/*.tsx at the tag in T3_VERSION, already
merged by hand where cn() would drop a class (only Badge sm and Input compact need it).
Sizes the consumer sets with className (Skeleton) use inline styles, because the compiled
stylesheet only contains classes T3 itself uses.
Usage: /usr/bin/python3 -I scripts/gen-forms-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def svg(name, paths, cls=""):
    cls_attr = f' class="lucide lucide-{name} {cls}"'.replace(" \"", "\"")
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
            f'{cls_attr} aria-hidden="true">{paths}</svg>')

SEARCH = svg("search", '<path d="m21 21-4.34-4.34"></path><circle cx="11" cy="11" r="8"></circle>')
ARROW_UP = svg("arrow-up", '<path d="m5 12 7-7 7 7"></path><path d="M12 19V5"></path>')
LOADER = '<path d="M21 12a9 9 0 1 1-6.219-8.56"></path>'

def write(component, source, states, cases):
    for c in cases:
        if component in ("label", "kbd", "badge"): c.setdefault("wrapperStyle", "display:flex")
    spec = {"component": component, "source": source, "states": states, "themes": ["light", "dark"], "cases": cases}
    with open(os.path.join(ROOT, f"design/component-reference/{component}.json"), "w") as f:
        json.dump(spec, f, indent=1)
    print(component, len(cases), "cases")

# Input (input.tsx)
INPUT_INNER = {
    "default": "h-8.5 w-full min-w-0 rounded-[inherit] px-[calc(--spacing(3)-1px)] leading-8.5 outline-none placeholder:text-placeholder sm:h-7.5 sm:leading-7.5 [transition:background-color_5000000s_ease-in-out_0s]",
    "compact": "w-full min-w-0 rounded-[inherit] outline-none placeholder:text-placeholder [transition:background-color_5000000s_ease-in-out_0s] h-7 px-[calc(--spacing(2.5)-1px)] text-xs leading-7 sm:h-7 sm:leading-7",
    "sm": "w-full min-w-0 rounded-[inherit] outline-none placeholder:text-placeholder [transition:background-color_5000000s_ease-in-out_0s] h-7.5 px-[calc(--spacing(2.5)-1px)] leading-7.5 sm:h-6.5 sm:leading-6.5",
    "lg": "w-full min-w-0 rounded-[inherit] px-[calc(--spacing(3)-1px)] outline-none placeholder:text-placeholder [transition:background-color_5000000s_ease-in-out_0s] h-9.5 leading-9.5 sm:h-8.5 sm:leading-8.5",
}
INPUT_WRAP = "relative inline-flex w-full rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-has-disabled:not-has-focus-visible:not-has-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] has-focus-visible:has-aria-invalid:border-destructive/64 has-focus-visible:has-aria-invalid:ring-destructive/16 has-aria-invalid:border-destructive/36 has-focus-visible:border-ring has-autofill:bg-foreground/4 has-disabled:opacity-64 has-[:disabled,:focus-visible,[aria-invalid]]:shadow-none has-focus-visible:ring-[3px] sm:text-sm dark:bg-input/32 dark:has-autofill:bg-foreground/8 dark:has-aria-invalid:ring-destructive/24 dark:not-has-disabled:not-has-focus-visible:not-has-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)]"
COMPACT_WRAP = INPUT_WRAP.replace("rounded-lg ", "").replace("before:rounded-[calc(var(--radius-lg)-1px)] ", "") + " rounded-md before:rounded-[calc(var(--radius-md)-1px)]"

def input_html(size="default", placeholder="", value="", mono=False, invalid=False):
    wrap = COMPACT_WRAP if size == "compact" else INPUT_WRAP
    if mono: wrap += " font-mono tabular-nums"
    attrs = f' placeholder="{placeholder}"' if placeholder else ""
    attrs += f' value="{value}"' if value else ""
    attrs += ' aria-invalid="true"' if invalid else ""
    return (f'<span class="{wrap}" data-size="{size}" data-slot="input-control">'
            f'<input class="{INPUT_INNER[size]}" data-slot="input" type="text"{attrs}></span>')

W240 = "display:block;width:240px"
cases = []
for size in ["default", "sm", "compact", "lg"]:
    cases.append({"name": f"{size}.placeholder", "html": input_html(size, placeholder="Search threads"),
                  "stateTarget": "input", "wrapperStyle": W240,
                  "native": {"size": size, "placeholder": "Search threads"}})
cases.append({"name": "default.value", "html": input_html(value="Hello world"), "stateTarget": "input",
              "wrapperStyle": W240, "native": {"size": "default", "value": "Hello world"}})
cases.append({"name": "mono.value", "html": input_html(value="/usr/local/bin 0123", mono=True), "stateTarget": "input",
              "wrapperStyle": W240, "native": {"size": "default", "value": "/usr/local/bin 0123", "font": "mono"}})
cases.append({"name": "invalid.value", "html": input_html(value="not an email", invalid=True), "stateTarget": "input",
              "wrapperStyle": W240, "native": {"size": "default", "value": "not an email", "invalid": "true"}})
write("input", "apps/web/src/components/ui/input.tsx", ["rest", "focus-visible", "disabled"], cases)

# Textarea (textarea.tsx)
TA_WRAP = "relative inline-flex w-full rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] has-focus-visible:has-aria-invalid:border-destructive/64 has-focus-visible:has-aria-invalid:ring-destructive/16 has-aria-invalid:border-destructive/36 has-focus-visible:border-ring has-disabled:opacity-64 has-[:disabled,:focus-visible,[aria-invalid]]:shadow-none has-focus-visible:ring-[3px] not-has-disabled:has-not-focus-visible:not-has-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] sm:text-sm dark:bg-input/32 dark:has-aria-invalid:ring-destructive/24 dark:not-has-disabled:has-not-focus-visible:not-has-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)]"
TA_INNER = {
    "default": "field-sizing-content min-h-17.5 max-h-64 w-full rounded-[inherit] px-[calc(--spacing(3)-1px)] py-[calc(--spacing(1.5)-1px)] outline-none max-sm:min-h-20.5",
    "sm": "field-sizing-content max-h-64 w-full rounded-[inherit] outline-none min-h-16.5 px-[calc(--spacing(2.5)-1px)] py-[calc(--spacing(1)-1px)] max-sm:min-h-19.5",
    "lg": "field-sizing-content max-h-64 w-full rounded-[inherit] px-[calc(--spacing(3)-1px)] outline-none min-h-18.5 py-[calc(--spacing(2)-1px)] max-sm:min-h-21.5",
}

def textarea_html(size="default", placeholder="", value="", invalid=False):
    attrs = f' placeholder="{placeholder}"' if placeholder else ""
    attrs += ' aria-invalid="true"' if invalid else ""
    return (f'<span class="{TA_WRAP}" data-size="{size}" data-slot="textarea-control">'
            f'<textarea class="{TA_INNER[size]}" data-slot="textarea"{attrs}>{value}</textarea></span>')

cases = []
for size in ["default", "sm", "lg"]:
    cases.append({"name": f"{size}.placeholder", "html": textarea_html(size, placeholder="Describe the change"),
                  "stateTarget": "textarea", "wrapperStyle": W240,
                  "native": {"size": size, "placeholder": "Describe the change"}})
cases.append({"name": "default.value", "html": textarea_html(value="First line\nSecond line\nThird line\nFourth line"),
              "stateTarget": "textarea", "wrapperStyle": W240,
              "native": {"size": "default", "value": "First line\nSecond line\nThird line\nFourth line"}})
cases.append({"name": "invalid.value", "html": textarea_html(value="Too short", invalid=True), "stateTarget": "textarea",
              "wrapperStyle": W240, "native": {"size": "default", "value": "Too short", "invalid": "true"}})
write("textarea", "apps/web/src/components/ui/textarea.tsx", ["rest", "focus-visible", "disabled"], cases)

# InputGroup (input-group.tsx). The input inside is Input with `unstyled`, so its wrapper span has no class.
IG_BASE = "relative inline-flex w-full min-w-0 items-center rounded-[var(--control-radius)] border text-base text-foreground ring-ring/24 transition-shadow has-[input:focus-visible,textarea:focus-visible]:has-[input[aria-invalid],textarea[aria-invalid]]:border-destructive/64 has-[input:focus-visible,textarea:focus-visible]:has-[input[aria-invalid],textarea[aria-invalid]]:ring-destructive/16 has-[textarea]:h-auto has-data-[align=block-end]:h-auto has-data-[align=block-start]:h-auto has-data-[align=block-end]:flex-col has-data-[align=block-start]:flex-col has-[input:focus-visible,textarea:focus-visible]:border-ring has-[input[aria-invalid],textarea[aria-invalid]]:border-destructive/36 has-autofill:bg-foreground/4 has-[input:disabled,textarea:disabled]:opacity-64 has-[input:disabled,textarea:disabled,input:focus-visible,textarea:focus-visible,input[aria-invalid],textarea[aria-invalid]]:shadow-none has-[input:focus-visible,textarea:focus-visible]:ring-[3px] sm:text-sm dark:has-autofill:bg-foreground/8 dark:has-[input[aria-invalid],textarea[aria-invalid]]:ring-destructive/24 has-data-[align=inline-start]:**:[[data-size=sm]_input]:ps-1.5 has-data-[align=inline-end]:**:[[data-size=sm]_input]:pe-1.5 *:[[data-slot=input-control],[data-slot=textarea-control]]:contents *:[[data-slot=input-control],[data-slot=textarea-control]]:before:hidden has-[[data-align=block-start],[data-align=block-end]]:**:[input]:h-auto has-data-[align=inline-start]:**:[input]:ps-2 has-data-[align=inline-end]:**:[input]:pe-2 has-data-[align=block-end]:**:[input]:pt-1.5 has-data-[align=block-start]:**:[input]:pb-1.5 **:[textarea]:min-h-20.5 **:[textarea]:resize-none **:[textarea]:py-[calc(--spacing(3)-1px)] **:[textarea]:max-sm:min-h-23.5 **:[textarea_button]:rounded-[calc(var(--control-radius)-1px)]"
IG_VARIANT = {
    "default": "border-input bg-background not-dark:bg-clip-padding shadow-xs/5 before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] not-has-[input:disabled,textarea:disabled]:not-has-[input:focus-visible,textarea:focus-visible]:not-has-[input[aria-invalid],textarea[aria-invalid]]:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-has-[input:disabled,textarea:disabled]:not-has-[input:focus-visible,textarea:focus-visible]:not-has-[input[aria-invalid],textarea[aria-invalid]]:before:shadow-[0_-1px_--theme(--color-white/6%)]",
    "ghost": "border-transparent bg-transparent shadow-none hover:bg-muted/40 has-[input:focus-visible,textarea:focus-visible]:bg-background",
}
ADDON = "[&_svg]:-mx-0.5 flex h-auto cursor-text select-none items-center justify-center gap-2 leading-none [&>kbd]:rounded-[calc(var(--radius)-5px)] in-[[data-slot=input-group]:has([data-slot=input-control],[data-slot=textarea-control])]:[&_svg:not([class*='size-'])]:size-4.5 sm:in-[[data-slot=input-group]:has([data-slot=input-control],[data-slot=textarea-control])]:[&_svg:not([class*='size-'])]:size-4 not-has-[button]:**:[svg:not([class*='opacity-'])]:opacity-80"
ADDON_ALIGN = {
    "inline-start": "has-[>:last-child[data-slot=badge]]:-ms-1.5 has-[>button]:-ms-2 order-first ps-[calc(--spacing(3)-1px)] has-[>kbd:last-child]:ms-[-0.35rem] [[data-size=sm]+&]:ps-[calc(--spacing(2.5)-1px)]",
    "inline-end": "has-[>:last-child[data-slot=badge]]:-me-1.5 has-[>button]:-me-2 order-last pe-[calc(--spacing(3)-1px)] has-[>kbd:last-child]:me-[-0.35rem] [[data-size=sm]+&]:pe-[calc(--spacing(2.5)-1px)]",
}
KBD = "pointer-events-none inline-flex h-5 min-w-5 select-none items-center justify-center gap-1 rounded bg-muted px-1 font-medium font-sans text-muted-foreground text-xs [&_svg:not([class*='size-'])]:size-3"

def addon(align, content):
    return f'<div class="{ADDON} {ADDON_ALIGN[align]}" data-align="{align}" data-slot="input-group-addon">{content}</div>'

def group_html(variant="default", size="default", start=None, end=None, placeholder="Search"):
    cls = IG_BASE + " " + IG_VARIANT[variant] + (" h-9" if size == "lg" else "")
    inner = (f'<span data-size="default" data-slot="input-control"><input class="{INPUT_INNER["default"]}" '
             f'data-slot="input" type="text" placeholder="{placeholder}"></span>')
    parts = inner
    if start: parts += addon("inline-start", start)
    if end: parts += addon("inline-end", end)
    return f'<div class="{cls}" data-slot="input-group" role="group">{parts}</div>'

cases = [
    {"name": "default.search", "html": group_html(start=SEARCH), "native": {"variant": "default", "start": "search"}},
    {"name": "default.search-kbd", "html": group_html(start=SEARCH, end=f'<kbd class="{KBD}" data-slot="kbd">⌘K</kbd>'),
     "native": {"variant": "default", "start": "search", "kbd": "⌘K"}},
    {"name": "lg.search", "html": group_html(size="lg", start=SEARCH), "native": {"variant": "default", "size": "lg", "start": "search"}},
    {"name": "ghost.search", "html": group_html(variant="ghost", start=SEARCH), "native": {"variant": "ghost", "start": "search"}},
]
for c in cases:
    c["stateTarget"] = "input"
    c["wrapperStyle"] = W240
write("input-group", "apps/web/src/components/ui/input-group.tsx", ["rest", "focus-visible", "disabled"], cases)
# Forced :hover does not propagate to ancestors, so group hover needs the group itself as the target.
hover = [dict(c, stateTarget=None) for c in cases if c["name"] in ("default.search", "ghost.search")]
for c in hover: del c["stateTarget"]
write("input-group-hover", "apps/web/src/components/ui/input-group.tsx", ["hover"], hover)

# Label (label.tsx)
LABEL = "inline-flex items-center gap-2 text-base/4.5 sm:text-sm/4 font-medium text-foreground"
FLEX = "display:flex"
write("label", "apps/web/src/components/ui/label.tsx", ["rest"], [
    {"name": "text", "html": f'<label class="{LABEL}" data-slot="label">Email address</label>', "native": {"text": "Email address"}},
    {"name": "short", "html": f'<label class="{LABEL}" data-slot="label">Name</label>', "native": {"text": "Name"}},
])

# Kbd and KbdGroup (kbd.tsx)
def kbd(content): return f'<kbd class="{KBD}" data-slot="kbd">{content}</kbd>'
GROUP = "inline-flex items-center gap-1"
write("kbd", "apps/web/src/components/ui/kbd.tsx", ["rest"], [
    {"name": "esc", "html": kbd("Esc"), "native": {"keys": "Esc"}},
    {"name": "cmd", "html": kbd("⌘"), "native": {"keys": "⌘"}},
    {"name": "shortcut", "html": kbd("⇧⌘K"), "native": {"keys": "⇧⌘K"}},
    {"name": "enter", "html": kbd("Enter"), "native": {"keys": "Enter"}},
    {"name": "icon", "html": kbd(ARROW_UP), "native": {"icon": "arrowUp"}},
    {"name": "group", "html": f'<kbd class="{GROUP}" data-slot="kbd-group">{kbd("⌘")}{kbd("K")}</kbd>', "native": {"group": "⌘,K"}},
])

# Badge (badge.tsx)
BADGE = "relative inline-flex shrink-0 items-center justify-center gap-1 whitespace-nowrap rounded-sm border border-transparent font-medium outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 [&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-3.5 sm:[&_svg:not([class*='size-'])]:size-3 [&_svg]:pointer-events-none [&_svg]:shrink-0 [button&,a&]:cursor-pointer [button&,a&]:pointer-coarse:after:absolute [button&,a&]:pointer-coarse:after:size-full [button&,a&]:pointer-coarse:after:min-h-11 [button&,a&]:pointer-coarse:after:min-w-11"
BADGE_BASE_NO_RADIUS = BADGE.replace(" rounded-sm", "")
BADGE_SIZES = {
    "control": "h-7 min-w-7 rounded-[var(--control-radius)] px-[calc(--spacing(2)-1px)] text-sm sm:h-6 sm:min-w-6 sm:text-xs",
    "default": "h-5.5 min-w-5.5 px-[calc(--spacing(1)-1px)] text-sm sm:h-4.5 sm:min-w-4.5 sm:text-xs",
    "lg": "h-6.5 min-w-6.5 px-[calc(--spacing(1.5)-1px)] text-base sm:h-5.5 sm:min-w-5.5 sm:text-sm",
    "sm": "h-5 min-w-5 rounded-[.25rem] px-[calc(--spacing(1)-1px)] text-xs leading-none sm:h-4 sm:min-w-4 sm:text-[.625rem]",
}
BADGE_VARIANTS = {
    "default": "bg-primary text-primary-foreground [button&,a&]:hover:bg-primary/90",
    "destructive": "bg-destructive text-white [button&,a&]:hover:bg-destructive/90",
    "error": "bg-destructive/8 text-destructive-foreground dark:bg-destructive/16",
    "info": "bg-info/8 text-info-foreground dark:bg-info/16",
    "outline": "border-input bg-background text-foreground dark:bg-input/32 [button&,a&]:hover:bg-accent/50 dark:[button&,a&]:hover:bg-input/48",
    "secondary": "bg-secondary text-secondary-foreground [button&,a&]:hover:bg-secondary/90",
    "success": "bg-success/8 text-success-foreground dark:bg-success/16",
    "warning": "bg-warning/8 text-warning-foreground dark:bg-warning/16",
}

def badge(variant, size):
    base = BADGE_BASE_NO_RADIUS if size in ("control", "sm") else BADGE
    if variant == "outline": base = base.replace(" border-transparent", "")
    return f'<span class="{base} {BADGE_SIZES[size]} {BADGE_VARIANTS[variant]}" data-slot="badge">{variant if size == "default" else size}</span>'

cases = [{"name": f"{v}.default", "html": badge(v, "default"), "native": {"variant": v, "size": "default", "text": v}} for v in BADGE_VARIANTS]
cases += [{"name": f"outline.{s}", "html": badge("outline", s), "native": {"variant": "outline", "size": s, "text": s}} for s in ("sm", "lg", "control")]
cases += [{"name": "secondary.count", "html": f'<span class="{BADGE} {BADGE_SIZES["default"]} {BADGE_VARIANTS["secondary"]}" data-slot="badge">3</span>',
           "native": {"variant": "secondary", "size": "default", "text": "3"}}]
write("badge", "apps/web/src/components/ui/badge.tsx", ["rest"], cases)

# Separator (separator.tsx)
SEP = "shrink-0 bg-border data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:w-px data-[orientation=vertical]:not-[[class^='h-']]:not-[[class*='_h-']]:self-stretch"
write("separator", "apps/web/src/components/ui/separator.tsx", ["rest"], [
    {"name": "horizontal", "html": f'<div class="{SEP}" data-orientation="horizontal" data-slot="separator" role="separator"></div>',
     "wrapperStyle": "display:block;width:120px", "native": {"orientation": "horizontal", "length": "120"}},
    {"name": "vertical", "html": f'<div class="{SEP}" data-orientation="vertical" data-slot="separator" role="separator" aria-orientation="vertical"></div>',
     "wrapperStyle": "display:flex;height:24px", "native": {"orientation": "vertical", "length": "24"}},
])

# Skeleton (skeleton.tsx)
SK = {"block": "rounded-sm", "card": "rounded-lg", "pill": "rounded-full"}
write("skeleton", "apps/web/src/components/ui/skeleton.tsx", ["rest"], [
    {"name": shape, "html": f'<div class="bg-muted-foreground/15 motion-safe:animate-skeleton {SK[shape]}" data-slot="skeleton" style="width:{w}px;height:{h}px"></div>',
     "native": {"shape": shape, "width": str(w), "height": str(h)}}
    for shape, w, h in (("block", 120, 16), ("card", 160, 48), ("pill", 80, 20))
])

# Spinner (spinner.tsx)
SPIN_SIZE = {"xs": "size-3", "sm": "size-3.5", "md": "size-4", "lg": "size-5"}
cases = []
for size, cls in SPIN_SIZE.items():
    for tone in ("current", "muted"):
        extra = cls + (" text-muted-foreground" if tone == "muted" else "")
        cases.append({"name": f"{size}.{tone}",
                      "html": svg("loader-circle", LOADER, f"motion-safe:visible-animate-spin {extra}").replace('aria-hidden="true"', 'aria-label="Loading" role="status"'),
                      "native": {"size": size, "tone": tone}})
write("spinner", "apps/web/src/components/ui/spinner.tsx", ["rest"], cases)
