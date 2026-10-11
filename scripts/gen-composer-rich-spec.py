"""Composer rich text states, from ComposerPromptEditorTiptap.tsx:999 and index.css:2226-2254.
Run scripts/component-reference design/component-reference/composer-rich.json after generation.
"""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cases = [
    ("marks", "<p><strong>Bold</strong> and <em>italic</em> and <s>strike</s></p>", "**Bold** and *italic* and ~~strike~~"),
    ("nested", "<p><em>Outer <strong>inner</strong> end</em></p>", "*Outer **inner** end*"),
    ("code", "<p>Use <code>let x = 1</code> here</p>", "Use `let x = 1` here"),
]
spec = {"component": "composer-rich", "states": ["rest"], "themes": ["light", "dark"], "cases": [
    {"name": name, "html": '<div class="composer-tiptap text-sm leading-relaxed text-foreground whitespace-pre-wrap" style="width:560px">' + html + '</div>',
     "native": {"text": text}, "wrapperStyle": "display:block;width:560px"} for name, html, text in cases]}
with open(os.path.join(root, 'design/component-reference/composer-rich.json'), 'w') as f: json.dump(spec, f, indent=2)
