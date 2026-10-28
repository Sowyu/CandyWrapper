"""Writes design/component-reference/git.json for scripts/component-reference: the branch toolbar under the draft
composer (BranchToolbar.tsx RunContextSelector and BranchToolbarBranchSelector), the thread details card with the
run context, branch, git actions split button and Changes rows (ThreadDetailsPanel.tsx, ThreadDetailsCard.tsx,
ThreadDetailsControl.tsx, threadDetailsPanelStyles.ts, GitActionsControl.tsx), the git actions menu in its panel
form, and the commit dialog (GitActionsControl.tsx:1983-2134).

Class strings come from those files at the tag in T3_VERSION; the panel classes are read from
threadDetailsPanelStyles.ts so they stay exact. Helpers (lucide, composer control, surfaces, buttons, dialog
parts, menu rows, textarea) are reused from the run-on, overlays, popups and forms generators.
Usage: /usr/bin/python3 -I scripts/gen-git-spec.py
"""
import json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = "/Users/mrm/CandyWrapper-research/t3code/apps/web/src/components"

def load(name, until):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    return src[:src.index(until)]

g = {"__file__": os.path.join(ROOT, "scripts/gen-run-on-spec.py")}
exec(load("gen-run-on-spec.py", "ENVS = ["), g)
o = {"__file__": os.path.join(ROOT, "scripts/gen-overlays-spec.py")}
exec(load("gen-overlays-spec.py", 'specs["dialog"]'), o)
p = {"__file__": os.path.join(ROOT, "scripts/gen-popups-spec.py")}
exec(load("gen-popups-spec.py", "# Presets"), p)
forms = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
f = {}
textarea_src = forms[forms.index("# Textarea"):]
exec(textarea_src[:textarea_src.index("cases = []")], f) # only the textarea definitions, none of its writes
lucide, machine, CONTROL_XS, context_label = g["lucide"], g["machine"], g["CONTROL_XS"], g["context_label"]
SHELL, HOST, STRIP = g["SHELL"], g["HOST"], g["STRIP"]
btn, POPUP, CLOSE = o["btn"], o["POPUP"], o["CLOSE"]
MENU_POPUP, MENU_ITEM = p["MENU_POPUP"], p["MENU_ITEM"]
textarea_html = f["textarea_html"]

# EnvironmentMachineIcon.tsx:8-29 at 3814, independent of the composer's generator.
old_machine = machine
def machine(kind, cls):
    if kind == "mac-studio": return old_machine(kind, cls).replace('stroke-width="2"', 'stroke-width="1.75"')
    if kind != "mac-mini": return old_machine(kind, cls)
    return (f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" '
            f'stroke-linecap="round" stroke-linejoin="round" class="{cls}">'
            '<rect width="18" height="12" x="3" y="6" rx="2.5"/><circle cx="7.5" cy="12" r="1" fill="currentColor" stroke="none"/></svg>')

# threadDetailsPanelStyles.ts: resolve the template strings.
styles_src = subprocess.check_output(["git", "-C", os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(T3)))), "show",
    "v0.1.4-nightly.20261028.3814:apps/web/src/components/chat/threadDetailsPanelStyles.ts"], text=True)
S = {}
for name, value in re.findall(r"const (THREAD_DETAILS_\w+) =\s*([`\"].*?[`\"]);", styles_src, re.S):
    S[name] = re.sub(r"\$\{(\w+)\}", lambda m: S[m.group(1)], value[1:-1])

# ThreadDetailsControl.tsx: the panel control's base classes.
CTRL = ("relative inline-flex shrink-0 cursor-pointer items-center whitespace-nowrap border outline-none transition-[box-shadow,scale] "
        "[&:active:not([aria-haspopup])]:scale-[0.97] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 "
        "focus-visible:ring-offset-background pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 "
        "pointer-coarse:after:min-w-11 [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-4 disabled:pointer-events-none "
        "disabled:opacity-64 aria-disabled:cursor-not-allowed aria-disabled:opacity-64 [&_svg]:shrink-0")
PARTS = {"row": S["THREAD_DETAILS_PANEL_ROW_CLASS"], "select": S["THREAD_DETAILS_PANEL_SELECT_ROW_CLASS"],
         "primary": S["THREAD_DETAILS_PANEL_SPLIT_PRIMARY_CLASS"], "secondary": S["THREAD_DETAILS_PANEL_SPLIT_SECONDARY_CLASS"]}
ICON = S["THREAD_DETAILS_PANEL_ICON_CLASS"]
CHEVRON_PANEL = S["THREAD_DETAILS_PANEL_CHEVRON_CLASS"]

def control(part, children, extra=""):
    if part == "select":
        children += f'<span data-slot="select-icon">{lucide("chevron-down", CHEVRON_PANEL)}</span>'
    return f'<button type="button" class="{CTRL} {PARTS[part]} {extra}">{children}</button>'

def panel_label(text):  # ComposerContextLabel, panel mode
    return (f'<span data-composer-label class="min-w-0 flex-1 truncate text-left">'
            f'<span data-composer-label-motion class="block w-full min-w-0 truncate">{text}</span></span>')

def middle(value):  # MiddleTruncate without a split (short values)
    return f'<span class="inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap w-full"><span class="min-w-0 truncate">{value}</span></span>'

def card(machine_kind, env_label, branch, quick_label, quick_icon, plus, minus):
    run = control("select", '<span class="inline-flex shrink-0 items-center gap-0.5">'
                  f'<span class="inline-flex shrink-0">{machine(machine_kind, ICON)}</span>'
                  f'<span class="inline-flex shrink-0">{lucide("folder", ICON)}</span></span>{panel_label(env_label)}')
    branch_btn = control("select", f'{lucide("git-branch", "shrink-0 opacity-70 size-4 text-muted-foreground")}{panel_label(middle(branch))}',
                         "min-w-0 max-w-full active:scale-100")
    split = (f'<div role="group" aria-label="Git actions" class="shrink-0 {S["THREAD_DETAILS_PANEL_SPLIT_GROUP_CLASS"]}">'
             + control("primary", f'{lucide(quick_icon, ICON)}<span class="not-sr-only ml-0 truncate">{quick_label}</span>')
             + f'<span aria-hidden="true" class="{S["THREAD_DETAILS_PANEL_SPLIT_SEPARATOR_CLASS"]}"></span>'
             + control("secondary", lucide("chevron-down", CHEVRON_PANEL)) + '</div>')
    changes = control("row", f'{lucide("file-diff", ICON)}<span class="flex-1 text-left">Changes</span>'
                      f'<span class="flex items-center gap-1 font-mono text-2xs tabular-nums"><span class="text-success">+{plus}</span>'
                      f'<span class="text-destructive">-{minus}</span></span>')
    section = "px-2 pt-2 pb-2.5"
    return ('<div class="dropdown-glass isolate contain-paint grid max-h-full grid-rows-[minmax(0,1fr)] overflow-hidden rounded-3xl" '
            'style="width:264px"><div><div>'
            f'<section class="{section}"><div class="flex flex-col"><div class="flex w-full flex-col">{run}</div></div></section>'
            f'<section class="{section} border-t border-border/65"><div class="flex flex-col">'
            f'<div class="flex w-full flex-col"><div class="flex min-w-0 w-full flex-col items-stretch"><span class="flex min-w-0">{branch_btn}</span></div></div>'
            f'{split}{changes}</div></section></div></div></div>')

def toolbar_trigger(icon_html, label, extra):
    plain_chevron = lucide("chevron-down", "size-3 shrink-0 opacity-50")
    return f'<button type="button" class="{CONTROL_XS.replace(" min-w-0 max-w-full", "")} {extra}">{icon_html}{context_label(label)}{plain_chevron}</button>'

def strip(workspace, folder, branch):
    run = toolbar_trigger(f'<span class="inline-flex shrink-0">{lucide(folder, "size-3 shrink-0")}</span>', workspace,
                          "min-w-0 max-w-[48%] flex-initial justify-start")
    br = toolbar_trigger(lucide("git-branch", "size-3 shrink-0 opacity-70"), middle(branch), "min-w-0 max-w-full active:scale-100")
    return (f'<div data-slot="composer-shell" data-with-context="true" class="{SHELL}" style="width:600px">'
            f'<div data-slot="composer-host" class="{HOST}"><div class="relative z-10" style="height:64px"></div></div>'
            '<div class="min-h-0"><div class="relative z-0"><div class="pointer-events-auto">'
            f'<div data-slot="composer-context-strip" class="{STRIP}">{run}'
            '<div class="flex min-w-0 flex-1 items-center justify-start overflow-x-clip overflow-y-visible"></div>'
            f'<div class="flex min-w-0 items-center gap-1 min-w-0 flex-initial justify-end"><span class="flex min-w-0">{br}</span></div>'
            '</div></div></div></div></div>')

DIS = ' data-disabled=""'

def git_menu(items, width):
    rows = "".join(
        f'<div role="menuitem" class="{MENU_ITEM}" data-density="default" data-slot="menu-item" data-variant="default"{DIS if dis else ""}>'
        f'{lucide(ic, "")}<span data-slot="menu-item-label" class="min-w-0 truncate">{title}</span></div>'
        for title, ic, dis in items)
    return (f'<div role="menu" class="{MENU_POPUP} w-(--anchor-width)" data-slot="menu-popup" data-side="bottom" style="--anchor-width:{width}px">'
            f'<div class="max-h-(--available-height) w-full overflow-y-auto p-1">{rows}</div></div>')

FILES = [("Sources/App/main.swift", 4, 0), ("README.md", 12, 3)]

def commit_dialog(branch, default_branch):
    file_rows = "".join(
        '<div class="flex w-full items-center gap-2 rounded-md px-2 py-1 font-mono hover:bg-accent/50">'
        '<button type="button" class="flex min-w-0 flex-1 items-center justify-between gap-3 text-left">'
        f'<span class="min-w-0 overflow-hidden text-ellipsis whitespace-nowrap text-left flex-1" dir="rtl"><bdi>{path}</bdi></span>'
        f'<span class="shrink-0"><span class="text-diff-addition">+{ins}</span><span class="text-muted-foreground"> / </span>'
        f'<span class="text-diff-deletion">-{dels}</span></span></button></div>'
        for path, ins, dels in FILES)
    ins, dels = sum(x[1] for x in FILES), sum(x[2] for x in FILES)
    warn = '<span class="text-right text-warning">Default branch</span>' if default_branch else ""
    summary = ('<div class="space-y-3 rounded-xl bg-zinc-25 p-3 text-sm ring-1 ring-black/5 dark:bg-white/[0.035] dark:ring-white/5">'
               '<div class="grid grid-cols-[auto_1fr] items-center gap-x-2 gap-y-1"><span class="text-muted-foreground">Branch</span>'
               f'<span class="flex items-center justify-between gap-2"><span class="font-medium">{branch}</span>{warn}</span></div>'
               '<div class="space-y-1"><div class="flex items-center justify-between"><div class="flex items-center gap-2">'
               f'<span class="text-muted-foreground">Files</span></div>{btn("ghost", "xs", "Edit")}</div>'
               '<div class="space-y-2"><div class="h-44 rounded-lg bg-card ring-1 ring-black/5 dark:bg-white/[0.025] dark:ring-white/5">'
               f'<div><div class="space-y-1 p-1">{file_rows}</div></div></div>'
               f'<div class="flex justify-end font-mono"><span class="text-diff-addition">+{ins}</span><span class="text-muted-foreground"> / </span>'
               f'<span class="text-diff-deletion">-{dels}</span></div></div></div></div>')
    message = ('<div class="space-y-1"><p class="text-sm font-medium">Commit message (optional)</p>'
               f'{textarea_html("sm", placeholder="Leave empty to auto-generate")}</div>')
    header = ('<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
              '<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">Commit changes</h2>'
              '<p class="text-muted-foreground text-sm" data-slot="dialog-description">Review and confirm your commit. Leave the message blank to auto-generate one.</p></div>')
    panel = ('<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 '
             'in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">'
             f'{summary}{message}</div>')
    footer = ('<div class="flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)] py-4" data-slot="dialog-footer">'
              f'{btn("outline", "sm", "Cancel")}{btn("outline", "sm", "Commit on new branch")}{btn("default", "sm", "Commit")}</div>')
    return f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">{header}{panel}{footer}{CLOSE}</div>'

cases = [
    {"name": "strip.checkout", "html": strip("Current checkout", "folder", "main"),
     "native": {"kind": "strip", "workspace": "Current checkout", "folder": "folder", "branch": "main"}},
    {"name": "strip.worktree", "html": strip("New worktree", "folder-git-2", "From main"),
     "native": {"kind": "strip", "workspace": "New worktree", "folder": "folderGit2", "branch": "From main"}},
    {"name": "card.commit", "html": card("mac-mini", "This Mac", "main", "Commit", "git-commit-horizontal", 4, 0),
     "native": {"kind": "card", "env": "This Mac", "branch": "main", "quick": "Commit", "icon": "gitCommitHorizontal", "plus": "4", "minus": "0"}},
    {"name": "card.push", "html": card("mac-mini", "This Mac", "feature/demo", "Push", "cloud-upload", 12, 3),
     "native": {"kind": "card", "env": "This Mac", "branch": "feature/demo", "quick": "Push", "icon": "cloudUpload", "plus": "12", "minus": "3"}},
    {"name": "menu.publish", "html": git_menu([("Commit", "git-commit-horizontal", False), ("Publish repository...", "cloud-upload", False)], 248),
     "wrapperStyle": "display:inline-block;--available-height:600px", "native": {"kind": "menu", "variant": "publish"}},
    {"name": "menu.remote", "html": git_menu([("Commit", "git-commit-horizontal", True), ("Push", "cloud-upload", False)], 248),
     "wrapperStyle": "display:inline-block;--available-height:600px", "native": {"kind": "menu", "variant": "remote"}},
    {"name": "dialog.commit", "html": commit_dialog("main", True), "wrapperStyle": "display:grid;width:512px",
     "native": {"kind": "dialog", "branch": "main", "default": "true"}},
]
spec = {"component": "git", "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/git.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
