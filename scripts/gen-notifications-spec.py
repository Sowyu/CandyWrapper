"""Writes design/component-reference/thread-toast.json and quit-hold-overlay.json for scripts/component-reference:
the in-app thread notification toasts (ThreadNotificationCoordinator.tsx:178-205: leading icon, title, the
thread title, "Open thread") and the hold-to-quit overlay (QuitHoldOverlay.tsx:46-54).
Toast markup reuses scripts/gen-overlays-spec.py; icons come from lucide-static 0.564.0.
Usage: /usr/bin/python3 -I scripts/gen-notifications-spec.py
"""
import json, os, re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"
# The toast pieces (ROOT, STYLE, ORB, btn, svg) from the overlays generator, before its cases.
src = open(os.path.join(root, "scripts/gen-overlays-spec.py")).read()
exec(src[:src.index("T_CASES = [")])

def lucide(name, cls):
    s = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", s[s.index(">", s.index("<svg")) + 1:s.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return svg(inner, cls)

def thread_toast(kind, icon, color, title, desc):
    # `data.leadingIcon` (toast.tsx:343-349) in place of the type icon; the inline action layout.
    lead = f'<div class="flex h-lh w-4 shrink-0 items-center justify-center" data-slot="toast-icon">{lucide(icon, "size-4 " + color)}</div>'
    body = (f'<div class="flex min-h-0 min-w-0 flex-col gap-0.5 flex-1"><div class="flex min-w-0 gap-2">{lead}'
            f'<div class="min-w-0 wrap-break-word font-medium" data-slot="toast-title">{title}</div></div>'
            f'<div class="min-w-0 select-text wrap-break-word text-muted-foreground" data-slot="toast-description">{desc}</div></div>')
    b = btn("default", "xs", "Open thread").replace(' class="', ' data-slot="toast-action" class="shrink-0 ', 1)
    body += f'<div class="flex items-center gap-1.5 shrink-0">{b}</div>'
    content = ("pointer-events-auto min-h-0 overflow-y-visible pl-3.5 text-sm transition-opacity duration-250 [overflow-x:clip] data-expanded:opacity-100 "
               "py-3 flex items-center justify-between gap-1.5 pr-6")
    return (f'<div data-type="{kind}" data-position="top-right" role="dialog" class="{ROOT}" style="{STYLE}">{ORB}'
            f'<div class="{content}">{body}</div></div>')

CASES = [
    ("completed", "success", "circle-check", "text-success-foreground", "circleCheck", "successForeground", "Thread completed", "Fix the login form"),
    ("approval", "warning", "shield-question", "text-warning-foreground", "shieldQuestion", "warningForeground", "Approval needed", "Rename the settings route"),
    ("failed", "error", "circle-alert", "text-destructive-foreground", "circleAlert", "destructiveForeground", "Thread failed", "Migrate the billing tables to the new schema"),
    ("input", "warning", "message-circle-question", "text-info-foreground", "messageCircleQuestion", "infoForeground", "Input needed", "Pick a color palette"),
]
toast_spec = {"sourceVersion": "v0.1.4-nightly.20261028.3814", "component": "thread-toast", "source": "apps/web/src/components/ThreadNotificationCoordinator.tsx", "states": ["rest"],
              "themes": ["light", "dark"], "cases": [
    {"name": name, "html": thread_toast(kind, icon, color, title, desc), "wrapperStyle": "position:relative;display:block;width:360px;height:120px",
     "native": {"kind": kind, "icon": native_icon, "color": native_color, "title": title, "description": desc, "action": "Open thread"}}
    for name, kind, icon, color, native_icon, native_color, title, desc in CASES]}

OVERLAY = "rounded-full bg-foreground/95 px-8 py-4 text-2xl font-bold text-background shadow-xl"
overlay_spec = {"sourceVersion": "v0.1.4-nightly.20261028.3814", "component": "quit-hold-overlay", "source": "apps/web/src/components/QuitHoldOverlay.tsx", "states": ["rest"],
                "themes": ["light", "dark"], "cases": [
    {"name": mode, "html": f'<div class="{OVERLAY}">{text}</div>', "wrapperStyle": "display:inline-block;padding:0",
     "native": {"mode": mode, "text": text}}
    for mode, text in [("hold", "Hold ⌘Q or press twice to quit"), ("double-click", "Press ⌘Q again to quit")]]}

for spec in [toast_spec, overlay_spec]:
    with open(os.path.join(root, f"design/component-reference/{spec['component']}.json"), "w") as f:
        json.dump(spec, f, indent=1, ensure_ascii=False)
    print(spec["component"], len(spec["cases"]), "cases")
