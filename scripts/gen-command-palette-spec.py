"""Writes design/component-reference/command-palette.json for scripts/component-reference: the whole command
palette popup (CommandDialogPopup > CommandPaletteContent) in the states CandyWrapper builds: the root
actions, a submenu (Change appearance), search results with projects and threads, and the empty state.

Class strings come from apps/web/src/components/{CommandPaletteContent,CommandPaletteResults}.tsx and
ui/{command,autocomplete,input,kbd,dialog-styles}.tsx at the tag in T3_VERSION. Thread rows use a text
description where T3 renders ThreadCommandSubtitle (favicon, provider icon), as CandyWrapper does.
Usage: /usr/bin/python3 -I scripts/gen-command-palette-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

# dialog-styles.ts DIALOG_POPUP_CLASS plus CommandDialogPopup (command.tsx:61-67).
POPUP = ("dialog-glass -translate-y-[calc(1.25rem*var(--nested-dialogs))] relative flex min-h-0 w-full min-w-0 scale-[calc(1-0.1*var(--nested-dialogs))] flex-col opacity-[calc(1-0.1*var(--nested-dialogs))] outline-none transition-[scale,opacity,translate] duration-200 ease-in-out will-change-transform rounded-2xl border "
         "pointer-events-auto max-h-105 max-w-xl text-foreground")
# input.tsx control and field, size lg, with CommandInput's and AutocompleteInput's start-addon classes.
CONTROL = ("relative inline-flex w-full rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] sm:text-sm dark:bg-input/32 "
           "*:data-[slot=autocomplete-input]:ps-[calc(--spacing(8.5)-1px)] sm:*:data-[slot=autocomplete-input]:ps-[calc(--spacing(8)-1px)] "
           "border-transparent! bg-transparent! shadow-none before:hidden has-focus-visible:ring-0 placeholder:text-placeholder *:data-[slot=autocomplete-input]:ps-9! sm:*:data-[slot=autocomplete-input]:ps-[calc(var(--command-shell-inset)+1.5rem)]!")
FIELD = "h-8.5 w-full min-w-0 rounded-[inherit] px-[calc(--spacing(3)-1px)] leading-8.5 outline-none placeholder:text-placeholder sm:h-7.5 sm:leading-7.5 h-9.5 leading-9.5 sm:h-8.5 sm:leading-8.5"
ADDON = ("[&_svg]:-mx-0.5 pointer-events-none has-[button]:pointer-events-auto absolute inset-y-0 start-px z-10 flex items-center ps-[calc(--spacing(3)-1px)] opacity-80 "
         "[&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4")
PANEL = "relative min-h-0 overflow-hidden rounded-t-xl bg-transparent max-h-[min(28rem,70vh)]"
FOOTER = ("relative flex items-center justify-between gap-2 rounded-b-[calc(var(--radius-2xl)-1px)] border-t border-foreground/[0.07] bg-foreground/[0.025] px-[var(--command-content-inset)] py-2.5 font-medium text-sm text-muted-foreground "
          "[&_[data-slot=kbd-group]]:font-sans [&_[data-slot=kbd]]:bg-foreground/[0.08] [&_[data-slot=kbd]]:text-foreground [&_[data-slot=kbd]]:ring-0")
KBD = "pointer-events-none inline-flex h-5 min-w-5 select-none items-center justify-center gap-1 rounded bg-foreground/[0.07] px-1 font-medium font-sans text-muted-foreground text-xs [&_svg:not([class*='size-'])]:size-3"
ITEM = ("flex min-h-8 select-none items-center gap-2 rounded-sm px-2 text-base outline-none data-disabled:pointer-events-none data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='text-'])]:text-muted-foreground "
        "py-1.5 cursor-pointer hover:bg-transparent hover:text-inherit")
LABEL = "px-2 py-1.5 font-medium text-muted-foreground text-xs"
SHORTCUT = "ms-auto font-medium font-sans text-secondary-label text-xs tracking-widest"
ICON = "size-4 text-icon-muted"  # CommandPalette.logic.ts ITEM_ICON_CLASS

def input_row(placeholder, value, back, addon_icon=None, accessory=""):
    addon = (f'<button type="button" class="flex cursor-pointer items-center" aria-label="Back">{lucide("arrow-left", "")}</button>' if back
             else lucide(addon_icon, "") if addon_icon else lucide("search", "translate-x-0.5 text-icon-muted"))
    v = f' value="{value}"' if value else ""
    return ('<div class="relative"><div class="px-[var(--command-shell-inset)] py-1.5 [&_[data-slot=autocomplete-start-addon]]:ps-[calc(var(--command-shell-inset)+0.0625rem)]">'
            '<div class="relative not-has-[>*.w-full]:w-fit w-full text-foreground has-disabled:opacity-64">'
            f'<div aria-hidden="true" class="{ADDON}" data-slot="autocomplete-start-addon">{addon}</div>'
            f'<span class="{CONTROL}" data-size="lg" data-slot="input-control"><input class="{FIELD}" data-slot="autocomplete-input" placeholder="{placeholder}"{v}></span>'
            f'</div></div>{accessory}</div>')

def row(icon, title, active=False, emphasis=None, desc=None, shortcut=None, chevron=False, note=None, stamp=None):
    t = title + (f'<span class="font-semibold">{emphasis}</span>' if emphasis else "")
    if desc:
        body = ('<span class="flex min-w-0 flex-1 flex-col"><span class="flex min-w-0 items-center gap-1.5 text-sm text-foreground">'
                f'<span class="truncate">{t}</span></span><span class="min-w-0 text-muted-foreground/70 text-xs">{desc}</span></span>')
    else:
        body = f'<span class="flex min-w-0 flex-1 items-center gap-1.5 text-sm text-foreground"><span class="truncate">{t}</span></span>'
    out = lucide(icon, ICON) + body
    if note: out += f'<span class="text-xs text-muted-foreground/70">{note}</span>'
    if stamp: out += f'<span class="min-w-12 shrink-0 text-right text-xs tabular-nums text-muted-foreground/70">{stamp}</span>'
    if shortcut: out += f'<kbd class="{SHORTCUT}" data-slot="command-shortcut">{shortcut}</kbd>'
    if chevron: out += lucide("chevron-right", "-me-0.5 ms-auto size-4 shrink-0 text-muted-foreground/70")
    cls = ITEM + (" bg-accent! text-accent-foreground!" if active else "")
    return f'<div role="option" data-slot="command-item" class="{cls}"{" data-active" if active else ""}>{out}</div>'

def results(groups):
    rows = ""
    for i, (label, items) in enumerate(groups):
        rows += f'<div class="{"pt-1.5" if i else ""}"><div class="{LABEL}" data-slot="command-group-label">{label}</div></div>' + "".join(items)
    return ('<div class="flex max-h-[inherit] flex-col size-full min-w-0" data-slot="command-list">'
            f'<div class="min-h-0 scroll-py-6 overflow-x-hidden overscroll-y-contain py-2"><div class="px-2">{rows}</div></div></div>')

def footer(back, action="Select", trailing=""):
    def hint(keys, text):
        inner = "".join('<kbd data-slot="kbd" class="' + KBD + '">' + k + "</kbd>" for k in keys)
        return f'<kbd data-slot="kbd-group" class="inline-flex items-center gap-1">{inner}<span>{text}</span></kbd>'
    hints = hint([lucide("arrow-up", ""), lucide("arrow-down", "")], "Navigate") + (hint(["Enter"], action) if action else "")
    if back: hints += hint(["Backspace"], "Back")
    hints += hint(["Esc"], "Close")
    return f'<div class="{FOOTER}" data-slot="command-footer"><div class="flex items-center gap-3">{hints}</div>{trailing}</div>'

def palette(body, placeholder="Search commands, projects, and threads...", value="", back=False, addon_icon=None, accessory="",
            action="Select", trailing=""):
    return (f'<div role="dialog" data-slot="command-dialog-popup" class="{POPUP}">'
            f'{input_row(placeholder, value, back, addon_icon, accessory)}<div class="{PANEL}">{body}</div>{footer(back, action, trailing)}</div>')

# ThreadSearchMatch.tsx:51-66 under a thread row (CommandPaletteResults.tsx:205-218).
def match_row(title, desc, stamp, source, before, hit, after, active=False):
    tag = ('<span class="text-info-foreground">You:</span>' if source == "user" else '<span class="text-success-foreground">Agent:</span>')
    excerpt = (f'<span class="truncate text-xs text-muted-foreground/85">{tag} {before}'
               f'<mark class="bg-transparent font-semibold text-foreground">{hit}</mark>{after}</span>')
    body = ('<span class="flex min-w-0 flex-1 flex-col"><span class="flex min-w-0 items-center gap-1.5 text-sm text-foreground">'
            f'<span class="truncate">{title}</span></span>{excerpt}<span class="min-w-0 text-muted-foreground/70 text-xs">{desc}</span></span>')
    out = lucide("message-square", ICON) + body + f'<span class="min-w-12 shrink-0 text-right text-xs tabular-nums text-muted-foreground/70">{stamp}</span>'
    cls = ITEM + (" bg-accent! text-accent-foreground!" if active else "")
    return f'<div role="option" data-slot="command-item" class="{cls}"{" data-active" if active else ""}>{out}</div>'

# button.tsx base, outline, xs (scripts/gen-button-spec.py), then the accessory's own classes (CommandPalette.tsx:3404-3440).
# `cn()` drops the base's `relative` for `absolute`; the placement is repeated inline as well.
BUTTON = ("[--control-icon-color:currentColor] [&_svg]:-mx-0.5 relative inline-flex shrink-0 cursor-pointer items-center justify-center gap-2 whitespace-nowrap rounded-[var(--control-radius)] border font-medium text-base outline-none transition-[box-shadow,scale] before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--control-radius)-1px)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 sm:text-sm [&_svg:not([class*='text-'])]:text-[var(--control-icon-color)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0 ")
OUTLINE = ("[--control-icon-color:var(--contrast-muted-foreground)] border-input bg-popover not-dark:bg-clip-padding text-foreground shadow-xs/5 not-disabled:not-active:not-data-pressed:before:shadow-[0_1px_--theme(--color-black/4%)] dark:bg-input/32 dark:not-disabled:before:shadow-[0_-1px_--theme(--color-white/2%)] dark:not-disabled:not-active:not-data-pressed:before:shadow-[0_-1px_--theme(--color-white/6%)] ")
GHOST_MUTED = "[--control-icon-color:currentColor] border-transparent text-muted-foreground data-pressed:bg-accent "
XS = "h-7 gap-1 px-[calc(--spacing(2)-1px)] text-sm sm:h-6 sm:text-xs [&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5 "
ACCESSORY = (f'<button type="button" tabindex="-1" class="{BUTTON.replace("relative ", "")}{OUTLINE}{XS}absolute inset-e-2.5 top-1/2 -translate-y-1/2" style="inset-inline-end:0.625rem;top:50%;translate:0 -50%"><span>Add</span>'
             f'<kbd data-slot="kbd-group" class="inline-flex items-center gap-1 pointer-events-none -me-0.5"><kbd data-slot="kbd" class="{KBD}">Enter</kbd></kbd-group></button>')
FINDER = f'<button type="button" class="{BUTTON}{GHOST_MUTED}{XS}h-auto px-2 text-xs hover:bg-transparent">Open in Finder</button>'

EMPTY = '<div class="py-10 text-center text-sm text-muted-foreground">{}</div>'

cases = [
    {"name": "root", "html": palette(results([("Actions", [
        row("square-pen", "New thread in ", active=True, emphasis="demo-repo", shortcut="⇧⌘O"),
        row("square-pen", "New thread in...", chevron=True),
        row("folder-plus", "Add project"),
        row("monitor", "Change appearance", shortcut="⌥⇧⌘A", chevron=True),
        row("settings", "Open settings"),
    ])])), "native": {"case": "root"}},
    {"name": "submenu", "html": palette(results([("Change appearance", [
        row("monitor", "System", note="Current"), row("sun", "Light"), row("moon", "Dark"),
    ])]), placeholder="Search...", back=True), "native": {"case": "submenu"}},
    {"name": "search", "html": palette(results([
        ("Projects", [row("folder", "demo-repo", active=True, desc="Local · /Users/mrm/demo-repo")]),
        ("Threads", [row("message-square", "Reply with markdown only", desc="demo-repo · Local", stamp="18m ago"),
                     row("message-square", "Add notes and docstring", desc="demo-repo · Local", stamp="2d ago")]),
    ]), value="demo"), "native": {"case": "search"}},
    {"name": "empty", "html": palette(EMPTY.format("No matching commands, projects, or threads."), value="zzzz"), "native": {"case": "empty"}},
    {"name": "match", "html": palette(results([
        ("Threads", [match_row("Write a story", "demo-repo · Local", "2m ago", "assistant", "The ", "lighthouse", " keeper climbed", active=True),
                     match_row("Plan a migration", "demo-repo · Local", "16m ago", "user", "move the ", "lighthouse", " policies")]),
    ]), value="lighthouse"), "native": {"case": "match"}},
    {"name": "browse", "html": palette(results([("Directories", [
        row("corner-left-up", ".."), row("folder", "demo-repo"), row("folder", "git-demo"),
    ])]), placeholder="Enter project path (e.g. ~/projects/my-app)", value="~/sandbox/", addon_icon="folder-plus", accessory=ACCESSORY,
        action=None, trailing=FINDER), "native": {"case": "browse"}},
]
spec = {"component": "command-palette", "source": "apps/web/src/components/CommandPaletteContent.tsx",
        "states": ["rest"], "themes": ["light", "dark"],
        "cases": [dict(c, wrapperStyle="display:block;width:576px") for c in cases]}
with open(os.path.join(ROOT, "design/component-reference/command-palette.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
