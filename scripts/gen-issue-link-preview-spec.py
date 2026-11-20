"""Writes design/component-reference/issue-link-preview.json for scripts/component-reference: the card an issue link
in chat shows on hover (4928 IssueLinkPreview.tsx `IssueLinkPreview` and `IssuePreviewCardBody`, #38294) on
ui/preview-card.tsx's popup with `w-80` and `p-3`. The state glyph and tone follow issuePresentation.tsx (open wears
the open pull request's green and `circle-dot`). Data matches fixtures/issues/detail.json, opened 9 days before
2026-11-19T09:00Z.
Usage: /usr/bin/python3 -I scripts/gen-issue-link-preview-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "scripts/gen-run-on-spec.py")).read()
g = {"__file__": os.path.join(ROOT, "scripts/gen-run-on-spec.py")}
exec(src[:src.index("ENVS = [")], g)
lucide = g["lucide"]

OPEN = "text-emerald-600 dark:text-emerald-300/90"
POPUP = ("origin-(--transform-origin) rounded-lg border bg-popover text-popover-foreground shadow-lg outline-none "
         "w-80 max-w-[calc(100vw-2rem)]")
avatar = ('<span aria-hidden class="flex size-4 shrink-0 items-center justify-center rounded-full bg-muted text-3xs font-medium '
          'text-muted-foreground size-4">O</span>')
html = (f'<div class="{POPUP}" data-slot="preview-card-popup"><div class="p-3"><div class="min-w-0">'
        '<div class="flex min-w-0 items-center gap-1.5 text-2xs text-muted-foreground"><span class="min-w-0 truncate">acme/demo-repo</span>'
        '<span class="shrink-0">#42</span><span aria-hidden>·</span><span class="inline-flex shrink-0 items-center gap-1">'
        f'{lucide("circle-dot", "size-3 " + OPEN)}Open</span></div>'
        '<p class="mt-1 text-sm font-medium leading-snug text-foreground text-pretty">Sidebar badge opens the wrong panel</p>'
        f'<div class="mt-2 flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">{avatar}'
        '<span class="min-w-0 truncate">Octo Reader (@octo-reader)</span><span aria-hidden>·</span>'
        '<span class="shrink-0">opened 9d ago</span></div></div></div></div>')

cases = [{"name": "open", "html": html, "native": {"case": "open"}, "wrapperStyle": "display:inline-block"}]
spec = {"component": "issue-link-preview", "source": "apps/web/src/components/issue/IssueLinkPreview.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/issue-link-preview.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
