"""Writes design/component-reference/text-generators.json for scripts/component-reference: the 4928 Text generators
section under Settings > Providers (TextGeneratorsSettings.tsx:72-247, PR #33147) empty and with two generators, and the
add wizard's Service grid with OpenAI picked (:362-418). Helpers come from scripts/gen-settings-pages2-spec.py; the marks
come from Icons.tsx.
Usage: /usr/bin/python3 -I scripts/gen-text-generators-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-settings-pages2-spec.py")).read()
exec(src[:src.index("W796 = ")], ns)
lucide, button, section, tsx_icon, row, switch = ns["lucide"], ns["button"], ns["section"], ns["tsx_icon"], ns["row"], ns["switch"]

ICON_WRAP = "relative isolate z-30 inline-flex shrink-0 items-center justify-center overflow-visible"


def mark(icon):
    """`ProviderInstanceIcon` with `badgeContent="none"`: the mark at `size-5` in the current color."""
    return f'<span class="{ICON_WRAP}">{tsx_icon(icon, "size-5 shrink-0")}</span>'


def generator_row(name, icon, detail):
    title = f'<span class="inline-flex items-center gap-2.5">{mark(icon)}{name}</span>'
    desc = f'<p class="max-w-2xl text-pretty text-xs leading-normal text-muted-foreground"><span class="block truncate ps-7.5">{detail}</span></p>'
    more = button("ghost-muted", "icon-sm", lucide("ellipsis-vertical", ""))
    control = f'<div class="flex items-center gap-2">{more}{switch("default", "on" if not detail.startswith("Off") else "off", False)}</div>'
    return row(name, "", control, desc_html=desc, title_html=title)


ADD = button("outline", "xs", lucide("plus", "size-3") + "Add generator")
empty = section("Text generators", row("No text generators yet",
                "Add a model API to write thread titles, commit messages, and other short text without starting a coding agent.", ""), action=ADD)
listed = section("Text generators", generator_row("OpenRouter", "OpenRouterIcon", "openrouter.ai/api/v1")
                 + generator_row("localhost:11434", "OllamaIcon", "Off · localhost:11434/v1"), action=ADD)

CARD_ON = ("flex flex-col items-center gap-2 rounded-lg border border-primary bg-primary/5 px-2 py-3 text-sm font-medium text-foreground "
           "ring-1 ring-primary ring-inset outline-none focus-visible:ring-2 focus-visible:ring-inset")
CARD_OFF = ("flex flex-col items-center gap-2 rounded-lg border bg-background px-2 py-3 text-sm text-muted-foreground outline-none "
            "hover:bg-accent/50 hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset")


def service_grid():
    cards = [("OpenAI", mark("OpenAI"), True), ("OpenRouter", mark("OpenRouterIcon"), False),
             ("Anthropic", mark("AnthropicIcon"), False), ("Custom", lucide("server", "size-5"), False)]
    inner = "".join(f'<button type="button" role="radio" aria-checked="{str(on).lower()}" class="{CARD_ON if on else CARD_OFF}">{icon}{label}</button>'
                    for label, icon, on in cards)
    return ('<div class="grid gap-1.5"><span class="text-sm font-medium">Service</span>'
            f'<div role="radiogroup" aria-label="Service" class="grid grid-cols-2 gap-2 sm:grid-cols-4">{inner}</div></div>')


W796 = "display:block;width:796px"
cases = [
    {"name": "text-generators.empty", "html": empty, "wrapperStyle": W796, "native": {"kind": "empty"}},
    {"name": "text-generators.rows", "html": listed, "wrapperStyle": W796, "native": {"kind": "rows"}},
    {"name": "text-generators.service", "html": service_grid(), "wrapperStyle": "display:block;width:526px", "native": {"kind": "service"}},
]
spec = {"component": "text-generators", "source": "apps/web/src/components/settings/TextGeneratorsSettings.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/text-generators.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("text-generators", len(cases), "cases")
