"""Writes design/component-reference/run-on.json for scripts/component-reference: the draft composer's
"Run on" control (BranchToolbarEnvironmentSelector.tsx) as a picker and as a locked label, its select list,
and the context strip it sits in under the composer (ComposerSurface.tsx Shell, Host and ContextStrip).

Class strings come from apps/web/src/components/{BranchToolbarEnvironmentSelector,BranchToolbar,
ComposerContextLabel,EnvironmentMachineIcon}.tsx, chat/{ComposerControl,ComposerSurface}.tsx and ui/select.tsx
at the tag in T3_VERSION. The surface classes are read from ComposerSurface.tsx so they stay exact.
Usage: /usr/bin/python3 -I scripts/gen-run-on-spec.py
"""
import json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = "/Users/mrm/CandyWrapper-research/t3code/apps/web/src/components"
LUCIDE = "/Users/mrm/CandyWrapper-research/downloads/lucide-static-0.564.0/package/icons"

def lucide(name, cls, stroke="2", extra=""):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}"{extra} aria-hidden="true">{inner}</svg>')

def machine(kind, cls):
    if kind == "mac-mini":  # EnvironmentMachineIcon.tsx:26-33, drawn to lucide's grammar
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
                f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="{cls}"><rect width="20" height="8" x="2" y="8" rx="2"></rect><path d="M6 12h.01"></path></svg>')
    return lucide(kind, cls)

# ComposerControl.tsx composerControlClassName, size xs, plus the selector's `min-w-0 max-w-full`.
CONTROL_XS = ("relative inline-flex shrink-0 cursor-pointer items-center justify-center whitespace-nowrap rounded-(--control-radius) border border-transparent text-base outline-none hover:bg-accent data-pressed:bg-accent focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-64 data-disabled:pointer-events-none data-disabled:opacity-64 pointer-coarse:after:absolute pointer-coarse:after:size-full pointer-coarse:after:min-h-11 pointer-coarse:after:min-w-11 [&:active:not([aria-haspopup])]:scale-[0.97] [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg]:-mx-0.5 [&_svg[data-composer-control-icon]]:mx-0 "
              "h-7 gap-1 px-1.75 font-normal text-foreground/70 text-sm hover:text-foreground dark:text-muted-foreground sm:h-6 sm:text-xs [&_svg:not([class*='size-'])]:size-4 sm:[&_svg:not([class*='size-'])]:size-3.5 [&_svg[data-composer-control-chevron]]:ms-0 [&_svg[data-composer-control-chevron]]:-me-1 "
              "aria-pressed:bg-accent aria-pressed:text-accent-foreground aria-pressed:hover:bg-accent/80 min-w-0 max-w-full")
CHEVRON = lucide("chevron-down", "shrink-0 size-3 text-current", stroke="2.25", extra=" data-composer-control-chevron")

def context_label(text):  # ComposerContextLabel.tsx, toolbar mode
    return ('<span data-composer-label class="min-w-0 max-w-[240px] group-data-[compact]/composer-context:max-w-0">'
            '<span data-composer-label-motion class="block w-full min-w-0 truncate max-w-[240px] transition-opacity duration-180 ease-drawer group-data-[compact]/composer-context:opacity-0 motion-reduce:transition-none">'
            f'{text}</span></span>')

def picker(kind, label):
    value = f'<span class="flex-1 truncate data-placeholder:text-placeholder">{label}</span>'
    return (f'<button type="button" role="combobox" aria-haspopup="listbox" aria-label="Run on" class="{CONTROL_XS}">'
            f'{machine(kind, "size-3 shrink-0")}{context_label(value)}</button>')

def locked(kind, label):
    return ('<span class="inline-flex h-7 min-w-0 max-w-full items-center gap-1 border border-transparent px-1.75 font-normal text-foreground/70 text-xs dark:text-muted-foreground sm:h-6">'
            f'{machine(kind, "size-3 shrink-0")}{context_label(label)}</span>')

# ui/select.tsx SelectPopup (alignItemWithTrigger off), SelectGroupLabel and SelectItem.
ITEM = "flex min-h-8 in-data-[side=none]:min-w-[calc(var(--anchor-width)+1.25rem)] cursor-pointer items-center rounded-sm px-2 py-1 text-base outline-none data-selected:bg-foreground/[0.08] data-disabled:pointer-events-none data-disabled:cursor-not-allowed data-highlighted:bg-accent data-highlighted:text-accent-foreground data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='size-'])]:size-4.5 sm:[&_svg:not([class*='size-'])]:size-4 [&_svg]:pointer-events-none [&_svg]:shrink-0"

SELECTED = ' data-selected=""'

def popup(envs, selected):
    text_cls = "min-w-0 flex-1 [&_svg:not([class*='text-'])]:text-muted-foreground"
    items = "".join(
        f'<div role="option" class="{ITEM}"{SELECTED if env == selected else ""}><div class="{text_cls}">'
        f'<span class="inline-flex items-center gap-1.5">{machine(kind, "size-3")}{label}</span></div></div>'
        for env, kind, label in envs)
    return ('<div class="origin-(--transform-origin) rounded-lg text-foreground outline-none" data-side="bottom">'
            '<div class="dropdown-glass relative h-full rounded-lg shadow-[0_16px_40px_-18px_rgb(0_0_0/55%)] dark:shadow-[0_18px_44px_-18px_rgb(0_0_0/80%)] min-w-(--anchor-width)">'
            '<div class="max-h-(--available-height) overflow-y-auto p-1" role="listbox"><div role="group">'
            f'<div class="px-2 py-1.5 font-medium text-muted-foreground text-xs">Run on</div>{items}</div></div></div></div>')

def cn_strings(src, start, end):
    body = src[src.index(start):src.index(end, src.index(start))]
    return " ".join(re.findall(r'"([^"]*)"', body))

surface = subprocess.check_output(["git", "-C", os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(T3)))), "show", "v0.1.4-nightly.20261028.3824:apps/web/src/components/chat/ComposerSurface.tsx"], text=True)
SHELL = cn_strings(surface, '"@container/composer-surface', "className,\n")
OUTLINE = cn_strings(surface, "const outlineClasses", ";\n")
SEAM = ""
HOST = cn_strings(surface, '"relative z-10 w-full rounded-2xl', "className,\n") + " " + OUTLINE + " " + SEAM
STRIP = cn_strings(surface, '"group/composer-context', "className,\n") + " gap-1 text-xs font-normal text-muted-foreground/70"

def strip(kind, label):
    # The draft composer reduced to its surface: an empty 64px host. BranchToolbar.tsx:791-812 without git controls.
    return (f'<div data-slot="composer-shell" data-context-row="true" class="{SHELL}" style="width:600px">'
            f'<div data-slot="composer-host" class="{HOST}"><div class="relative z-10" style="height:64px"></div></div>'
            '<div class="min-h-0"><div class="relative z-0"><div class="pointer-events-auto">'
            f'<div data-slot="composer-context-strip" class="{STRIP}">'
            f'<div class="min-h-7 min-w-10 items-center gap-1 sm:min-h-6 flex shrink">{picker(kind, label)}</div>'
            '<div class="flex min-w-0 flex-1 items-center justify-start overflow-x-clip overflow-y-visible"></div>'
            '</div></div></div></div></div>')

ENVS = [("local", "mac-mini", "This Mac"), ("env2", "server", "sandbox-env2")]
cases = [
    {"name": "trigger.local", "html": picker("mac-mini", "This Mac"), "native": {"kind": "trigger", "selected": "local"}},
    {"name": "trigger.remote", "html": picker("server", "sandbox-env2"), "native": {"kind": "trigger", "selected": "env2"}},
    {"name": "locked.remote", "html": locked("server", "sandbox-env2"), "native": {"kind": "locked", "selected": "env2"}},
    {"name": "popup.remote", "html": popup(ENVS, "env2"), "native": {"kind": "popup", "selected": "env2"}},
    {"name": "strip.remote", "html": strip("server", "sandbox-env2"), "native": {"kind": "strip", "selected": "env2"}},
]
spec = {"sourceVersion": "v0.1.4-nightly.20261028.3824", "component": "run-on", "states": ["rest", "hover"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/run-on.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
