"""Writes design/component-reference/settings-pages2.json for scripts/component-reference: the WP7.7b pages.
Settings > Project (the overview card and the Actions section), Settings > Source Control (Repositories and the
Version Control discovery rows) and Settings > Providers (the instance list).

Class strings are copied from apps/web/src/components/settings/{ProjectSettingsPanel.tsx, ProjectActionsSettings.tsx,
ProjectActionsList.tsx, ProjectDefaultsSettings.tsx, SourceControlSettings.tsx, ProviderSettingsPanel.tsx,
ProviderInstanceCard.tsx, settingsLayout.tsx}, components/chat/ProviderInstanceIcon.tsx and components/Icons.tsx at the
tag in T3_VERSION. Rows, sections, switches and selects come from gen-settings-spec.py and gen-connections-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-settings-pages2-spec.py [t3code checkout]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = sys.argv[1] if len(sys.argv) > 1 else "/Users/mrm/CandyWrapper-research/t3code"

ns = {"__file__": os.path.join(ROOT, "scripts/gen-settings-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-settings-spec.py")).read()
exec(src[:src.index("behavior = section(")], ns)
lucide, button, merge, conn, pop = ns["lucide"], ns["button"], ns["merge"], ns["conn"], ns["pop"]
switch, row, select, SPAN, LAYERS, GROUP, ROW = ns["switch"], ns["row"], ns["select"], ns["SPAN"], ns["LAYERS"], ns["GROUP"], ns["ROW"]
form_ns = conn["form_ns"]
section = conn["section"]
exec(open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read().split("cases = [{\"name\": f\"{v}.default\"")[0].split("def svg(")[0], form_ns)
fsrc = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
exec(fsrc[fsrc.index("BADGE = "):fsrc.index("cases = [{\"name\": f\"{v}.default\"")], form_ns)
i = fsrc.index("INPUT_INNER = {")
exec(fsrc[i:fsrc.index("cases", i)], form_ns)
ICONS = open(os.path.join(T3, "apps/web/src/components/Icons.tsx")).read()


def tsx_icon(name, cls):
    """An `Icon` from Icons.tsx as HTML: props spread dropped, `cn(base, className)` merged, camelCase attributes kebab-cased."""
    start = ICONS.index(f"export const {name}: Icon")
    svg = ICONS[ICONS.index("<svg", start):ICONS.index("</svg>", start) + 6]
    svg = svg.replace("{...props}", "")
    m = re.search(r'className=\{cn\("([^"]*)", className\)\}', svg)
    base = m.group(1) if m else ""
    svg = re.sub(r'className=\{cn\("([^"]*)", className\)\}', "", svg)
    svg = re.sub(r"\s+", " ", svg).replace(" >", ">")
    for camel, kebab in (("fillRule", "fill-rule"), ("clipRule", "clip-rule"), ("preserveAspectRatio", "preserveAspectRatio")):
        svg = svg.replace(camel + "=", kebab + "=")
    return svg.replace("<svg", f'<svg xmlns="http://www.w3.org/2000/svg" class="{merge((base + " " + cls).strip())}" aria-hidden="true"', 1)


def badge(text, variant="warning"):
    b = form_ns
    return f'<span class="{b["BADGE_BASE_NO_RADIUS"]} {b["BADGE_SIZES"]["sm"]} {b["BADGE_VARIANTS"][variant]}" data-slot="badge">{text}</span>'


def server_row(title, desc, control, reset=""):
    """SettingsRow with the inheritance indicator and a reset span."""
    return (f'<div data-slot="settings-row" class="{ROW}"><div class="flex flex-col gap-3 @min-[32rem]/settings-row:grid '
            '@min-[32rem]/settings-row:grid-cols-[minmax(0,1fr)_minmax(10rem,auto)] @min-[32rem]/settings-row:items-center @min-[32rem]/settings-row:gap-8">'
            f'<div class="min-w-0 flex-1 space-y-1"><div class="flex min-h-5 items-center gap-1.5"><h3 class="text-sm font-medium text-foreground">{title}</h3>'
            f'{SPAN.format(LAYERS)}{SPAN.format(reset)}</div>'
            f'<p class="max-w-xl text-xs leading-normal text-muted-foreground/80">{desc}</p></div>'
            f'<div class="flex w-full min-w-0 shrink-0 items-center gap-2 @min-[32rem]/settings-row:w-auto @min-[32rem]/settings-row:justify-end">{control}</div></div></div>')


def sm_input(value, width_cls):
    html = form_ns["input_html"]("sm", "", value)
    return html.replace('class="', f'class="{width_cls} ', 1)


# --- Project: the overview card (ProjectSettingsPanel.tsx:461-540), favicon left out of both sides.
choose = button("outline", "sm", "Choose icon") + button("outline", "sm", "Choose file")
overview = (f'<section class=""><h2 class="sr-only">Project</h2><div class="{GROUP}" data-settings-scroll-target="">'
            + row("Name", "The shared name for this project group in the sidebar and thread lists.", sm_input("git-demo", "w-full sm:w-64"))
            + row("Project icon", "Automatic", f'<div class="flex items-center gap-2">{choose}</div>')
            + "</div></section>")

# --- Project: Actions (ProjectActionsSettings.tsx:139-212, ProjectActionsList.tsx).
ADD_ACTION = button("outline", "xs", lucide("plus", "size-3.5") + "Add action")
ROLE = "shrink-0 rounded-sm border border-border/60 px-1.5 py-px text-2xs font-normal text-muted-foreground"
action_title = (f'<span class="flex min-w-0 items-center gap-2">{lucide("list-checks", "size-4 shrink-0 text-muted-foreground")}'
                f'<span class="min-w-0 truncate">Lint</span><span class="{ROLE}">setup</span></span>')
action_control = ('<span class="text-xs text-muted-foreground">⇧⌘L</span><span class="flex shrink-0 opacity-0 group-focus-within:opacity-100 group-hover:opacity-100">'
                  + button("ghost-muted", "icon-xs", lucide("settings", "size-3.5")) + "</span>")
action_row = row("", "", action_control, title_html=action_title,
                 desc_html='<p class="max-w-xl text-xs leading-normal text-muted-foreground/80"><code class="block max-w-full truncate font-mono">bun run lint</code></p>')
action_row = action_row.replace(f'class="{ROW}"', f'class="{ROW.replace(" py-3", "")} group py-2"', 1)
actions = section("Actions", server_row("Actions", "Commands that run in this project's checkout or its worktree, with optional shortcuts.",
                                        f'<div class="flex flex-wrap items-center gap-1.5">{ADD_ACTION}</div>') + action_row)

# --- Source Control: Repositories (ProjectDefaultsSettings.tsx:408-520).
repositories = section("Repositories", "".join([
    server_row("Automatically pull", "Keeps the default branch current when the checkout has no local changes or commits. Projects can override it.",
               switch("default", "off", False)),
    server_row("Remove agent credits when merging",
               "Remove recognized agent credit lines from merge and squash messages on hosts that support it, keeping human co-authors. Includes auto-merge. Excludes merge queues, stack merges, and existing commits.",
               switch("default", "off", False)),
    server_row("Default merge method", "Pull requests start with this method. Last selected reuses whatever you chose most recently on this device.",
               pop["select_trigger"]("default", "sm", "Last selected")),
]))

# --- Source Control: discovery rows (SourceControlSettings.tsx:259-361).
DOT_RING = "pointer-events-none absolute -left-0.5 -top-0.5 size-2 rounded-full ring-2 ring-background"


def discovery_row(label, version, summary, icon, dot, chevron, switch_on, coming=False):
    mark = (f'<span class="relative inline-flex size-5 shrink-0 items-center justify-center">{icon}<span class="{DOT_RING} {dot}" aria-hidden=""></span></span>'
            if icon else f'<span class="size-2 shrink-0 rounded-full {dot}" aria-hidden=""></span>')
    ver = f'<code class="text-xs text-muted-foreground">{version}</code>' if version else ""
    controls = (button("ghost-muted", "icon-xs", lucide("chevron-down", "size-3.5 transition-transform")) if chevron else "") + \
        ("" if coming else switch("default", "on" if switch_on else "off", True))
    return (f'<div class="first:rounded-t-xl last:rounded-b-xl transition-colors hover:bg-muted/20{" opacity-80" if coming else ""}"><div class="px-3 py-3 sm:px-4">'
            '<div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"><div class="min-w-0 flex-1 space-y-1">'
            f'<div class="flex min-w-0 flex-wrap items-center gap-2">{mark}<span class="truncate text-sm font-medium text-foreground">{label}</span>{ver}'
            f'{badge("Coming Soon") if coming else ""}</div>'
            f'<p class="flex min-w-0 flex-wrap items-center gap-x-1 text-xs leading-normal text-muted-foreground/80"><span>{summary}</span></p></div>'
            f'<div class="flex w-full shrink-0 items-center gap-2 sm:w-auto sm:justify-end">{controls}</div></div></div></div>')


scan = button("ghost-muted", "icon-xs", lucide("refresh-cw"))
vcs = section("Version Control", discovery_row("Git", "git version 2.54.0 (Apple Git-157)", "Available", tsx_icon("GitIcon", "size-4.5 text-foreground/80"),
                                              "bg-success", True, True)
              + discovery_row("Jujutsu", None, "Support for Jujutsu is coming soon.", None, "bg-muted-foreground/35", False, False, coming=True),
              action=scan)

# --- Providers: the instance list (ProviderSettingsPanel.tsx:1185-1205, ProviderInstanceCard.tsx:909-975).
ICON_WRAP = "relative isolate z-30 inline-flex shrink-0 items-center justify-center overflow-visible size-5"


def provider_row(name, icon, version, status, dot=None, selected=False):
    ver = f'<code class="max-w-24 shrink-0 truncate text-xs text-muted-foreground">{version}</code>' if version else ""
    dot_html = (f'<span class="flex h-[1.45em] shrink-0 items-center"><span class="size-1.5 shrink-0 rounded-full {dot}" aria-hidden=""></span></span>'
                if dot else "")
    return (f'<div data-slot="settings-row" class="group flex min-h-18 items-center gap-3 px-3 py-3 transition-colors sm:px-4 {"bg-muted/45" if selected else "hover:bg-muted/25"}">'
            '<div class="pointer-events-none relative flex min-w-0 flex-1 items-start gap-3 rounded-md text-left transition-opacity">'
            f'<span class="{ICON_WRAP}">{icon}</span><span class="min-w-0 flex-1"><span class="flex min-w-0 items-center gap-2">'
            f'<span class="truncate text-sm font-medium text-foreground">{name}</span>{ver}</span>'
            f'<span class="mt-0.5 flex items-start gap-1.5 text-xs leading-normal text-muted-foreground/80">{dot_html}'
            f'<span class="pointer-events-auto line-clamp-2 [overflow-wrap:anywhere]">{status}</span></span></span></div>'
            f'<span class="flex h-5 shrink-0 items-center">{switch("default", "on", False)}</span></div>')


ADD_ROW = ('<button type="button" class="flex w-full cursor-pointer items-center gap-3 px-3 py-3 text-left text-sm text-muted-foreground transition-colors '
           'outline-none hover:bg-muted/25 hover:text-foreground focus-visible:bg-muted/25 focus-visible:text-foreground sm:px-4">'
           f'{lucide("plus", "size-4 shrink-0")}Add provider</button>')
providers = ('<div class="border-b border-border/60 bg-muted/10"><div class="divide-y divide-border/50">'
             + provider_row("Codex", tsx_icon("OpenAI", "size-5 shrink-0 size-4 text-foreground/80"), None,
                            "Not found · Could not start Codex CLI (`codex`). Check Settings → Providers → Codex → Binary path on the server.", dot="bg-destructive")
             + provider_row("Claude", tsx_icon("ClaudeAI", "size-5 shrink-0 size-4 text-foreground/80"), "v2.1.295",
                            "Authenticated · Claude Max Subscription", selected=True)
             + ADD_ROW + "</div></div>")

W796 = "display:block;width:796px"
cases = [
    {"name": "project.overview", "html": overview, "wrapperStyle": W796, "native": {"kind": "overview"}},
    {"name": "project.actions", "html": actions, "wrapperStyle": W796, "native": {"kind": "actions"}},
    {"name": "source-control.repositories", "html": repositories, "wrapperStyle": W796, "native": {"kind": "repositories"}},
    {"name": "source-control.vcs", "html": vcs, "wrapperStyle": W796, "native": {"kind": "vcs"}},
    {"name": "providers.list", "html": providers, "wrapperStyle": "display:block;width:272px", "native": {"kind": "providers"}},
]
spec = {"component": "settings-pages2", "source": "apps/web/src/components/settings/ProjectSettingsPanel.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/settings-pages2.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("settings-pages2", len(cases), "cases")
