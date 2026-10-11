"""Writes design/component-reference/small-areas.json for scripts/component-reference: the visual states the
small areas sweep added. NoActiveThreadState (NoActiveThreadState.tsx:6-33 with ui/empty.tsx and
WorkspacePageHeader.tsx), the hover card's branch mismatch line (Sidebar.tsx:488-505) and the publish wizard's
Bitbucket and Azure DevOps provider cards (GitActionsControl.tsx:784-801, Icons.tsx:162-354).
Usage: /usr/bin/python3 -I scripts/gen-small-areas-spec.py, then scripts/component-reference design/component-reference/small-areas.json
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = "/Users/mrm/CandyWrapper-research/t3code/apps/web/src"

# The hover card helpers of the sidebar leftovers spec.
ns = {"__file__": os.path.join(ROOT, "scripts/gen-sidebar-leftovers-spec.py")}
src = open(ns["__file__"]).read()
exec(src[:src.index("cases = []")], ns)
lucide, favicon, card_row, hover_card = ns["lucide"], ns["favicon"], ns["card_row"], ns["hover_card"]

def brand_svg(name, gid, cls):
    """Icons.tsx markup as plain SVG, the way SourceControlBrandGlyph.swift embeds it."""
    tsx = open(os.path.join(T3, "components/Icons.tsx")).read()
    body = tsx[tsx.index(f"export const {name}: Icon"):]
    svg = body[body.index("<svg"):body.index("</svg>") + len("</svg>")]
    svg = svg.replace("{...props} ", f'class="{cls}" ')
    svg = re.sub(r"\{`\$\{gradientId\}(-?[a-z]*)`\}", lambda m: f'"{gid}{m.group(1)}"', svg)
    svg = re.sub(r"\{`url\(#\$\{gradientId\}(-?[a-z]*)\)`\}", lambda m: f'"url(#{gid}{m.group(1)})"', svg)
    svg = svg.replace("id={gradientId}", f'id="{gid}"')
    for a, b in [("stopColor", "stop-color"), ("stopOpacity", "stop-opacity"), ("fillOpacity", "fill-opacity")]:
        svg = svg.replace(a + "=", b + "=")
    return re.sub(r"\s+", " ", svg)

cases = []

# NoActiveThreadState, desktop branch, in a 720x420 chat surface. `cn` merges EmptyHeader's max-w-sm away for
# max-w-none; the topbar height is the 52px `--workspace-topbar-height`.
cases.append({"name": "no-active-thread", "native": {"kind": "no-active-thread"}, "wrapperStyle": "display:block;width:720px;height:420px",
    "html": '<div class="flex h-full min-h-0 min-w-0 flex-1 flex-col overflow-x-hidden bg-background">'
            '<header class="flex shrink-0 items-center gap-3 px-5 border-b border-border" style="height:52px"><span class="text-xs text-muted-foreground/50">No active thread</span></header>'
            '<div class="flex min-w-0 flex-1 flex-col items-center justify-center text-balance text-center gap-6 p-6 md:p-12" data-slot="empty">'
            '<div class="w-full max-w-lg px-8 py-12"><div class="flex flex-col items-center text-center max-w-none">'
            '<div class="font-semibold text-xl" data-slot="empty-title">Pick a thread to continue</div>'
            '<div class="text-muted-foreground text-sm [[data-slot=empty-title]+&amp;]:mt-1" data-slot="empty-description">Select an existing thread or create a new one to get started.</div>'
            '</div></div></div></div>'})

# The hover card of a Current checkout thread whose checkout moved to another branch.
cases.append({"name": "hover-card.mismatch", "native": {"kind": "hover-card"}, "wrapperStyle": "display:inline-block",
    "html": hover_card("Fix the login redirect", [
        card_row(favicon("candywrapper", "size-3"), "candywrapper"),
        '<div class="flex min-w-0 items-center gap-2">' + lucide("git-branch", "size-3 shrink-0 stroke-muted-foreground")
        + '<span class="inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap flex"><span class="min-w-0 truncate">fix-login</span></span></div>',
        '<div class="flex min-w-0 items-start gap-2 text-warning">' + lucide("circle-alert", "mt-0.5 size-3 shrink-0 stroke-current")
        + '<div class="min-w-0 flex-1 wrap-break-word leading-5">You\'re currently checked out on another branch.</div></div>',
    ])})

# Ready, unselected provider cards (`RadioPrimitive.Root`), half the 528px panel.
CARD = ("relative flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-3 text-left outline-none "
        "border-border bg-background dark:border-transparent dark:bg-white/[0.035]")
for kind, name, label, gid in [("bitbucket", "BitbucketIcon", "Bitbucket", "bb"), ("azure-devops", "AzureDevOpsIcon", "Azure DevOps", "az")]:
    cases.append({"name": f"publish.{kind}", "native": {"kind": "publish", "provider": kind, "label": label}, "wrapperStyle": "display:block;width:258px",
        "html": f'<div class="{CARD}">{brand_svg(name, gid, "size-5 shrink-0")}'
                f'<span class="min-w-0 flex-1 truncate text-sm font-medium text-foreground">{label}</span></div>'})

# The slow request toast with its details open (SlowRpcRequestToastCoordinator.tsx:19-62, toast.tsx:176-258), on the
# overlays generator's toast root.
ov = {"__file__": os.path.join(ROOT, "scripts/gen-overlays-spec.py")}
osrc = open(os.path.join(ROOT, "scripts/gen-overlays-spec.py")).read()
exec(osrc[:osrc.index("T_CASES = [")], ov)
rows = "".join(f'<li class="min-w-0 border-border/50 border-b pb-2 last:border-b-0 last:pb-0"><div class="wrap-break-word font-medium text-foreground">{tag}</div>'
               f'<div class="mt-0.5 text-3xs opacity-75">Started {at}</div></li>'
               for tag, at in [("orchestration.getTurnDiff", "10:42:07 AM"), ("projects.searchEntries", "10:42:09 AM")])
chev = lucide("chevron-up", "mt-0.5 size-3.5 shrink-0 text-muted-foreground opacity-80").replace('stroke-width="2"', 'stroke-width="2.25"')
slow = ov["toast"]("warning", "Some requests are slow", "DESC_SLOT", None).replace(
    '<div class="min-w-0 select-text wrap-break-word text-muted-foreground" data-slot="toast-description">DESC_SLOT</div>',
    '<div class="group flex min-w-0 w-full cursor-pointer select-none items-start gap-1.5 rounded-sm text-left outline-none">'
    '<div class="min-w-0 flex-1"><div class="min-w-0 select-none wrap-break-word text-muted-foreground" data-slot="toast-description">'
    '2 requests waiting longer than 15s.</div></div>' + chev + '</div>'
    '<div class="mt-2 max-h-40 min-h-0 overflow-y-auto overscroll-contain pr-0.5 select-text"><ul class="space-y-2.5 text-xs text-muted-foreground">'
    + rows + '</ul></div>')
assert "DESC_SLOT" not in slow
cases.append({"name": "slow-requests.open", "native": {"kind": "slow-requests"}, "wrapperStyle": "position:relative;display:block;width:360px;height:180px",
              "html": slow})

out = {"component": "small-areas", "source": "NoActiveThreadState.tsx; Sidebar.tsx:488-505; GitActionsControl.tsx:784-801",
       "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/small-areas.json"), "w") as f:
    json.dump(out, f, indent=1, ensure_ascii=False)
print("small-areas", len(cases), "cases")
