"""Writes design/component-reference/use-in-another-app.json for scripts/component-reference: the 4928 "Use T3 Code
in another app (MCP)" wizard (components/mcp/UseInAnotherAppDialog.tsx, PR #33196) step by step at the panel's
content width (a 576px popup less its borders and `px-6`): the app grid with Claude picked, the access levels with
Auto picked, the Connect step for Claude before a code, the Turn on gate for a machine linked on its host, and the
Authorized clients header with its Use in another app (MCP) button (AuthorizedClientsSettings.tsx:668-698).
Helpers come from scripts/gen-connections-spec.py; the logos are T3's PNGs inlined as data URLs.
Usage: /usr/bin/python3 -I scripts/gen-use-in-another-app-spec.py
"""
import base64, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-connections-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, button, FOLD = ns["lucide"], ns["button"], ns["FOLD"]
LOGOS = os.path.join(ROOT, "Packages/CandyKit/Sources/Features/Resources/mcp-logos")

APPS = [("Poke", "poke"), ("Claude", "claude"), ("ChatGPT", "chatgpt"), ("Grok Bot", "grokbot"), ("Muse", "muse"),
        ("Instinct", "instinct"), ("OpenClaw", "openclaw"), ("Hermes Agent", "hermes")]
FOCUS = "outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"


def logo(name):
    data = base64.b64encode(open(os.path.join(LOGOS, f"{name}.png"), "rb").read()).decode()
    return f'<img src="data:image/png;base64,{data}" alt="" class="size-10 rounded-lg ring-1 ring-black/10 dark:ring-white/12">'


def app_step(selected):
    """`AppStep` (UseInAnotherAppDialog.tsx:546-590)."""
    tiles = "".join(
        f'<button type="button" aria-pressed="{str(name == selected).lower()}" class="flex min-w-0 flex-col items-center gap-2 rounded-lg border border-transparent px-1 py-3 {FOCUS} hover:bg-accent aria-pressed:border-primary aria-pressed:bg-primary/8">'
        f'{logo(file)}<span class="max-w-full truncate whitespace-nowrap text-xs font-medium">{name}</span></button>'
        for name, file in APPS)
    other = (f'<button type="button" aria-pressed="false" class="w-full rounded-lg border border-border px-3 py-2.5 text-sm font-medium {FOCUS} '
             'hover:bg-accent aria-pressed:border-primary aria-pressed:bg-primary/8">Something else…</button>')
    return (f'<section class="space-y-3"><h3 class="text-sm font-medium">Which app?</h3>'
            f'<div class="grid grid-cols-3 gap-2 sm:grid-cols-4">{tiles}</div>{other}</section>')


LEVELS = [("Read only", "Read projects and threads. Cannot start, message or change anything.", "eye"),
          ("Supervised", "Ask before commands and file changes.", "lock"),
          ("Auto-accept edits", "Auto-approve edits, ask before other actions.", "pen-line"),
          ("Auto", "Supported providers approve routine actions; others still ask.", "shield-check"),
          ("Full access", "Runs commands and edits files without asking", "shield-off")]


def access_option(label, detail, icon, selected):
    """`AccessOption` (auth/ConnectAgentSurface.tsx:453-496)."""
    state = ("border-primary bg-background ring-2 ring-inset ring-primary/25 dark:border-transparent dark:bg-primary/10 dark:ring-1 dark:ring-primary/30"
             if selected else "border-border bg-background hover:bg-muted/50 dark:border-transparent dark:bg-white/[0.035] dark:hover:bg-accent")
    tone = "text-primary" if selected else "text-muted-foreground"
    return (f'<button type="button" role="radio" aria-checked="{str(selected).lower()}" class="flex cursor-pointer items-start gap-3 rounded-lg border px-3 py-2.5 text-left outline-none transition-[background-color,border-color,box-shadow] {state}">'
            f'{lucide(icon, "mt-0.5 size-4 shrink-0 " + tone)}<span class="min-w-0"><span class="block text-sm font-medium text-foreground">{label}</span>'
            f'<span class="block text-xs text-muted-foreground">{detail}</span></span></button>')


def access_step(app, selected):
    options = "".join(access_option(l, d, i, l == selected) for l, d, i in LEVELS)
    return (f'<section class="space-y-3"><h3 class="text-sm font-medium">What can {app} do?</h3>'
            f'<div role="radiogroup" class="flex flex-col gap-3">{options}</div></section>')


def copy_row(label, value):
    """`CopyRow` (UseInAnotherAppDialog.tsx:856-878)."""
    return ('<div class="flex min-w-0 items-center gap-2 rounded-lg border border-border bg-muted/50 px-3 py-2">'
            f'<span class="shrink-0 text-xs text-muted-foreground">{label}</span><span class="min-w-0 flex-1 truncate font-mono text-sm">{value}</span>'
            f'{button("ghost", "icon-xs", lucide("copy", "size-3.5"))}</div>')


def command_block(command):
    """`CommandBlock` (components/CommandBlock.tsx:27-48)."""
    return ('<div class="flex items-center justify-between gap-3 rounded-lg border border-border bg-muted/50 font-mono px-3 py-2.5 text-sm">'
            f'<span class="min-w-0 truncate"><span class="mr-2 text-muted-foreground">$</span>{command}</span>'
            f'{button("ghost", "icon-xs", lucide("copy", "size-3.5"))}</div>')


TEXT_BUTTON = "block text-sm font-medium underline-offset-4 outline-none hover:underline focus-visible:underline"
URL = "https://prod-a1.t3coderelay.com/mcp"


def connect_step():
    """`ConnectStep` for Claude, one click, before a code (UseInAnotherAppDialog.tsx:592-676, 782-854)."""
    primary = f'<div class="space-y-2">{button("default", "default", "Open in Claude", "w-full")}</div>'
    code = ('<div class="space-y-1.5"><div class="flex flex-wrap items-center justify-between gap-2"><span class="text-sm">'
            f'Code to approve <span class="font-medium">Auto</span></span>{button("outline", "sm", "Get code")}</div></div>')
    return (f'<section class="space-y-4">{primary}{copy_row("URL", URL)}{code}'
            f'<button type="button" class="{TEXT_BUTTON}">Set up another way</button></section>')


def turn_on():
    """The Turn on gate for a machine linked on its host (UseInAnotherAppDialog.tsx:477-532, 525-537)."""
    lines = ("<p>Mac mini gets a public https address, with no router setup.</p>"
             "<p>Only apps you approve can use it. You can turn it off in Settings.</p>")
    return ('<section class="space-y-3"><h3 class="text-base font-medium">Turn on T3 Connect for Mac mini</h3>'
            f'<div class="space-y-1 text-sm text-muted-foreground">{lines}</div>'
            f'<div class="space-y-2 text-sm">{command_block("t3 connect link")}<p>Restart T3 Code on Mac mini.</p>'
            f'{button("outline", "default", "Check again")}</div></section>')


def authorized_mcp():
    chevron = lucide("chevron-right", "size-4 shrink-0 text-muted-foreground transition-transform duration-150 motion-reduce:transition-none")
    control = ('<div class="ms-auto flex max-w-full items-center py-1.5"><div class="flex flex-wrap items-center justify-end gap-2">'
               f'{button("outline", "xs", lucide("plug", "size-3") + "Use in another app (MCP)")}'
               f'{button("destructive-outline", "xs", "Revoke others")}{button("default", "xs", lucide("plus", "size-3") + "Create link")}</div></div>')
    header = ('<div class="flex flex-wrap items-center gap-x-4 px-3 sm:px-4"><button type="button" class="flex min-h-11 min-w-0 flex-1 basis-40 items-center gap-2 py-2 text-left outline-none rounded-md">'
              f'{chevron}<span class="shrink-0 text-sm font-medium">Authorized clients</span>'
              f'<span class="min-w-0 truncate text-xs text-muted-foreground">2 clients · 1 pairing link</span></button>{control}</div>')
    return f'<section><div class="{FOLD}">{header}</div></section>'


W = "display:block;width:526px"
cases = [
    {"name": "mcp.apps", "html": app_step("Claude"), "wrapperStyle": W, "native": {"kind": "apps"}},
    {"name": "mcp.access", "html": access_step("Claude", "Auto"), "wrapperStyle": W, "native": {"kind": "access"}},
    {"name": "mcp.connect", "html": connect_step(), "wrapperStyle": W, "native": {"kind": "connect"}},
    {"name": "mcp.turn-on", "html": turn_on(), "wrapperStyle": W, "native": {"kind": "turn-on"}},
    {"name": "authorized-clients.mcp", "html": authorized_mcp(), "wrapperStyle": "display:block;width:796px", "native": {"kind": "authorized"}},
]
spec = {"component": "use-in-another-app", "source": "apps/web/src/components/mcp/UseInAnotherAppDialog.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/use-in-another-app.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("use-in-another-app", len(cases), "cases")
