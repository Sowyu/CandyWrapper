"""Nightly 3814 AppRouteModal.tsx:40-88 and routes/_chat.settings.tsx:120-143.
The children isolate the route shell: an empty settings navigation column and the real breadcrumb/close row.
Usage's shell has no navigation column. Page content has separate component specs.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-settings-spec.py")}
source = open(ns["__file__"]).read()
exec(source[:source.index("behavior = section(")], ns)
close = ns["button"]("ghost", "icon-sm", ns["lucide"]("x", "size-4"), "", ' aria-label="Close"')
popup = "relative flex size-full min-h-0 min-w-0 flex-col overflow-hidden bg-background text-foreground outline-none transition-[opacity,scale] duration-150 ease-out sm:max-h-[60rem] sm:max-w-[80rem] sm:rounded-2xl sm:border sm:shadow-2xl/40"
cases = []
for kind in ["settings", "usage"]:
    # A positioned viewport keeps the source's fixed inset-0 classes local to each test case.
    nav = '<nav class="w-60 shrink-0 border-e bg-sidebar text-sidebar-foreground"></nav>' if kind == 'settings' else ''
    crumb = ('<span class="font-medium text-muted-foreground">Settings</span><span class="text-icon-muted">/</span>'
             '<span class="font-medium">Appearance</span>') if kind == 'settings' else '<span class="font-medium text-muted-foreground">Usage</span>'
    header = '<header class="flex h-12 shrink-0 items-center gap-3 border-b ps-5 pe-2 text-sm">' + crumb + '<div class="ms-auto">' + close + '</div></header>'
    children = '<div class="relative flex min-h-0 flex-1">' + nav + '<div class="flex min-h-0 min-w-0 flex-1 flex-col">' + header + '</div></div>'
    html = '<div style="position:relative;isolation:isolate;width:1100px;height:780px;overflow:hidden;transform:translateZ(0)"><div class="dialog-backdrop fixed inset-0 z-50"></div><div class="fixed inset-0 z-50 flex items-center justify-center sm:p-6 lg:p-10"><div data-slot="dialog-popup" data-app-modal aria-label="' + kind.title() + '" class="' + popup + '">' + children + '</div></div></div>'
    cases.append(dict(name=kind, html=html, native=dict(kind=kind)))
with open(os.path.join(ROOT, 'design/component-reference/settings-modal.json'), 'w') as out:
    json.dump(dict(component='settings-modal', viewportWidth=1100, source='3814 AppRouteModal.tsx:40-88; _chat.settings.tsx:120-143', states=['rest'], themes=['light','dark'], cases=cases),out,indent=2)
    out.write('\n')
