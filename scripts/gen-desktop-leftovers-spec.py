# Reference stylesheet and component primitives: T3 Nightly 3814.
"""WP7.16 references from toast.tsx:731-740, wizard.tsx:88-143, WelcomeWizard.tsx:350-377.
Run scripts/component-reference design/component-reference/desktop-leftovers.json after this script.
"""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cases = []
for text, name in [("Copied!", "copied"), ("Failed to copy", "copy-failed")]:
    cases.append({"name": name, "native": {"kind": "copy", "text": text}, "html": '<div class="dropdown-glass relative overflow-visible text-balance text-popover-foreground text-xs shadow-xl shadow-black/25 rounded-md"><div class="pointer-events-auto px-2 py-1">'+text+'</div></div>'})
for current in range(3):
    steps = []
    for i, label in enumerate(["Connect", "Agents", "Projects"]):
        look = "bg-card text-foreground shadow-xs ring-1 ring-black/5 dark:shadow-none dark:ring-white/5" if i == current else ""
        disc = "bg-primary text-primary-foreground ring-primary" if i < current else "bg-primary/10 text-primary ring-primary/30" if i == current else "bg-card text-muted-foreground ring-black/10 dark:bg-white/5 dark:ring-white/10"
        mark = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="size-4"><path d="m20 6-11 11-5-5"/></svg>' if i < current else str(i+1)
        steps.append(f'<li class="min-w-0"><div class="flex w-full min-w-0 items-center gap-2 rounded-lg px-2.5 py-2 text-left {look}"><span class="grid size-5 shrink-0 place-items-center rounded-full text-sm font-medium ring-1 {disc}">{mark}</span><span class="min-w-0 truncate text-sm font-medium {"text-foreground" if i == current else "text-muted-foreground"}">{label}</span></div></li>')
    cases.append({"name": f"progress-{current}", "native": {"kind":"progress", "step": str(current)}, "html": '<ol style="width:528px" class="grid auto-cols-fr grid-flow-col gap-1 rounded-xl bg-zinc-25 p-1 ring-1 ring-black/5 dark:bg-white/4 dark:ring-white/5">'+''.join(steps)+'</ol>'})
spec={"component":"desktop-leftovers", "source":"toast.tsx:731-740; ui/wizard.tsx:88-143", "themes":["light","dark"],"states":["rest"],"cases":cases}
with open(os.path.join(root,"design/component-reference/desktop-leftovers.json"),"w") as f: json.dump(spec,f,indent=2)
