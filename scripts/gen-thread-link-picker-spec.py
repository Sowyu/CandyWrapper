"""Writes design/component-reference/thread-link-picker.json for scripts/component-reference: the dialog that links a
pull request or an issue to a thread from their pages (4928 ThreadLinkPicker.tsx:13-87 in PullRequestThreadLinks.tsx:
205-224 and IssueThreadLinks.tsx). A `DialogPopup className="max-w-md" showCloseButton={false}` around `Command` with
`CommandInput` and `CommandList className="max-h-80 overflow-y-auto"`. The input markup comes from the command
palette generator; CommandItem and AutocompleteItem classes are copied from ui/command.tsx:190-205 and
ui/autocomplete.tsx:123-131. Threads match the sandbox fixtures. The first row is highlighted (`autoHighlight`).
Usage: /usr/bin/python3 -I scripts/gen-thread-link-picker-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "scripts/gen-command-palette-spec.py")).read()
g = {"__file__": os.path.join(ROOT, "scripts/gen-command-palette-spec.py")}
exec(src[:src.index("cases = [")], g)
lucide, input_row = g["lucide"], g["input_row"]

dialog = json.load(open(os.path.join(ROOT, "design/component-reference/dialog.json")))
html0 = next(c["html"] for c in dialog["cases"] if c["name"] == "default")
POPUP = html0[html0.index('class="') + 7:html0.index('"', html0.index('class="') + 7)].replace("max-w-lg", "max-w-md")

ITEM = ("flex min-h-8 cursor-default select-none items-center gap-2 rounded-sm px-2 py-1 text-base outline-none hover:bg-accent "
        "data-disabled:pointer-events-none data-selected:bg-accent/50 data-selected:text-foreground data-highlighted:bg-accent "
        "data-highlighted:text-accent-foreground [&[data-highlighted][data-selected]]:bg-accent [&[data-highlighted][data-selected]]:text-accent-foreground "
        "data-disabled:opacity-64 sm:min-h-7 sm:text-sm [&_svg:not([class*='text-'])]:text-muted-foreground "
        "py-1.5 data-selected:bg-foreground/[0.06] data-highlighted:bg-foreground/[0.09] data-highlighted:text-foreground "
        "[&[data-highlighted][data-selected]]:bg-foreground/[0.09] [&[data-highlighted][data-selected]]:text-foreground")

def item(title, project, highlighted=False, linked=False):
    attrs = (" data-highlighted" if highlighted else "") + (' data-disabled aria-disabled="true"' if linked else "")
    tail = (lucide("check", "size-3.5") + '<span class="text-xs text-muted-foreground">Linked</span>') if linked else ""
    return (f'<div role="option" data-slot="command-item" class="{ITEM}"{attrs}>{lucide("message-square", "size-4 shrink-0")}'
            f'<span class="flex min-w-0 flex-1 flex-col"><span class="truncate">{title}</span>'
            f'<span class="truncate text-xs text-muted-foreground">{project}</span></span>{tail}</div>')

def picker(body, empty=False):
    lst = (f'<div class="flex flex-col" data-slot="scroll-area"><div role="listbox" data-slot="command-list" '
           f'class="{"" if empty else "scroll-py-2 p-2 "}max-h-80 overflow-y-auto">{body}</div></div>')
    return (f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">'
            f'{input_row("Search threads or projects...", "", False)}{lst}</div>')

cases = [
    {"name": "rows", "html": picker(item("Reply with markdown only", "demo-repo", highlighted=True)
                                     + item("Plan a migration", "git-demo", linked=True)
                                     + item("Add notes and docstring", "demo-repo")), "native": {"case": "rows"}},
    {"name": "empty", "html": picker('<div class="px-3 py-6 text-center text-sm text-muted-foreground">No active threads found.</div>', empty=True),
     "native": {"case": "empty"}},
]
spec = {"component": "thread-link-picker", "source": "apps/web/src/components/ThreadLinkPicker.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": [dict(c, wrapperStyle="display:grid;width:448px") for c in cases]}
with open(os.path.join(ROOT, "design/component-reference/thread-link-picker.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
