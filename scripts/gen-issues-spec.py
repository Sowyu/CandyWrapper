"""Writes design/component-reference/issues.json for scripts/component-reference: the Issues page row (4928
issue/IssueRow.tsx on pullRequest/PullRequestListRow.tsx's PULL_REQUEST_ROW_CLASS, PullRequestRowLines and
PullRequestRowAuthor) with the state glyph of issuePresentation.tsx:33-53. Data matches fixtures/issues/list.json
(#42 open with two assignees and three comments, #40 closed as completed), relative to 2026-11-19T09:00Z, in a
520px row where the labels stay hidden (`@xl/issue-row-meta`).
Left for a later pass: the detail panel (IssueDetailPanel.tsx) and the comment box (IssueCommentComposer.tsx on
ComposerSurface), which need the composer shell's glass in the generator.
Usage: /usr/bin/python3 -I scripts/gen-issues-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-run-on-spec.py")}
exec(load("gen-run-on-spec.py", "ENVS = ["), g)
o = {"__file__": os.path.join(ROOT, "scripts/gen-overlays-spec.py")}
exec(load("gen-overlays-spec.py", 'specs["dialog"]'), o)
lucide, merge = g["lucide"], o["merge"]

W = 520
TONE = {"open": "text-emerald-600 dark:text-emerald-300/90", "draft": "text-zinc-500 dark:text-zinc-400/80",
        "merged": "text-violet-600 dark:text-violet-300/90"}
# PULL_REQUEST_ROW_CLASS (PullRequestListRow.tsx:19) merged with IssueRow's `@container/issue-row-meta px-3 py-2.5`.
ROW = merge("group/pr-row flex w-full items-center gap-2 rounded-md py-1 pr-1 text-left @container/issue-row-meta px-3 py-2.5")

def avatar(login, cls=""):
    # PullRequestActorAvatar's fallback (pullRequestPresentation.tsx:479-481).
    return (f'<span aria-hidden class="{merge("flex size-4 shrink-0 items-center justify-center rounded-full bg-muted text-3xs font-medium text-muted-foreground " + cls)}">'
            f'{login[0].upper()}</span>')

def row(key, title, glyph, tone, assignees, comments, author, time):
    status = ""
    if assignees:
        status += ('<span class="flex items-center -space-x-1">'
                   + "".join(avatar(a, "ring-1 ring-background") for a in assignees[:3]) + '</span>')
    if comments:
        status += f'<span class="inline-flex items-center gap-0.5 tabular-nums">{lucide("message-square", "size-3")}{comments}</span>'
    meta = (f'<span class="inline-flex min-w-0 items-center gap-1">{avatar(author, "size-3.5")}<span class="truncate">{author}</span></span>')
    lines = ('<span class="min-w-0 flex-1"><span class="flex min-w-0 items-center gap-1.5">'
             f'<span class="shrink-0 font-mono text-xs tabular-nums text-muted-foreground">{key}</span>'
             f'<span class="min-w-0 truncate text-sm">{title}</span>'
             + (f'<span class="ml-auto flex shrink-0 items-center gap-1.5 text-2xs">{status}</span>' if status else "")
             + '</span><span class="flex min-w-0 items-center gap-1.5 overflow-hidden text-2xs text-muted-foreground">'
             f'{meta}<span class="ml-auto shrink-0 whitespace-nowrap tabular-nums">{time}</span></span></span>')
    button = (f'<button type="button" class="{ROW}"><span class="inline-flex shrink-0">{lucide(glyph, "size-4 shrink-0 " + TONE[tone])}</span>'
              f'{lines}</button>')
    return f'<div class="flex items-center rounded-md">{button}</div>'

cases = [
    {"name": "row.open", "html": row("#42", "Sidebar badge opens the wrong panel", "circle-dot", "open", ["octo-reader", "hubot"], 3, "octo-reader", "1d ago"),
     "native": {"case": "row", "index": "0"}, "wrapperStyle": f"display:block;width:{W}px"},
    {"name": "row.completed", "html": row("#40", "Document the greet command", "circle-check", "merged", [], 0, "ghost", "7d ago"),
     "native": {"case": "row", "index": "1"}, "wrapperStyle": f"display:block;width:{W}px"},
]
spec = {"component": "issues", "source": "apps/web/src/components/issue/IssueRow.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/issues.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
