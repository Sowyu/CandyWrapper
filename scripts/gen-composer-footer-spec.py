"""Writes design/component-reference/composer-footer.json for scripts/component-reference: the composer
footer's narrow states (labels dropped, blocks moved into the "..." overflow trigger) and the overflow
menu (CompactComposerControlsMenu.tsx).

The cluster cases start at the traits block: model trigger fidelity is covered by reference 03c. Class
strings are copied from apps/web/src/components/chat/{ComposerControl,ChatComposer,TraitsPicker,
CompactComposerControlsMenu}.tsx and ui/menu.tsx at the tag in T3_VERSION. Traits use Claude Haiku 5.5
from fixtures/transcripts/01-basic.jsonl with Medium (its default) picked, access is Full access.
Usage: /usr/bin/python3 -I scripts/gen-composer-footer-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"

def icon(name, cls="", stroke="2"):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

# ComposerControl.tsx:17-26, size sm.
CONTROL = ("relative inline-flex shrink-0 cursor-pointer items-center justify-center whitespace-nowrap rounded-(--control-radius) border border-transparent text-base outline-none hover:bg-accent data-pressed:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 data-disabled:pointer-events-none data-disabled:opacity-64 [&:active:not([aria-haspopup])]:scale-[0.97] [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg]:-mx-0.5 [&_svg[data-composer-control-icon]]:mx-0 "
           "h-7 gap-1.5 px-2.5 font-medium text-secondary-label [&_svg:not([class*='text-'])]:text-muted-foreground hover:text-foreground sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 "
           "aria-pressed:bg-accent aria-pressed:text-accent-foreground aria-pressed:hover:bg-accent/80")
SEPARATOR = '<div role="separator" aria-orientation="vertical" data-slot="separator" class="shrink-0 bg-border data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:w-px data-[orientation=vertical]:self-stretch data-[orientation=vertical]:not-[[class^=\'h-\']]:not-[[class*=\'_h-\']]:self-stretch mx-0.5 hidden sm:block h-4" data-orientation="vertical"></div>'
CHEVRON = icon("chevron-down", "shrink-0 size-3.5 text-icon-muted", stroke="2.25").replace("aria-hidden", "data-composer-control-chevron aria-hidden")

def control_icon(name):
    return icon(name, "shrink-0 size-4").replace("aria-hidden", "data-composer-control-icon aria-hidden")

# The icon-only block hides labels out of flow (ChatComposer.tsx:5604).
ICON_ONLY = " [&_[data-composer-control-label]]:pointer-events-none [&_[data-composer-control-label]]:invisible [&_[data-composer-control-label]]:absolute [&_[data-composer-control-label]]:w-max [&_[data-composer-control-label]]:max-w-none"

def block(trigger_icon, label, icon_only):
    trigger = (f'<button type="button" aria-haspopup="menu" class="{CONTROL} shrink-0 whitespace-nowrap">'
               f'{control_icon(trigger_icon)}<span data-composer-control-label>{label}</span>{CHEVRON}</button>')
    cls = "flex w-max min-w-max shrink-0 items-center gap-1" + (ICON_ONLY if icon_only else "")
    return f'<div data-resting-block class="{cls}">{SEPARATOR}{trigger}</div>'

OVERFLOW = (f'<div data-resting-controls-overflow class="min-w-0 shrink-0"><button type="button" aria-haspopup="menu" aria-label="More composer controls" class="{CONTROL} shrink-0">'
            f'{control_icon("ellipsis")}</button></div>')

def cluster(icon_only, hidden):
    blocks = [("brain", "Medium"), ("lock-open", "Full access")]
    parts = [block(i, l, n >= len(blocks) - icon_only) for n, (i, l) in enumerate(blocks)][:len(blocks) - hidden]
    if hidden: parts.append(OVERFLOW)
    return f'<div class="flex items-center gap-1">{"".join(parts)}</div>'

# Menu (menu.tsx) with the radio items of CompactComposerControlsMenu.tsx and TraitsPicker.tsx:395-486.
GLASS_SHADOW = "shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)]"
MENU_POPUP = ("dropdown-glass relative flex origin-(--transform-origin) rounded-lg " + GLASS_SHADOW.split()[0] +
              " outline-none focus:outline-none " + GLASS_SHADOW.split()[1] +
              " [-webkit-app-region:no-drag] min-w-[min(10rem,calc(100vw-2rem))] max-w-[calc(100vw-2rem)]")
MENU_RADIO = "[&_svg]:-mx-0.5 flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base text-foreground outline-none data-checked:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"
MENU_SEP = '<div role="separator" class="mx-2 my-1 h-px bg-border" data-slot="menu-separator"></div>'
BADGE = ('<span class="relative inline-flex shrink-0 items-center justify-center gap-1 whitespace-nowrap border font-medium outline-none transition-shadow '
         'h-5 min-w-5 rounded-[.25rem] px-[calc(--spacing(1)-1px)] text-xs leading-none sm:h-4 sm:min-w-4 sm:text-[.625rem] border-input bg-background text-foreground dark:bg-input/32 min-w-0" data-slot="badge">Default</span>')

def radio(content, checked):
    attr = ' data-checked=""' if checked else ""
    return f'<div role="menuitemradio" class="{MENU_RADIO}"{attr} data-slot="menu-radio-item"><span class="min-w-0 flex-1">{content}</span></div>'

def traits_content():
    rows = []
    for v, label in [("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra High"), ("max", "Max"), ("ultrathink", "Ultrathink")]:
        badge = f" {BADGE}" if v == "medium" else ""
        rows.append(radio(f'<span class="flex w-full min-w-0 flex-col"><span class="flex w-full min-w-0 items-center justify-between gap-3">'
                          f'<span class="min-w-0 truncate">{label}{badge}</span></span></span>', v == "medium"))
    return f'<div><div role="group"><div class="px-2 pt-1.5 pb-1 font-medium text-muted-foreground text-xs">Reasoning</div>{"".join(rows)}</div></div>'

def overflow_menu(with_traits):
    access = [radio(l, l == "Full access") for l in ["Supervised", "Auto-accept edits", "Auto", "Full access"]]
    body = (traits_content() + MENU_SEP if with_traits else "") + \
        '<div class="px-2 py-1.5 font-medium text-muted-foreground text-xs">Access</div>' + "".join(access)
    return f'<div role="menu" class="{MENU_POPUP}" data-slot="menu-popup" data-side="bottom"><div class="max-h-(--available-height) w-full overflow-y-auto p-1">{body}</div></div>'

cases = []
for icon_only, hidden, name in [(1, 0, "access-icon"), (2, 0, "both-icon"), (2, 1, "overflow-access"), (2, 2, "overflow-both")]:
    cases.append({"name": f"cluster.{name}", "html": cluster(icon_only, hidden), "native": {"kind": "cluster", "iconOnly": str(icon_only), "hidden": str(hidden)}})
cases.append({"name": "menu.access", "html": overflow_menu(False), "native": {"kind": "menu", "traits": "false"}})
cases.append({"name": "menu.traits-access", "html": overflow_menu(True), "native": {"kind": "menu", "traits": "true"}})

# Question file answers above the editor (ChatComposer.tsx:7313-7386). The pierre icon is a blank
# 16px box here and hidden on our side: its sprite isn't in the static stylesheet (the changed files
# card covers the icons).
GHOST_ICON_XS = ("[&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 whitespace-nowrap rounded-[var(--control-radius)] border font-medium text-base outline-none "
                 "transition-[box-shadow,scale] [&:active:not([aria-haspopup])]:scale-[0.97] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] "
                 "focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 sm:text-sm "
                 "[&_svg:not([class*='text-'])]:text-[var(--control-icon-color)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0 "
                 "[--control-icon-color:var(--contrast-muted-foreground)] border-transparent text-foreground data-pressed:bg-accent [:hover,[data-pressed]]:bg-accent "
                 "size-7 sm:size-6 not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-4 sm:not-in-data-[slot=input-group]:[&_svg:not([class*='size-'])]:size-3.5")

def file_row(name, detail, failed=False):
    retry = f'<button type="button" data-slot="button" class="{GHOST_ICON_XS}">{icon("refresh-cw")}</button>' if failed else ""
    return (f'<div class="flex min-w-0 items-center gap-2 py-1 text-sm text-foreground"><span class="size-4 shrink-0"></span>'
            f'<button type="button" class="min-w-0 flex-1 truncate text-left">{name}</button>'
            f'<span class="shrink-0 text-xs text-secondary-label">{detail}</span>{retry}'
            f'<button type="button" data-slot="button" class="{GHOST_ICON_XS}">{icon("x")}</button></div>')

FILES = [("notes.txt", "3 KB", False), ("screenshot-2026-10-10-with-a-long-name.png", "45%", False), ("report.pdf", "1.4 MB", True)]
cases.append({"name": "files.question", "html": '<div class="flex flex-col gap-1" style="width:360px">' + "".join(file_row(*f) for f in FILES) + "</div>",
              "native": {"kind": "files"}})

spec = {"component": "composer-footer", "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/composer-footer.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
