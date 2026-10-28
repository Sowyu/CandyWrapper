"""Writes design/component-reference/settings-pages3.json for scripts/component-reference: the WP7.14 states.
Bitbucket credentials (both methods), a provider's Environment section with two variables, the provider version
popover with Update now, and the accent color popover.

Class strings are copied from apps/web/src/components/settings/{BitbucketCredentialsSettings.tsx, ProviderInstanceCard.tsx,
ProviderAccentColorPicker.tsx}, components/ui/{label,input,button,popover,color-picker}.tsx at v0.1.4-nightly.20261028.3814.
Rows, sections, toggles, buttons and inputs come from the other spec generators.
Usage: /usr/bin/python3 -I scripts/gen-settings-pages3-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(name, stop):
    ns = {"__file__": os.path.join(ROOT, "scripts", name)}
    src = open(os.path.join(ROOT, "scripts", name)).read()
    exec(src[:src.index(stop)], ns)
    return ns


pages = load("gen-settings-pages2-spec.py", "# --- Project: the overview card")
tog = load("gen-toggles-spec.py", "# 3. Switch")
popups = load("gen-popups-spec.py", "specs[\"popover\"]")
lucide, button, row, section, merge = pages["lucide"], pages["button"], pages["row"], pages["section"], pages["merge"]
form_ns = pages["form_ns"]
toggle = tog["toggle"]

LABEL = "inline-flex items-center gap-2 text-base/4.5 sm:text-sm/4 font-medium text-foreground"
INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring "
          "disabled:pointer-events-none disabled:opacity-64 text-foreground")


def text_input(size, placeholder, value="", mono=False, password=False, cls=""):
    html = form_ns["input_html"](size, placeholder, value, mono=mono)
    if password:
        html = html.replace('type="text"', 'type="password"')
    return html.replace('class="', f'class="{cls} ', 1) if cls else html


def segmented(items, pressed):
    html = "".join(toggle("segmented", "segmented", t, i == pressed, icon=False) for i, t in enumerate(items))
    return f'<div data-slot="toggle-group" data-variant="segmented" role="group" class="{tog["G_ALWAYS"]} {tog["G_VARIANT"]["segmented"]}">{html}</div>'


def field(label, control):
    return f'<div class="grid gap-1.5"><label class="{LABEL}">{label}</label>{control}</div>'


# --- Bitbucket (BitbucketCredentialsSettings.tsx:132-222), nothing saved.
def bitbucket(method):
    info = {"access": ("Scoped to one repository, project, or workspace. Create it in that item's Bitbucket settings.", "Learn more"),
            "api": ("Uses your Atlassian account, so it reaches every repository you can. Give it read and write access to repositories and pull requests, and read:user:bitbucket.",
                    "Create an API token")}[method]
    fields = (field("Access token", text_input("sm", "Not set", password=True)) if method == "access" else
              field("Atlassian account email", text_input("sm", "you@example.com")) + field("API token", text_input("sm", "Not set", password=True)))
    save = button("default", "xs", "Save").replace("<button ", "<button disabled ", 1)
    return ('<form class="grid gap-4">' + segmented(["Access token", "API token"], 0 if method == "access" else 1)
            + f'<p class="max-w-2xl text-xs leading-relaxed text-muted-foreground">{info[0]} '
            + f'<a class="{INLINE}">{info[1]}{lucide("external-link", "size-3")}</a></p>' + fields
            + '<div class="flex items-center justify-between gap-3"><p class="text-xs text-muted-foreground">'
            + 'Without a saved token, the server falls back to its T3CODE_BITBUCKET_* environment variables.</p>'
            + f'<div class="flex shrink-0 gap-2">{save}</div></div></form>')


# --- Environment (ProviderInstanceCard.tsx:381-470), one sensitive and one plain variable.
def var_row(index, name, value, sensitive):
    lock = button("ghost-muted", "icon-micro", lucide("lock" if sensitive else "lock-open", "size-3"))
    remove = button("ghost-destructive", "icon-micro", lucide("x", "size-3"))
    value_input = text_input("sm", "value", value, mono=True, password=sensitive, cls="min-w-0 flex-1")
    return ('<div class="flex min-w-0 flex-wrap items-center gap-1.5">'
            + text_input("sm", "VARIABLE_NAME", name, mono=True, cls="w-full min-w-0 sm:w-44 sm:shrink-0")
            + '<span class="hidden text-xs text-muted-foreground sm:inline" aria-hidden="">=</span>'
            + value_input + lock + remove + '</div>')


add = button("outline", "sm", lucide("plus", "size-3") + "Add variable")
children = ('<div class="mt-3 min-w-0 space-y-2 pb-2">' + var_row(1, "OPENAI_BASE_URL", "http://localhost:8080", False)
            + var_row(2, "WP714_FAKE", "fakevalue", True)
            + '<p class="text-xs text-muted-foreground">Sensitive values are stored separately and never returned to the app.</p></div>')
variables = row("Variables", "API keys, base URLs, and other per-instance CLI settings.", add)
variables = variables[:variables.rindex("</div>")] + children + "</div>"
environment = section("Environment", variables)

# --- The version popover (ProviderInstanceCard.tsx:701-801), Update available with the command.
update = button("outline", "xs", lucide("download") + "Update now").replace('class="', 'class="w-full ', 1)
copy = button("ghost-muted", "icon-xs", lucide("copy", "size-3")).replace('class="', 'class="shrink-0 ', 1)
advisory_body = ('<div class="grid min-w-0 gap-3"><div class="grid gap-0.5">'
                 '<p class="text-sm font-semibold leading-tight text-foreground">Update available</p>'
                 '<p class="text-xs leading-snug text-muted-foreground">Install the update now or review provider settings.</p></div>'
                 + update
                 + '<div class="flex items-center gap-2 text-3xs font-medium uppercase tracking-wider text-muted-foreground">'
                 '<span aria-hidden="" class="h-px flex-1 bg-border"></span>or, update manually using<span aria-hidden="" class="h-px flex-1 bg-border"></span></div>'
                 '<div class="flex min-w-0 items-center gap-1 rounded-md border border-border/70 bg-muted/40 py-0.5 pr-0.5 pl-2">'
                 '<code class="min-w-0 flex-1 truncate font-mono text-2xs text-foreground">claude update</code>' + copy + '</div></div>')
advisory = (f'<div class="{popups["P_BASE"]} {popups["P_WIDTH"]["md"]}" data-slot="popover-popup" data-side="bottom">'
            f'<div class="{popups["P_VIEWPORT"]} {popups["P_PAD"]["default"]}" data-slot="popover-viewport">{advisory_body}</div></div>')

# --- Load balancing, open (LoadBalancingSettings.tsx:72-131, FoldedSettingsSection.tsx:72-100, EnvironmentRow.tsx:72-99).
conn = pages["conn"]
FOLD = conn["FOLD"]
select_trigger = popups["select_trigger"]
# select.tsx:33, the `xs` trigger size the other spec generators did not need yet.
popups["S_SIZE"]["xs"] = ("h-7 gap-1 rounded-md px-[calc(--spacing(2)-1px)] text-sm before:rounded-[calc(var(--radius-md)-1px)] sm:h-6 sm:text-xs "
                          "[&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5")


def lb_row(kind, label, subtitle, value):
    trigger = select_trigger("default", "xs", value).replace('class="', 'class="w-32 ', 1)
    return ('<div class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-3 px-3 py-2.5 sm:px-4">'
            + conn["machine"](kind, "size-4 text-muted-foreground")
            + f'<div class="min-w-0"><p class="truncate text-sm font-medium text-foreground">{label}</p>'
            + f'<div class="truncate text-xs text-muted-foreground">{subtitle}</div></div>'
            + f'<div class="flex shrink-0 items-center gap-1">{trigger}</div></div>')


lb_chevron = lucide("chevron-right", "size-4 shrink-0 text-muted-foreground transition-transform duration-150 motion-reduce:transition-none rotate-90")
lb_header = ('<div class="flex items-center gap-4 px-3 sm:px-4"><button type="button" class="flex min-h-11 min-w-0 flex-1 items-center gap-2 py-2 text-left outline-none rounded-md">'
             f'{lb_chevron}<span class="shrink-0 text-sm font-medium">Load balancing</span>'
             '<span class="min-w-0 truncate text-xs text-muted-foreground">Studio prefer</span></button>'
             f'<div class="flex shrink-0 items-center">{pages["switch"]("default", "on", False)}</div></div>')
lb_panel = ('<div class="border-t border-border/50 [&>*+*]:border-t [&>*+*]:border-border/50">'
            '<p class="px-3 py-2.5 text-xs text-muted-foreground sm:px-4">New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine\'s preference.</p>'
            + lb_row("mac-mini", "miniko", "This machine", "Normal") + lb_row("server", "Studio", "192.168.1.20:3773", "Prefer") + "</div>")
load_balancing = f'<section><div class="{FOLD}">{lb_header}{lb_panel}</div></section>'

W764 = "display:block;width:764px"
cases = [
    {"name": "bitbucket.access", "html": bitbucket("access"), "wrapperStyle": W764, "native": {"kind": "bitbucket-access"}},
    {"name": "bitbucket.api", "html": bitbucket("api"), "wrapperStyle": W764, "native": {"kind": "bitbucket-api"}},
    {"name": "provider.environment", "html": environment, "wrapperStyle": "display:block;width:492px", "native": {"kind": "environment"}},
    {"name": "connections.load-balancing", "html": load_balancing, "wrapperStyle": "display:block;width:796px", "native": {"kind": "load-balancing"}},
    {"name": "provider.advisory", "html": advisory, "wrapperStyle": "display:inline-block;--available-height:600px", "native": {"kind": "advisory"}},
]
spec = {"component": "settings-pages3", "source": "apps/web/src/components/settings/ProviderInstanceCard.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/settings-pages3.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("settings-pages3", len(cases), "cases")
