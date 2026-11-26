"""Writes design/component-reference/sidebar-update-capsule.json for scripts/component-reference: the sidebar
update capsule at Nightly 5258 (sidebar/SidebarUpdateCapsule.tsx:126-182, in SidebarUpdatePill.tsx:445).

Each case is the capsule's `@container/sidebar-update` list item alone at the width the footer row gives it.
The trigger button, the popover and the hover fill are not drawn at rest. Cases: a slow machine with its time
and the icon, a failed machine with Retry, the restart countdown wide and narrow, and a pass too narrow for
its label. CircleArrowUp is the run's icon while this app does not install last (DesktopUpdateStatusIcon.tsx:118).
Usage: /usr/bin/python3 -I scripts/gen-sidebar-update-capsule-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE = os.path.expanduser("~/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons")

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, f"{name}.svg")).read()
    inner = src[src.index(">", src.index("<svg")) + 1:src.rindex("</svg>")].strip()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

def capsule(label, tone=None, slow=None, action=None, seconds=None):
    wide = "@min-[5rem]/sidebar-update" if seconds is None else "@min-[12rem]/sidebar-update"
    ring = {"slow": " ring-1 ring-warning/40 ring-inset", "failed": " ring-1 ring-destructive/40 ring-inset"}.get(tone, "")
    out = (f'<div class="relative ml-auto flex h-8 w-8 shrink-0 items-center justify-end rounded-full bg-sidebar-control-surface text-sidebar-foreground '
           f'transition-[width] duration-200 ease-out motion-reduce:transition-none {wide}:w-full{ring}">'
           '<button type="button" class="absolute inset-0 cursor-pointer rounded-full outline-hidden ring-ring hover:bg-sidebar-row-hover focus-visible:ring-2 focus-visible:ring-inset"></button>'
           f'<span class="pointer-events-none relative hidden min-w-0 flex-1 truncate pl-3 text-xs {wide}:block">'
           f'<span class="{"text-destructive" if tone == "failed" else ""}">{label}</span>'
           + (f'<span class="text-warning tabular-nums"> {slow}</span>' if slow else "") + '</span>')
    if action:
        out += (f'<button type="button" class="relative hidden shrink-0 cursor-pointer pr-3 pl-1.5 text-xs underline decoration-muted-foreground/60 '
                f'underline-offset-3 hover:decoration-current {wide}:block">{action}</button>')
    icon_cls = "pointer-events-none relative grid size-8 shrink-0 place-items-center"
    if action:
        icon_cls += f" {wide}:hidden"
    if seconds is not None:
        icon_cls += " rounded-full text-xs font-medium tabular-nums ring-1 ring-current/22 ring-inset"
    out += f'<span class="{icon_cls}">' + (f"{seconds}s" if seconds is not None else lucide("circle-arrow-up", "size-4")) + "</span></div>"
    return out

CASES = []
for name, width, kw, native in [
    ("capsule.slow", 150, dict(label="studio", tone="slow", slow="4m"), {"mode": "slow", "label": "studio", "elapsed": "4m"}),
    ("capsule.failed", 150, dict(label="alvin failed", tone="failed", action="Retry"), {"mode": "failed", "label": "alvin failed"}),
    ("capsule.countdown", 200, dict(label="Restart in 9s", action="Later", seconds=9), {"mode": "countdown", "label": "Restart in 9s"}),
    ("capsule.countdown.narrow", 120, dict(label="Restart in 9s", action="Later", seconds=9), {"mode": "countdown", "label": "Restart in 9s"}),
    ("capsule.narrow", 60, dict(label="1 of 2 updated"), {"mode": "progress", "label": "1 of 2 updated"}),
]:
    item = ('<li data-slot="sidebar-menu-item" data-sidebar="menu-item" class="group/menu-item relative @container/sidebar-update ml-auto flex min-w-8 flex-1">'
            + capsule(**kw) + "</li>")
    native["width"] = str(width)
    CASES.append({"name": name, "html": f'<div data-app-sidebar class="bg-sidebar text-sidebar-foreground" style="width:{width}px;box-shadow:0 0 0 8px var(--sidebar)">'
                  f'<ul class="flex w-full min-w-0 flex-row items-center gap-1" style="width:{width}px">{item}</ul></div>',
                  "wrapperStyle": "display:block", "native": native})

spec = {"component": "sidebar-update-capsule", "sourceVersion": "v0.1.13-nightly.20261125.5258",
        "source": "apps/web/src/components/sidebar/SidebarUpdateCapsule.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/sidebar-update-capsule.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("sidebar-update-capsule", len(CASES), "cases")
