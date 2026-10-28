"""Writes design/component-reference/{thread-lineage,subagent-bar,secret-request}.json for scripts/component-reference:
the thread details card's Lineage section (ThreadRelationshipsControl.tsx:82-579, ThreadRelationshipIcon.tsx,
ThreadDetailsSection.tsx, collapsible-section-header.tsx), the provider subagent bar (ProviderSubagentBar.tsx:55-91)
and the secret request card (SecretRequestCard.tsx:28-179, WorkLog.tsx:46-116).

Panel classes come from threadDetailsPanelStyles.ts through the git generator; buttons, inputs and lucide icons
from the overlays, forms and run-on generators. Subagent rows here have no provider glyph (no subagent record),
so they draw the bot fallback, as T3 does for a child without one.
Usage: /usr/bin/python3 -I scripts/gen-thread-lineage-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-git-spec.py")}
exec(load("gen-git-spec.py", "def panel_label"), g)
forms = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
f = {}
input_src = forms[forms.index("# Input (input.tsx)"):]
exec(input_src[:input_src.index("W240 =")], f)
lucide, S, CTRL, btn = g["lucide"], g["S"], g["CTRL"], g["btn"]
input_html = f["input_html"]

# MARK: Lineage

DOTS = {"info": "bg-info", "destructive": "bg-destructive", "success": "bg-success", "muted": "bg-muted-foreground/45"}

def rel_icon(icon, dot):
    return (f'<span class="relative inline-flex size-4 shrink-0 items-center justify-center">{lucide(icon, "size-4 shrink-0 text-muted-foreground")}'
            f'<span class="absolute -bottom-1 -right-1 size-2 rounded-full border-2 border-card {DOTS[dot]}" aria-hidden="true"></span></span>')

def content(icon, dot, title, trailing=None, failed=False):
    html = rel_icon(icon, dot)
    html += f'<span class="min-w-0 flex-1"><span class="block truncate text-left text-sm font-medium leading-4 text-foreground/85">{title}</span></span>'
    html += lucide("arrow-right", "size-3 shrink-0 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100")
    if trailing:
        html += f'<span class="shrink-0 text-2xs {"text-destructive" if failed else "text-muted-foreground"}">{trailing}</span>'
    return html

def row(icon, dot, title, status, failed=False):
    return (f'<li class="group relative flex h-8 items-center rounded-lg">'
            f'<button type="button" class="{CTRL} {S["THREAD_DETAILS_PANEL_ROW_CLASS"]}">{content(icon, dot, title, status, failed)}</button></li>')

def merge_row(title, status, enabled):
    secondary = (f'<button type="button" class="{CTRL} {S["THREAD_DETAILS_PANEL_SPLIT_SECONDARY_CLASS"]}"{"" if enabled else " disabled"}>'
                 f'{lucide("git-merge", "size-3")}</button>')
    return (f'<li class="group relative flex h-8 items-center rounded-lg"><div class="{S["THREAD_DETAILS_PANEL_SPLIT_GROUP_CLASS"]}">'
            f'<button type="button" class="{CTRL} {S["THREAD_DETAILS_PANEL_SPLIT_PRIMARY_CLASS"]}">{content("corner-left-up", "success", title)}</button>'
            f'<span aria-hidden="true" class="{S["THREAD_DETAILS_PANEL_SPLIT_SEPARATOR_CLASS"]}"></span>{secondary}'
            f'<span class="shrink-0 border border-transparent ps-1 pe-2.5 text-2xs font-medium text-muted-foreground">{status}</span></div></li>')

def rows(items, hidden=0):
    more = ""
    if hidden:
        more = (f'<button type="button" class="flex h-8 w-full cursor-pointer items-center rounded-lg {S["THREAD_DETAILS_PANEL_ROW_CONTENT_CLASS"]} '
                f'text-sm font-medium text-muted-foreground/70 hover:bg-black/[0.055] hover:text-foreground/80 dark:hover:bg-white/[0.075]">'
                f'{lucide("plus", "size-4 shrink-0")}Show {min(hidden, 12)} more</button>')
    return f'<ul aria-label="Related threads" class="m-0 max-h-[13.5rem] list-none overflow-y-auto overscroll-contain p-0">{"".join(items)}</ul>{more}'

def previous(count, failed, expanded=False):
    accessory = f'<span class="shrink-0 text-3xs leading-none text-destructive-foreground">{failed} failed</span>' if failed else ""
    total = f'<span class="shrink-0 text-xs font-normal tabular-nums text-muted-foreground">{count}</span>' if not expanded else ""
    return (f'<div><button type="button" aria-expanded="{str(expanded).lower()}" class="{CTRL} {S["THREAD_DETAILS_PANEL_ROW_CLASS"]}">'
            + lucide("bot", S["THREAD_DETAILS_PANEL_ICON_CLASS"])
            + f'<span class="{S["THREAD_DETAILS_PANEL_LABEL_CLASS"]} min-w-0 flex-1 truncate">Previous agents</span>'
            + accessory + total + lucide("chevron-down", S["THREAD_DETAILS_PANEL_CHEVRON_CLASS"] + (" -rotate-90" if not expanded else ""))
            + '</button></div>')

def section(title, body, menu):
    actions = ""
    if menu:
        actions = (f'<div class="flex shrink-0 items-center gap-1"><button type="button" aria-label="More thread actions" '
                   f'class="{CTRL} {S["THREAD_DETAILS_PANEL_ICON_ACTION_CLASS"]}">{lucide("ellipsis", "size-3.5")}</button></div>')
    return (f'<section data-thread-relationships-panel class="px-2 pt-2 pb-2.5 border-t border-border/65">'
            f'<div class="mb-1 flex min-h-8 min-w-0 items-center justify-between gap-2 px-2.5">'
            f'<h3 class="min-w-0 truncate text-2xs font-medium text-muted-foreground select-none">{title}</h3>{actions}</div>{body}</section>')

# Each case: html, and the native description the test builds `ThreadRelationships.Lineage` from.
LINEAGE = [
    ("agents", "Lineage · 1 running", True,
     f'<div>{rows([row("corner-left-up", "info", "Plan the migration", "Running")])}</div>'
     f'<div>{rows([row("bot", "info", "Audit the schema", "Running"), row("bot", "info", "Draft the rollout notes", "Queued")])}</div>'
     + previous(2, 1),
     {"related": [["parent", "running", "Plan the migration"]],
      "active": [["subagent", "running", "Audit the schema"], ["subagent", "pending", "Draft the rollout notes"]],
      "previous": [["subagent", "completed", "Count the rows"], ["subagent", "failed", "Check the indexes"]],
      "canDetach": True, "running": 1}),
    ("forks", "Lineage", False,
     f'<div>{rows([merge_row("Fix the login form", "Done", True), row("git-fork", "success", "Try a second layout", "Done")])}</div>',
     {"related": [["merge", "completed", "Fix the login form"], ["fork", "completed", "Try a second layout"]], "mergeRun": True}),
    ("expanded", "Lineage", False, "",  # built by expanded_body()
     {"previous": [["subagent", "completed", "Count the rows"], ["subagent", "failed", "Check the indexes"]], "expandPrevious": True}),
    ("paged", "Lineage", False,
     f'<div>{rows([row("git-fork", "muted", f"Fork {i}", "Idle") for i in range(1, 7)], hidden=2)}</div>',
     {"related": [["fork", "idle", f"Fork {i}"] for i in range(1, 9)]}),
]

def expanded_body():
    head = previous(2, 1, expanded=True)
    inner = rows([row("bot", "success", "Count the rows", "Done"), row("bot", "destructive", "Check the indexes", "Failed", failed=True)])
    # The group's div holds the header button, then the list.
    return head[:-len("</div>")] + inner + "</div>"

lineage_cases = []
for name, title, menu, body, native in LINEAGE:
    if name == "expanded":
        body = expanded_body()
    lineage_cases.append({"name": name, "html": section(title, body, menu), "wrapperStyle": "display:block;width:262px", "native": native})

# MARK: Subagent bar

def bar(model, effort, status, parent):
    cluster = f'<span class="min-w-0 truncate font-medium text-foreground">{model}</span>'
    if effort:
        cluster += f'<span class="shrink-0 text-muted-foreground">{effort}</span>'
    open_parent = btn("ghost", "sm", lucide("arrow-up-left", "") + "Open parent") if parent else ""
    return (f'<div class="flex min-h-12 items-center gap-3 rounded-2xl py-2 ps-5 pe-2 text-sm">'
            f'<span class="flex min-w-0 items-center gap-2">{cluster}</span>'
            f'<span aria-hidden="true" class="min-w-0 truncate text-muted-foreground tabular-nums">{status}</span>'
            f'<span class="ms-auto shrink-0 text-muted-foreground max-sm:hidden">Runs on its own</span>{open_parent}</div>')

BAR = [
    ("completed", "Claude Haiku 4.5", "High", "Completed in 34s", True, {"status": "completed", "startedAt": "2026-10-11T10:00:00.000Z", "completedAt": "2026-10-11T10:00:34.000Z"}),
    ("failed", "Claude Sonnet 4.5", None, "Failed", True, {"status": "failed"}),
    ("starting", "GPT-5.4 Mini", None, "Starting", False, {}),
]
bar_cases = [{"name": name, "html": bar(model, effort, status, parent), "wrapperStyle": "display:block;width:640px",
              "native": {"model": model, "effort": effort or "", "parent": "yes" if parent else "", **st}}
             for name, model, effort, status, parent, st in BAR]

# MARK: Secret request

def secret_form(label, reason, error):
    field = input_html(placeholder="Paste the secret").replace('data-slot="input" type="text"', 'data-slot="input" type="text" style="-webkit-text-security:disc"')
    save = btn("default", "default", "Save securely").replace('<button type="button"', '<button type="submit" disabled', 1)
    why = f'<p class="text-sm text-muted-foreground">{reason}</p>' if reason else ""
    err = f'<p role="alert" class="text-xs text-destructive">{error}</p>' if error else ""
    return (f'<form class="flex min-w-0 flex-col gap-3 rounded-xl border border-border/60 bg-card p-4">'
            f'<div class="flex min-w-0 flex-col gap-1"><label class="text-sm font-medium text-foreground">{label}</label>{why}</div>'
            f'<div class="flex min-w-0 items-center gap-2"><div class="min-w-0 flex-1">{field}</div>{save}</div>{err}'
            f'<div class="flex min-w-0 items-center justify-between gap-2"><p class="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">'
            f'{lucide("shield-check", "size-3.5 shrink-0")}Stored securely, never shown to the agent</p>{btn("ghost-muted", "xs", "Decline")}</div></form>')

def secret_line(icon, text):
    return ('<div class="group/timeline-row relative w-full min-w-0 rounded-md px-0.5 text-left transition-colors py-0.5">'
            '<div class="flex min-h-6 min-w-0 gap-1.5 text-sm leading-relaxed select-none items-center">'
            f'<span class="relative flex size-6 shrink-0 items-center justify-center">{lucide(icon, "size-3.5 text-icon-muted")}</span>'
            f'<div class="min-w-0 flex-1 text-secondary-label truncate">{text}</div></div></div>')

SECRET = [
    ("pending", secret_form("STAGING_API_KEY", "Needed to call the staging API for the smoke test.", None),
     {"label": "STAGING_API_KEY", "reason": "Needed to call the staging API for the smoke test.", "status": "pending", "visibility": "local"}),
    ("no-reason-error", secret_form("NPM_TOKEN", None, "Could not answer the request. Try again."),
     {"label": "NPM_TOKEN", "reason": "", "status": "pending", "visibility": "local", "error": "Could not answer the request. Try again."}),
    ("saved", secret_line("check", "STAGING_API_KEY · Saved securely and kept private"),
     {"label": "STAGING_API_KEY", "status": "saved", "visibility": "local"}),
    ("elsewhere", secret_line("lock", "STAGING_API_KEY · Waiting for an answer in the original thread"),
     {"label": "STAGING_API_KEY", "status": "pending", "visibility": "inherited"}),
]
secret_cases = [{"name": name, "html": html, "wrapperStyle": "display:block;width:520px", "native": native} for name, html, native in SECRET]

SPECS = [
    {"component": "thread-lineage", "source": "apps/web/src/components/chat/ThreadRelationshipsControl.tsx", "cases": lineage_cases},
    {"component": "subagent-bar", "source": "apps/web/src/components/chat/ProviderSubagentBar.tsx", "cases": bar_cases},
    {"component": "secret-request", "source": "apps/web/src/components/chat/SecretRequestCard.tsx", "cases": secret_cases},
]
for spec in SPECS:
    spec.update({"states": ["rest"], "themes": ["light", "dark"]})
    with open(os.path.join(ROOT, f"design/component-reference/{spec['component']}.json"), "w") as out:
        json.dump(spec, out, indent=1, ensure_ascii=False)
    print(spec["component"], len(spec["cases"]), "cases")
