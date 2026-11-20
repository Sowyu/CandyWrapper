"""Writes design/component-reference/device-sources.json for scripts/component-reference: the 4928 Device sources section
under Settings > Devices (DeviceSourcesSettings.tsx:157-876) with Local simulators (iOS available, Android not) and an SSH
host that cannot connect, with Retry, Edit and the ⋯ menu. Helpers come from scripts/gen-settings-pages2-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-device-sources-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, button, section, tsx_icon = ns["lucide"], ns["button"], ns["section"], ns["tsx_icon"]

INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring "
          "disabled:pointer-events-none disabled:opacity-64 text-foreground")


def platform(icon, available, ios):
    tone = "text-foreground" if available else "text-muted-foreground/45"
    return (f'<button type="button" class="relative grid size-6 shrink-0 place-items-center rounded-md outline-hidden {tone}">'
            f'{tsx_icon(icon, "size-3.5" + (" -translate-y-px" if ios else ""))}</button>')


def source_row(title, kind, description, problem=None, action=None, platforms="", actions=""):
    badge = (f'<span class="shrink-0 rounded border border-border px-1 text-3xs uppercase tracking-wide text-muted-foreground">{kind}</span>'
             if kind else "")
    issue = ""
    if problem:
        retry = f'<button type="button" class="{INLINE}">{action}</button>' if action else ""
        issue = (f'<p role="status" class="mt-1 flex flex-wrap items-center gap-1.5 text-xs text-destructive">'
                 f'<span class="min-w-0 break-words">{problem}</span>{retry}</p>')
    acts = f'<div class="flex shrink-0 items-center gap-1">{actions}</div>' if actions else ""
    return ('<div class="flex items-center gap-3 border-t border-border/60 px-3 py-3 first:border-t-0 sm:px-4"><div class="min-w-0 flex-1">'
            f'<div class="flex min-w-0 items-center gap-1.5"><p class="truncate text-sm font-medium">{title}</p>{badge}</div>'
            f'<p class="truncate text-xs text-muted-foreground">{description}</p>{issue}</div>'
            f'<div class="flex shrink-0 items-center gap-0.5">{platforms}</div>{acts}</div>')


ADD = button("outline", "sm", lucide("plus", "size-3.5") + " Add source" + lucide("chevron-down", "size-3.5"))
ACTIONS = button("outline", "sm", "Edit") + button("ghost-muted", "icon-sm", lucide("ellipsis-vertical", ""))
rows = (source_row("Local simulators", None, "Simulators and emulators installed on this environment's machine.",
                   platforms=platform("AppleIcon", True, True) + platform("AndroidIcon", False, False))
        + source_row("Studio", "SSH", "me@studio.local", problem="ssh: connect refused", action="Retry",
                     platforms=platform("AppleIcon", True, True), actions=ACTIONS))
html = section("Device sources", rows, action=ADD)
cases = [{"name": "device-sources.rows", "html": html, "wrapperStyle": "display:block;width:796px", "native": {"kind": "rows"}}]
spec = {"component": "device-sources", "source": "apps/web/src/components/settings/DeviceSourcesSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/device-sources.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("device-sources", len(cases), "cases")
