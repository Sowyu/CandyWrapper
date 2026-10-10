"""Writes design/component-reference/terminal-drawer.json for scripts/component-reference: the
terminal drawer's chrome (ThreadTerminalDrawer.tsx:1494-1700) with one terminal (the floating
action cluster over an empty terminal) and the empty state.

Class strings are copied from that file at the tag in T3_VERSION. The terminal's canvas is left
empty: its text comes from libghostty in T3 and SwiftTerm here, which no screenshot compares.
Usage: /usr/bin/python3 -I scripts/gen-terminal-drawer-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or "/Users/mrm/CandyWrapper-research"
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")

# Button classes and tailwind-merge from gen-button-spec.py (its definitions only).
src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
exec(src[:src.index("def camel")])

def lucide(name, cls=""):
    s = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", s[s.index(">", s.index("<svg")) + 1:s.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

W, H = 640, 200
ASIDE = "relative flex min-w-0 flex-col overflow-hidden bg-background shrink-0 border-t border-border/80"
HANDLE = '<div class="absolute inset-x-0 top-0 z-20 h-1.5 cursor-row-resize"></div>'
BTN = "p-1 text-foreground/90 transition-colors hover:bg-accent"
RULE = '<div class="h-4 w-px bg-border/80"></div>'
cluster = ('<div class="pointer-events-none absolute right-2 top-2 z-20">'
           '<div class="pointer-events-auto inline-flex items-center overflow-hidden rounded-md border border-border/80 bg-background shadow-xs">'
           + RULE.join(f'<button type="button" class="{BTN}">{lucide(icon, "size-3.25")}</button>'
                       for icon in ["square-split-horizontal", "square-split-vertical", "plus", "trash-2"])
           + '</div></div>')
drawer = (f'<aside class="{ASIDE}" style="height:{H}px;width:{W}px">{HANDLE}{cluster}'
          '<div class="min-h-0 w-full flex-1"><div class="flex h-full min-h-0 bg-(--terminal-background)">'
          '<div class="min-w-0 flex-1"><div class="h-full"><div class="relative h-full w-full overflow-hidden bg-(--terminal-background)"></div></div></div>'
          '</div></div></aside>')
button = merge(f"{BASE} {VARIANTS['outline']} {SIZES['xs']}")
empty = (f'<aside class="{ASIDE}" style="height:{H}px;width:{W}px">{HANDLE}'
         '<div class="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">'
         f'<p>No terminal sessions for this thread yet.</p><button data-slot="button" class="{button}">New Terminal (⌘N)</button>'
         '</div></aside>')

cases = [
    {"name": "drawer", "html": drawer, "native": {"case": "drawer"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "empty", "html": empty, "native": {"case": "empty"}, "wrapperStyle": f"display:block;width:{W}px"},
]
spec = {"component": "terminal-drawer", "source": "apps/web/src/components/ThreadTerminalDrawer.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/terminal-drawer.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
