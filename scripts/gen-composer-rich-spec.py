"""Composer rich text states, from ComposerPromptEditorTiptap.tsx:999 and index.css:1775-1860, 2226-2322.
Block cases use the markup Tiptap builds for the draft in "native" (composer-rich-text-doc.ts
`buildTiptapContent`, ListItem renderHTML with data-marker, TaskItem's label and div). The editor
element contains its children's margins, as the real one does with its p-1 padding.
Run scripts/component-reference design/component-reference/composer-rich.json after generation.
"""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def li(marker, text, nested=""):
    return f'<li data-marker="{marker}"><p>{text}</p>{nested}</li>'

def task(checked, text):
    box = '<input type="checkbox"' + (' checked' if checked else '') + '>'
    return f'<li data-checked="{str(checked).lower()}"><label contenteditable="false">{box}<span></span></label><div><p>{text}</p></div></li>'

cases = [
    ("marks", "<p><strong>Bold</strong> and <em>italic</em> and <s>strike</s></p>", "**Bold** and *italic* and ~~strike~~"),
    ("nested", "<p><em>Outer <strong>inner</strong> end</em></p>", "*Outer **inner** end*"),
    ("code", "<p>Use <code>let x = 1</code> here</p>", "Use `let x = 1` here"),
    ("list",
     "<p>Steps</p><ul>" + li("-", "First item") + li("-", "Second item") + "</ul>"
     + "<ol>" + li("1.", "One") + li("2.", "Two") + "</ol><p>after</p>",
     "Steps\n- First item\n- Second item\n1. One\n2. Two\nafter"),
    ("nestedlist",
     "<ul>" + li("-", "Parent", "<ul>" + li("-", "Child", "<ul>" + li("-", "Grandchild") + "</ul>") + "</ul>")
     + li("-", "Next", "<ol>" + li("1.", "Numbered") + "</ol>") + "</ul>",
     "- Parent\n  - Child\n    - Grandchild\n- Next\n  1. Numbered"),
    ("quote",
     "<p>before</p><blockquote><p>Quoted line one</p><p>Quoted line two</p></blockquote><p>after</p>",
     "before\n> Quoted line one\n> Quoted line two\nafter"),
    ("heading",
     "<h1>Heading one</h1><p>Body text</p><h2>Heading two</h2><p>More text</p><h3>Heading three</h3>",
     "# Heading one\nBody text\n## Heading two\nMore text\n### Heading three"),
    ("task",
     '<ul data-type="taskList">' + task(False, "Open task") + task(True, "Done task") + "</ul>",
     "- [ ] Open task\n- [x] Done task"),
]
spec = {"component": "composer-rich", "states": ["rest"], "themes": ["light", "dark"], "cases": [
    {"name": name, "html": '<div class="composer-tiptap text-sm leading-relaxed text-foreground whitespace-pre-wrap" style="width:560px;display:flow-root">' + html + '</div>',
     "native": {"text": text}, "wrapperStyle": "display:block;width:560px"} for name, html, text in cases]}
with open(os.path.join(root, 'design/component-reference/composer-rich.json'), 'w') as f: json.dump(spec, f, indent=2)
