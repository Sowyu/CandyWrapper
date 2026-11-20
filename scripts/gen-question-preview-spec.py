"""Writes design/component-reference/question-option-preview.json for scripts/component-reference: the Markdown under a
question option (4928 ComposerPendingUserInputPanel.tsx:334-340, #34784). ChatMarkdown with `lineBreaks` and
`className="ps-9 pe-2 pb-1.5 text-xs text-foreground/70 sm:ps-8"`, which tailwind-merge folds into the root
classes: `text-xs` drops `text-sm` and `leading-relaxed`, `text-foreground/70` drops the 90% color. The padding is
the panel's layout, so the reference leaves it out. Markup as react-markdown with remark-breaks renders it.
Usage: /usr/bin/python3 -I scripts/gen-question-preview-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT_CLASS = "chat-markdown w-full min-w-0 [overflow-wrap:anywhere] [word-break:break-word] text-xs text-foreground/70"

CASES = []
def case(name, markdown, body, width=320):
    CASES.append({"name": name, "html": f'<div class="{ROOT_CLASS}">{body}</div>',
                  "wrapperStyle": f"display:block;width:{width}px;--font-size-code:13px",
                  "native": {"markdown": markdown, "width": str(width)}})

case("plain", "Title: Login fails\nBody: A quote in the password breaks login.",
     "<p>Title: Login fails<br>\nBody: A quote in the password breaks login.</p>")
# Inline code is left out: T3 sizes it 0.85em, and the chip keeps the 14px body's 11.9 here.
case("styled", "Uses **bold** and *italic* text.\nSecond line keeps its break.\n\n- First step\n- Second step",
     "<p>Uses <strong>bold</strong> and <em>italic</em> text.<br>\nSecond line keeps its break.</p>\n"
     "<ul>\n<li>First step</li>\n<li>Second step</li>\n</ul>")

spec = {"component": "question-option-preview", "source": "apps/web/src/components/chat/ComposerPendingUserInputPanel.tsx, ChatMarkdown.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/question-option-preview.json"), "w") as f:
    json.dump(spec, f, indent=1)
print("question-option-preview", len(CASES), "cases")
