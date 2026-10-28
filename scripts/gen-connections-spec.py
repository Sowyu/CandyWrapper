# Reference stylesheet and component primitives: T3 Nightly 3814.
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
exec(between("gen-toggles-spec.py", "# 4. Checkbox", "for kind, values in"), tog_ns)
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


# Settings nav: Nightly 3754 SettingsSidebarNav.tsx:244-405, classic design, with the existing sidebar.tsx menu button.
MB = ("peer/menu-button flex w-full cursor-pointer items-center gap-[var(--sidebar-control-gap)] overflow-hidden text-left outline-hidden ring-ring transition-[width,height,padding] hover:bg-sidebar-row-hover hover:text-sidebar-foreground focus-visible:ring-2 active:bg-sidebar-row-active active:text-sidebar-foreground disabled:pointer-events-none disabled:opacity-64 aria-disabled:pointer-events-none aria-disabled:opacity-64 data-[active=true]:bg-sidebar-row-selected data-[active=true]:font-medium data-[active=true]:text-sidebar-foreground data-[state=open]:hover:bg-sidebar-row-hover data-[state=open]:hover:text-sidebar-foreground [&>span:last-child]:truncate [&>svg:not([class*='size-'])]:size-4 [&>svg]:shrink-0 [&>svg]:text-[var(--sidebar-icon-color)] hover:[&>svg]:text-sidebar-foreground active:[&>svg]:text-sidebar-foreground data-[active=true]:[&>svg]:text-sidebar-foreground "
      "h-8 rounded-[var(--control-radius)] px-[var(--sidebar-row-content-inset)] py-1.5 text-sm font-medium text-sidebar-muted-foreground/80")
SNAPSHOT = ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 3H6a3 3 0 0 0-3 3v2M16 3h2a3 3 0 0 1 3 3v2M21 16v2a3 3 0 0 1-3 3h-2M8 21H6a3 3 0 0 1-3-3v-2"></path>'
            '<rect width="10" height="8" x="7" y="8" rx="2"></rect><circle cx="12" cy="12" r="1.5"></circle></svg>')
# Nightly 3754 settingsSearch.ts:85-143 and SettingsSidebarNav.tsx:83-106, 350-403.
# Keep the old theme's stylesheet; only the concern groups and their content changed.
NAV_GROUPS = [
    (None, [("General", "settings-2"), ("Appearance", "palette"), ("Chat", "message-square-text"),
            ("Diffs & pull requests", "file-diff"), ("Keybindings", "keyboard"), ("SnapShots", None)]),
    ("Agents", [("Providers", "bot"), ("Threads", "messages-square"), ("Browser", "globe"),
                ("Devices", "smartphone"), ("Scheduled tasks", "calendar-clock")]),
    ("Code", [("Projects", "panels-top-left"), ("Source control", "git-branch"), ("Worktrees", "folder-tree")]),
    ("Connections", [("Environments", "server"), ("Sharing & access", "shield-check")]),
    (None, [("Maintenance", "wrench"), ("Labs", "flask-conical"), ("About", "info"), ("Archive", "archive")]),
]
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
def nav_group(heading, entries):
    title = (f'<h3 class="px-2 text-xs font-medium text-sidebar-muted-foreground/80">{heading}</h3>'
             if heading else "")
    menu = "".join(menu_item(label, icon, label == "Environments", False) for label, icon in entries)
    return (f'<div role="group" class="flex flex-col gap-1">{title}'
            f'<ul class="flex w-full min-w-0 flex-col gap-1">{menu}</ul></div>')


menu = "".join(nav_group(heading, entries) for heading, entries in NAV_GROUPS)
nav = SIDEBAR.format('<div class="relative flex w-full min-w-0 flex-col p-[var(--sidebar-content-inset)]"><div class="flex flex-col gap-2">'
                     f'{search}<div class="flex flex-col gap-4">{menu}</div></div></div>')
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

# SettingsSection / SettingsGroup / SettingsRow (3824 settingsLayout.tsx:235,467-499, #24865).
GROUP = "relative overflow-visible text-foreground rounded-xl border border-border/60 bg-card/40 shadow-xs/5 [&>*+*]:border-t [&>*+*]:border-border/50 [&>[data-slot=settings-row]]:rounded-none"
ROW = "@container/settings-row rounded-xl px-3 sm:px-4 aria-disabled:opacity-64 aria-disabled:[&_*]:text-muted-foreground py-3"
ELLIPSIS = button("ghost-muted", "icon-xs", lucide("ellipsis", "size-3.5"))


def section(title, children, icon="", action=""):
    return (f'<section class="space-y-2.5"><div class="flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4">'
            f'<div class="flex min-w-0 items-center gap-1"><h2 class="flex min-h-7 items-center gap-2 text-base font-semibold text-foreground">{icon}{title}</h2></div>'
            f'<div class="flex min-h-7 min-w-7 items-center justify-end">{action}</div></div><div class="{GROUP}">{children}</div></section>')


def settings_row(title, desc, control):
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>'
            '<span class="inline-flex h-5 w-5 shrink-0 items-center justify-center"></span></div>'
            f'<p class="max-w-2xl text-balance text-xs leading-normal text-muted-foreground">{desc}</p></div>'
            f'<div class="flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end">{control}</div></div></div>')


this_machine = section("miniko", settings_row("Version", "0.0.46-nightly.20261009.2861 · http://127.0.0.1:47391/",
                                              '<span class="text-xs text-muted-foreground">Up to date</span>'),
                       icon=machine("mac-mini", "size-4"), action=ELLIPSIS)

ADD = button("ghost-muted", "xs", lucide("plus", "size-3") + "<span>Add environment</span>", attrs=' aria-label="Add environment"')
CHEVRON_BTN = "inline-flex shrink-0 items-center gap-0.5 rounded-sm text-muted-foreground outline-none hover:text-foreground focus-visible:ring-1 focus-visible:ring-ring"


def env_row(kind, label, subtitle, error, enabled, routes=None, perms=None):
    status_cls = "min-w-0 truncate" + (" text-destructive" if error and enabled else "")
    n = len(routes) if routes else 1
    chevron = lambda open_: lucide("chevron-right", "size-3 shrink-0 transition-transform duration-150 motion-reduce:transition-none" + (" rotate-90" if open_ else ""))
    sub = (f'<span class="flex min-w-0 items-center gap-1"><span class="{status_cls}">{subtitle}</span><span aria-hidden="true" class="shrink-0">·</span>'
           f'<button type="button" class="{CHEVRON_BTN}">{"Routes" if n == 1 else f"{n} routes"}{chevron(routes is not None)}</button>'
           f'<span aria-hidden="true" class="shrink-0">·</span><button type="button" class="{CHEVRON_BTN}">Permissions{chevron(perms is not None)}</button></span>')
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
    if perms is not None:
        detail = f'<div class="col-span-2 col-start-2 min-w-0"><div class="mt-2 border-t border-border/50">{perms}</div></div>'
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


def ssh_fields(error=None):
    # renderSshFields (ConnectionsSettings.tsx:3020-3134): AutocompleteInput renders an Input in a `relative w-full` box.
    host = (f'<div class="block"><label class="mb-1.5 block text-xs font-medium text-foreground">SSH host or alias</label>'
            f'<div class="relative not-has-[>*.w-full]:w-fit w-full text-foreground has-disabled:opacity-64">{form_ns["input_html"]("default", "Search hosts or type devbox")}</div></div>')
    grid = f'<div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_7rem]">{field("Username", "root")}{field("Port", "22")}</div>'
    alert = ('<div class="relative rounded-xl border px-3.5 py-3 text-card-foreground text-sm border-error/32 bg-error-surface text-error-foreground '
             '[&_[data-slot=alert-description]]:text-error-foreground/80 [&_svg]:text-error" data-slot="alert" data-variant="error" role="alert">'
             '<div class="flex gap-2 items-center"><div class="flex min-w-0 flex-1 flex-col gap-0.5">'
             f'<div class="flex flex-col gap-2.5 text-muted-foreground" data-slot="alert-description">{error}</div></div></div></div>') if error else ""
    submit = button("outline", "default", lucide("plus", "size-3.5") + "Add environment", "w-full")
    return f'<div class="space-y-4"><div class="space-y-3">{host}{grid}{alert}{submit}</div></div>'


def add_dialog(route_label=None, error=None, ssh=False):
    title = f"Add a route to {route_label}" if route_label else "Add Environment"
    desc = ("Pair this machine again over another address, such as its Tailscale name. It joins the existing routes instead of adding a second machine."
            if route_label else "Pair another environment to this client.")
    fields = (f'<div class="space-y-3"><div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_10rem]">{field("Host", "backend.example.com")}{field("Pairing code", "PAIRCODE")}</div>'
              '<div><span class="mt-1 block text-2xs text-muted-foreground">Paste a full pairing URL here to fill both fields automatically.</span></div></div>')
    err = f'<p class="text-xs text-destructive">{error}</p>' if error else ""
    submit = button("outline", "default", lucide("plus", "size-3.5") + ("Add route" if route_label else "Add environment"), "w-full")
    body = (f'<div class="space-y-4"><div class="grid gap-3 sm:grid-cols-2">'
            f'{card("Remote link", "Enter a backend host and pairing code.", "chevrons-left-right-ellipsis", not ssh)}'
            f'{card("SSH", "Use local SSH config, agent, and tunnels for the backend.", "terminal", ssh)}</div>'
            + (f'<div>{ssh_fields(error)}</div></div>' if ssh else f'<div><div class="space-y-4">{fields}{err}{submit}</div></div></div>'))
    return (f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">'
            f'<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
            f'<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">{title}</h2>'
            f'<p class="text-muted-foreground text-sm" data-slot="dialog-description">{desc}</p></div>'
            f'<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">{body}</div>'
            f'{CLOSE}</div>')


# --- Host rows, Permissions, Authorized clients and Create pairing link (ConnectionsSettings.tsx:568-1312, 3613-3776,
# SessionPermissions.tsx, settingsLayout.tsx SettingsRow). Switches CandyWrapper can't change render disabled, as
# T3 renders a CloudLinkSwitch with a disabled reason.
def disabled_switch(on):
    return f'<span class="inline-flex">{tog_ns["switch"]("default", "on" if on else "off", True)}</span>'


def host_row(title, desc, control=None):
    if control is not None:
        return settings_row(title, desc, control)
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>'
            '<span class="inline-flex h-5 w-5 shrink-0 items-center justify-center"></span></div>'
            f'<p class="max-w-2xl text-balance text-xs leading-normal text-muted-foreground">{desc}</p></div></div></div>')


GRANTS = [("View environment", True), ("Operate tasks", True), ("Change environment settings", True), ("Manage providers", True),
          ("Maintain environment", True), ("Control previews", True), ("View diagnostics and usage", True), ("View terminals", True),
          ("Use terminals", True), ("Change source control", True), ("Read files", True), ("Write files", True),
          ("View access", True), ("Manage access", False), ("View relay", True), ("Manage relay", False)]


def session_permissions(grants, route):
    if grants is None:
        return '<p class="py-3 text-xs text-muted-foreground">Permissions not checked. Connect to this environment to view this session’s permissions.</p>'
    note = ("These permissions apply to your active route. Other routes may have different permissions." if route
            else "These permissions apply to this client’s current connection.")
    items = "".join(f'<li class="flex items-start justify-between gap-3"><span>{t}</span><span class="shrink-0 text-muted-foreground">'
                    f'{"Allowed" if a else "Not granted"}</span></li>' for t, a in grants)
    return f'<div class="space-y-3 py-3 text-xs"><p class="text-muted-foreground">{note}</p><ul class="grid gap-x-6 gap-y-2 sm:grid-cols-2">{items}</ul></div>'


def permissions_details(open_):
    chevron = lucide("chevron-right", "size-3 text-muted-foreground group-open:rotate-90")
    summary = ('<summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-md text-sm font-medium outline-none '
               f'[&::-webkit-details-marker]:hidden">Permissions{chevron}</summary>')
    return f'<details class="group px-3 sm:px-4"{" open" if open_ else ""}>{summary}{session_permissions(GRANTS, False) if open_ else ""}</details>'


def host_section(perms_open):
    rows = (host_row("Local environment", "Run agents on this computer. Turn off to use T3 Code only with remote environments.", disabled_switch(True))
            + host_row("Version", "0.0.46-nightly.20261009.2861 · http://127.0.0.1:47391/", '<span class="text-xs text-muted-foreground">Up to date</span>')
            + host_row("Network access", "Limited to this machine.", disabled_switch(False))
            + host_row("Tailscale HTTPS", "Start Tailscale to set up HTTPS access through MagicDNS.")
            + host_row("T3 Connect", "Make this environment available to your other devices through T3 Connect.", disabled_switch(False))
            + host_row("Publish agent activity", "Send activity to mobile notifications and Live Activities without T3 Connect.", disabled_switch(False))
            + permissions_details(perms_open))
    return section("miniko", rows, icon=machine("mac-mini", "size-4"), action=ELLIPSIS)


this_machine_full = host_section(False)
this_machine_perms = host_section(True)

# Authorized clients (FoldedSettingsSection inside header, PairingLinkListRow, ConnectedClientListRow).
FOLD = "relative overflow-visible text-foreground rounded-xl border border-border/60 bg-card/40 shadow-xs/5"
ITEM_ROW = "first:rounded-t-xl last:rounded-b-xl px-3 py-3 sm:px-4"
ITEM_INNER = "flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"


def dot(cls):
    return (f'<button type="button" class="relative flex size-3 shrink-0 cursor-help items-center justify-center rounded-full outline-hidden">'
            f'<span class="relative inline-flex size-2 rounded-full {cls}"></span></button>')


def scope_summary(n):
    return (f'<button type="button" class="cursor-help underline decoration-border underline-offset-2 outline-hidden">'
            f'{n} {"scope" if n == 1 else "scopes"}</button>')


def link_row(label, expires, scopes, note=None, share=False):
    buttons = ""
    if share:
        buttons += button("outline", "xs", lucide("qr-code") + "Share")
    buttons += button("destructive-outline", "xs", "Revoke")
    note_html = f'<p class="text-2xs text-muted-foreground/70">{note}</p>' if note else ""
    return (f'<div class="{ITEM_ROW}"><div class="{ITEM_INNER}"><div class="min-w-0 flex-1 space-y-1">'
            f'<div class="flex min-h-5 items-center gap-1.5">{dot("bg-warning")}<h3 class="text-sm font-medium text-foreground">{label}</h3></div>'
            f'<p class="text-xs text-muted-foreground"><span>{expires}</span><span aria-hidden="true"> · </span>{scope_summary(scopes)}</p>{note_html}</div>'
            f'<div class="flex w-full shrink-0 items-center gap-2 sm:w-auto sm:justify-end">{buttons}</div></div></div>')


def client_row(label, info, scopes, current, live):
    chip = ('<span class="text-3xs text-muted-foreground/80 rounded-md border border-border/50 bg-muted/50 px-1 py-0.5">This device</span>'
            if current else "")
    revoke = "" if current else button("destructive-outline", "xs", "Revoke")
    return (f'<div class="{ITEM_ROW}"><div class="{ITEM_INNER}"><div class="min-w-0 flex-1 space-y-1">'
            f'<div class="flex min-h-5 items-center gap-1.5">{dot("bg-success" if live else "bg-muted-foreground/30")}'
            f'<h3 class="text-sm font-medium text-foreground">{label}</h3>{chip}</div>'
            f'<p class="text-xs text-muted-foreground">{info}<span aria-hidden="true"> · </span>{scope_summary(scopes)}</p></div>'
            f'<div class="flex w-full shrink-0 items-center gap-2 sm:w-auto sm:justify-end">{revoke}</div></div></div>')


def authorized(open_):
    chevron = lucide("chevron-right", "size-4 shrink-0 text-muted-foreground transition-transform duration-150 motion-reduce:transition-none" + (" rotate-90" if open_ else ""))
    control = (f'<div class="flex shrink-0 items-center"><div class="flex items-center gap-2">{button("destructive-outline", "xs", "Revoke others")}'
               f'{button("default", "xs", lucide("plus", "size-3") + "Create link")}</div></div>')
    header = (f'<div class="flex items-center gap-4 px-3 sm:px-4"><button type="button" class="flex min-h-11 min-w-0 flex-1 items-center gap-2 py-2 text-left outline-none rounded-md">'
              f'{chevron}<span class="shrink-0 text-sm font-medium">Authorized clients</span>'
              f'<span class="min-w-0 truncate text-xs text-muted-foreground">2 clients · 1 pairing link</span></button>{control}</div>')
    panel = ""
    if open_:
        rows = (link_row("Living room iPad", "Expires in 4m 12s", 13, share=True)
                + client_row("CandyWrapper", "Desktop · macOS · 127.0.0.1", 16, True, True)
                + client_row("iPhone", "Mobile · iOS · Safari", 13, False, False))
        panel = f'<div class="border-t border-border/50 [&>*+*]:border-t [&>*+*]:border-border/50">{rows}</div>'
    return f'<section><div class="{FOLD}">{header}{panel}</div></section>'


# A saved machine with its Permissions open (not connected: the "not checked" note).
env_perms_html = section("Environments", env_row("server", "Studio", "LAN · Offline", False, True, perms=session_permissions(None, True)), action=ADD)

# Create pairing link (AuthorizedClientsHeaderAction dialog, max-w-md, bare footer).
CL_POPUP = f"dialog-glass {POPUP_BASE} rounded-2xl border row-start-2 text-popover-foreground max-h-full max-w-md"


def create_link_dialog():
    options = [("View environment", "Read threads, status, checkpoints, and configuration.", True),
               ("Operate tasks", "Start, update, and stop tasks.", True),
               ("Change environment settings", "Edit environment preferences and keybindings.", True),
               ("Manage providers", "Configure, install, sign in to, and update providers and usage sources.", True),
               ("Maintain environment", "Update the server and control environment processes.", True),
               ("Control previews", "Open browser previews and host browser automation.", True),
               ("View diagnostics and usage", "Read process diagnostics, resource history, and usage totals.", True),
               ("View terminals", "Read existing terminal output and status.", True),
               ("Use terminals", "Create terminals and send input to running shells.", True),
               ("Change source control", "Commit, push, manage branches and repositories, and change pull requests.", True),
               ("Read files", "Browse host files, search workspaces, and inspect local changes.", True),
               ("Write files", "Edit workspace files and save plans to disk.", True),
               ("View access", "Inspect pairing links and authorized clients.", False),
               ("Manage access", "Issue and revoke credentials for other clients.", False),
               ("View relay", "Inspect managed relay connectivity.", True),
               ("Manage relay", "Change managed tunnel connectivity.", False)]
    rows = "".join(f'<label class="flex cursor-pointer items-start gap-3 px-3 py-2.5 transition-colors">'
                   f'<span class="mt-0.5 inline-flex">{tog_ns["choice"]("checkbox", "on" if on else "off")}</span>'
                   f'<span class="min-w-0"><span class="block text-xs font-medium text-foreground">{t}</span>'
                   f'<span class="block text-xs leading-snug text-muted-foreground">{d}</span></span></label>' for t, d, on in options)
    panel = (f'<label class="block"><span class="mb-1.5 block text-xs font-medium text-foreground">Client label (optional)</span>'
             f'{form_ns["input_html"]("default", "e.g. Living room iPad")}</label>'
             f'<section class="space-y-3"><div class="flex items-center justify-between gap-3"><div><h3 class="text-xs font-medium text-foreground">Permissions</h3>'
             f'<p class="text-xs text-muted-foreground">Limit what the paired client can do.</p></div><div class="flex gap-1">'
             f'{button("outline", "xs", "Read only")}{button("outline", "xs", "Standard")}</div></div>'
             f'<div class="divide-y divide-border/60 rounded-lg border border-input bg-muted/25">{rows}</div></section>')
    footer = (f'<div class="flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)] py-4" data-slot="dialog-footer">'
              f'{button("outline", "default", "Cancel")}{button("default", "default", "Create link")}</div>')
    return (f'<div role="dialog" data-slot="dialog-popup" class="{CL_POPUP}">'
            f'<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
            f'<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">Create pairing link</h2>'
            f'<p class="text-muted-foreground text-sm" data-slot="dialog-description">Generate a one-time link that another device can use to pair with this backend as an authorized client.</p></div>'
            f'<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">{panel}</div>'
            f'{footer}{CLOSE}</div>')


W796 = "display:block;width:796px"
cases = [
    {"name": "nav", "html": nav, "wrapperStyle": "display:block", "native": {"kind": "nav"}},
    {"name": "nav.back", "html": back, "wrapperStyle": "display:block", "native": {"kind": "back"}},
    {"name": "header", "html": header, "wrapperStyle": "display:block", "native": {"kind": "header"}},
    {"name": "this-machine", "html": this_machine, "wrapperStyle": W796, "native": {"kind": "this-machine"}},
    {"name": "environments.empty", "html": empty_html, "wrapperStyle": W796, "native": {"kind": "empty"}},
    {"name": "environments.rows", "html": rows_html, "wrapperStyle": W796, "native": {"kind": "rows"}},
    {"name": "environments.routes", "html": routes_html, "wrapperStyle": W796, "native": {"kind": "routes"}},
    {"name": "this-machine.full", "html": this_machine_full, "wrapperStyle": W796, "native": {"kind": "this-machine-full"}},
    {"name": "this-machine.permissions", "html": this_machine_perms, "wrapperStyle": W796, "native": {"kind": "this-machine-full", "permissions": "open"}},
    {"name": "authorized-clients", "html": authorized(False), "wrapperStyle": W796, "native": {"kind": "access"}},
    {"name": "authorized-clients.open", "html": authorized(True), "wrapperStyle": W796, "native": {"kind": "access", "open": "true"}},
    {"name": "environments.permissions", "html": env_perms_html, "wrapperStyle": W796, "native": {"kind": "env-permissions"}},
    {"name": "create-link-dialog", "html": create_link_dialog(), "wrapperStyle": "display:grid;width:448px", "native": {"kind": "create-link"}},
    {"name": "add-dialog", "html": add_dialog(), "wrapperStyle": "display:grid;width:768px", "native": {"kind": "dialog"}},
    {"name": "add-dialog.error", "html": add_dialog(error="Enter a backend host."), "wrapperStyle": "display:grid;width:768px",
     "native": {"kind": "dialog", "error": "Enter a backend host."}},
    {"name": "add-dialog.ssh", "html": add_dialog(ssh=True), "wrapperStyle": "display:grid;width:768px", "native": {"kind": "dialog", "ssh": "1"}},
    {"name": "add-dialog.ssh-error", "html": add_dialog(ssh=True, error="SSH port must be between 1 and 65535."), "wrapperStyle": "display:grid;width:768px",
     "native": {"kind": "dialog", "ssh": "1", "error": "SSH port must be between 1 and 65535."}},
    {"name": "add-dialog.route", "html": add_dialog(route_label="Studio"), "wrapperStyle": "display:grid;width:768px",
     "native": {"kind": "dialog", "route": "Studio"}},
]
spec = {"component": "connections", "source": "apps/web/src/components/settings/ConnectionsSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/connections.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("connections", len(cases), "cases")
