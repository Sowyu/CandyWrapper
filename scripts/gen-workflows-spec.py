"""Writes design/component-reference/workflows.json for scripts/component-reference: the chrome of T3 5258's
Workflows page from apps/web/src/components/workflows. The page header (WorkflowsPage.tsx:150-249 with
WorkspacePageHeader.tsx and WorkspaceBreadcrumb.tsx), the run list's filters (WorkflowRunsView.tsx:303-371), run
rows in each state (WorkflowRunListItem, :446-511), the run feed's header (WorkflowRunFeed.tsx:458-533), the
timeline's rows (TimelineRow, StepMark and Rail, :640-930) and the question card (WorkflowQuestionCard,
:1890-2047). Data matches WorkflowsFidelityTests' fixtures; relative times are written as T3 words them.
Usage: /usr/bin/python3 -I scripts/gen-workflows-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-connections-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, btn_ns, merge = ns["lucide"], ns["btn_ns"], ns["merge"]
# 5258's button.tsx gives xs, compact and micro a `gap-1.5` (#37358).
for size in ("xs", "compact"):
    btn_ns["SIZES"][size] = btn_ns["SIZES"][size].replace("gap-1 ", "gap-1.5 ")


def button(variant, size, inner, extra_cls="", attrs=""):
    cls = merge(f'{btn_ns["BASE"]} {btn_ns["VARIANTS"][variant]} {btn_ns["SIZES"][size]} {extra_cls}')
    return f'<button type="button" data-slot="button" class="{cls}"{attrs}>{inner}</button>'


t = {}
tsrc = open(os.path.join(ROOT, "scripts/gen-toggles-spec.py")).read()
exec(tsrc[:tsrc.index("cases = []")], t)
p = {"__file__": os.path.join(ROOT, "scripts/gen-popups-spec.py")}
psrc = open(os.path.join(ROOT, "scripts/gen-popups-spec.py")).read()
start = psrc.index("cases = []\nfor variant, size, value, open_")
exec(psrc[:start], p)
S_BASE, S_VARIANT, S_SIZE, icon = p["S_BASE"], p["S_VARIANT"], p["S_SIZE"], p["icon"]


def select(value):
    v = f'<span class="flex-1 truncate data-placeholder:text-placeholder" data-slot="select-value">{value}</span>'
    chevron = f'<span data-slot="select-icon" class="flex">{icon("chevron-down", "-me-1 size-3.5 opacity-70")}</span>'
    return f'<button type="button" class="{S_BASE} {S_VARIANT["default"]} {S_SIZE["sm"]}" data-slot="select-trigger">{v}{chevron}</button>'


G_SEG = "flex w-fit *:focus-visible:z-10 *:pointer-coarse:after:min-w-auto gap-0.5 rounded-lg bg-input/40 p-0.5"


def tabs(pressed):
    items = "".join(t["toggle"]("segmented", "segmented", label, label == pressed, icon=False).replace(
        'class="', 'class="flex-1 ', 1) for label in ["Needs you", "Running", "All"])
    return f'<div data-slot="toggle-group" role="group" class="{G_SEG} w-full">{items}</div>'


# WorkflowsPage.tsx:150-249: the breadcrumb's one item, then the Definitions button.
def header():
    crumb = ('<nav aria-label="Workflows breadcrumb" class="min-w-0 flex-1"><ol class="m-0 flex min-w-0 list-none items-center gap-2 p-0 text-sm sm:gap-3">'
             '<li aria-current="page" class="flex min-w-0 items-center font-medium text-foreground"><h1 class="truncate">Workflows</h1></li></ol></nav>')
    definitions = button("outline", "sm", lucide("file-code-2") + "Definitions")
    return (f'<header class="flex shrink-0 items-center gap-3 border-b" style="height:52px;padding-left:20px;padding-right:20px">'
            f'{crumb}{definitions}</header>')


def filters(pressed, workflow, kind, line):
    parts = [tabs(pressed), select(workflow)]
    if kind is not None: parts.append(select(kind))
    if line: parts.append(f'<p class="px-1 text-xs text-muted-foreground">{line}</p>')
    return f'<div class="space-y-2 p-2 pb-1">{"".join(parts)}</div>'


CHIP_TONES = ["bg-sky-500/15 text-sky-700 dark:text-sky-300", "bg-violet-500/15 text-violet-700 dark:text-violet-300",
              "bg-amber-500/15 text-amber-700 dark:text-amber-300", "bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",
              "bg-rose-500/15 text-rose-700 dark:text-rose-300"]
TONE = {"input": "text-warning-foreground", "failed": "text-destructive", "working": "text-info-foreground",
        "quiet": "text-muted-foreground", "done": "text-success-foreground"}


def chip(letters, tone):
    return (f'<span aria-hidden="true" class="grid size-4 shrink-0 place-items-center rounded-sm text-4xs leading-none font-bold {CHIP_TONES[tone]}">'
            f'{letters}</span>')


def state_word(word, tone):
    mark = ('<span aria-hidden="true" class="size-1.5 rounded-full bg-info"></span>' if tone == "working"
            else lucide("check", "size-3") if tone == "done" else "")
    return f'<span class="flex shrink-0 items-center gap-1 text-xs font-medium whitespace-nowrap {TONE[tone]}">{mark}{word}</span>'


def row(r, current):
    li = "rounded-lg bg-accent" if current else "rounded-lg"
    b = ("flex w-full cursor-pointer flex-col gap-0.5 rounded-lg px-2 py-1.5 text-left focus-visible:ring-2 focus-visible:ring-ring/70 "
         "focus-visible:outline-none focus-visible:ring-inset" + ("" if current else " hover:bg-accent/50"))
    return (f'<ul class="space-y-0.5"><li class="{li}"><button type="button" class="{b}">'
            f'<span class="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">{chip(r["letters"], r["tone"])}'
            f'<span class="min-w-0 flex-1 truncate">{r["workflow"]}</span>{state_word(r["word"], r["stateTone"])}</span>'
            f'<span class="truncate text-sm text-foreground">{r["title"]}</span>'
            f'<span class="flex min-w-0 gap-1.5 text-xs text-muted-foreground"><span class="min-w-0 flex-1 truncate">{r["now"]}</span>'
            f'<span class="shrink-0">{r["time"]}</span></span></button></li></ul>')


# The fixtures WorkflowsFidelityTests builds: chips are read from `workflowChip` there and checked against these.
ROWS = {
    "needs": {"workflow": "triage", "letters": "TR", "tone": 0, "word": "Needs you", "stateTone": "input",
              "title": "Fix the login bug", "now": "Asks: Ship the fix?", "time": "5m ago"},
    "working": {"workflow": "nightly-review", "letters": "NR", "tone": 0, "word": "Working", "stateTone": "working",
                "title": "Review last night's commits", "now": "review is working", "time": "2m ago"},
    "paused": {"workflow": "deploy", "letters": "DE", "tone": 1, "word": "Paused", "stateTone": "failed",
               "title": "Deploy to staging", "now": "build failed: exit 1", "time": "1h ago"},
    "done": {"workflow": "triage", "letters": "TR", "tone": 0, "word": "Done", "stateTone": "done",
             "title": "Label new issues", "now": "labelled: 4", "time": "3d ago"},
    "quiet": {"workflow": "deploy", "letters": "DE", "tone": 1, "word": "Sleeping", "stateTone": "quiet",
              "title": "Wait for the window", "now": "Sleeping at wait-window", "time": "just now"},
}


# WorkflowRunFeed.tsx:458-533: no "Part of" button, the title row, the meta line.
def feed_header(title, word, tone, meta, stop):
    stop_btn = button("ghost-destructive", "xs", lucide("square", "size-2.5 fill-current") + "Stop", attrs=' title="Cancel run"') if stop else ""
    spans = []
    for i, part in enumerate(meta[1:]):
        spans.append('<span aria-hidden="true">·</span>')
        spans.append(f"<span>{part}</span>")
    return ('<header class="space-y-1"><div class="flex items-center gap-2">'
            f'<h2 class="min-w-0 flex-1 text-base font-semibold break-words">{title}</h2>{state_word(word, tone)}{stop_btn}</div>'
            f'<p class="flex flex-wrap items-center gap-x-1.5 text-xs text-muted-foreground">{chip(meta[0][1], meta[0][2])}<span>{meta[0][0]}</span>'
            f'{"".join(spans)}</p></header>')


# StepMark (:661-735).
RING = {"working": "stroke-info", "input": "stroke-warning", "quiet": "stroke-muted-foreground/60",
        "done": "stroke-muted-foreground/45", "failed": "stroke-destructive", "ended": "stroke-muted-foreground/60"}


def step_mark(tone):
    live = tone in ("working", "input")
    dash = ' stroke-dasharray="2.6 2.2"' if tone == "input" else ""
    inner = f'<circle cx="10" cy="10" r="8.2" stroke-width="1.6"{dash} class="fill-background {RING[tone]}"></circle>'
    if live or tone == "quiet":
        fill = "fill-warning" if tone == "input" else "fill-muted-foreground/60" if tone == "quiet" else "fill-info"
        inner += f'<circle cx="10" cy="10" r="3.4" class="{fill}"></circle>'
    elif tone == "done":
        inner += ('<path d="M6.3 10.3l2.5 2.4 4.9-5" fill="none" stroke-width="1.8" stroke-dasharray="12" stroke-linecap="round" '
                  'stroke-linejoin="round" class="stroke-muted-foreground"></path>')
    elif tone == "failed":
        inner += '<path d="M10 6.2v4.6M10 13.6v.1" fill="none" stroke-width="1.8" stroke-linecap="round" class="stroke-destructive"></path>'
    else:
        inner += '<path d="M6.6 10h6.8" fill="none" stroke-width="1.6" stroke-linecap="round" class="stroke-muted-foreground"></path>'
    return (f'<span aria-hidden="true" class="relative z-10 grid size-5 shrink-0 place-items-center">'
            f'<svg viewBox="0 0 20 20" class="size-5 overflow-visible">{inner}</svg></span>')


VERB_TONE = {"working": "text-info-foreground", "input": "text-warning-foreground", "quiet": "text-muted-foreground", "failed": "text-destructive"}


# TimelineRow (:737-883) inside the timeline's `li` with its Rail (:886-898), at the narrow feed's width.
def timeline_row(s, first, last):
    live = s["tone"] in ("working", "input")
    name_cls = "font-medium text-foreground" if live or s.get("selected") else "text-foreground/75"
    hi = "bg-accent" if s.get("selected") else "group-hover/row:bg-accent/60"
    aside = s.get("aside")
    aside_html = (f'<span class="min-w-0 truncate text-xs {"text-destructive" if s.get("asideFailed") else "text-muted-foreground"}">{aside}</span>'
                  if aside else "")
    verb = s.get("verb")
    verb_html = f'<span class="relative max-w-[40%] shrink-0 truncate text-xs {VERB_TONE[s.get("verbTone", "working")]}">{verb}</span>' if verb else ""
    rail_cls = ("pointer-events-none absolute start-[9px] w-0.5 bg-border " + ("top-4" if first else "top-0") + " "
                + ("h-4" if last else "bottom-0") + (" hidden" if first and last else ""))
    return (f'<li class="relative"><span aria-hidden="true" class="{rail_cls}"></span>'
            f'<button type="button" class="group/row relative flex w-full min-w-0 cursor-pointer items-center gap-2.5 pe-2 text-left py-1.5">'
            f'<span aria-hidden="true" class="pointer-events-none absolute inset-y-0 end-0 rounded-lg start-6 {hi}"></span>{step_mark(s["tone"])}'
            f'<span class="relative flex min-w-0 flex-1 items-baseline gap-2"><span class="flex max-w-[60%] min-w-0 shrink-0 items-baseline gap-1.5">'
            f'<span class="min-w-0 truncate text-sm {name_cls}">{s["name"]}</span></span>{aside_html}</span>{verb_html}'
            f'<span class="relative min-w-12 shrink-0 text-right text-xs text-muted-foreground tabular-nums">{s.get("duration", "")}</span>'
            f'</button></li>')


STEPS = [
    {"name": "checkout · install", "tone": "done", "duration": "0.4s"},
    {"name": "review", "tone": "done", "aside": "Two files need a test.", "duration": "1m 12s"},
    {"name": "build", "tone": "failed", "aside": "exit 1", "asideFailed": True, "duration": "9.7s"},
    {"name": "approve", "tone": "input", "verb": "Asks you", "verbTone": "input", "duration": "12s", "selected": True},
    {"name": "fix", "tone": "working", "verb": "working", "duration": "34s"},
    {"name": "wait-window", "tone": "quiet", "verb": "wakes in 5m", "verbTone": "quiet", "duration": "2m 0s"},
    {"name": "Cancelled", "tone": "ended", "aside": "Stopped by hand"},
]


def timeline():
    items = "".join(timeline_row(s, i == 0, i == len(STEPS) - 1) for i, s in enumerate(STEPS))
    return f'<nav aria-label="Steps so far" class="w-full shrink-0"><ol>{items}</ol></nav>'


# WorkflowQuestionCard (:1890-2047), not inline: with its head, a link, two described choices and "Add a reason".
def question(reason):
    head = ('<p class="flex items-center gap-2 text-xs text-muted-foreground"><span class="font-medium text-warning-foreground">Needs you</span>'
            '<span>asked 5m ago · the run waits for you</span></p>')
    title = '<h3 class="text-sm font-semibold break-words mt-1">Ship the fix?</h3>'
    links = (f'<div class="mt-2 flex flex-wrap items-center gap-2">{button("outline", "sm", "Pull request" + lucide("external-link"))}</div>')
    choices = ""
    for i, (value, desc) in enumerate([("Ship it", "Merges and deploys."), ("Hold", None)]):
        d = f'<span class="max-w-60 text-xs text-muted-foreground">{desc}</span>' if desc else ""
        choices += f'<div class="flex flex-col items-start gap-1">{button("default" if i == 0 else "outline", "sm", value)}{d}</div>'
    choices = f'<div class="mt-2.5 flex flex-wrap items-start gap-2">{choices}</div>'
    if reason:
        f = {}
        fsrc = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
        isrc = fsrc[fsrc.index("# Input (input.tsx)"):]
        exec(isrc[:isrc.index("W240 =")], f)
        field = f["input_html"]("sm", placeholder="Why, in a sentence. It goes with whichever answer you pick.")
        tail = (f'<div class="mt-2">{field}<p class="mt-1 text-xs text-muted-foreground">Hold needs a reason.</p></div>')
    else:
        tail = ('<div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">'
                '<button type="button" class="cursor-pointer hover:text-foreground disabled:cursor-default">Add a reason</button></div>')
    return (f'<section aria-label="Ship the fix?" class="min-w-0 rounded-xl border border-warning/30 bg-warning-surface px-3 py-2.5">'
            f'{head}{title}{links}{choices}{tail}</section>')


W_PAGE = "display:block;width:900px"
# `md:w-72 md:border-e` with border-box: 287px inside the border.
W_LIST = "display:block;width:287px"
W_ROW = "display:block;width:271px"
W_FEED = "display:block;width:560px"
cases = [
    {"name": "page.header", "html": header(), "wrapperStyle": W_PAGE, "native": {"kind": "header"}},
    {"name": "list.filters", "html": filters("Needs you", "All 2 workflows", "All kinds", "Bug? 1 · Other 1"), "wrapperStyle": W_LIST,
     "native": {"kind": "filters", "workflow": ""}},
    {"name": "list.section", "html": filters("All", "triage", None, "Starts on every 1h"), "wrapperStyle": W_LIST,
     "native": {"kind": "filters", "workflow": "triage"}},
]
for key in ROWS:
    for current in ([True, False] if key == "needs" else [False]):
        cases.append({"name": f"row.{key}{'.current' if current else ''}", "html": row(ROWS[key], current), "wrapperStyle": W_ROW,
                      "native": {"kind": "row", "row": key, "current": str(current).lower(), **{k: str(v) for k, v in ROWS[key].items()}}})
cases += [
    {"name": "feed.header.running", "html": feed_header("Fix the login bug", "Needs you", "input",
                                                        [("triage", "TR", 0), "started 5m ago", "5m 0s so far"], True),
     "wrapperStyle": W_FEED, "native": {"kind": "feedHeader", "run": "needs"}},
    {"name": "feed.header.done", "html": feed_header("Label new issues", "Done", "done",
                                                     [("triage", "TR", 0), "started 3d ago", "took 2m 3s"], False),
     "wrapperStyle": W_FEED, "native": {"kind": "feedHeader", "run": "done"}},
    {"name": "feed.timeline", "html": timeline(), "wrapperStyle": "display:block;width:384px", "native": {"kind": "timeline"}},
    {"name": "question.card", "html": question(False), "wrapperStyle": W_FEED, "native": {"kind": "question", "reason": "false"}},
    {"name": "question.reason", "html": question(True), "wrapperStyle": W_FEED, "native": {"kind": "question", "reason": "true"}},
]
spec = {"component": "workflows", "source": "apps/web/src/components/workflows (5258)", "states": ["rest"],
        "themes": ["light", "dark"], "viewportWidth": 960, "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/workflows.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("workflows", len(cases), "cases")
