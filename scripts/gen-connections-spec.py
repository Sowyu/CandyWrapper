"""Writes design/component-reference/connections.json for scripts/component-reference: the settings shell
(settings nav, Back footer, breadcrumb header), Settings > Connections ("This machine", the Environments
list with rows, routes and the empty state) and the Add Environment dialog.

Class strings are copied from apps/web/src/components/settings/{SettingsSidebarNav.tsx, settingsLayout.tsx,
ConnectionsSettings.tsx, EnvironmentRow.tsx, EnvironmentRoutesList.tsx, SettingsBreadcrumb.tsx},
components/WorkspaceBreadcrumb.tsx, components/EnvironmentMachineIcon.tsx and ui/*.tsx at the tag in
T3_VERSION. Button, Switch, Empty, Input and Dialog markup comes from the other spec generators.
Rows sit in a 796px column, the Connections page's content width in an 856px main area.
Usage: /usr/bin/python3 -I scripts/gen-connections-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"


def prefix(name, marker):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(marker)]


def between(name, start, end):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    i = src.index(start)
    return src[i:src.index(end, i)]


btn_ns = {}
exec(prefix("gen-button-spec.py", "cases = []"), btn_ns)
tog_ns = {"__file__": os.path.join(ROOT, "scripts/gen-toggles-spec.py")}
exec(prefix("gen-toggles-spec.py", "# 4. Checkbox"), tog_ns)
exec(between("gen-toggles-spec.py", "E_BASE =", "cases = []"), tog_ns)
form_ns = {"__file__": os.path.join(ROOT, "scripts/gen-forms-spec.py")}
exec(prefix("gen-forms-spec.py", "W240 ="), form_ns)
merge = btn_ns["merge"]


def lucide(name, cls=""):
    body = open(os.path.join(LUCIDE, f"{name}.svg")).read()
    inner = body[body.index(">", body.index("<svg")) + 1:body.rindex("</svg>")].strip()
    inner = re.sub(r"\s*\n\s*", "", inner)
    c = f' class="lucide lucide-{name} {cls}"'.replace(' "', '"')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"{c} aria-hidden="true">{inner}</svg>')


# EnvironmentMachineIcon.tsx: the Mac mini drawn to lucide's grammar.
def machine(kind, cls):
    if kind == "mac-mini":
        inner = '<rect width="20" height="8" x="2" y="8" rx="2"></rect><path d="M6 12h.01"></path>'
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
                f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="{cls}" aria-hidden="true">{inner}</svg>')
    return lucide({"server": "server", "laptop": "laptop"}[kind], cls)


def button(variant, size, inner, extra_cls="", attrs=""):
    cls = merge(f'{btn_ns["BASE"]} {btn_ns["VARIANTS"][variant]} {btn_ns["SIZES"][size]} {extra_cls}')
    return f'<button type="button" data-slot="button" class="{cls}"{attrs}>{inner}</button>'


# Settings nav (SettingsSidebarNav.tsx:244-345) with the sidebar.tsx menu button.
MB = ("peer/menu-button flex w-full cursor-pointer items-center gap-[var(--sidebar-control-gap)] overflow-hidden text-left outline-hidden ring-ring transition-[width,height,padding] hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 data-[active=true]:bg-sidebar-row-selected data-[active=true]:font-medium data-[active=true]:text-sidebar-foreground data-[state=open]:hover:bg-sidebar-row-hover data-[state=open]:hover:text-sidebar-foreground [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-[var(--sidebar-icon-color)] hover:[&>svg]:text-sidebar-foreground active:[&>svg]:text-sidebar-foreground data-[active=true]:[&>svg]:text-sidebar-foreground "
      "h-8 rounded-[var(--control-radius)] px-[var(--sidebar-row-content-inset)] py-1.5 text-sm font-medium text-sidebar-muted-foreground/80")
SNAPSHOT = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3H6a3 3 0 0 0-3 3v2M16 3h2a3 3 0 0 1 3 3v2M21 16v2a3 3 0 0 1-3 3h-2M8 21H6a3 3 0 0 1-3-3v-2"></path>'
            '<rect width="10" height="8" x="7" y="8" rx="2"></rect><circle cx="12" cy="12" r="1.5"></circle></svg>')
NAV = [("General", "settings-2"), ("Appearance", "palette"), ("Keybindings", "keyboard"), ("SnapShots", None), ("Providers", "bot"),
       ("Integrations", "blocks"), ("Scheduled Tasks", "calendar-clock"), ("Source Control", "git-branch"), ("Storage", "hard-drive"),
       ("Connections", "link-2"), ("Archive", "archive")]
SIDEBAR = '<div data-app-sidebar="" class="bg-sidebar text-sidebar-foreground" style="width:255px">{}</div>'


def menu_item(label, icon, active, disabled):
    svg = SNAPSHOT if icon is None else lucide(icon)
    attrs = f' data-active="{str(active).lower()}"' + (" disabled" if disabled else "")
    return (f'<li data-slot="sidebar-menu-item" class="group/menu-item relative"><button type="button" data-sidebar="menu-button" '
            f'data-slot="sidebar-menu-button" data-size="default"{attrs} class="{MB}">{svg}<span class="truncate">{label}</span></button></li>')


SIDEBAR_INPUT = ("min-w-0 flex-1 bg-transparent outline-none h-auto p-0 font-medium text-sidebar-foreground text-sm leading-normal "
                 "placeholder:text-sidebar-muted-foreground")
KBD = form_ns.get("KBD") or "pointer-events-none inline-flex h-5 min-w-5 select-none items-center justify-center gap-1 rounded bg-muted px-1 font-medium font-sans text-muted-foreground text-xs [&_svg:not([class*='size-'])]:size-3"
search = ('<div class="flex h-8 items-center gap-2 rounded-md px-2 py-1.5 text-sm font-medium text-sidebar-muted-foreground hover:bg-sidebar-row-hover hover:text-sidebar-foreground">'
          f'{lucide("search", "size-4 shrink-0 text-sidebar-muted-foreground/80")}'
          f'<input type="search" placeholder="Search" class="{SIDEBAR_INPUT}">'
          f'<kbd class="{KBD}" data-slot="kbd">/</kbd></div>')
menu = "".join(menu_item(label, icon, label == "Connections", label != "Connections") for label, icon in NAV)
nav = SIDEBAR.format('<div class="relative flex w-full min-w-0 flex-col p-[var(--sidebar-content-inset)]"><div class="flex flex-col gap-2">'
                     f'{search}<ul class="flex w-full min-w-0 flex-col gap-1">{menu}</ul></div></div>')
back = SIDEBAR.format('<div class="flex flex-col gap-2 px-[var(--sidebar-content-inset)] py-1"><div class="flex items-center gap-1"><div class="min-w-0 flex-1">'
                      '<ul class="flex w-full min-w-0 flex-col gap-1 flex-row items-center"><li class="group/menu-item relative min-w-0 flex-1">'
                      f'<button type="button" data-sidebar="menu-button" data-slot="sidebar-menu-button" data-active="false" class="{MB}">{lucide("arrow-left")}<span>Back</span></button>'
                      '</li></ul></div></div></div>')

# WorkspacePageHeader + SettingsBreadcrumb.
header = ('<header class="flex shrink-0 items-center gap-3" style="height:52px;padding-left:20px;width:600px"><div class="flex w-full items-center gap-3">'
          '<nav aria-label="Settings breadcrumb" class="min-w-0"><ol class="m-0 flex min-w-0 list-none items-center gap-2 p-0 text-sm sm:gap-3">'
          '<li class="flex min-w-0 items-center font-medium shrink-0 text-muted-foreground">Settings</li>'
          '<li aria-hidden="true" class="flex shrink-0 items-center text-icon-muted">/</li>'
          '<li aria-current="page" class="flex min-w-0 items-center font-medium text-foreground truncate">Connections</li></ol></nav></div></header>')

# SettingsSection / SettingsGroup / SettingsRow (settingsLayout.tsx).
GROUP = "relative overflow-visible text-foreground rounded-xl border border-border/60 bg-card/40 shadow-xs/5 [&>*+*]:border-t [&>*+*]:border-border/50 [&>[data-slot=settings-row]]:rounded-none"
ROW = "@container/settings-row rounded-xl px-3 sm:px-4 aria-disabled:opacity-64 aria-disabled:[&_*]:text-muted-foreground py-3"
ELLIPSIS = button("ghost-muted", "icon-xs", lucide("ellipsis", "size-3.5"))


def section(title, children, icon="", action=""):
    return (f'<section class="space-y-2.5"><div class="flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4">'
            f'<div class="flex min-w-0 items-center gap-1"><h2 class="flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70">{icon}{title}</h2></div>'
            f'<div class="flex min-h-7 min-w-7 items-center justify-end">{action}</div></div><div class="{GROUP}">{children}</div></section>')


def settings_row(title, desc, control):
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>'
            '<span class="inline-flex h-5 w-5 shrink-0 items-center justify-center"></span></div>'
            f'<p class="max-w-xl text-xs leading-normal text-muted-foreground/80">{desc}</p></div>'
            f'<div class="flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end">{control}</div></div></div>')


this_machine = section("miniko", settings_row("Version", "0.0.46-nightly.20261009.2861 · http://127.0.0.1:47391/",
                                              '<span class="text-xs text-muted-foreground">Up to date</span>'),
                       icon=machine("mac-mini", "size-4"), action=ELLIPSIS)

ADD = button("ghost-muted", "xs", lucide("plus", "size-3") + "<span>Add environment</span>", attrs=' aria-label="Add environment"')
CHEVRON_BTN = "inline-flex shrink-0 items-center gap-0.5 rounded-sm text-muted-foreground outline-none hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring"


def env_row(kind, label, subtitle, error, enabled, routes=None):
    status_cls = "min-w-0 truncate" + (" text-destructive" if error and enabled else "")
    n = len(routes) if routes else 1
    chevron = lambda open_: lucide("chevron-right", "size-3 shrink-0 transition-transform duration-150 motion-reduce:transition-none" + (" rotate-90" if open_ else ""))
    sub = (f'<span class="flex min-w-0 items-center gap-1"><span class="{status_cls}">{subtitle}</span><span aria-hidden="true" class="shrink-0">·</span>'
           f'<button type="button" class="{CHEVRON_BTN}">{"Routes" if n == 1 else f"{n} routes"}{chevron(routes is not None)}</button>'
           f'<span aria-hidden="true" class="shrink-0">·</span><button type="button" class="{CHEVRON_BTN}">Permissions{chevron(False)}</button></span>')
    switch = tog_ns["switch"]("sm", "on" if enabled else "off", False)
    detail = ""
    if routes:
        items = ""
        for rl, addr, in_use in routes:
            chip = ('<span class="rounded-sm bg-success/12 px-1 text-2xs font-normal text-success-foreground">In use</span>' if in_use else "")
            remove = button("ghost-muted", "icon-xs", lucide("x", "size-3"))
            items += (f'<li class="flex items-center gap-2 py-2"><div class="min-w-0 flex-1"><p class="flex items-center gap-1.5 text-xs font-medium text-foreground">{rl}{chip}</p>'
                      f'<p class="truncate text-2xs text-muted-foreground">{addr}</p></div>'
                      f'<button type="button" class="flex size-6 shrink-0 cursor-grab touch-none items-center justify-center rounded text-muted-foreground/70 outline-none">{lucide("grip-vertical", "size-3.5")}</button>'
                      f'{remove}</li>')
        detail = (f'<div class="col-span-2 col-start-2 min-w-0"><div class="mt-2 border-t border-border/50 py-2"><ol>{items}</ol>'
                  f'<div class="-ml-1.5 pt-1">{button("ghost-muted", "xs", lucide("plus", "size-3") + "Add route")}</div></div></div>')
    return (f'<div class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-3 px-3 py-2.5 sm:px-4{"" if enabled else " opacity-60"}">'
            f'{machine(kind, "size-4 text-muted-foreground")}<div class="min-w-0"><p class="truncate text-sm font-medium text-foreground">{label}</p>'
            f'<div class="truncate text-xs text-muted-foreground">{sub}</div></div><div class="flex shrink-0 items-center gap-1">{switch}{ELLIPSIS}</div>{detail}</div>')


ROWS = [("mac-mini", "Sandbox", "http://127.0.0.1:47391/ · Connected", False, True),
        ("server", "Studio", "LAN · Reconnecting: The environment credential is invalid.", True, True),
        ("laptop", "Old laptop", "box.example.com · Off", False, False)]
rows_html = section("Environments", "".join(env_row(*r) for r in ROWS), action=ADD)
routes_html = section("Environments", env_row("mac-mini", "Studio", "via LAN · Connected", False, True,
                                              routes=[("LAN", "http://192.168.1.4:3773/", True), ("Tailscale", "https://studio.tail1234.ts.net/", False)]),
                      action=ADD)

E = tog_ns
empty_media = (f'<div class="relative mb-6" data-slot="empty-media" data-variant="icon"><div aria-hidden="true" class="{E["left"]}"></div>'
               f'<div aria-hidden="true" class="{E["right"]}"></div><div class="{E["media"]}">{lucide("chevrons-left-right-ellipsis")}</div></div>')
EMPTY_MSG = "Click “Add environment” to pair another environment."
empty_html = section("Environments",
                     f'<div data-slot="empty" class="{E["E_BASE"]} {E["E_SIZES"]["default"]} min-h-52"><div data-slot="empty-header" class="flex max-w-sm flex-col items-center text-center">'
                     f'{empty_media}<div class="font-semibold text-xl" data-slot="empty-title">No saved remote environments</div>'
                     f'<div class="text-muted-foreground text-sm [[data-slot=empty-title]+&]:mt-1" data-slot="empty-description">{EMPTY_MSG}</div></div></div>',
                     action=ADD)

# Add Environment (ConnectionsSettings.tsx:4098-4130, 2881-3001) in DialogPopup sm:max-w-3xl.
POPUP_BASE = "-translate-y-[calc(1.25rem*var(--nested-dialogs))] relative flex min-h-0 w-full min-w-0 scale-[calc(1-0.1*var(--nested-dialogs))] flex-col opacity-[calc(1-0.1*var(--nested-dialogs))] outline-none"
POPUP = f"dialog-glass {POPUP_BASE} rounded-2xl border row-start-2 text-popover-foreground max-h-full max-h-[80dvh] sm:max-w-3xl"
CLOSE = button("ghost", "icon", lucide("x"), "absolute end-2 top-2", ' aria-label="Close"')


def card(title, desc, icon, selected):
    cls = "group flex min-h-24 items-start gap-3 rounded-lg border p-4 text-left " + ("border-primary/50 bg-primary/5" if selected else "border-border/60 hover:bg-muted/40")
    box = "mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-md border " + (
        "border-primary/30 bg-primary/10 text-primary" if selected else "border-border/70 bg-background text-muted-foreground group-hover:text-foreground")
    return (f'<button type="button" aria-pressed="{str(selected).lower()}" class="{cls}"><span class="{box}">{lucide(icon, "size-4")}</span>'
            f'<span class="min-w-0"><span class="block text-sm font-medium text-foreground">{title}</span>'
            f'<span class="mt-1 block text-xs leading-relaxed text-muted-foreground">{desc}</span></span></button>')


def field(label, placeholder):
    return f'<label class="block"><span class="mb-1.5 block text-xs font-medium text-foreground">{label}</span>{form_ns["input_html"]("default", placeholder)}</label>'


def add_dialog(route_label=None, error=None):
    title = f"Add a route to {route_label}" if route_label else "Add Environment"
    desc = ("Pair this machine again over another address, such as its Tailscale name. It joins the existing routes instead of adding a second machine."
            if route_label else "Pair another environment to this client.")
    fields = (f'<div class="space-y-3"><div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_10rem]">{field("Host", "backend.example.com")}{field("Pairing code", "PAIRCODE")}</div>'
              '<div><span class="mt-1 block text-2xs text-muted-foreground">Paste a full pairing URL here to fill both fields automatically.</span></div></div>')
    err = f'<p class="text-xs text-destructive">{error}</p>' if error else ""
    submit = button("outline", "default", lucide("plus", "size-3.5") + ("Add route" if route_label else "Add environment"), "w-full")
    body = (f'<div class="space-y-4"><div class="grid gap-3 sm:grid-cols-2">'
            f'{card("Remote link", "Enter a backend host and pairing code.", "chevrons-left-right-ellipsis", True)}'
            f'{card("SSH", "Use local SSH config, agent, and tunnels for the backend.", "terminal", False)}</div>'
            f'<div><div class="space-y-4">{fields}{err}{submit}</div></div></div>')
    return (f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">'
            f'<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
            f'<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">{title}</h2>'
            f'<p class="text-muted-foreground text-sm" data-slot="dialog-description">{desc}</p></div>'
            f'<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">{body}</div>'
            f'{CLOSE}</div>')


W796 = "display:block;width:796px"
cases = [
    {"name": "nav", "html": nav, "wrapperStyle": "display:block", "native": {"kind": "nav"}},
    {"name": "nav.back", "html": back, "wrapperStyle": "display:block", "native": {"kind": "back"}},
    {"name": "header", "html": header, "wrapperStyle": "display:block", "native": {"kind": "header"}},
    {"name": "this-machine", "html": this_machine, "wrapperStyle": W796, "native": {"kind": "this-machine"}},
    {"name": "environments.empty", "html": empty_html, "wrapperStyle": W796, "native": {"kind": "empty"}},
    {"name": "environments.rows", "html": rows_html, "wrapperStyle": W796, "native": {"kind": "rows"}},
    {"name": "environments.routes", "html": routes_html, "wrapperStyle": W796, "native": {"kind": "routes"}},
    {"name": "add-dialog", "html": add_dialog(), "wrapperStyle": "display:grid;width:768px", "native": {"kind": "dialog"}},
    {"name": "add-dialog.error", "html": add_dialog(error="Enter a backend host."), "wrapperStyle": "display:grid;width:768px",
     "native": {"kind": "dialog", "error": "Enter a backend host."}},
    {"name": "add-dialog.route", "html": add_dialog(route_label="Studio"), "wrapperStyle": "display:grid;width:768px",
     "native": {"kind": "dialog", "route": "Studio"}},
]
spec = {"component": "connections", "source": "apps/web/src/components/settings/ConnectionsSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/connections.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("connections", len(cases), "cases")
