"""Writes design/component-reference/side-chat-pane.json for scripts/component-reference: a side chat tab's header
(SideThreadPane.tsx:160-200 at 5258) with Add to chat ready or aria-disabled before the first message, a long title, and the
deleted state (:172-177). Buttons come from the overlays generator and lucide icons from the run-on generator,
through the git generator.
Usage: /usr/bin/python3 -I scripts/gen-side-chat-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-git-spec.py")}
exec(load("gen-git-spec.py", "def panel_label"), g)
lucide, btn = g["lucide"], g["btn"]

def header(title, blocked):
    bring = btn("ghost", "xs", "Add to chat")
    if blocked:
        bring = bring.replace("<button ", '<button aria-disabled="true" ', 1)
    trash = btn("ghost", "icon-xs", lucide("trash-2", "")).replace("<button ", '<button aria-label="Delete side chat" ', 1)
    close = btn("ghost", "icon-xs", lucide("x", "")).replace("<button ", '<button aria-label="Close side chat" ', 1)
    return (f'<div class="flex h-9 shrink-0 items-center gap-1 border-b border-border pr-1 pl-3">'
            f'<span class="min-w-0 flex-1 truncate text-xs font-medium">{title}</span>{bring}{trash}{close}</div>')

def pane(title, blocked, deleted=False):
    body = '<p class="p-3 text-xs text-muted-foreground">This side chat was deleted.</p>' if deleted else ""
    return f'<div data-side-chat-pane class="flex h-full min-h-0 flex-col">{header(title, blocked)}{body}</div>'

CASES = [
    ("before-reply", pane("Side chat", True), {"title": "Side chat", "blocked": "Available after the first message."}),
    ("ready", pane("Why is the sky blue", False), {"title": "Why is the sky blue"}),
    ("long-title", pane("Explain the difference between the queue and steer modes in the composer and when each one applies", False),
     {"title": "Explain the difference between the queue and steer modes in the composer and when each one applies"}),
    ("deleted", pane("Side chat", True, deleted=True), {"title": "Side chat", "blocked": "Available after the first message.", "deleted": "yes"}),
]
spec = {"component": "side-chat-pane", "source": "apps/web/src/components/chat/SideThreadPane.tsx",
        "cases": [{"name": n, "html": h, "wrapperStyle": "display:block;width:483px", "native": native} for n, h, native in CASES],
        "states": ["rest"], "themes": ["light", "dark"]}
with open(os.path.join(ROOT, "design/component-reference/side-chat-pane.json"), "w") as out:
    json.dump(spec, out, indent=1, ensure_ascii=False)
print(spec["component"], len(spec["cases"]), "cases")
