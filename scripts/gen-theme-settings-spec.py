"""Writes design/component-reference/theme-settings.json for scripts/component-reference: Settings > Appearance's
Themes heading, a row of theme cards (T3 Code picked for both sides, T3 Chat, Grove) and the theme editor in its
guided (simple) form.

Class strings are copied from apps/web/src/components/settings/{ThemeSettings.tsx, ThemePreviewCircles.tsx,
ThemeEditorPanel.tsx, ThemeColorPicker.tsx} and packages/shared/src/themePreview.ts at v0.1.4-nightly.20261028.3814. Buttons,
icons, inputs, switches and the segmented toggle group come from gen-connections-spec.py and gen-toggles-spec.py.
The editor's `fixed bottom-4 right-4` placement is replaced by a static box; everything else is T3's markup.
Usage: /usr/bin/python3 -I scripts/gen-theme-settings-spec.py [t3code checkout]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = sys.argv[1] if len(sys.argv) > 1 else "/Users/mrm/CandyWrapper-research/t3code"

conn = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-connections-spec.py")).read()
exec(src[:src.index("W796 =")], conn)
lucide, button, merge = conn["lucide"], conn["button"], conn["merge"]
tog, form = conn["tog_ns"], conn["form_ns"]
switch, toggle = tog["switch"], tog["toggle"]

# Built-in theme colors (packages/shared/src/themePalettes.ts), parsed like scripts/gen-theme-palettes.py.
PALETTES = open(os.path.join(T3, "packages/shared/src/themePalettes.ts")).read()


def block(name):
    m = re.search(r"export const " + name + r"(?::[^=]+)? = (\{.*?\n\});", PALETTES, re.S)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    body = re.sub(r"(\b[A-Za-z_][A-Za-z0-9_]*)\s*:", r'"\1":', body)
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", body))


ROLES = ["sidebar", "canvas", "surface", "accentSurface", "accent", "messageSurface", "messageAction"]
STANDARD = {"light": {"sidebar": "#fafafa", "surface": "#ffffff", "accentSurface": "#f4f4f5", "messageSurface": "#e4e4e7",
                      "canvas": "#fcfcfc", "accent": "#f4f4f5", "messageAction": "#4f46e5"},
            "dark": {"sidebar": "#0f0f10", "surface": "#121212", "accentSurface": "#27272a", "messageSurface": "#27272a",
                     "canvas": "#0a0a0a", "accent": "#1c1c1f", "messageAction": "#8b9cff"}}
SPECS = {"light": {"target": "#ffffff", "accent": (0.72, 0.22, 0.72), "action": (0.18, 0.82)},
         "dark": {"target": "#09090b", "accent": (0.28, 0.78, 0.62), "action": (0.82, 0.18)}}


def ball(colors, mode):
    """`ThemePreviewCircle` with `getThemePreviewStyle` (ThemePreviewCircles.tsx:99-170)."""
    s = SPECS[mode]
    ax, ay, mid = s["accent"]
    bx, by = s["action"]
    base = f"color-mix(in oklab, {colors['canvas']} 80%, {s['target']})"
    image = (f"radial-gradient(circle at {ax * 100:g}% {ay * 100:g}% in oklab, {colors['accent']} 0%, "
             f"color-mix(in oklab, {colors['accent']} {mid * 100:g}%, transparent) 28%, transparent 58%), "
             f"radial-gradient(circle at {bx * 100:g}% {by * 100:g}% in oklab, color-mix(in oklab, {colors['messageAction']} 45%, transparent) 0%, transparent 55%)")
    edge = ("inset 0 0 0 1px rgb(255 255 255 / 0.14), 0 1px 2px rgb(0 0 0 / 0.18)" if mode == "dark"
            else "inset 0 0 0 1px rgb(0 0 0 / 0.10), 0 1px 2px rgb(0 0 0 / 0.08)")
    return (f'<span aria-hidden="" class="relative block size-14 shrink-0 overflow-hidden rounded-full border-2 border-background" style="box-shadow:{edge}">'
            f'<span class="absolute inset-0 rounded-full" style="background-color:{base};background-image:{image};filter:blur(3px);transform:scale(1.1)"></span></span>')


def circle(colors, mode, picked):
    extra = ""
    if picked:
        icon = lucide("sun" if mode == "light" else "moon", "size-3")
        extra = ('<span aria-hidden="" class="pointer-events-none absolute inset-0 rounded-full" style="box-shadow:inset 0 0 0 2px var(--ring)"></span>'
                 '<span aria-hidden="" class="pointer-events-none absolute bottom-0.5 right-0.5 flex size-5 items-center justify-center rounded-full border '
                 f'border-border/70 bg-background text-foreground shadow-sm">{icon}</span>')
    cls = ("relative flex size-[68px] shrink-0 transform-gpu cursor-pointer items-center justify-center rounded-full p-1 outline-none transition-transform "
           "hover:scale-105 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-card" + (" hover:scale-100" if picked else ""))
    return f'<button type="button" class="{cls}">{ball(colors, mode)}{extra}</button>'


def card(label, previews, picked, actions):
    circles = "".join(circle(c, m, m in picked) for m, c in previews)
    icons = "".join(button("ghost-destructive" if a == "trash-2" else "ghost", "icon-xs", lucide(a)) for a in actions)
    return ('<div class="cursor-pointer overflow-hidden rounded-xl border border-border/70 bg-card/60 transition-colors hover:bg-accent/10">'
            f'<div class="relative"><div class="flex min-h-16 items-center justify-center gap-2.5 px-3 pt-3">{circles}</div></div>'
            '<div class="flex items-center gap-2 px-3 pb-3 pt-2"><div class="min-w-0 flex-1"><div class="flex items-center gap-1.5">'
            f'<button type="button" class="min-w-0 cursor-pointer truncate rounded-sm text-left text-sm font-medium text-foreground outline-none">{label}</button>'
            f'</div></div><div class="flex shrink-0 items-center gap-1">{icons}</div></div></div>')


def theme_previews(name):
    t = block(name)
    out = [(t["appearance"], {r: t["colors"][r] for r in ROLES})]
    for mode, colors in t.get("variants", {}).items():
        out.append((mode, {r: colors[r] for r in ROLES}))
    return t["label"], sorted(out, key=lambda p: p[0] != "light")


cards = [card("T3 Code", [("light", STANDARD["light"]), ("dark", STANDARD["dark"])], {"light", "dark"}, ["copy"])]
for name in ("T3_CHAT_THEME", "GROVE_THEME"):
    label, previews = theme_previews(name)
    cards.append(card(label, previews, set(), ["copy"]))
grid = ('<div class="grid w-full gap-2" style="grid-template-columns:repeat(auto-fit, minmax(min(100%, 16rem), 1fr))">' + "".join(cards) + "</div>")

header = ('<div class="flex min-h-8 flex-wrap items-center justify-between gap-3 px-3 pt-5 sm:px-4">'
          '<h3 class="text-base font-semibold text-foreground">Themes</h3><div class="flex flex-wrap items-center justify-end gap-2">'
          + button("outline", "xs", lucide("paintbrush") + "Create theme") + button("outline", "xs", lucide("plus") + "Add theme") + "</div></div>")

# The editor (ThemeEditorPanel.tsx:1118-1312) in its guided form.
GRID = "grid grid-cols-[minmax(0,1fr)_minmax(0,2fr)] items-center gap-3"


def field(label, value):
    """`ThemeColorField` (ThemeColorPicker.tsx:313-367)."""
    inp = form["input_html"]("compact", value=value, mono=True).replace(' w-full ', ' w-28 shrink-0 ', 1)
    return ('<div class="flex min-h-11 min-w-0 items-center gap-2 rounded-lg px-2 py-1.5">'
            '<button type="button" class="flex min-w-0 flex-1 cursor-pointer items-center rounded-md text-left text-sm text-muted-foreground outline-none">'
            f'<span class="min-w-0 flex-1 truncate">{label}</span></button><div class="ml-auto flex shrink-0 items-center gap-2">'
            '<button type="button" class="relative flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full border border-foreground/30">'
            f'<span class="absolute inset-0 rounded-full shadow-sm" style="background-color:{value}"></span></button>{inp}</div></div>')


name_input = form["input_html"]("sm", placeholder="e.g. Aurora", value="Aurora")
segmented = (f'<div data-slot="toggle-group" data-size="segmented" data-variant="segmented" role="group" class="{tog["G_ALWAYS"]} {tog["G_VARIANT"]["segmented"]}">'
             + toggle("segmented", "segmented", "Light", False, icon=False) + toggle("segmented", "segmented", "Dark", True, icon=False) + "</div>")
editor_header = ('<div class="flex cursor-grab touch-none select-none items-center gap-1 border-b border-border/70 px-3 py-2">'
                 '<div class="flex min-w-0 flex-1 items-baseline gap-2"><h2 class="shrink-0 truncate text-sm font-medium">Create theme</h2>'
                 '<p class="truncate text-xs text-muted-foreground">Select a color below</p></div>'
                 + button("ghost", "xs", lucide("mouse-pointer-2") + "Inspect") + button("ghost", "icon-xs", lucide("chevron-down"))
                 + button("ghost", "icon-xs", lucide("x")) + "</div>")
body = ('<div class="min-h-0 flex-1 space-y-3 overflow-y-auto py-3 pl-3 pr-1.5">'
        f'<label class="{GRID}"><span class="text-sm font-medium">Theme name</span>{name_input}</label>'
        f'<div class="{GRID}"><span class="text-sm font-medium">Appearance</span><div>{segmented}</div></div>'
        '<div class="space-y-3"><div class="grid grid-cols-[minmax(0,1fr)_minmax(0,2fr)] items-start gap-3"><div>'
        '<h3 class="text-sm font-medium">Colors</h3><p class="text-xs text-muted-foreground">Two colors, rest derived</p></div>'
        '<div class="flex min-w-0 items-start gap-3"><label class="ml-auto flex shrink-0 cursor-pointer items-center gap-2 pt-0.5 text-sm font-medium">'
        f'<span>Advanced</span>{switch("default", "off", False)}</label></div></div>'
        f'<div class="grid gap-1">{field("Background", "#0a0a0a")}{field("Accent", "#346bf1")}</div></div></div>')
footer = ('<div class="flex items-center justify-end gap-2 border-t border-border/70 px-3 py-2">'
          + button("ghost", "sm", "Cancel") + button("default", "sm", lucide("paintbrush") + "Create theme") + "</div>")
grip = ('<div aria-hidden="" class="absolute bottom-0 right-0 z-10 flex size-5 cursor-se-resize touch-none select-none items-end justify-end p-1 text-muted-foreground/70">'
        '<svg class="size-2.5" fill="none" stroke="currentColor" stroke-linecap="round" stroke-width="1.2" viewBox="0 0 8 8"><path d="M7 1 1 7M7 4.5 4.5 7"/></svg></div>')
editor = ('<div class="dialog-glass relative flex w-[26rem] flex-col overflow-hidden rounded-xl border text-popover-foreground" role="dialog">'
          + editor_header + body + footer + grip + "</div>")

cases = [
    {"name": "header", "html": header, "wrapperStyle": "display:block;width:796px", "native": {"kind": "header"}},
    {"name": "cards", "html": grid, "wrapperStyle": "display:block;width:796px", "native": {"kind": "cards"}},
    {"name": "editor", "html": editor, "wrapperStyle": "display:block;width:416px", "native": {"kind": "editor"}},
]
spec = {"component": "theme-settings", "source": "apps/web/src/components/settings/ThemeSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/theme-settings.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("theme-settings", len(cases), "cases")
