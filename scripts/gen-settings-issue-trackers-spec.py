"""Writes design/component-reference/settings-issue-trackers.json for scripts/component-reference: the 4928 issue
tracker rows under Settings > Source control (IssueTrackerSettings.tsx:96-218), Linear connected and Linear not
connected, folded. Helpers, the row shell and the badge come from scripts/gen-settings-pages2-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-settings-issue-trackers-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, button, section, tsx_icon, badge = ns["lucide"], ns["button"], ns["section"], ns["tsx_icon"], ns["badge"]
DOT_RING = ns["DOT_RING"]


def tracker_row(name, summary, usable, rejected=False):
    """`TrackerRow` folded (IssueTrackerSettings.tsx:128-170)."""
    icon = tsx_icon("LinearIcon", "size-4.5 text-foreground/80")
    dot = "bg-success" if usable else "bg-muted-foreground/35"
    chevron = button("ghost-muted", "icon-xs", lucide("chevron-down", "size-3.5 transition-transform"))
    return ('<div class="first:rounded-t-xl last:rounded-b-xl transition-colors hover:bg-muted/20">'
            '<div class="flex items-center justify-between gap-3 px-3 py-3 sm:px-4"><div class="min-w-0 flex-1 space-y-1">'
            '<div class="flex min-w-0 flex-wrap items-center gap-2">'
            f'<span class="relative inline-flex size-5 shrink-0 items-center justify-center">{icon}<span aria-hidden="" class="{DOT_RING} {dot}"></span></span>'
            f'<span class="truncate text-sm font-medium text-foreground">{name}</span>'
            f'{badge("Credential rejected", "destructive") if rejected else ""}</div>'
            f'<p class="text-xs leading-normal text-muted-foreground/80">{summary}</p></div>{chevron}</div></div>')


connected = section("Issue trackers", tracker_row(
    "Linear", "Connected as dev@example.com · no projects linked yet. Pick a team for a project to list its issues.", True))
offline = section("Issue trackers", tracker_row("Linear", "Not connected. Add a personal api key to list its issues.", False))

W796 = "display:block;width:796px"
cases = [
    {"name": "issue-trackers.connected", "html": connected, "wrapperStyle": W796, "native": {"kind": "connected"}},
    {"name": "issue-trackers.disconnected", "html": offline, "wrapperStyle": W796, "native": {"kind": "disconnected"}},
]
spec = {"component": "settings-issue-trackers", "source": "apps/web/src/components/settings/IssueTrackerSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/settings-issue-trackers.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("settings-issue-trackers", len(cases), "cases")
