"""Writes design/component-reference/sidebar-footer.json for scripts/component-reference: the sidebar
footer's undo notice at Nightly 4928 (sidebar/SidebarThreadUndoNotice.tsx:24-68, #26874).

The notice fills the free space of the footer's utility row (SidebarChrome.tsx:265-313), so each case is
the notice's list item alone at the width it gets beside the utility icons. The label is
threadUndoLabel with the default mod+z binding (keybindings.ts:133 in packages/shared), "⌘Z to undo".
Cases: a notice that fits, and one too narrow for the summary, where the reversed wrap drops the
summary out of view and leaves the button.
Usage: /usr/bin/python3 -I scripts/gen-sidebar-footer-spec.py
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = os.path.expanduser("~/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons")

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, f"{name}.svg")).read()
    inner = src[src.index(">", src.index("<svg")) + 1:src.rindex("</svg>")].strip()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

# InlineButton, tone default (ui/button.tsx:103-120).
INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring "
          "disabled:pointer-events-none disabled:opacity-64 text-foreground min-w-0 shrink")

def notice(summary):
    return ('<li data-slot="sidebar-menu-item" data-sidebar="menu-item" class="group/menu-item relative @container flex min-w-0 flex-1">'
            '<div class="flex h-6 min-w-0 flex-1 flex-row-reverse flex-wrap gap-x-1 overflow-hidden text-2xs leading-6 whitespace-nowrap text-sidebar-muted-foreground transition-opacity duration-200 ease-out starting:opacity-0">'
            f'<button type="button" data-slot="inline-button" class="{INLINE}"><span class="flex h-6 min-w-0 flex-wrap justify-end overflow-hidden">'
            f'{lucide("undo-2", "-ml-4 h-6 w-4 @max-[1rem]:invisible")}<span>⌘Z to undo</span></span></button>'
            f'<span>{summary}</span></div></li>')

CASES = []
for name, summary, width in [("undo.archived", "Archived,", 150), ("undo.archived-many.narrow", "Archived 3,", 76)]:
    CASES.append({"name": name, "html": f'<ul class="flex w-full min-w-0 flex-row items-center gap-1" style="width:{width}px">{notice(summary)}</ul>',
                  "wrapperStyle": "display:block;background:var(--sidebar)",
                  "native": {"kind": "undo", "summary": summary, "width": str(width)}})

spec = {"component": "sidebar-footer", "sourceVersion": "v0.1.11-nightly.20261119.4928",
        "source": "apps/web/src/components/sidebar/SidebarThreadUndoNotice.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/sidebar-footer.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("sidebar-footer", len(CASES), "cases")
