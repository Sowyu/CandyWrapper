"""Writes design/component-reference/model-chip-popover.json for scripts/component-reference: the popover a model chip in
a sent message opens (4928 chat/ModelMentionChip.tsx:100-125 inside ContextChipPopover, contextChipParts.tsx:96-99):
`PopoverPopup side="top" width="lg" padding="compact"` around `space-y-1 p-2 text-sm` with the model in medium, its
provider muted and the source in `font-mono text-xs`. The `sr-only` PopoverTitle draws nothing. Popover classes come
from gen-popups-spec.py, as the citation comment popover's do (gen-timeline-gaps-spec.py).
Usage: /usr/bin/python3 -I scripts/gen-model-chip-popover-spec.py
"""
import html, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(ROOT, "scripts", "gen-popups-spec.py")
src = open(path).read()
pp = {"__file__": path}
exec(src[:src.index("def popover(")], pp)
P_BASE, P_VIEWPORT, P_PAD = pp["P_BASE"], pp["P_VIEWPORT"], pp["P_PAD"]
# ui/popover.tsx:23 `lg: "w-96"`, with the `max-w` every sized popup gets.
P_WIDTH = {"lg": "max-w-[calc(100vw-2rem)] w-96"}

def popover(label, provider, source):
    return (f'<div class="{P_BASE} {P_WIDTH["lg"]}" data-slot="popover-popup" data-side="top">'
            f'<div class="{P_VIEWPORT} {P_PAD["compact"]} not-data-transitioning:overflow-y-auto" data-slot="popover-viewport">'
            f'<h2 class="sr-only" data-slot="popover-title">Model {html.escape(label)}</h2>'
            '<div class="space-y-1 p-2 text-sm">'
            f'<p class="font-medium">{html.escape(label)}</p>'
            f'<p class="text-muted-foreground">{html.escape(provider)}</p>'
            f'<p class="font-mono text-xs text-muted-foreground">{html.escape(source)}</p>'
            '</div></div></div>')

WRAP = "display:inline-block;--available-height:600px;margin-bottom:64px"
cases = [
    {"name": "claude", "html": popover("Claude Haiku 5.5", "Claude", "@claudeAgent/claude-haiku-5-5"), "wrapperStyle": WRAP,
     "native": {"label": "Claude Haiku 5.5", "provider": "Claude", "source": "@claudeAgent/claude-haiku-5-5"}},
    {"name": "long", "html": popover("GPT-6 Astra (high reasoning, long context)", "Codex Work Account",
                                     "@codex_work/gpt-6-astra-high-reasoning-long-context-preview"), "wrapperStyle": WRAP,
     "native": {"label": "GPT-6 Astra (high reasoning, long context)", "provider": "Codex Work Account",
                "source": "@codex_work/gpt-6-astra-high-reasoning-long-context-preview"}},
]
spec = {"component": "model-chip-popover", "source": "apps/web/src/components/chat/ModelMentionChip.tsx, contextChipParts.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/model-chip-popover.json"), "w") as f:
    json.dump(spec, f, indent=1)
print("model-chip-popover", len(cases), "cases")
