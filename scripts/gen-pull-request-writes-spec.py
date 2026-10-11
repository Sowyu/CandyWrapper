"""Writes design/component-reference/pull-request-writes.json for scripts/component-reference: WP7.5c's
pull request popups. The checks popover (PullRequestChecksPopover.tsx:200-216 with ChecksBody, lines
74-122), the composer in review mode (PullRequestComposer.tsx:102-186 with PullRequestReviewForm.tsx:
124-174) and a Markdown pull request link's preview card (PullRequestLinkPreview.tsx:117-149 on
ui/preview-card.tsx). Class strings are copied from those files at the tag in T3_VERSION; popover, select,
textarea, toggle, button and lucide helpers come from the popups, forms, toggles, overlays and run-on
generators. Data matches fixtures/pull-requests (relative times at 2026-10-10T16:00Z).
Usage: /usr/bin/python3 -I scripts/gen-pull-request-writes-spec.py
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
t = {}
exec(load("gen-toggles-spec.py", "cases = []"), t)
p = {"__file__": os.path.join(ROOT, "scripts/gen-popups-spec.py")}
exec(load("gen-popups-spec.py", "# Tooltip (tooltip.tsx"), p)
forms = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
f = {}
src = forms[forms.index("# Textarea"):] if "# Textarea" in forms else forms[forms.index("TA_WRAP ="):]
exec(src[:src.index("cases = []")], f)
lucide, merge, BASE, VARIANTS, SIZES = g["lucide"], o["merge"], o["BASE"], o["VARIANTS"], o["SIZES"]
P_BASE, P_VIEWPORT, P_PAD = p["P_BASE"], p["P_VIEWPORT"], p["P_PAD"]
S_BASE, S_VARIANT = p["S_BASE"], p["S_VARIANT"]
textarea_html = f["textarea_html"]

def button(variant, size, inner, cls=""):
    return f'<button type="button" data-slot="button" class="{merge(BASE + " " + VARIANTS[variant] + " " + SIZES[size] + " " + cls)}">{inner}</button>'

def popover(width, inner, side="bottom"):
    w = {"md": "w-80 max-w-[calc(100vw-2rem)]", "lg": "w-96 max-w-[calc(100vw-2rem)]"}[width]
    return (f'<div class="{P_BASE} {w}" data-slot="popover-popup" data-side="{side}"><div class="{P_VIEWPORT} {P_PAD["default"]} '
            f'not-data-transitioning:overflow-y-auto" data-slot="popover-viewport">{inner}</div></div>')

OPEN = "text-emerald-600 dark:text-emerald-300/90"
# CHECK_STATUS_PRESENTATION (pullRequestPresentation.tsx): failure, success, skipped.
STATUS = {"failure": ("circle-x", "text-destructive", "Failed"), "success": ("circle-check", OPEN, "Passed"),
          "skipped": ("circle-dashed", "text-muted-foreground/70", "Skipped")}

def check_row(name, status, details):
    ic, tone, label = STATUS[status]
    link = '<button type="button" class="shrink-0 text-primary hover:underline">Details</button>' if details else ""
    return (f'<li class="flex items-center gap-2 text-xs">{lucide(ic, "size-3.5 shrink-0 " + tone)}'
            f'<span class="min-w-0 flex-1 truncate">{name}</span><span class="shrink-0 text-muted-foreground">{label}</span>{link}</li>')

# Failing: one failure needs attention and two completed ones fold behind "Show all".
checks_html = popover("md", (
    '<p class="mb-2 font-medium text-sm">Some checks were not successful</p>'
    '<p class="mb-2 text-muted-foreground text-xs">1 of 3 failing</p>'
    '<div class="max-h-64 overflow-hidden"><ul class="flex flex-col gap-1">'
    + check_row("Typecheck", "failure", True) + '</ul></div>'
    + button("ghost", "xs", "Show all")))

# The composer in review mode with a summary typed, Comment verdict selected.
G_CLS = ("flex w-fit *:focus-visible:z-10 gap-0.5 rounded-lg bg-input/40 p-0.5")
toggles = "".join(t["toggle"]("segmented", "segmented", label, i == 1, icon=False) for i, label in enumerate(["Comment", "Review"]))
close = button("ghost", "icon-xs", lucide("x", "size-3.5"))
# `className="w-auto min-w-0"` replaces the variant's `w-full min-w-36` (tailwind-merge in `cn`).
SELECT_XS = ("h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-sm before:rounded-[calc(var(--radius-md)-1px)] sm:h-6 sm:text-xs "
             "[&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5")
select = (f'<button type="button" class="{S_BASE + " " + S_VARIANT["default"].replace("w-full min-w-36 ", "") + " " + SELECT_XS + " w-auto min-w-0"}" data-slot="select-trigger">'
          f'<span class="flex-1 truncate" data-slot="select-value"><span class="flex items-center gap-1.5">{lucide("message-square", "size-3")}Comment</span></span>'
          f'<span data-slot="select-icon" class="flex">{lucide("chevron-down", "-me-1 size-3 opacity-50")}</span></button>')
review_html = popover("lg", (
    f'<div class="mb-3 flex items-center justify-between gap-2"><div data-slot="toggle-group" role="group" class="{G_CLS}">{toggles}</div>'
    f'<div class="flex items-center gap-1">{close}</div></div>'
    f'<div>{textarea_html(value="Looks good overall, two nits inline.")}'
    f'<div class="mt-2 flex justify-between gap-2">{select}{button("default", "xs", "Submit review")}</div></div>'), side="top")

# The preview card for https://github.com/pingdotgg/t3code/pull/2861 (open).
PREVIEW_POPUP = ("origin-(--transform-origin) rounded-lg border bg-popover text-popover-foreground shadow-lg outline-none "
                 "w-80 max-w-[calc(100vw-2rem)]")
avatar = ('<span aria-hidden class="flex size-4 shrink-0 items-center justify-center rounded-full bg-muted text-3xs font-medium '
          'text-muted-foreground">O</span>')
preview_html = (f'<div class="{PREVIEW_POPUP}" data-slot="preview-card-popup"><div class="p-3"><div class="min-w-0">'
                '<div class="flex min-w-0 items-center gap-1.5 text-2xs text-muted-foreground"><span class="min-w-0 truncate">pingdotgg/t3code</span>'
                '<span class="shrink-0">#2861</span><span aria-hidden>·</span><span class="inline-flex shrink-0 items-center gap-1">'
                f'{lucide("git-pull-request-arrow", "size-3 " + OPEN)}Open</span></div>'
                '<p class="mt-1 text-sm font-medium leading-snug text-foreground text-pretty">Add the pull requests page</p>'
                f'<div class="mt-2 flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">{avatar}'
                '<span class="min-w-0 truncate">The Octocat (@octocat)</span><span aria-hidden>·</span>'
                '<span class="shrink-0">opened 39d ago</span></div></div></div></div>')

cases = [
    {"name": "checks-popover", "html": checks_html, "native": {"case": "checks-popover"}, "wrapperStyle": "display:inline-block;--available-height:600px"},
    {"name": "review-form", "html": review_html, "native": {"case": "review-form"}, "wrapperStyle": "display:inline-block;--available-height:600px"},
    {"name": "link-preview", "html": preview_html, "native": {"case": "link-preview"}, "wrapperStyle": "display:inline-block"},
]
spec = {"component": "pull-request-writes", "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/pull-request-writes.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
