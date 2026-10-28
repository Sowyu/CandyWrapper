"""Writes design/component-reference/settings-pages.json for scripts/component-reference: the settings nav with
search results, a General section (Behavior's first rows: selects, switches and a server row's inheritance
indicator), and a Keybindings section.

Class strings are copied from apps/web/src/components/settings/{SettingsSidebarNav.tsx, settingsLayout.tsx,
SettingsPanels.tsx, NotificationSettings.tsx, SettingInheritance.tsx, KeybindingsSettings.tsx}, ui/sidebar.tsx,
ui/select.tsx and ui/kbd.tsx at the tag in T3_VERSION. The nav, row and section helpers come from
gen-connections-spec.py, the switch from gen-toggles-spec.py, the select trigger from gen-popups-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-settings-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def prefix(name, marker):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(marker)]


conn = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
exec(prefix("gen-connections-spec.py", "W796 ="), conn)
pop = {"__file__": os.path.join(ROOT, "scripts/gen-popups-spec.py")}
exec(prefix("gen-popups-spec.py", "cases = []\nfor variant, size, value, open_ in"), pop)
lucide, button, merge, MB, SIDEBAR, KBD = conn["lucide"], conn["button"], conn["merge"], conn["MB"], conn["SIDEBAR"], conn["KBD"]
switch = conn["tog_ns"]["switch"]
SIDEBAR_INPUT = conn["SIDEBAR_INPUT"]

# Nightly 3754 SettingsSidebarNav.tsx:313-348 with the query "time": the clear button replaces the Kbd, results replace the nav.
MB_SM = merge(MB.replace("h-8 rounded-[var(--control-radius)] px-[var(--sidebar-row-content-inset)] py-1.5 text-sm",
                         "h-7 rounded-lg p-2 text-xs") + " h-auto min-h-10 items-start") + " text-left"
# The script's merge drops `text-left` next to `text-xs`; tailwind-merge keeps both (alignment and size differ).
CLEAR = button("ghost-muted", "icon-micro", lucide("x", "size-3"), "shrink-0", ' aria-label="Clear settings search"')
search = ('<div class="flex h-8 items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium text-sidebar-muted-foreground hover:bg-sidebar-row-hover hover:text-sidebar-foreground">'
          f'{lucide("search", "size-4 shrink-0 text-sidebar-muted-foreground/80")}'
          f'<input type="search" placeholder="Search" value="time" class="{SIDEBAR_INPUT}">{CLEAR}</div>')
RESULTS = [("Time format", "General", "settings-2"), ("Permissions", "Threads", "messages-square"),
           ("Days of inactivity before auto-settle", "Threads", "messages-square"), ("Collapse composer on scroll", "Chat", "message-square-text"),
           ("Simulator support", "Devices", "smartphone")]


def result(title, section, icon, active):
    return (f'<li data-slot="sidebar-menu-item" class="group/menu-item relative" role="presentation"><button type="button" data-sidebar="menu-button" '
            f'data-slot="sidebar-menu-button" data-size="sm" data-active="{str(active).lower()}" role="option" class="{MB_SM}">'
            f'{lucide(icon, "size-4 shrink-0 text-[var(--sidebar-icon-color)]")}<span class="min-w-0 flex-1">'
            f'<span class="block truncate text-sm font-medium text-sidebar-foreground">{title}</span>'
            f'<span class="block truncate text-2xs text-sidebar-muted-foreground/75">{section}</span></span></button></li>')


results = "".join(result(t, s, i, n == 0) for n, (t, s, i) in enumerate(RESULTS))
nav_search = SIDEBAR.format('<div class="relative flex w-full min-w-0 flex-col p-[var(--sidebar-content-inset)]"><div class="flex flex-col gap-2">'
                            f'{search}<ul class="flex w-full min-w-0 flex-col gap-1" role="listbox">{results}</ul></div></div>')

# SettingsRow (settingsLayout.tsx:451-497) with the inheritance and reset spans.
ROW = conn["ROW"]
GROUP = conn["GROUP"]
SPAN = '<span class="inline-flex h-5 w-5 shrink-0 items-center justify-center">{}</span>'
LAYERS = button("ghost-muted", "icon-micro", lucide("layers", "size-3"))


def row(title, desc, control, server=False, desc_html=None, title_html=None):
    spans = (SPAN.format(LAYERS) if server else "") + SPAN.format("")
    d = desc_html if desc_html is not None else f'<p class="max-w-xl text-xs leading-normal text-muted-foreground/80">{desc}</p>'
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title_html or title}</h3>'
            f'{spans}</div>{d}</div>'
            f'<div class="flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end">{control}</div></div></div>')


def select(value, width_cls):
    html = pop["select_trigger"]("default", "sm", value)
    return html.replace('class="', f'class="{width_cls} ', 1).replace(" w-full min-w-36", " min-w-36")


def section(title, rows):
    return (f'<section class="space-y-2.5"><div class="flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4">'
            f'<div class="flex min-w-0 items-center gap-1"><h2 class="flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70">{title}</h2></div>'
            f'<div class="flex min-h-7 min-w-7 items-center justify-end"></div></div><div class="{GROUP}">{rows}</div></section>')


behavior = section("Behavior", "".join([
    row("Thread notifications", "System alerts when a thread finishes, fails, or needs input or approval. Applies to this device while T3 Code is open.",
        select("Off", "w-full sm:w-56")),
    row("In-app notifications", "Show a toast when another thread finishes, fails, or needs input or approval while this app has focus.",
        switch("default", "off", False)),
    row("Time format", "System default follows your browser or OS clock preference.", select("System default", "w-full sm:w-40")),
    row("Response streaming", "Each paragraph or code block appears as soon as it is complete.",
        select("Show finished paragraphs", "w-full sm:w-56"), server=True),
    row("Hide whitespace changes", "Set whether the diff panel ignores whitespace-only edits by default.", switch("default", "on", False)),
]))

# KeybindingsSettings.tsx: rows with the When line, the hover menu span and the pill (KeybindingPill, kbd.tsx).
PILL = ("inline-flex h-8 cursor-pointer items-center rounded-md border border-transparent px-1.5 sm:h-7 outline-none transition-colors "
        "hover:border-border/70 hover:bg-accent focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/24 -mr-1.5")


def kbds(parts):
    return '<kbd class="inline-flex items-center gap-1" data-slot="kbd-group">' + "".join(f'<kbd class="{KBD}" data-slot="kbd">{p}</kbd>' for p in parts) + "</kbd>"


def binding(label, parts, when):
    variant = "ghost" if when else "ghost-muted"
    trigger = button(variant, "micro", f'<span class="truncate font-mono">{when or "Always"}</span>{lucide("chevron-down", "size-3.5 shrink-0 opacity-60")}', "min-w-0 shrink")
    desc = ('<p class="max-w-xl text-xs leading-normal text-muted-foreground/80"><span class="flex h-6 items-center gap-1.5">'
            f'<span class="text-xs leading-none text-muted-foreground/70">When</span>{trigger}</span></p>')
    control = ('<div class="flex flex-wrap items-center justify-end gap-1.5"><span class="flex items-center opacity-0"></span>'
               f'<button type="button" class="{PILL}">{kbds(parts)}</button></div>')
    return row(label, "", control, desc_html=desc, title_html=f'<span class="flex items-center gap-2">{label}</span>').replace(
        'class="' + ROW, 'class="group/row rounded-none ' + ROW.replace("rounded-xl ", ""), 1)


keybindings = section("Navigation", "".join([
    binding("Command Palette: Toggle", ["⌘", "K"], "!terminalFocus"),
    binding("Editor: Open Favorite", ["⌘", "O"], ""),
    binding("Project Search: Toggle", ["⌘", "⇧", "F"], "!terminalFocus"),
]))

W796 = "display:block;width:796px"
cases = [
    {"name": "nav.search", "html": nav_search, "wrapperStyle": "display:block", "native": {"kind": "nav-search"}},
    {"name": "general.behavior", "html": behavior, "wrapperStyle": W796, "native": {"kind": "behavior"}},
    {"name": "keybindings.navigation", "html": keybindings, "wrapperStyle": W796, "native": {"kind": "keybindings"}},
]
spec = {"component": "settings-pages", "source": "apps/web/src/components/settings/SettingsPanels.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/settings-pages.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("settings-pages", len(cases), "cases")
