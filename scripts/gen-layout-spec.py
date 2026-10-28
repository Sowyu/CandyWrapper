"""Writes the layout batch specs for scripts/component-reference: scroll-area, settings, table, group,
standalone-page, wizard-steps, discovery-list, middle-truncate, panel-tab-close, qr-code, number-field
(design/component-reference/<component>.json).

Class strings are copied from apps/web/src/components/ui/*.tsx and components/settings/*.tsx at the
tag in T3_VERSION. Base UI's runtime state (ScrollArea's data-hovering, thumb size and position, the
overflow variables) is written inline, with the values Base UI computes for the same geometry.
QR codes run T3's own bundled QrCode class (Nayuki's library, compiled into the installed client)
in the page, so the reference matrix is T3's, not ours.
Usage: /usr/bin/python3 -I scripts/gen-layout-spec.py [--skip-qr]
Standalone and truncation markup target Nightly 3814; --skip-qr retains the unchanged QR encoder.
"""
import glob, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def svg(inner, cls):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="{cls}" aria-hidden="true">{inner}</svg>')

CHECK = '<path d="M20 6 9 17l-5-5"></path>'
X = '<path d="M18 6 6 18"></path><path d="m6 6 12 12"></path>'
MINUS = '<path d="M5 12h14"></path>'
PLUS = '<path d="M5 12h14"></path><path d="M12 5v14"></path>'
TERMINAL = '<path d="M12 19h8"></path><path d="m4 17 6-6-6-6"></path>'
FOLDER = '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path>'

def write(component, source, states, cases):
    spec = {"component": component, "source": source, "states": states, "themes": ["light", "dark"], "cases": cases}
    with open(os.path.join(ROOT, f"design/component-reference/{component}.json"), "w") as f:
        json.dump(spec, f, indent=1)
    print(component, len(cases), "cases")

# Button classes from gen-button-spec.py (only its definitions, not its file-writing tail).
src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
ns = {}
exec(src[:src.index("PLUS = (")], ns)
def button(variant, size, title, extra=""):
    cls = ns["merge"](f'{ns["BASE"]} {ns["VARIANTS"][variant]} {ns["SIZES"][size]}')
    return f'<button type="button" data-slot="button" class="{cls}"{extra}>{title}</button>'

# ScrollArea (scroll-area.tsx). 12 rows of 32px in a 240x160 root: track 152px, thumb max(16, 152*160/384).
VIEWPORT = "h-full max-h-[inherit] overflow-auto overscroll-contain rounded-[inherit] outline-none transition-shadow focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background data-has-overflow-x:overscroll-x-contain"
FADE = "mask-t-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-start)))] mask-b-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-end)))] mask-l-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-start)))] mask-r-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-end)))] [--fade-size:1.5rem] scroll-p-[var(--fade-size)]"
SCROLLBAR = "flex opacity-0 transition-opacity delay-300 data-[orientation=horizontal]:mx-1 data-[orientation=horizontal]:mb-px data-[orientation=horizontal]:h-1.5 data-[orientation=vertical]:my-1 data-[orientation=vertical]:mr-px data-[orientation=vertical]:w-1.5 data-[orientation=horizontal]:flex-col data-hovering:opacity-100 data-scrolling:opacity-100 data-hovering:delay-0 data-scrolling:delay-0 data-hovering:duration-100 data-scrolling:duration-100"
THUMB = "relative flex-1 rounded-full bg-[var(--app-scrollbar-thumb)] transition-colors hover:bg-[var(--app-scrollbar-thumb-hover)]"

def scroll_area(offset, fade, visible, rows=12, w=240, h=160):
    content = rows * 32
    track = h - 8
    thumb = max(16, track * h / content)
    y = offset / (content - h) * (track - thumb)
    vp_style = f"--scroll-area-overflow-y-start:{offset}px;--scroll-area-overflow-y-end:{content - h - offset}px;--scroll-area-overflow-x-start:0px;--scroll-area-overflow-x-end:0px"
    body = "".join('<div class="h-8 border-b"></div>' for _ in range(rows))
    return (f'<div class="relative size-full min-h-0 overflow-hidden rounded-none" style="width:{w}px;height:{h}px">'
            f'<div class="{VIEWPORT}{" " + FADE if fade else ""}" data-slot="scroll-area-viewport" style="{vp_style}">'
            f'<div style="margin-top:-{offset}px">{body}</div></div>'
            f'<div class="{SCROLLBAR}" data-slot="scroll-area-scrollbar" data-orientation="vertical"{" data-hovering" if visible else ""} '
            f'style="position:absolute;top:0;bottom:0;inset-inline-end:0">'
            f'<div class="{THUMB}" data-slot="scroll-area-thumb" style="height:{thumb}px;transform:translate3d(0,{y}px,0)"></div></div></div>')

cases = []
for name, offset, fade, visible in [("faded.middle", 40, True, True), ("faded.top", 0, True, True),
                                    ("faded.near-top", 10, True, False), ("plain.bottom", 224, False, True)]:
    cases.append({"name": name, "html": scroll_area(offset, fade, visible), "stateTarget": "[data-slot=scroll-area-thumb]",
                  "native": {"offset": str(offset), "fade": str(fade).lower(), "visible": str(visible).lower()}})
write("scroll-area", "apps/web/src/components/ui/scroll-area.tsx", ["rest", "hover"], cases)

# SettingsSection, SettingsGroup and SettingsRow (settings/settingsLayout.tsx, settings/SettingsGroup.tsx).
GROUP = "relative overflow-visible text-foreground rounded-xl border border-border/60 bg-card/40 shadow-xs/5 [&>*+*]:border-t [&>*+*]:border-border/50 [&>[data-slot=settings-row]]:rounded-none"
ROW = "@container/settings-row rounded-xl px-3 sm:px-4 aria-disabled:opacity-64 aria-disabled:[&_*]:text-muted-foreground py-3"

def row(title, desc, control):
    d = f'<p class="max-w-xl text-xs leading-normal text-muted-foreground/80">{desc}</p>' if desc else ""
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>'
            '<span class="inline-flex h-5 w-5 shrink-0 items-center justify-center"></span></div>'
            f'{d}</div><div class="flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end">{control}</div></div></div>')

ROWS = [("Theme", "Choose how T3 Code looks on this device.", "System"),
        ("Confirm thread deletion", "Ask before deleting a thread and its history.", "Enabled"),
        ("Diff word wrap", None, "Off")]

def section(title, rows):
    body = "".join(row(t, d, button("outline", "sm", c)) for t, d, c in rows)
    return (f'<section class="space-y-2.5"><div class="flex min-h-7 items-start justify-between gap-4 px-3 sm:px-4">'
            f'<div class="flex min-w-0 items-center gap-1"><h2 class="flex min-h-7 items-center gap-2 text-sm font-normal text-foreground/70">{title}</h2></div>'
            f'<div class="flex min-h-7 min-w-7 items-center justify-end"></div></div><div class="{GROUP}">{body}</div></section>')

cases = [{"name": "section.three-rows", "html": section("General", ROWS), "wrapperStyle": "display:block;width:640px",
          "native": {"title": "General", "rows": "3"}},
         {"name": "section.one-row", "html": section("Notifications", ROWS[:1]), "wrapperStyle": "display:block;width:640px",
          "native": {"title": "Notifications", "rows": "1"}}]
write("settings", "apps/web/src/components/settings/settingsLayout.tsx", ["rest"], cases)

# Table (table.tsx).
TH = "h-10 px-2 text-left align-middle font-medium whitespace-nowrap text-foreground [&:has([role=checkbox])]:pr-0"
TD = "p-2 align-middle whitespace-nowrap [&:has([role=checkbox])]:pr-0"
TR = "border-b transition-colors hover:bg-muted/50 has-aria-expanded:bg-muted/50 data-[state=selected]:bg-muted"
TABLE_HEAD = ["Process", "CPU", "Memory"]
TABLE_ROWS = [["t3 serve", "0.4%", "182 MB"], ["claude", "2.1%", "96 MB"], ["git status", "0.0%", "4 MB"]]

def table(selected=None):
    head = "".join(f'<th data-slot="table-head" class="{TH}">{h}</th>' for h in TABLE_HEAD)
    body = ""
    for i, r in enumerate(TABLE_ROWS):
        sel = ' data-state="selected"' if i == selected else ""
        body += f'<tr data-slot="table-row" class="{TR}"{sel}>' + "".join(f'<td data-slot="table-cell" class="{TD}">{c}</td>' for c in r) + "</tr>"
    return (f'<div data-slot="table-container" class="relative w-full overflow-x-auto"><table data-slot="table" class="w-full caption-bottom text-xs">'
            f'<thead data-slot="table-header" class="[&_tr]:border-b"><tr data-slot="table-row" class="{TR}">{head}</tr></thead>'
            f'<tbody data-slot="table-body" class="[&_tr:last-child]:border-0">{body}</tbody></table></div>')

cases = [{"name": "rows", "html": table(), "wrapperStyle": "display:block;width:360px", "stateTarget": "tbody tr:nth-child(2)",
          "native": {}},
         {"name": "selected", "html": table(selected=0), "wrapperStyle": "display:block;width:360px", "stateTarget": "tbody tr:nth-child(2)",
          "native": {"selected": "0"}}]
write("table", "apps/web/src/components/ui/table.tsx", ["rest", "hover"], cases)

# Group / ButtonGroup (group.tsx).
GROUP_BASE = "flex w-fit *:focus-visible:z-1 has-[>[data-slot=group]]:gap-2 *:has-focus-visible:z-1 dark:*:[[data-slot=button]:hover~[data-slot=separator]:not([data-slot]:hover~[data-slot=separator]~[data-slot=separator]),[data-slot][data-pressed]~[data-slot=separator]:not([data-slot][data-pressed]~[data-slot=separator]~[data-slot=separator])]:before:bg-input/64 dark:*:[[data-slot=separator]:has(~[data-slot=button]:hover):not(:has(~[data-slot=separator]~[data-slot]:hover)),[data-slot=separator]:has(~[data-slot][data-pressed]):not(:has(~[data-slot=separator]~[data-slot][data-pressed]))]:before:bg-input/64"
GROUP_H = "*:[[data-slot]~[data-slot]:not([data-slot=separator])]:before:-start-[0.5px] *:data-slot:not-data-[slot=separator]:has-[~[data-slot]]:before:-end-[0.5px] *:pointer-coarse:after:min-w-auto *:data-slot:has-[~[data-slot]]:rounded-e-none *:data-slot:has-[~[data-slot]]:border-e-0 *:data-slot:has-[~[data-slot]]:before:rounded-e-none *:[[data-slot]~[data-slot]]:rounded-s-none *:[[data-slot]~[data-slot]]:border-s-0 *:[[data-slot]~[data-slot]]:before:rounded-s-none"
SEP = "[[data-slot=input-control]:focus-within+&,[data-slot=input-group]:focus-within+&,[data-slot=select-trigger]:focus-visible+*+&,[data-slot=number-field]:focus-within+input+&]:-translate-x-px pointer-events-none relative z-2 bg-input before:absolute before:inset-0 has-[+[data-slot=input-control]:focus-within,+[data-slot=input-group]:focus-within,+[data-slot=select-trigger]:focus-visible+*,+[data-slot=number-field]:focus-within]:translate-x-px has-[+[data-slot=input-control]:focus-within,+[data-slot=input-group]:focus-within,+[data-slot=select-trigger]:focus-visible+*,+[data-slot=number-field]:focus-within]:bg-ring dark:before:bg-input/32 [[data-slot=input-control]:focus-within+&,[data-slot=input-group]:focus-within+&,[data-slot=select-trigger]:focus-visible+*+&,[data-slot=number-field]:focus-within+&,[data-slot=number-field]:focus-within+input+&]:bg-ring shrink-0 w-px self-stretch"

def group(titles, variant="outline", separators=False):
    parts = []
    for i, t in enumerate(titles):
        if i and separators: parts.append(f'<div data-slot="separator" data-orientation="vertical" role="separator" class="{SEP}"></div>')
        parts.append(button(variant, "sm", t))
    return f'<div role="group" data-slot="group" data-orientation="horizontal" class="{GROUP_BASE} {GROUP_H}">{"".join(parts)}</div>'

cases = [{"name": "outline.three", "html": group(["Left", "Middle", "Right"]), "stateTarget": "button:nth-child(2)",
          "native": {"variant": "outline", "titles": "Left,Middle,Right"}},
         {"name": "default.separated", "html": group(["Commit", "Push"], variant="default", separators=True),
          "stateTarget": "button:nth-child(1)", "native": {"variant": "default", "titles": "Commit,Push", "separators": "true"}}]
write("group", "apps/web/src/components/ui/group.tsx", ["rest", "hover", "focus-visible"], cases)

# StandalonePage (standalone-page.tsx).
def standalone(tone, eyebrow, title, text):
    # standalone-page.tsx:8-35, 3814. The native client substitutes its own wordmark.
    mark = '<svg class="h-3 w-auto shrink-0 text-foreground" viewBox="15.5309 37 94.3941 56.96" xmlns="http://www.w3.org/2000/svg"><path d="M33.4509 93V47.56H15.5309V37H64.3309V47.56H46.4109V93H33.4509ZM86.7253 93.96C82.832 93.96 78.9653 93.4533 75.1253 92.44C71.2853 91.3733 68.032 89.88 65.3653 87.96L70.4053 78.04C72.5386 79.5867 75.0186 80.8133 77.8453 81.72C80.672 82.6267 83.5253 83.08 86.4053 83.08C89.6586 83.08 92.2186 82.44 94.0853 81.16C95.952 79.88 96.8853 78.12 96.8853 75.88C96.8853 73.7467 96.0586 72.0667 94.4053 70.84C92.752 69.6133 90.0853 69 86.4053 69H80.4853V60.44L96.0853 42.76L97.5253 47.4H68.1653V37H107.365V45.4L91.8453 63.08L85.2853 59.32H89.0453C95.9253 59.32 101.125 60.8667 104.645 63.96C108.165 67.0533 109.925 71.0267 109.925 75.88C109.925 79.0267 109.099 81.9867 107.445 84.76C105.792 87.48 103.259 89.6933 99.8453 91.4C96.432 93.1067 92.0586 93.96 86.7253 93.96Z" fill="currentColor"></path></svg>'
    return (f'<div class="flex h-full items-center-safe justify-center overflow-y-auto scrollbar-gutter-both bg-background px-4 py-10 text-foreground sm:px-6" style="height:420px">'
            '<section class="dialog-glass w-full max-w-xl rounded-2xl border p-6">'
            '<div class="flex items-baseline justify-between gap-3 text-muted-foreground">'
            f'<span class="flex items-baseline gap-1.5" role="img" aria-label="T3 Code">{mark}<span class="text-lg font-medium tracking-tight">Code</span></span></div>'
            f'<h1 class="mt-6 text-xl leading-tight font-semibold">{title}</h1>'
            f'<p class="mt-2 text-sm text-muted-foreground">{text}</p></section></div>')

cases = []
for tone, eyebrow, title, text in [("pairing", "Pair device", "Connect to T3 Code", "Open this link on the device you want to pair."),
                                   ("error", "Something went wrong", "Pairing failed", "The pairing link expired. Ask for a new one."),
                                   ("brand", "T3 Code", "Welcome back", "Sign in to continue to your workspace.")]:
    cases.append({"name": tone, "html": standalone(tone, eyebrow, title, text), "wrapperStyle": "display:block;width:720px",
                  "native": {"tone": tone, "eyebrow": eyebrow, "title": title, "text": text}})
write("standalone-page", "apps/web/src/components/ui/standalone-page.tsx", ["rest"], cases)

# WizardSteps (wizard.tsx).
def wizard_steps(steps, current):
    items = ""
    for i, s in enumerate(steps):
        cls = "flex w-full min-w-0 items-center gap-2 rounded-lg px-2.5 py-2 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring max-sm:justify-center max-sm:px-2 cursor-pointer hover:bg-card disabled:cursor-default disabled:hover:bg-transparent"
        if i == current: cls += " bg-card text-foreground shadow-xs ring-1 ring-black/5 hover:bg-card dark:shadow-none dark:ring-white/5"
        if i < current: disc = "bg-primary text-primary-foreground ring-primary"
        elif i == current: disc = "bg-primary/10 text-primary ring-primary/30"
        else: disc = "bg-card text-muted-foreground ring-black/10 dark:bg-white/5 dark:ring-white/10"
        inner = svg(CHECK, "lucide lucide-check size-4 shrink-0") if i < current else str(i + 1)
        label = "text-foreground" if i == current else "text-muted-foreground"
        items += (f'<li class="min-w-0"><button type="button" class="{cls}"><span class="grid size-5 shrink-0 place-items-center rounded-full text-sm font-medium ring-1 {disc}" aria-hidden="true">{inner}</span>'
                  f'<span class="min-w-0 truncate text-sm font-medium max-sm:hidden {label}">{s}</span></button></li>')
    return f'<ol class="grid auto-cols-fr grid-flow-col gap-1 rounded-xl bg-zinc-25 p-1 ring-1 ring-black/5 dark:bg-white/4 dark:ring-white/5" role="list">{items}</ol>'

STEPS = ["Project", "Environment", "Review"]
cases = [{"name": f"current-{c}", "html": wizard_steps(STEPS, c), "wrapperStyle": "display:block;width:520px",
          "stateTarget": "li:nth-child(3) button", "native": {"steps": ",".join(STEPS), "current": str(c)}} for c in (0, 1)]
write("wizard-steps", "apps/web/src/components/ui/wizard.tsx", ["rest", "hover", "focus-visible"], cases)

# DiscoveryList (discovery-list.tsx). The icon is the caller's; settings use a size-4 muted lucide icon.
DROW = "group flex w-full items-center gap-3 px-3 py-3 text-left hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-64"
def discovery(rows):
    body = "".join(f'<button type="button" class="{DROW}">{svg(icon, "size-4 shrink-0 text-muted-foreground")}<div class="flex min-w-0 flex-1 flex-col">'
                   f'<span class="truncate text-sm font-medium text-foreground">{t}</span><span class="truncate text-xs text-muted-foreground">{d}</span></div></button>'
                   for icon, t, d in rows)
    return f'<div class="flex flex-col divide-y divide-border/60 overflow-hidden rounded-xl border border-border/70 bg-background">{body}</div>'

cases = [{"name": "two-rows", "html": discovery([(FOLDER, "candywrapper", "~/Projects/candywrapper"), (TERMINAL, "t3code", "~/Projects/t3code, a very long description that truncates")]),
          "wrapperStyle": "display:block;width:320px", "stateTarget": "button:nth-child(1)", "native": {}}]
write("discovery-list", "apps/web/src/components/ui/discovery-list.tsx", ["rest", "hover", "focus-visible", "disabled"], cases)

# MiddleTruncate (middle-truncate.tsx). Head and tail come from splitForMiddleTruncate.
def split(value, tail=None):
    chars = list(value)
    keep = 10 if tail is None else tail
    if tail is None:
        slash = value.rfind("/")
        if 0 < slash < len(chars) - 1:
            seg = len(chars) - slash - 1
            keep = seg if seg <= 16 else 10
    if keep <= 0 or len(chars) <= keep + 4: return None
    cut = len(chars) - keep
    breaks = "-_./"
    if tail is None and chars[cut - 1] not in breaks:
        shorter = next((n for n in range(cut + 1, len(chars) - 3) if chars[n - 1] in breaks), None)
        longer = next((n for n in range(cut - 1, max(4, len(chars) - 17), -1) if chars[n - 1] in breaks), None)
        cut = shorter or longer or cut
    return "".join(chars[:cut]), "".join(chars[cut:])

def middle(value):
    s = split(value)
    inner = (f'<span class="peer min-w-0 overflow-hidden">{s[0]}</span><span class="shrink-0 peer-data-overflow:before:content-[\'…\']">{s[1]}</span>' if s
             else f'<span class="min-w-0 truncate">{value}</span>')
    return f'<span class="inline-flex min-w-0 max-w-full overflow-hidden whitespace-nowrap text-sm text-foreground" title="{value}">{inner}</span>'

cases = []
for name, value in [("path", "/Users/mrm/Projects/candywrapper/Sources/ScrollAreaView.swift"),
                    ("branch", "fix/cache-main-20260918-180825"), ("sha-long", "t3code-worktree-3b6af0b2c41d9e"), ("short", "main")]:
    cases.append({"name": name, "html": middle(value), "wrapperStyle": "display:flex;width:180px", "native": {"value": value}})
write("middle-truncate", "apps/web/src/components/ui/middle-truncate.tsx", ["rest"], cases)
midpath = os.path.join(ROOT, "design/component-reference/middle-truncate.json")
with open(midpath) as f: midspec = json.load(f)
midspec["prepare"] = """(() => { document.querySelectorAll('.peer').forEach(head => {
 const text = head.firstChild; const overflow = head.scrollWidth > head.clientWidth;
 head.toggleAttribute('data-overflow', overflow); if (!overflow) return;
 const range = document.createRange(); const left = head.getBoundingClientRect().left;
 const widthTo = n => { range.setStart(text, 0); range.setEnd(text, n); return range.getBoundingClientRect().right - left; };
 let fits = 0, over = text.length;
 while (over - fits > 1) { const mid = (fits + over) >> 1; if (widthTo(mid) <= head.clientWidth) fits = mid; else over = mid; }
 const slack = Math.max(0, head.clientWidth - widthTo(fits));
 head.style.clipPath = slack > 0 ? `inset(-0.25em ${slack}px -0.25em 0)` : '';
 head.nextElementSibling.style.translate = slack > 0 ? `-${slack}px 0` : '';
 }); return true; })()"""
with open(midpath, 'w') as f: json.dump(midspec, f, indent=1)


# PanelTabCloseButton (panel-tab-close-button.tsx) inside a `group/tab` row.
def tab_close():
    return ('<div class="group/tab inline-flex items-center gap-1.5 px-1 py-1">'
            '<button type="button" class="cursor-pointer group/close relative flex size-4 shrink-0 items-center justify-center rounded-sm hover:bg-muted" aria-label="Close tab">'
            f'<span class="relative flex size-3 items-center justify-center group-hover/tab:hidden group-focus-visible/close:hidden">{svg(TERMINAL, "size-3 text-muted-foreground")}</span>'
            f'{svg(X, "lucide lucide-x hidden size-3 group-hover/tab:block group-focus-visible/close:block")}</button></div>')

cases = [{"name": "tab", "html": tab_close(), "native": {}},
         {"name": "button-hover", "html": tab_close(), "stateTarget": "button", "native": {"buttonTarget": "true"}}]
write("panel-tab-close", "apps/web/src/components/ui/panel-tab-close-button.tsx", ["rest", "hover", "focus-visible"], cases)

# QRCodeSvg (qr-code.tsx) with T3's compiled QrCode class.
# Layout-only refreshes can retain the existing QR encoder; it did not change in 3814.
# This also keeps a visual refresh independent of installed server bundles.
if "--skip-qr" not in sys.argv:
    bundle = sorted(glob.glob(os.path.expanduser("~/.t3/runtime/versions/*/client/assets/main-*.js")))[-1]
    js = open(bundle).read()
    start = js.rfind("var ", 0, js.index("static encodeText("))
    end = js.index("return n.join(``)}", js.index("M${", start)) + len("return n.join(``)}")
    lib = js[start:end]
    qr_name = lib[4:lib.index("=class")]
    path_fn = lib[lib.rindex("function ") + 9:lib.rindex("(e,t){")]
    ecc = "{L:%s.Ecc.LOW,M:%s.Ecc.MEDIUM,Q:%s.Ecc.QUARTILE,H:%s.Ecc.HIGH}" % ((qr_name,) * 4)
    QR_SCRIPT = ("<script>(()=>{" + lib + ";const E=" + ecc + ";for(const d of document.querySelectorAll('div.qr:not([data-done])')){"
                 "const q=" + qr_name + ".encodeText(d.dataset.value,E[d.dataset.level]);const m=+d.dataset.margin;const n=q.size+m*2;"
                 "d.dataset.done='1';d.innerHTML=`<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ${n} ${n}\" width=\"${d.dataset.size}\" height=\"${d.dataset.size}\" shape-rendering=\"crispEdges\">"
                 "<rect width=\"${n}\" height=\"${n}\" fill=\"#fff\"></rect><path d=\"${" + path_fn + "(q,m)}\" fill=\"#000\"></path></svg>`;}})()</script>")

    cases = []
    for name, value, level, margin, size in [("pairing-m2-132", "https://app.t3.codes/pair?token=abcdEFGH1234#k=Zm9vYmFy", "M", 2, 132),
                                             ("nightly-m1-128", "https://t3.codes/download/nightly", "M", 1, 128),
                                             ("numeric-l0-128", "0123456789012345", "L", 0, 128),
                                             ("alnum-h1-128", "HTTPS://T3.CODES/PAIR/ABC123", "H", 1, 128)]:
        cases.append({"name": name, "html": f'<div class="qr" style="display:block;width:{size}px;height:{size}px;line-height:0" data-value="{value}" data-level="{level}" data-margin="{margin}" data-size="{size}"></div>',
                      "native": {"value": value, "level": level, "margin": str(margin), "size": str(size)}})
    cases[-1]["html"] += QR_SCRIPT
    write("qr-code", "apps/web/src/components/ui/qr-code.tsx", ["rest"], cases)

else:
    print("qr-code: retained the unchanged encoder spec")

# NumberField (number-field.tsx).
NF_GROUP = "relative flex w-full justify-between rounded-lg border border-input bg-background not-dark:bg-clip-padding text-base text-foreground shadow-xs/5 ring-ring/24 transition-shadow before:pointer-events-none before:absolute before:inset-0 before:rounded-[calc(var(--radius-lg)-1px)] not-data-disabled:not-focus-within:not-aria-invalid:before:shadow-[0_1px_--theme(--color-black/4%)] focus-within:border-ring focus-within:ring-[3px] has-aria-invalid:border-destructive/36 has-autofill:bg-foreground/4 focus-within:has-aria-invalid:border-destructive/64 focus-within:has-aria-invalid:ring-destructive/48 data-disabled:pointer-events-none data-disabled:opacity-64 sm:text-sm dark:bg-input/32 dark:has-autofill:bg-foreground/8 dark:has-aria-invalid:ring-destructive/24 dark:not-data-disabled:not-focus-within:not-aria-invalid:before:shadow-[0_-1px_--theme(--color-white/6%)] [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0 [[data-disabled],:focus-within,[aria-invalid]]:shadow-none"
NF_STEP = "relative flex shrink-0 cursor-pointer items-center justify-center in-data-[size=sm]:px-[calc(--spacing(2.5)-1px)] px-[calc(--spacing(3)-1px)] transition-colors pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 hover:bg-accent"
NF_INPUT = "h-8.5 in-data-[size=lg]:h-9.5 in-data-[size=sm]:h-7.5 w-full min-w-0 grow bg-transparent in-data-[size=sm]:px-[calc(--spacing(2.5)-1px)] px-[calc(--spacing(3)-1px)] text-center tabular-nums in-data-[size=lg]:leading-9.5 in-data-[size=sm]:leading-7.5 leading-8.5 outline-none [transition:background-color_5000000s_ease-in-out_0s] sm:h-7.5 sm:in-data-[size=lg]:h-8.5 sm:in-data-[size=sm]:h-6.5 sm:in-data-[size=lg]:leading-8.5 sm:in-data-[size=sm]:leading-8.5 sm:leading-7.5"

def number_field(value, size="default", disabled=False):
    dis = " data-disabled" if disabled else ""
    return (f'<div class="flex w-full flex-col items-start gap-2" data-size="{size}" data-slot="number-field"{dis}>'
            f'<div class="{NF_GROUP}" data-slot="number-field-group"{dis}>'
            f'<button type="button" tabindex="-1" class="{NF_STEP} rounded-s-[calc(var(--radius-lg)-1px)]" data-slot="number-field-decrement">{svg(MINUS, "lucide lucide-minus")}</button>'
            f'<input class="{NF_INPUT}" data-slot="number-field-input" value="{value}" inputmode="numeric">'
            f'<button type="button" tabindex="-1" class="{NF_STEP} rounded-e-[calc(var(--radius-lg)-1px)]" data-slot="number-field-increment">{svg(PLUS, "lucide lucide-plus")}</button>'
            '</div></div>')

W = "display:block;width:160px"
cases = [{"name": "default.input", "html": number_field("8"), "wrapperStyle": W, "stateTarget": "input", "native": {"value": "8", "size": "default", "target": "input"}},
         {"name": "default.increment", "html": number_field("120"), "wrapperStyle": W, "stateTarget": "[data-slot=number-field-increment]",
          "native": {"value": "120", "size": "default", "target": "increment"}},
         {"name": "sm.input", "html": number_field("3", size="sm"), "wrapperStyle": W, "stateTarget": "input", "native": {"value": "3", "size": "sm", "target": "input"}},
         {"name": "lg.input", "html": number_field("1024", size="lg"), "wrapperStyle": W, "stateTarget": "input", "native": {"value": "1024", "size": "lg", "target": "input"}},
         {"name": "disabled", "html": number_field("5", disabled=True), "wrapperStyle": W, "stateTarget": "input", "native": {"value": "5", "size": "default", "disabled": "true"}}]
write("number-field", "apps/web/src/components/ui/number-field.tsx", ["rest", "hover", "focus-visible"], cases)
