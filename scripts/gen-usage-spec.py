"""Writes design/component-reference/usage.json for scripts/component-reference: the WP7.7c surfaces.
The Usage page header at xl (UsagePage.tsx:368-470, WorkspaceBreadcrumb.tsx, ui/button.tsx InlineButton,
ui/toggle-group.tsx), one cost chart (UsageProviderChart.tsx, its paths computed by the same monotone curve),
the /usage-limits banner (ComposerUsageLimits.tsx, ComposerBanner.tsx, UsageLimits.tsx LimitWindows), the
Scheduled Tasks list (ScheduledTasksSettings.tsx:243-460, settingsLayout.tsx) and the editor's schedule rows
(ScheduledTasksSettings.tsx:1155-1325).

Class strings are copied from those files at the tag in T3_VERSION; buttons, rows, switches, badges and
inputs come from gen-settings-pages2-spec.py, gen-toggles-spec.py and gen-composer-attachments-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-usage-spec.py
"""
import json, math, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(script, stop):
    ns = {"__file__": os.path.join(ROOT, "scripts", script)}
    src = open(os.path.join(ROOT, "scripts", script)).read()
    exec(src[:src.index(stop)], ns)
    return ns


pages = load("gen-settings-pages2-spec.py", "# --- Project: the overview card")
tog = load("gen-toggles-spec.py", "# 3. Switch")
ban = load("gen-composer-attachments-spec.py", "menu = stash_menu(")
lucide, button, row, switch, GROUP, merge = pages["lucide"], pages["button"], pages["row"], pages["switch"], pages["GROUP"], pages["merge"]
form_ns = pages["form_ns"]
toggle = tog["toggle"]


def group(variant, items, pressed, disabled=False):
    cls = f'{tog["G_ALWAYS"]} {tog["G_VARIANT"][variant]}'
    html = "".join(toggle(variant, "segmented", t, i == pressed, icon=False) for i, t in enumerate(items))
    if disabled:
        html = html.replace("<button ", "<button disabled ")
    return f'<div data-slot="toggle-group" data-variant="{variant}" role="group" class="{cls}">{html}</div>'


# --- 1. The header at xl (no window label below 2xl).
INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline text-foreground min-w-0 max-w-full")
CHEV = lucide("chevron-down", "size-3.5 opacity-0")
crumb_env = f'<button type="button" class="{INLINE}"><span class="min-w-0 truncate">All environments</span><span class="flex size-3.5 shrink-0 items-center justify-center text-muted-foreground">{CHEV}</span></button>'
crumb_prov = f'<button type="button" class="{INLINE}"><span class="min-w-0 truncate">All providers</span>{lucide("chevron-down", "size-3.5 shrink-0 text-muted-foreground opacity-0")}</button>'
SEP = '<li aria-hidden="true" class="flex shrink-0 items-center text-icon-muted">/</li>'
header = ('<header class="flex shrink-0 items-center gap-3 px-5" style="height:52px"><div class="flex w-full min-w-0 items-center gap-x-3 py-2">'
          '<nav class="min-w-0"><ol class="m-0 flex min-w-0 list-none items-center gap-3 p-0 text-sm">'
          '<li class="flex min-w-0 items-center font-medium shrink-0 text-muted-foreground"><h1>Usage</h1></li>' + SEP
          + f'<li class="flex items-center font-medium shrink-0 text-muted-foreground min-w-10">{crumb_env}</li>' + SEP
          + f'<li class="flex items-center font-medium text-foreground min-w-10">{crumb_prov}</li></ol></nav>'
          '<div class="ms-auto flex min-w-0 items-center justify-end gap-2">'
          + group("segmented", ["Cost", "Tokens", "Limits"], 2)
          + group("segmented", ["Past 24h", "7 days", "30 days", "90 days"], 2, disabled=True)
          + button("ghost", "icon-sm", lucide("refresh-cw", "size-3.5"))
          + '</div></div></header>')

# --- 2. A 7-day cost chart (UsageProviderChart.tsx), paths from the ported maths.
DAYS = ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10"]
SERIES = {"codex": [0, 1.2, 3.5, 2, 0, 4.1, 2.2], "claude": [2, 2.5, 1, 0.5, 3, 3.2, 1.8]}
COLORS = {"codex": "var(--contrast-foreground)", "claude": "#d97757"}
VW, VH, TOP = 960, 260, 8


def nice(peak, count=4):
    raw = peak / count
    mag = 10 ** math.floor(math.log10(raw))
    n = raw / mag
    step = (10 if n > 5 else 5 if n > 2 else 2 if n > 1 else 1) * mag
    mx = math.ceil(peak / step) * step
    ticks, v = [], 0.0
    while v <= mx + step * 1e-6:
        ticks.append(v)
        v += step
    return mx, ticks


def y_of(v, mx):
    return VH if mx == 0 else VH - (v / mx) * (VH - TOP)


def tangents(p):
    n = len(p)
    s = [(p[i + 1][1] - p[i][1]) / (p[i + 1][0] - p[i][0]) for i in range(n - 1)]
    t = [0.0] * n
    t[0], t[-1] = s[0], s[-1]
    for i in range(1, n - 1):
        t[i] = 0 if s[i - 1] * s[i] <= 0 else (s[i - 1] + s[i]) / 2
    for i in range(n - 1):
        if s[i] == 0:
            t[i] = t[i + 1] = 0
            continue
        a, b = t[i] / s[i], t[i + 1] / s[i]
        m = a * a + b * b
        if m > 9:
            k = 3 / math.sqrt(m)
            t[i], t[i + 1] = k * a * s[i], k * b * s[i]
    return t


def path(points):
    t = tangents(points)
    d = f"M{points[0][0]:.2f},{points[0][1]:.2f}"
    for i in range(len(points) - 1):
        (x0, y0), (x1, y1) = points[i], points[i + 1]
        dx = x1 - x0
        d += f" C{x0 + dx / 3:.2f},{y0 + t[i] * dx / 3:.2f} {x1 - dx / 3:.2f},{y1 - t[i + 1] * dx / 3:.2f} {x1:.2f},{y1:.2f}"
    return d


peak = max(max(v) for v in SERIES.values())
MX, TICKS = nice(peak)
step = VW / (len(DAYS) - 1)
paths = []
for p in ("codex", "claude"):
    line = path([(i * step, y_of(v, MX)) for i, v in enumerate(SERIES[p])])
    paths.append((p, sum(SERIES[p]), line))
paths.sort(key=lambda e: -e[1])
grid = "".join(f'<line x1="0" x2="{VW}" y1="{y_of(t, MX)}" y2="{y_of(t, MX)}" stroke="currentColor" stroke-width="1" class="text-border" vector-effect="non-scaling-stroke"></line>' for t in TICKS)
fills = "".join(f'<path d="{d} L{VW},{VH} L0,{VH} Z" fill="{COLORS[p]}" fill-opacity="0.12"></path>' for p, _, d in paths)
strokes = "".join(f'<path d="{d}" fill="none" stroke="{COLORS[p]}" stroke-width="2" vector-effect="non-scaling-stroke"></path>' for p, _, d in paths)
usd = lambda v: "${:,.2f}".format(v)
ylabels = "".join(f'<span class="absolute right-0 -translate-y-1/2 text-3xs text-muted-foreground tabular-nums" style="top: {y_of(t, MX) / VH * 100}%">{"0" if t == 0 else usd(t)}</span>' for t in TICKS)
chart = ('<div class="flex flex-col gap-1"><div class="flex gap-2">'
         f'<div class="relative h-56 w-14 shrink-0">{ylabels}</div>'
         f'<div class="relative h-56 flex-1"><svg class="h-full w-full" viewBox="0 0 {VW} {VH}" preserveAspectRatio="none">{grid}{fills}{strokes}</svg></div></div>'
         '<div class="flex justify-between pl-16 text-3xs text-muted-foreground uppercase"><span>Oct 4</span><span>Oct 7</span><span>Oct 10</span></div></div>')

# --- 3. The /usage-limits banner: one Codex account, a 5-hour and a weekly window.
def window_row(label, left, time_left, icon, resets):
    bar = ('<div class="relative h-6 cursor-default rounded-full"><div class="absolute inset-x-0 inset-y-1.5 rounded-full bg-muted"></div>'
           f'<div class="absolute inset-y-1.5 left-0 rounded-full" style="width: {left}%; background-color: var(--contrast-foreground)"></div>'
           f'<span class="absolute inset-y-0.5 w-px -translate-x-1/2 bg-foreground/60" style="left: {time_left}%"></span></div>')
    return (f'<span class="flex min-w-0 items-center gap-2 text-xs"><span class="truncate text-muted-foreground">{label}</span>'
            f'<span class="ms-auto shrink-0 font-medium text-foreground tabular-nums">{left}% left</span></span>{bar}'
            '<span class="flex items-center gap-2 text-xs whitespace-nowrap text-muted-foreground tabular-nums">'
            f'<span class="inline-flex text-muted-foreground">{ban["lucide"](icon, "size-3.5")}</span><span class="ms-auto shrink-0">{resets}</span></span>')


windows = ('<div class="grid grid-cols-[minmax(0,9rem)_minmax(3rem,1fr)_auto] gap-x-3 gap-y-0.5">'
           + window_row("5h limit", 63, 44, "trending-down", "resets in 2h 13m") + window_row("Weekly limit", 38, 45, "trending-up", "resets in 3d 4h") + "</div>")
B = ban
banner = (f'<div role="alert" class="{B["SURFACE"]} {B["ROOT_CLS"]} [--composer-banner-padding-block:--spacing(1.25)] @container">'
          f'<div data-composer-banner-row="true" class="{B["ROW"]}"><span class="{B["ICON"]} h-(--composer-banner-icon-column) self-start">{B["lucide"]("gauge")}</span>'
          f'<span class="{B["CONTENT"]} whitespace-nowrap"><span class="min-w-0 truncate font-medium leading-7 sm:leading-6">Usage limits</span>'
          '<span class="flex min-w-8 flex-1 items-center gap-1"><span class="min-w-0 truncate text-muted-foreground">Codex · ChatGPT Pro</span></span></span>'
          f'<span class="{B["ACTIONS"]}">{B["dismiss"]()}</span></div>'
          '<div class="grid gap-px [&_[data-composer-banner-row]]:min-h-5"><div class="relative h-auto max-h-[384px] overflow-hidden"><div>'
          f'<div class="min-w-0 ps-8 sm:ps-7 flex flex-col gap-2 pt-1 pb-1.5 pe-2"><div class="flex min-w-0 flex-col gap-1">{windows}</div></div>'
          '</div></div></div></div>')

# --- 4. Settings > Scheduled Tasks with one environment: the plain section and its card of two tasks.
BADGE = lambda text, v: (f'<span class="{form_ns["BADGE"]} {form_ns["BADGE_SIZES"]["default"]} {form_ns["BADGE_VARIANTS"][v]}" data-slot="badge">{text}</span>')
MORE = button("ghost", "icon-sm", lucide("ellipsis", "size-4"))


def task_row(title, prompt, status, badge, enabled):
    desc = (f'<p class="max-w-xl text-xs leading-normal text-muted-foreground/80"><span class="line-clamp-2">{prompt}</span></p>'
            f'<div class="pt-0.5 text-xs text-muted-foreground"><div class="flex flex-wrap items-center gap-2"><span>{status}</span>{badge}</div></div>')
    return row(title, "", f'<div class="flex items-center gap-2">{switch("default", "on" if enabled else "off", False)}{MORE}</div>', desc_html=desc)


NEW_TASK = button("ghost-muted", "xs", lucide("plus", "size-3") + "New task")
tasks = ('<section class="space-y-2.5"><div class="flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4">'
         '<div class="flex min-w-0 items-center gap-1"><h2 class="flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70">Scheduled tasks</h2></div>'
         f'<div class="flex min-h-7 min-w-7 items-center justify-end">{NEW_TASK}</div></div>'
         '<div class="relative overflow-visible text-foreground space-y-1"><div class="space-y-8"><section><h2 class="sr-only">host</h2>'
         f'<div class="{GROUP}">'
         + task_row("Morning triage", "Read new issues in the demo repo and summarize anything that needs a reply today.", "Weekdays at 09:00 · Next run in 3h",
                    BADGE("succeeded", "success"), True)
         + task_row("Deploy hook", "Handle this webhook:\n{{body}}", "On webhook · Paused", "", False)
         + '</div></section></div></div></section>')

# --- 5. The editor's schedule rows: the type toggle, then the time and the weekdays.
LABEL = "flex items-center gap-2 text-base/4.5 font-medium text-foreground sm:text-sm/4"
OUTLINE_JOINED = ("*:not-first:not-data-[slot=separator]:before:-start-[0.5px] *:not-last:not-data-[slot=separator]:before:-end-[0.5px] *:not-first:rounded-s-none "
                  "*:not-last:rounded-e-none *:not-first:border-s-0 *:not-last:border-e-0 *:not-first:before:rounded-s-none *:not-last:before:rounded-e-none")
days = "".join(toggle("outline", "sm", d, d not in ("Sa", "Su"), icon=False) for d in ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"])
time_input = form_ns["input_html"]("default", "", "09:00").replace(" w-full", " w-32", 1)
schedule = ('<div class="space-y-3"><div class="flex items-center justify-between gap-2">'
            f'<label class="{LABEL}">Schedule</label>' + group("segmented", ["At a time", "Every interval", "On webhook"], 0) + '</div>'
            '<div class="flex flex-wrap items-center gap-3"><div class="flex items-center gap-2">'
            f'<label class="{LABEL}">Run at</label>{time_input}<span class="text-xs text-muted-foreground">on</span></div>'
            f'<div data-slot="toggle-group" data-variant="outline" role="group" class="{tog["G_ALWAYS"]} {OUTLINE_JOINED}">{days}</div></div></div>')

cases = [
    {"name": "header", "html": header, "wrapperStyle": "display:block;width:860px", "native": {"kind": "header"}},
    {"name": "chart", "html": chart, "wrapperStyle": "display:block;width:600px", "native": {"kind": "chart"}},
    {"name": "limits-banner", "html": banner, "wrapperStyle": "display:block;width:692px", "native": {"kind": "banner"}},
    {"name": "scheduled-tasks", "html": tasks, "wrapperStyle": "display:block;width:796px", "native": {"kind": "tasks"}},
    {"name": "task-schedule", "html": schedule, "wrapperStyle": "display:block;width:528px", "native": {"kind": "schedule"}},
]
spec = {"component": "usage", "source": "apps/web/src/components/usage/UsagePage.tsx, settings/ScheduledTasksSettings.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/usage.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("usage", len(cases), "cases")
