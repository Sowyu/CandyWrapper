"""Writes design/component-reference/environments-map.json for scripts/component-reference: the chrome of T3 5258's
Environments map and its details panel at the Connections column's width (796px), from
apps/web/src/components/settings/EnvironmentsMap.tsx (toolbar :885-1000, footer and legend :1056-1137) and
EnvironmentsMapDetails.tsx (Heading :234-242, FleetSummary :244-273, LinkDetails :835-881, AccessMeter :73-96).
The scene between toolbar and footer is CandyWrapper's own drawing of the same layout engine and has no
reference yet: T3 builds it from positioned elements per machine. The details panel's `border-t` is left out,
because in CandyWrapper the group's divider draws it. Dates follow this Mac's time zone, as Chromium's
`Intl.DateTimeFormat` and CandyWrapper's formatter both do.
Usage: /usr/bin/python3 -I scripts/gen-environments-map-spec.py
"""
import json, os
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-connections-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, button = ns["lucide"], ns["button"]
forms = {"__file__": os.path.join(ROOT, "scripts/gen-forms-spec.py")}
fsrc = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
# Its earlier sections write their own specs; only the definitions are wanted here.
exec(fsrc[:fsrc.index('cases = [\n    {"name": "default.search"')].replace("\nwrite(", "\nNone and write("), forms)
SEARCH = lucide("search")


def toolbar():
    field = forms["group_html"](start=SEARCH, placeholder="Find a machine")
    link_several = button("outline", "xs", "Link several…")
    help_ = button("ghost", "icon-xs", lucide("circle-help"))
    return ('<div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 rounded-t-xl border-b border-border/60 bg-background/50 px-3 py-1.5">'
            f'<div class="w-48">{field}</div><p role="status" class="min-w-0 text-2xs text-muted-foreground"></p>'
            f'<div class="ml-auto flex items-center gap-2">{link_several}{help_}</div></div>')


def sample(wire, width, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<svg aria-hidden="true" viewBox="0 0 18 4" class="h-1 w-4.5 {wire}"><path d="M0 2H18" stroke="currentColor" '
            f'stroke-width="{width + 0.25}"{d}></path></svg>')


def footer():
    items = [
        sample("text-success", 1.75) + "In use",
        sample("text-muted-foreground/60", 1) + "Standby",
        sample("text-muted-foreground/60", 1, "4 4") + "Offline",
        '<svg aria-hidden="true" viewBox="0 0 22 6" class="h-1.5 w-5.5 text-foreground/70"><path d="M0 3L22 0.5V5.5Z" fill="currentColor"></path></svg>Link',
    ]
    legend = ('<ul aria-label="How to read the lines" class="flex min-w-0 items-center gap-x-3 overflow-clip text-2xs whitespace-nowrap text-muted-foreground">'
              + "".join(f'<li class="flex items-center gap-1.5">{i}</li>' for i in items) + "</ul>")
    zoom = "".join(button("ghost", "icon-xs", lucide(n)) for n in ["minus", "plus"])
    zoom += button("ghost", "icon-xs", lucide("maximize"), attrs=" disabled")
    return ('<div class="flex items-center justify-between gap-3 bg-background/50 px-3 py-1">'
            f'{legend}<div class="flex shrink-0 items-center gap-1 rounded-lg border border-border/60 bg-popover/90 p-0.5 shadow-xs/5">{zoom}</div></div>')


SECTION = "px-3 py-3 sm:px-4"
PANEL = "min-h-20 text-xs outline-none"


def heading(title, detail=None):
    d = f'<span class="text-muted-foreground">{detail}</span>' if detail else ""
    return (f'<div class="mb-2 flex flex-wrap items-baseline gap-x-2 gap-y-0.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>{d}</div>')


def summary():
    return f'<div class="{PANEL}"><div class="{SECTION}">{heading("9 machines, 10 links")}</div></div>'


def meter(level):
    bars = "".join(f'<rect x="{i * 4}" y="{8 - i * 2}" width="3" height="{4 + i * 2}" rx="0.75" fill="currentColor" opacity="{1 if i <= level else 0.22}"></rect>'
                   for i in range(5))
    return f'<svg aria-hidden="true" viewBox="0 0 19 12" class="h-3 w-[19px] shrink-0 text-foreground/80">{bars}</svg>'


def when(iso):
    t = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()
    return t.strftime("%b %-d, %Y, %-I:%M %p")


def link_details():
    endpoint = ("cursor-pointer rounded-sm font-medium text-foreground underline-offset-2 outline-none hover:underline "
                "focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset")
    head = ('<div class="mb-2 flex flex-wrap items-center justify-between gap-2"><h3 class="flex min-w-0 flex-wrap items-center gap-1.5 text-sm">'
            f'<button type="button" class="{endpoint}">nucbox</button>{lucide("arrow-right", "size-3.5 text-muted-foreground")}'
            f'<button type="button" class="{endpoint}">fs-3</button></h3>'
            f'<div class="flex items-center gap-2">{button("destructive-outline", "xs", "Forget")}</div></div>')
    term = "text-muted-foreground"
    dot = '<span aria-hidden="true" class="size-2 rounded-full bg-success forced-colors:border-4"></span>'
    rows = (f'<dt class="{term}">Access</dt><dd><span class="flex items-center gap-2 font-medium text-foreground">{meter(0)}Read only</span>'
            '<span class="text-muted-foreground">Read projects and threads. Cannot start, message or change anything.</span></dd>'
            f'<dt class="{term}">Status</dt><dd class="flex items-center gap-1.5 text-foreground">{dot}Reachable</dd>'
            f'<dt class="{term}">Expires</dt><dd class="text-foreground">{when("2027-01-01T00:00:00.000Z")}</dd>'
            f'<dt class="{term}">Addresses</dt><dd class="min-w-0 font-mono text-2xs break-all text-foreground"><span class="block">https://fs-3.example.ts.net</span></dd>'
            f'<dt class="{term}">Linked</dt><dd class="text-foreground">{when("2026-11-01T00:00:00.000Z")}</dd>')
    return (f'<div class="{PANEL}"><div class="{SECTION}"><div>{head}'
            f'<dl class="grid max-w-2xl grid-cols-[auto_1fr] gap-x-4 gap-y-1.5">{rows}</dl></div></div></div>')


W = "display:block;width:796px"
cases = [
    {"name": "map.toolbar", "html": toolbar(), "wrapperStyle": W, "native": {"kind": "toolbar"}},
    {"name": "map.footer", "html": footer(), "wrapperStyle": W, "native": {"kind": "footer"}},
    {"name": "details.summary", "html": summary(), "wrapperStyle": W, "native": {"kind": "summary"}},
    {"name": "details.link", "html": link_details(), "wrapperStyle": W, "native": {"kind": "link"}},
]
spec = {"component": "environments-map", "source": "apps/web/src/components/settings/EnvironmentsMap.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "viewportWidth": 900, "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/environments-map.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("environments-map", len(cases), "cases")
