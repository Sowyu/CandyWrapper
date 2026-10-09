"""Writes the overlay specs for scripts/component-reference: dialog, alert-dialog, sheet, toast and
text-block (design/component-reference/<name>.json). Popups are captured statically open, without the
fixed viewport, on the plain --background the harness uses; glass over that background is what the
native solid substitutes draw. Class strings come from apps/web/src/components/ui/{dialog-styles.ts,
dialog.tsx, alert-dialog.tsx, sheet.tsx, toast.tsx} at the tag in T3_VERSION.
Usage: /usr/bin/python3 -I scripts/gen-overlays-spec.py
"""
import json, os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Reuse the button classes and the tailwind-merge subset from the button spec generator.
src = open(os.path.join(root, "scripts/gen-button-spec.py")).read()
exec(src[:src.index("cases = []")])

def btn(variant, size, title):
    return f'<button type="button" data-slot="button" class="{merge(f"{BASE} {VARIANTS[variant]} {SIZES[size]}")}">{title}</button>'

def svg(inner, cls="", stroke=2):
    c = f' class="{cls}"' if cls else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"{c} aria-hidden="true">{inner}</svg>')

X = '<path d="M18 6 6 18"></path><path d="m6 6 12 12"></path>'
CLOSE_CLS = merge(" ".join([BASE, VARIANTS["ghost"], SIZES["icon"], "absolute end-2 top-2"]))
CLOSE = (f'<button type="button" aria-label="Close" data-slot="button" class="{CLOSE_CLS}">'
         f'{svg(X)}</button>')
specs = {}

# Dialog and AlertDialog (dialog-styles.ts:7-10, dialog.tsx:83-160, alert-dialog.tsx:40-118)
POPUP_BASE = "-translate-y-[calc(1.25rem*var(--nested-dialogs))] relative flex min-h-0 w-full min-w-0 scale-[calc(1-0.1*var(--nested-dialogs))] flex-col opacity-[calc(1-0.1*var(--nested-dialogs))] outline-none transition-[scale,opacity,translate] duration-200 ease-in-out will-change-transform data-nested:data-ending-style:translate-y-8 data-nested:data-starting-style:translate-y-8 data-nested-dialog-open:origin-top data-ending-style:scale-98 data-starting-style:scale-98 data-ending-style:opacity-0 data-starting-style:opacity-0 [-webkit-app-region:no-drag]"
POPUP = f"dialog-glass {POPUP_BASE} rounded-2xl border row-start-2 text-popover-foreground max-h-full max-w-lg"
TITLE = "Delete this thread?"
DESC = "The thread and its history are removed from this device and the server. This cannot be undone."
PANEL_TEXT = "Messages, tool calls and diffs in the thread go with it. Worktrees created for the thread stay on disk until you remove them."

def dialog(kind, footer, panel, title=TITLE, desc=DESC):
    header_cls = "flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4"
    if kind == "alert-dialog":
        header_cls = "flex flex-col gap-2 p-6 text-center max-sm:pb-4 sm:text-left"
    footer_base = "flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)]"
    footer_cls = footer_base + (" border-t bg-muted/72 py-4" if footer == "default" else (" pb-6" if kind == "alert-dialog" else " py-4"))
    body = (f'<div class="{header_cls}" data-slot="{kind}-header"><h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="{kind}-title">{title}</h2>'
            f'<p class="text-muted-foreground text-sm" data-slot="{kind}-description">{desc}</p></div>')
    if panel:
        body += (f'<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">'
                 f'<p class="text-sm">{PANEL_TEXT}</p></div>')
    body += f'<div class="{footer_cls}" data-slot="{kind}-footer">{btn("outline", "default", "Cancel")}{btn("destructive" if kind == "alert-dialog" else "default", "default", "Delete" if kind == "alert-dialog" else "Save")}</div>'
    if kind == "dialog": body += CLOSE
    return f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">{body}</div>'

specs["dialog"] = {"source": "apps/web/src/components/ui/dialog.tsx", "cases": [
    {"name": f"{footer}{'.panel' if panel else ''}", "html": dialog("dialog", footer, panel), "wrapperStyle": "display:grid;width:512px",
     "native": {"kind": "dialog", "footer": footer, "panel": str(panel).lower(), "title": TITLE, "description": DESC, "panelText": PANEL_TEXT}}
    for footer, panel in [("default", True), ("bare", True), ("default", False)]]}
specs["alert-dialog"] = {"source": "apps/web/src/components/ui/alert-dialog.tsx", "cases": [
    {"name": footer, "html": dialog("alert-dialog", footer, False), "wrapperStyle": "display:grid;width:512px",
     "native": {"kind": "alertDialog", "footer": footer, "panel": "false", "title": TITLE, "description": DESC}}
    for footer in ["default", "bare"]]}

# Sheet (sheet.tsx:90-118, 129-151): statically open in a 360px tall box.
SHEET = "relative flex max-h-full min-h-0 w-full min-w-0 flex-col bg-popover not-dark:bg-clip-padding text-popover-foreground shadow-lg/5 transition-[opacity,translate] duration-200 ease-in-out will-change-transform before:pointer-events-none before:absolute before:inset-0 before:shadow-[0_1px_--theme(--color-black/4%)] data-ending-style:opacity-0 data-starting-style:opacity-0 max-sm:before:hidden dark:before:shadow-[0_-1px_--theme(--color-white/6%)]"
SIDES = {
    "right": "col-start-2 w-[calc(100%-(--spacing(12)))] max-w-md border-s data-ending-style:translate-x-8 data-starting-style:translate-x-8",
    "left": "data-ending-style:-translate-x-8 data-starting-style:-translate-x-8 w-[calc(100%-(--spacing(12)))] max-w-md border-e",
}
INSET = "before:hidden sm:rounded-2xl sm:border sm:before:rounded-[calc(var(--radius-2xl)-1px)] sm:**:data-[slot=sheet-footer]:rounded-b-[calc(var(--radius-2xl)-1px)]"
S_TITLE, S_DESC = "Thread settings", "Model, runtime and worktree for this thread."
def sheet(side, inset):
    head = (f'<div class="flex flex-col gap-2 p-6 in-[[data-slot=sheet-popup]:has([data-slot=sheet-panel])]:pb-3 max-sm:pb-4" data-slot="sheet-header">'
            f'<h2 class="font-semibold text-xl leading-none" data-slot="sheet-title">{S_TITLE}</h2><p class="text-muted-foreground text-sm" data-slot="sheet-description">{S_DESC}</p></div>')
    return f'<div role="dialog" data-slot="sheet-popup" class="{SHEET} {SIDES[side]}{" " + INSET if inset else ""}">{head}{CLOSE}</div>'
specs["sheet"] = {"source": "apps/web/src/components/ui/sheet.tsx", "cases": [
    {"name": f"{side}{'.inset' if inset else ''}", "html": sheet(side, inset),
     "wrapperStyle": f"display:flex;justify-content:{'flex-end' if side == 'right' else 'flex-start'};width:496px;height:360px",
     "native": {"side": side, "inset": str(inset).lower(), "title": S_TITLE, "description": S_DESC}}
    for side, inset in [("right", False), ("left", False), ("right", True)]]}

# Toast (toast.tsx:96-102, 316-405, 578-676), front toast of a top-right stack, collapsed.
ROOT = " ".join([
    "dropdown-glass absolute z-[calc(9999-var(--toast-index))] w-full overflow-visible select-none rounded-lg text-popover-foreground shadow-xl shadow-black/25 [transition:transform_.5s_cubic-bezier(.22,1,.36,1),opacity_.5s,height_.15s]",
    "data-[position*=right]:right-0 data-[position*=right]:left-auto",
    "data-[position*=top]:top-0 data-[position*=top]:bottom-auto data-[position*=top]:origin-top",
    "[--toast-calc-height:max(var(--toast-frontmost-height,var(--toast-height)),var(--toast-height))]",
    "[--toast-gap:--spacing(3)] [--toast-peek:--spacing(3)] [--toast-scale:calc(max(0,1-(var(--toast-index)*.1)))] [--toast-shrink:calc(1-var(--toast-scale))]",
    "h-auto",
    "data-[position*=top]:transform-[translateX(var(--toast-swipe-movement-x))_translateY(calc(var(--toast-swipe-movement-y)+(var(--toast-index)*var(--toast-peek))+(var(--toast-shrink)*var(--toast-calc-height))))_scale(var(--toast-scale))]",
])
STYLE = "--toast-index:0;--toast-offset-y:0px;--toast-height:0px;--toast-frontmost-height:0px;--toast-swipe-movement-x:0px;--toast-swipe-movement-y:0px"
ORB = ('<div class="absolute z-20 -top-1.5 -right-1.5"><button aria-label="Dismiss notification" data-slot="toast-close" type="button" class="inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full border border-border/60 bg-popover/92 text-muted-foreground shadow-sm outline-none backdrop-blur-sm transition-[color,background-color,box-shadow] hover:bg-popover hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background">'
       f'{svg(X, "size-3", 2.25)}</button></div>')
ICONS = {
    "error": '<circle cx="12" cy="12" r="10"></circle><line x1="12" x2="12" y1="8" y2="12"></line><line x1="12" x2="12.01" y1="16" y2="16"></line>',
    "info": '<circle cx="12" cy="12" r="10"></circle><path d="M12 16v-4"></path><path d="M12 8h.01"></path>',
    "success": '<circle cx="12" cy="12" r="10"></circle><path d="m9 12 2 2 4-4"></path>',
    "warning": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path>',
}
ICON_CLS = "in-data-[type=error]:text-destructive in-data-[type=info]:text-info in-data-[type=success]:text-success in-data-[type=warning]:text-warning in-data-[type=loading]:opacity-80"
def toast(kind, title, desc, action):
    icon = (f'<div class="[&>svg]:h-lh [&>svg]:w-4 [&_svg]:pointer-events-none [&_svg]:shrink-0" data-slot="toast-icon">{svg(ICONS[kind], ICON_CLS)}</div>'
            if kind in ICONS else "")
    body = (f'<div class="flex min-h-0 min-w-0 flex-col gap-0.5 flex-1"><div class="flex min-w-0 gap-2">{icon}'
            f'<div class="min-w-0 wrap-break-word font-medium" data-slot="toast-title">{title}</div></div>'
            + (f'<div class="min-w-0 select-text wrap-break-word text-muted-foreground" data-slot="toast-description">{desc}</div>' if desc else "")
            + "</div>")
    if action:
        b = btn("default", "xs", action).replace(' class="', ' data-slot="toast-action" class="shrink-0 ', 1)
        body += f'<div class="flex items-center gap-1.5 shrink-0">{b}</div>'
    content = ("pointer-events-auto min-h-0 overflow-y-visible pl-3.5 text-sm transition-opacity duration-250 [overflow-x:clip] data-expanded:opacity-100 "
               f"py-3 flex items-center justify-between gap-1.5 {'pr-6' if action else 'pr-10'}")
    return (f'<div data-type="{kind}" data-position="top-right" role="dialog" class="{ROOT}" style="{STYLE}">{ORB}'
            f'<div class="{content}">{body}</div></div>')
T_CASES = [
    ("success", "success", "Changes pushed to origin/main", None, None),
    ("error", "error", "Could not reach the server", None, None),
    ("info.action", "info", "Thread archived", "You can find it under Archived in the sidebar.", "Undo"),
    ("plain.wrap", "plain", "Update ready", "Restart T3 Code to finish installing version 0.0.47. Your open threads and drafts are kept.", None),
    ("warning.wrap", "warning", "Provider rate limit reached while the agent was working on a long task", None, "Retry"),
]
specs["toast"] = {"source": "apps/web/src/components/ui/toast.tsx", "cases": [
    {"name": name, "html": toast(kind, title, desc, action), "wrapperStyle": "position:relative;display:block;width:360px;height:160px",
     "native": {k: v for k, v in {"kind": kind, "title": title, "description": desc, "action": action}.items() if v}}
    for name, kind, title, desc, action in T_CASES]}

# TextBlock: prose wrapped at several widths (14px/20px foreground, 13px/18px muted, 20px semibold).
PROSE = ("T3 Code runs coding agents against your repositories. Each thread keeps its own worktree, so two agents "
         "can edit the same project at once without stepping on each other, and every diff stays reviewable before you merge it.")
tb = []
for width in [180, 260, 343, 420]:
    tb.append({"name": f"sm.{width}", "html": f'<p class="text-sm text-foreground">{PROSE}</p>', "wrapperStyle": f"display:block;width:{width}px",
               "native": {"font": "14", "line": "20", "weight": "regular", "text": PROSE}})
tb.append({"name": "xs13.300", "html": f'<p class="text-muted-foreground" style="font-size:13px;line-height:18px">{PROSE}</p>', "wrapperStyle": "display:block;width:300px",
           "native": {"font": "13", "line": "18", "weight": "regular", "muted": "true", "text": PROSE}})
tb.append({"name": "xl.300", "html": f'<p class="font-semibold text-xl">{PROSE[:120]}</p>', "wrapperStyle": "display:block;width:300px",
           "native": {"font": "20", "line": "28", "weight": "semibold", "text": PROSE[:120]}})
tb.append({"name": "clamp2.260", "html": f'<p class="text-sm line-clamp-2">{PROSE}</p>', "wrapperStyle": "display:block;width:260px",
           "native": {"font": "14", "line": "20", "weight": "regular", "maxLines": "2", "text": PROSE}})
tb.append({"name": "center.260", "html": f'<p class="text-sm text-center">{PROSE}</p>', "wrapperStyle": "display:block;width:260px",
           "native": {"font": "14", "line": "20", "weight": "regular", "align": "center", "text": PROSE}})
specs["text-block"] = {"source": "apps/web (plain prose)", "cases": tb}

for name, spec in specs.items():
    out = {"component": name, "source": spec["source"], "states": ["rest"], "themes": ["light", "dark"], "cases": spec["cases"]}
    with open(os.path.join(root, f"design/component-reference/{name}.json"), "w") as f:
        json.dump(out, f, indent=1)
    print(name, len(spec["cases"]), "cases")
