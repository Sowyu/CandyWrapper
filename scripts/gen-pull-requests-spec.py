"""Writes design/component-reference/pull-requests.json for scripts/component-reference: the Pull Requests
page's list (group headers, PullRequestRow.tsx with PullRequestListRow.tsx's lines, pullRequestPresentation.tsx
glyphs and label chips), the pull request detail panel's header and tab bar (PullRequestDetailPanel.tsx:1662-2540,
PullRequestDetailLayout.tsx) and the Link pull request dialog (LinkPullRequestDialog.tsx:194-254).

Class strings are copied from those files at Nightly 3824 (CANDY_T3_SOURCE selects the source tree); the badge variants are read from
ui/badge.tsx. Button, toggle, input, dialog and lucide helpers are reused from the button, toggles, forms,
overlays and run-on generators. Data matches fixtures/pull-requests (relative times at 2026-10-10T16:00Z).
Usage: /usr/bin/python3 -I scripts/gen-pull-requests-spec.py
"""
import json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = os.path.join(os.environ.get("CANDY_T3_SOURCE") or os.path.expanduser("~/CandyWrapper-research/t3code/apps/web/src"), "components")

def source_file(relative):
    """Read the design tag without changing the shared checkout."""
    if os.environ.get("CANDY_T3_SOURCE"):
        return open(os.path.join(os.environ["CANDY_T3_SOURCE"], relative)).read()
    return subprocess.check_output(["git", "-C", os.path.expanduser("~/CandyWrapper-research/t3code"), "show",
        "v0.1.4-nightly.20261028.3824:apps/web/src/" + relative], text=True)

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-run-on-spec.py")}
exec(load("gen-run-on-spec.py", "ENVS = ["), g)
o = {"__file__": os.path.join(ROOT, "scripts/gen-overlays-spec.py")}
exec(load("gen-overlays-spec.py", 'specs["dialog"]'), o)
t = {}
exec(load("gen-toggles-spec.py", "cases = []"), t)
forms = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
f = {}
input_src = forms[forms.index("# Input (input.tsx)"):]
exec(input_src[:input_src.index("W240 =")], f)
lucide, btn, POPUP, CLOSE, merge = g["lucide"], o["btn"], o["POPUP"], o["CLOSE"], o["merge"]
BASE, VARIANTS, SIZES = o["BASE"], o["VARIANTS"], o["SIZES"]
input_html = f["input_html"]

# ui/badge.tsx: the base, the `sm` size and the variants, read from the source.
badge_src = source_file("components/ui/badge.tsx")
BADGE_BASE = re.search(r'cva\(\s*"([^"]+)"', badge_src).group(1)
def badge_part(key):
    m = re.search(r'\b' + re.escape(key) + r':\s*\n?\s*"([^"]+)"', badge_src)
    return m.group(1)
def badge(text, variant, size="sm", style=""):
    st = f' style="{style}"' if style else ""
    return f'<span data-slot="badge" class="{BADGE_BASE} {badge_part(size)} {badge_part(variant)} min-w-0 max-w-40 shrink justify-start"{st}><span class="truncate">{text}</span></span>'

def label_chip(name, color):
    return badge(name, "label", style=f"--label:#{color}") if color else badge(name, "secondary")

TONE = {"open": "text-emerald-600 dark:text-emerald-300/90", "draft": "text-zinc-500 dark:text-zinc-400/80",
        "closed": "text-red-600 dark:text-red-300/90", "merged": "text-violet-600 dark:text-violet-300/90"}
STATE_ICON = {"open": "git-pull-request-arrow", "draft": "git-pull-request-draft", "closed": "git-pull-request-closed", "merged": "git-merge"}
CHECKS = {"passing": ("circle-check", TONE["open"]), "failing": ("circle-x", "text-destructive"),
          "pending": ("circle-dot", "text-amber-600 dark:text-amber-400/90")}
REVIEW = {"approved": ("user-check", TONE["open"]), "changes-requested": ("user-round-x", "text-amber-600/90 dark:text-amber-400/80"),
          "review-required": ("user-round", "text-muted-foreground/60")}

def avatar(login, cls=""):
    return (f'<span aria-hidden class="flex size-4 shrink-0 items-center justify-center rounded-full bg-muted text-3xs font-medium '
            f'text-muted-foreground {cls}">{login[0].upper()}</span>')

def diffstat(add, rem, cls="font-mono"):
    if add == 0 and rem == 0: return ""
    return (f'<span class="inline-flex items-baseline gap-1 tabular-nums {cls}"><span class="text-diff-addition-foreground">+{add:,}</span>'
            f'<span class="text-diff-deletion-foreground">-{rem:,}</span></span>')

def row(e):
    tone = "draft" if e["state"] == "open" and e["draft"] else e["state"]
    conflict = ""
    if e["state"] == "open" and not e["draft"] and e["mergeability"] == "conflicting":
        conflict = ('<span class="absolute -right-1 -bottom-1 inline-flex"><span class="inline-flex shrink-0">'
                    + lucide("triangle-alert", "shrink-0 text-destructive size-3 fill-background [stroke-width:2.5]") + '</span></span>')
    glyph = (f'<span class="flex w-4 shrink-0 flex-col items-center gap-0.5 mt-0.75 self-start"><span class="relative inline-flex">'
             f'<span class="inline-flex shrink-0">{lucide(STATE_ICON[tone], "size-4 shrink-0 " + TONE[tone])}</span>{conflict}</span></span>')
    signals = ""
    if e.get("checks"):
        ic, cls = CHECKS[e["checks"]]
        signals += f'<span role="button" class="inline-flex shrink-0 cursor-pointer items-center">{lucide(ic, "size-3.5 " + cls)}</span>'
    if e.get("review"):
        ic, cls = REVIEW[e["review"]]
        signals += f'<span class="inline-flex shrink-0">{lucide(ic, "size-3.5 " + cls)}</span>'
    status = ""
    if e.get("stack"):
        status += (f'<span role="button" class="inline-flex shrink-0 cursor-pointer items-center gap-1 text-xs font-normal text-muted-foreground">'
                   f'{lucide("layers", "size-3")}{e["stack"]}</span>')
    status += diffstat(e["add"], e["rem"])
    labels = ""
    if e["labels"]:
        chips = []
        for i, (name, color) in enumerate(e["labels"][:3]):
            remaining = len(e["labels"]) - i - 1
            cls = "" if i == 0 else ("hidden @xl/pr-row-meta:inline-flex" if i == 1 else "hidden @3xl/pr-row-meta:inline-flex")
            over = ["@xl/pr-row-meta:hidden", "@3xl/pr-row-meta:hidden", ""][i]
            chip = label_chip(name, color)
            extra = f'<span class="shrink-0 {over}">+{remaining}</span>' if remaining > 0 else ""
            chip = chip.replace('</span></span>', f'</span>{extra}</span>', 1).replace('class="', f'class="{cls} ', 1) if cls or extra else chip
            chips.append(chip)
        labels = f'<span class="flex min-w-0 items-center gap-1">{"".join(chips)}</span>'
    lines = ('<span class="min-w-0 flex-1"><span class="flex min-w-0 items-center gap-1.5">'
             f'<span class="shrink-0 font-mono text-xs tabular-nums text-muted-foreground">#{e["number"]}</span>'
             f'<span class="min-w-0 truncate text-sm">{e["title"]}</span>'
             + (f'<span class="flex shrink-0 items-center gap-1 text-2xs">{signals}</span>' if signals else "")
             + (f'<span class="ml-auto flex shrink-0 items-center gap-1.5 text-2xs">{status}</span>' if status else "")
             + '</span><span class="flex min-w-0 items-center gap-1.5 overflow-hidden text-2xs text-muted-foreground @container/pr-row-meta">'
             f'<span class="inline-flex min-w-0 items-center gap-1 min-w-3.5 max-w-40">{avatar(e["author"], "size-3.5")}'
             f'<span class="truncate sr-only @xs/pr-row-meta:not-sr-only @xs/pr-row-meta:truncate">{e["author"]}</span></span>'
             f'<span class="truncate">pingdotgg/t3code</span>{labels}'
             f'<span class="ml-auto shrink-0 whitespace-nowrap tabular-nums">{e["time"]}</span></span></span>')
    button = (f'<button type="button" class="group/pr-row flex w-full items-center gap-2 rounded-md text-left px-3 py-2.5 min-w-0 flex-1 cursor-pointer">'
              f'{glyph}{lines}</button>')
    return f'<div class="flex items-center rounded-md">{button}</div>'

def group_header(key, label, count):
    icon = {"authored": "pen-line", "reviewRequested": "eye", "others": "users"}[key]
    return (f'<div class="flex items-center gap-2 px-3 pb-1 text-xs font-medium text-muted-foreground/70">{lucide(icon, "size-3.5 shrink-0")}'
            f'<h2 class="shrink-0">{label}</h2><span class="shrink-0 tabular-nums text-muted-foreground/50">{count}</span>'
            '<div data-slot="separator" data-orientation="horizontal" class="shrink-0 bg-border h-px min-w-2 flex-1"></div></div>')

ROWS = [
    {"number": 2861, "title": "Add the pull requests page", "author": "octocat", "state": "open", "draft": False, "mergeability": "mergeable",
     "add": 412, "rem": 37, "labels": [("enhancement", "a2eeef")], "checks": "passing", "review": "approved", "time": "2h ago"},
    {"number": 2850, "title": "Draft: native stack actions", "author": "octocat", "state": "open", "draft": True, "mergeability": "unknown",
     "add": 0, "rem": 0, "labels": [], "checks": "pending", "stack": "2/3", "time": "1d ago"},
    {"number": 2847, "title": "Fix the composer focus after a turn", "author": "hubot", "state": "open", "draft": False, "mergeability": "conflicting",
     "add": 12, "rem": 4, "labels": [("bug", "d73a4a"), ("size:S", None)], "checks": "failing", "review": "changes-requested", "time": "2d ago"},
]
W = 720
rows_html = (f'<div class="space-y-3" style="width:{W}px"><div class="space-y-0.5">{group_header("authored", "Authored", 2)}{row(ROWS[0])}{row(ROWS[1])}</div>'
             f'<div class="space-y-0.5">{group_header("reviewRequested", "Review requested", 1)}{row(ROWS[2])}</div></div>')

# The detail header (open, mergeable, checks passing: the Merge button) and its tab bar.
DW = 560
MERGE_CLS = merge(BASE + " " + VARIANTS["default"] + " " + SIZES["xs"])
MORE_CLS = merge(BASE + " " + VARIANTS["ghost-muted"] + " " + SIZES["icon-xs"])
# toggle-group.tsx:27-39, as gen-toggles-spec.py writes it.
G_CLS = ("flex w-fit *:focus-visible:z-10 dark:*:[[data-slot=separator]:has(+[data-slot=toggle]:hover)]:before:bg-input/64 "
         "dark:*:[[data-slot=separator]:has(+[data-slot=toggle][data-pressed])]:before:bg-input dark:*:[[data-slot=toggle]:hover+[data-slot=separator]]:before:bg-input/64 "
         "dark:*:[[data-slot=toggle][data-pressed]+[data-slot=separator]]:before:bg-input *:pointer-coarse:after:min-w-auto gap-0.5 rounded-lg bg-input/40 p-0.5")
merge_btn = (f'<span class="inline-flex shrink-0"><button type="button" data-slot="button" class="{MERGE_CLS}">'
             f'{lucide("git-merge", "size-3.5")}<span class="@max-[30rem]/pr-header:hidden">Merge</span></button></span>')
more_btn = f'<button type="button" data-slot="button" class="{MORE_CLS}">{lucide("ellipsis", "size-4")}</button>'
top = ('<div class="pl-4 grid h-7 min-w-0 items-center overflow-hidden"><div class="col-start-1 row-start-1 flex min-w-0 items-center gap-1 '
       'text-sm text-muted-foreground sm:text-xs">'
       '<button type="button" class="min-w-0 cursor-pointer truncate text-left font-medium text-muted-foreground underline-offset-2">pingdotgg/t3code</button>'
       f'<button type="button" class="inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 {TONE["open"]}">#2861'
       f'{lucide("external-link", "size-2.5")}</button></div></div>'
       f'<div class="mr-4 flex h-7 shrink-0 items-center justify-end gap-1">{merge_btn}{more_btn}</div>')
COPY = ("relative grid w-fit min-w-0 max-w-full shrink cursor-pointer rounded px-1 py-0.5 text-left outline-none transition-colors")
title_row = ('<div class="flex min-h-7 min-w-0 items-center sm:min-h-6 group gap-1"><h1 class="min-w-0 flex-1 truncate text-base font-semibold leading-snug">'
             'Add the pull requests page</h1></div>')
body = ('<div class="col-span-2 mt-1 min-w-0 px-4 pb-4">' + title_row +
        '<div class="mt-2 flex min-h-5 min-w-0 items-center gap-2 text-xs text-muted-foreground">'
        '<span class="flex min-w-0 items-center gap-1.5 min-w-0 whitespace-nowrap"><span class="flex min-w-0 shrink"><span class="flex min-w-0 items-center gap-1.5">'
        f'{avatar("octocat")}<span class="truncate font-medium text-foreground">octocat</span></span></span>'
        '<span aria-hidden class="shrink-0 text-muted-foreground/50">·</span><span>updated 37d ago</span></span>'
        f'<button type="button" class="{COPY} ml-auto font-mono"><code class="col-start-1 row-start-1 min-w-0 truncate">gh pr checkout 2861</code></button></div>'
        '<div class="mt-4 flex min-h-5 min-w-0 items-center gap-2 text-xs text-muted-foreground">'
        '<span class="flex min-w-0 flex-1 items-center gap-1.5 font-mono text-xs text-muted-foreground/70">'
        '<span class="inline-flex min-w-0 max-w-[40%] shrink-0 items-center gap-1"><code class="flex min-w-0"><span class="truncate">main</span></code></span>'
        f'{lucide("arrow-left", "size-3.5 shrink-0 opacity-60")}'
        f'<button type="button" class="{COPY}"><code class="col-start-1 row-start-1 min-w-0 truncate">feat/pull-requests-page</code></button></span>'
        '<span class="ml-auto inline-flex shrink-0 items-center justify-end gap-2"><span class="inline-flex min-w-16 items-center justify-end gap-1.5 tabular-nums">'
        f'{lucide("file-diff", "size-3.5")}9 files</span>{diffstat(412, 37, "shrink-0 font-mono text-xs")}</span></div></div>')
toggles = "".join(t["toggle"]("segmented", "segmented", label, i == 0, icon=False) for i, label in enumerate(["Summary", "Timeline", "Code"]))
tabbar = ('<nav class="col-span-2 flex min-w-0 flex-wrap items-center gap-2 border-t border-border/60 px-4 py-2">'
          f'<div data-slot="toggle-group" role="group" class="{G_CLS} shrink-0">{toggles}</div>'
          '<span class="ml-auto flex h-4 min-w-0 flex-1 flex-wrap content-start items-center justify-end gap-x-1.5 overflow-hidden text-xs text-muted-foreground">'
          f'<span role="button" class="inline-flex shrink-0 cursor-pointer items-center">{lucide("circle-check", "size-3.5 " + TONE["open"])}</span>'
          '<span class="whitespace-nowrap">All checks passed</span></span></nav>')
detail_html = (f'<div class="relative flex w-full flex-col bg-background" style="width:{DW}px">'
               '<div class="@container/pr-header grid min-w-0 shrink-0 grid-cols-[minmax(0,1fr)_auto] items-start gap-x-2 border-b border-border/60">'
               f'{top}<div class="col-span-2 grid grid-rows-[1fr]"><div class="min-h-0 overflow-hidden">{body}</div></div>{tabbar}</div></div>')

# Link pull request (`max-w-xl`), with "#42" typed and resolved against the thread's repository.
header = ('<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
          '<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">Link pull request</h2>'
          '<p class="text-muted-foreground text-sm" data-slot="dialog-description">Attach a pull request to this thread by its URL, or by its number for this thread\'s repository.</p></div>')
panel = ('<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 '
         'in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">'
         f'{input_html(placeholder="Pull request URL or #42", value="#42")}'
         '<p class="truncate text-muted-foreground text-xs">github.com/pingdotgg/t3code #42</p></div>')
footer = ('<div class="flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)] border-t bg-muted/72 py-4" data-slot="dialog-footer">'
          f'{btn("outline", "sm", "Cancel")}{btn("default", "sm", "Link")}</div>')
dialog_html = f'<div role="dialog" data-slot="dialog-popup" class="{POPUP} max-w-xl">{header}{panel}{footer}{CLOSE}</div>'

cases = [
    {"name": "rows", "html": rows_html, "native": {"case": "rows"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "detail-header", "html": detail_html, "native": {"case": "detail-header"}, "wrapperStyle": f"display:block;width:{DW}px"},
    {"name": "link-dialog", "html": dialog_html, "native": {"case": "link-dialog"}, "wrapperStyle": "display:grid;width:576px"},
]
# #25829: verdicts remain visible over bot avatars, including stale reviews.
for outcome, icon, ring, fill in [
    ("approved", "circle-check", "ring-2 ring-emerald-500 dark:ring-emerald-400", "fill-emerald-500 dark:fill-emerald-400"),
    ("changes-requested", "circle-x", "ring-2 ring-destructive", "fill-destructive"),
    ("dismissed", "circle-dashed", "ring-2 ring-muted-foreground/60", "fill-muted-foreground")]:
    for stale in [False, True]:
        if stale:
            tone = "var(--color-emerald-500)" if outcome == "approved" else "var(--destructive)" if outcome == "changes-requested" else "var(--contrast-muted-foreground)"
            dark_tone = "var(--color-emerald-400)" if outcome == "approved" else tone
            amount = "30%" if outcome == "dismissed" else "35%"
            ring = f"ring-2 ring-[color-mix(in_srgb,{tone}_{amount},var(--background))] dark:ring-[color-mix(in_srgb,{dark_tone}_{amount},var(--background))]"
        html = (f'<span class="relative inline-block size-4 rounded-full {ring}">{avatar("bot")}'
                + lucide(icon, "absolute -right-1 -bottom-1 size-3 text-background " + fill + (" opacity-50" if stale else ""), stroke="3") + '</span>')
        name = "avatar." + outcome + (".stale" if stale else "")
        cases.append({"name": name, "html": html, "native": {"case": name}, "wrapperStyle": "display:inline-flex"})
spec = {"component": "pull-requests", "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/pull-requests.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
