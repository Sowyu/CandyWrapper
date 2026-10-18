"""Writes design/component-reference/markdown.json, the ChatMarkdown cases for scripts/component-reference.

Each case pairs a markdown source (`native.markdown`, what MarkdownView renders) with the DOM that
T3's ChatMarkdown renders for it: react-markdown's tags plus the component overrides and class strings
in apps/web/src/components/ChatMarkdown.tsx at the tag in T3_VERSION (code block frame, alerts, table
container, image slot, task list inputs). Code blocks are highlighted in the page by T3's own bundled
Shiki (getSharedHighlighter from the installed client's diffRendering chunk, pierre-light and
pierre-dark), through the spec's `prepare` hook, so the token colors are T3's.

Deviations from T3, on both sides of the comparison:
- Code block titles show the pierre icon of a file in the block's language, or the language's name
  when no specific icon exists (MarkdownCodeBlockTitleContent, ChatMarkdown.tsx:801-840).
- Links point at `#fragments`, so T3 draws no favicon (external links get a fetched favicon).
- The image is the loading slot, which is what MarkdownView draws for every image for now.
- `--font-size-code` is set to 13px, the default that T3 writes on the root at runtime (appearanceFonts.ts).

Usage: /usr/bin/python3 -I scripts/gen-markdown-spec.py
Needs the installed T3 app (for its client assets) and lucide-static (for icon markup).
"""
import glob, html, json, os, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or os.path.join(os.path.dirname(ROOT), "CandyWrapper-research")
ASAR = os.path.join(RESEARCH, "apps/T3 Code (Nightly).app/Contents/Resources/app.asar")
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")
ASSETS = os.path.join(RESEARCH, "t3-client-assets")  # outside the repo, re-extracted when missing

def extract_assets():
    """Unpacks apps/server/dist/client/assets from app.asar (header JSON, then file bytes)."""
    if glob.glob(os.path.join(ASSETS, "diffRendering-*.js")):
        return
    with open(ASAR, "rb") as f:
        _, header_size, _, json_len = struct.unpack("<4I", f.read(16))
        node = json.loads(f.read(json_len))
        for key in ["apps", "server", "dist", "client", "assets"]:
            node = node["files"][key]
        os.makedirs(ASSETS, exist_ok=True)
        for name, entry in node["files"].items():
            if "offset" not in entry or entry.get("unpacked"):
                continue
            f.seek(8 + header_size + int(entry["offset"]))
            with open(os.path.join(ASSETS, name), "wb") as out:
                out.write(f.read(entry["size"]))

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, f"{name}.svg")).read()
    inner = src[src.index(">", src.index("<svg")) + 1:src.rindex("</svg>")].strip()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

# Button classes from gen-button-spec.py (only its definitions, not its file-writing tail).
src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
ns = {}
exec(src[:src.index("PLUS = (")], ns)
def button(variant, icon, extra=""):
    cls = ns["merge"](f'{ns["BASE"]} {ns["VARIANTS"][variant]} {ns["SIZES"]["icon-xs"]}')
    return f'<button type="button" data-slot="button" class="{cls}"{extra}>{lucide(icon, "size-3")}</button>'

ROOT_CLASS = ("chat-markdown w-full min-w-0 text-sm leading-relaxed "
              "text-foreground/[calc(80%+var(--appearance-contrast-boost)/5)] [overflow-wrap:anywhere] [word-break:break-word]")

# `syntheticFileNameForLanguageId` (pierre-icons.ts) to the icon token, with PierreEntryIcon.tsx's colors.
TITLE_ICONS = {"python": ("python", "#1a85d4", "#69b1ff"), "ts": ("typescript", "#1a85d4", "#69b1ff"),
               "bash": ("bash", "#199f43", "#5ecc71"), "json": ("json", "#d47628", "#ffa359")}
def code_title(language):
    if language not in TITLE_ICONS:
        return f'<span class="truncate">{language}</span>'
    import re
    extract_assets()
    bundle = open(glob.glob(os.path.join(ASSETS, "pierre-icons-*.js"))[0], encoding="utf-8").read()
    token, light, dark = TITLE_ICONS[language]
    m = re.search(r'<symbol id="file-tree-builtin-' + token + r'" viewBox="([^"]*)">(.*?)</symbol>', bundle, re.S)
    return (f'<span class="inline-flex shrink-0 rounded-sm" aria-label="Language: {language}">'
            f'<svg aria-hidden="true" data-light="{light}" data-dark="{dark}" class="size-3.5 shrink-0" '
            f'viewBox="{m.group(1)}">{m.group(2)}</svg></span>')

def code_block(language, code):
    """MarkdownCodeBlock with the wrap toggle (on, the wordWrap default) and copy; Shiki fills the pre."""
    actions = (button("secondary", "text-wrap", ' aria-pressed="true" aria-label="Disable line wrap"')
               + button("ghost-muted", "copy", ' aria-label="Copy code"'))
    return (
        '<div class="chat-markdown-codeblock my-[0.65rem] overflow-hidden rounded-lg border border-border/70 bg-secondary '
        f'leading-snug dark:border-transparent dark:bg-input/32" data-language="{language}" data-wrap="true">'
        '<div data-thread-find-ignore="true" class="chat-markdown-codeblock-header flex items-center justify-between gap-2 pt-1.5 pr-1.5 pb-0 pl-3 select-none">'
        f'<span class="inline-flex min-w-0 items-center gap-1.5 font-mono text-2xs">{code_title(language)}</span>'
        f'<span class="flex items-center gap-0.5" role="toolbar" aria-label="Code block actions">{actions}</span></div>'
        f'<div class="chat-markdown-shiki"><pre data-shiki-lang="{language}" data-code="{html.escape(code + chr(10))}"></pre></div></div>')

ALERTS = {
    "note": ("Note", "info", "border-blue-500/70", "text-blue-600 dark:text-blue-400"),
    "tip": ("Tip", "lightbulb", "border-emerald-500/70", "text-emerald-600 dark:text-emerald-400"),
    "important": ("Important", "message-square-warning", "border-purple-500/70", "text-purple-600 dark:text-purple-400"),
    "warning": ("Warning", "triangle-alert", "border-amber-500/70", "text-amber-600 dark:text-amber-500"),
    "caution": ("Caution", "octagon-alert", "border-red-500/70", "text-red-600 dark:text-red-400"),
}
def alert(kind, body):
    label, icon, border, title = ALERTS[kind]
    return (f'<div role="note" class="my-1 border-l-2 pl-3 {border}">'
            f'<p data-thread-find-ignore="true" class="flex items-center gap-1.5 font-medium {title}">{lucide(icon, "size-3.5 shrink-0")}{label}</p>\n'
            f'<p>{body}</p>\n</div>')

TABLE_VIEWPORT = ("h-full max-h-[inherit] overflow-auto overscroll-contain rounded-[inherit] outline-none transition-shadow "
                  "focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background "
                  "data-has-overflow-x:overscroll-x-contain overscroll-y-auto "
                  "mask-t-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-start)))] mask-b-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-y-end)))] "
                  "mask-l-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-start)))] mask-r-from-[calc(100%-min(var(--fade-size),var(--scroll-area-overflow-x-end)))] "
                  "[--fade-size:1.5rem] scroll-p-[var(--fade-size)]")
def table(header, aligns, rows, clipped=False):
    def cell(tag, text, align):
        style = f' style="text-align:{align}"' if align else ""
        return f"<{tag}{style}>{text}</{tag}>"
    head = "<tr>" + "".join(cell("th", h, a) for h, a in zip(header, aligns)) + "</tr>"
    body = "".join("<tr>" + "".join(cell("td", c, a) for c, a in zip(r, aligns)) + "</tr>" for r in rows)
    overflow = ";".join(f"--scroll-area-overflow-{s}:0px" for s in ["y-start", "y-end", "x-start", "x-end"])
    return ('<div class="chat-markdown-table-container" data-expanded="true">'
            '<div class="relative size-full min-h-0 overflow-hidden rounded-none w-full max-w-full" data-slot="scroll-area">'
            f'<div class="{TABLE_VIEWPORT}" data-slot="scroll-area-viewport" style="{overflow}">'
            f"<table><thead>{head}</thead><tbody>{body}</tbody></table></div></div>"
            '<div class="mt-0.5 flex items-center justify-between select-none">'
            # Since 3315 the toggle shows only when a cell is clipped; an empty span keeps copy at the right
            # (ChatMarkdown.tsx:663-682).
            + (button("secondary", "minimize-2", ' aria-pressed="true" aria-label="Collapse table cells"') if clipped else "<span></span>")
            + button("ghost-muted", "copy", ' aria-label="Copy table"') + "</div></div>")

CASES = []
def case(name, markdown, body, cwd=None, width=640):
    native = {"markdown": markdown, "width": str(width)}
    if cwd: native["cwd"] = cwd
    CASES.append({"name": name, "html": f'<div class="{ROOT_CLASS}">{body}</div>',
                  "wrapperStyle": f"display:block;width:{width}px;--font-size-code:13px", "native": native})

case("text", """# Release notes

Plain paragraph with **bold**, *italic*, ***both***, ~~struck~~, `inline code` and a [link to setup](#setup). It keeps going so the line wraps at least once at this width, and then once more for good measure.

## Second level
### Third level
#### Fourth level
##### Fifth level
###### Sixth level
A closing paragraph.""",
"""<h1>Release notes</h1>
<p>Plain paragraph with <strong>bold</strong>, <em>italic</em>, <em><strong>both</strong></em>, <del>struck</del>, <code>inline code</code> and a <a href="#setup">link to setup</a>. It keeps going so the line wraps at least once at this width, and then once more for good measure.</p>
<h2>Second level</h2>
<h3>Third level</h3>
<h4>Fourth level</h4>
<h5>Fifth level</h5>
<h6>Sixth level</h6>
<p>A closing paragraph.</p>""")

case("lists", """- First bullet
- Second bullet with `code`
  - Nested circle
    - Nested square
- Third bullet that is long enough to wrap onto a second line inside the list at this width, see.

1. Step one
2. Step two
   1. Sub step
   2. Another sub step
3. Step three

- [ ] Open task
- [x] Done task""",
"""<ul>
<li>First bullet</li>
<li>Second bullet with <code>code</code>
<ul>
<li>Nested circle
<ul>
<li>Nested square</li>
</ul>
</li>
</ul>
</li>
<li>Third bullet that is long enough to wrap onto a second line inside the list at this width, see.</li>
</ul>
<ol>
<li>Step one</li>
<li>Step two
<ol>
<li>Sub step</li>
<li>Another sub step</li>
</ol>
</li>
<li>Step three</li>
</ol>
<ul class="contains-task-list">
<li class="task-list-item"><input type="checkbox" disabled readonly> Open task</li>
<li class="task-list-item"><input type="checkbox" checked disabled readonly> Done task</li>
</ul>""")

case("quotes", """> A plain blockquote stays muted and keeps its
> soft line break as a space.

> [!NOTE]
> Useful information.

> [!TIP]
> A better way to do it.

> [!IMPORTANT]
> Key information.

> [!WARNING]
> Needs attention.

> [!CAUTION]
> Risky outcome.""",
"""<blockquote>
<p>A plain blockquote stays muted and keeps its
soft line break as a space.</p>
</blockquote>
""" + "\n".join(alert(k, b) for k, b in [("note", "Useful information."), ("tip", "A better way to do it."),
    ("important", "Key information."), ("warning", "Needs attention."), ("caution", "Risky outcome.")]))

case("table", """| Process | Status | CPU | Notes |
|---|:---:|---:|:---|
| t3 serve | running | 0.4% | idle most of the time |
| claude | waiting | 2.1% | one session |
| git status | done | 0.0% | none |""",
table(["Process", "Status", "CPU", "Notes"], [None, "center", "right", "left"],
      [["t3 serve", "running", "0.4%", "idle most of the time"], ["claude", "waiting", "2.1%", "one session"],
       ["git status", "done", "0.0%", "none"]]))

PY = '''def greet(name: str) -> str:
    # A comment that is long enough to wrap inside the code block at this width, it really is.
    return f"hello, {name}"'''
TS = '''export async function load(path: string): Promise<Config> {
  const text = await readFile(path, "utf8"); // read it
  return JSON.parse(text) as Config;
}'''
SH = 'npm install --save-dev typescript && echo "done: $HOME"'
JS = '{ "name": "candywrapper", "version": 3, "private": true, "tags": [null] }'
case("code", f"""Run this first:

```python
{PY}
```

```ts
{TS}
```

```bash
{SH}
```

```json
{JS}
```

```
plain text fence
```""",
"<p>Run this first:</p>\n" + "\n".join(code_block(l, c) for l, c in
    [("python", PY), ("ts", TS), ("bash", SH), ("json", JS), ("text", "plain text fence")]))

case("rule-image", """Before the rule.

---

After the rule, an image:

![Architecture diagram](https://example.com/diagram.png)""",
"""<p>Before the rule.</p>
<hr>
<p>After the rule, an image:</p>
<p><span class="inline-block! aspect-video w-full overflow-hidden bg-muted/60 max-w-[min(100%,30rem)] rounded-lg border border-border/40 relative" role="status" aria-label="Loading image"></span></p>""")

# File chips: MarkdownFileLink renders a ContextChip kind="mention" (ContextChip.tsx) around FileTagChipContent
# (chat/FileTagChip.tsx): lucide folder at text-icon-muted for paths without an extension, else the pierre icon
# tinted per theme (PierreEntryIcon.tsx; the prepare hook below picks the theme's color).
CHIP = ("inline-flex h-[1.41em] max-w-full items-center gap-[0.33em] rounded-[0.5em] border px-[0.5em] align-middle font-medium "
        "text-[0.86em] leading-none [&_svg]:block [&_svg]:size-[1.17em] [&_svg]:shrink-0 [&_svg]:self-center "
        "[button&,a&,[data-popup-open]&]:cursor-pointer [button&,a&]:transition-colors [button&,a&]:motion-reduce:transition-none "
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-foreground disabled:cursor-default "
        "[--context-chip-accent:oklch(0.62_0.11_215)] "
        "[--context-chip-border:color-mix(in_oklab,var(--context-chip-accent)_34%,var(--contrast-border))] "
        "[--context-chip-border-hover:color-mix(in_oklab,var(--context-chip-accent)_48%,var(--contrast-border))] "
        "[--context-chip-foreground:color-mix(in_oklab,var(--context-chip-accent)_22%,var(--contrast-foreground))] "
        "border-(--context-chip-border) bg-(--context-chip-accent)/11 text-(--context-chip-foreground) "
        "[button:enabled&,a&]:hover:border-(--context-chip-border-hover) [button:enabled&,a&]:hover:bg-(--context-chip-accent)/17 "
        "chat-markdown-file-link")
extract_assets()
PIERRE = open(glob.glob(os.path.join(ASSETS, "pierre-icons-*.js"))[0], encoding="utf-8").read()
ICON_COLORS = {"typescript": ("#1a85d4", "#69b1ff"), "npm": ("#d52c36", "#ff6762")}
def pierre(token):
    import re
    m = re.search(r'<symbol id="file-tree-builtin-' + token + r'" viewBox="([^"]*)">(.*?)</symbol>', PIERRE, re.S)
    light, dark = ICON_COLORS[token]
    return (f'<svg aria-hidden="true" data-light="{light}" data-dark="{dark}" class="size-4 shrink-0" '
            f'viewBox="{m.group(1)}">{m.group(2)}</svg>')
def chip(href, icon, label):
    return (f'<a href="{html.escape(href)}" class="{CHIP}" data-slot="context-chip">{icon}'
            f'<span class="block min-w-0 self-center truncate leading-tight" data-slot="context-chip-label">{html.escape(label)}</span></a>')
FOLDER = lucide("folder", "size-4 text-icon-muted")

case("file-chips", """Created `/tmp/cw-approval-demo`.

The entry point is `src/main.ts:12`, see [the manifest](package.json) and run `npm test` before you ship it.""",
f"""<p>Created {chip("/tmp/cw-approval-demo", FOLDER, "cw-approval-demo")}.</p>
<p>The entry point is {chip("/repo/src/main.ts:12", pierre("typescript"), "main.ts · L12")}, see <span>the manifest {chip("/repo/package.json", pierre("npm"), "package.json")}</span> and run <code>npm test</code> before you ship it.</p>""",
cwd="/repo")

diff_rendering = glob.glob(os.path.join(ASSETS, "diffRendering-*.js"))[0]
# getSharedHighlighter is exported as `g` from the diffRendering chunk at this T3 version.
PREPARE = f"""(document.querySelectorAll('svg[data-light]').forEach(s => s.style.color = document.documentElement.classList.contains('dark') ? s.dataset.dark : s.dataset.light), import('file://{diff_rendering}')).then(async m => {{
  const pres = [...document.querySelectorAll('pre[data-shiki-lang]')];
  const h = await m.g({{themes: ['pierre-light', 'pierre-dark'], langs: [...new Set(pres.map(p => p.dataset.shikiLang))], preferredHighlighter: 'shiki-wasm'}});
  const theme = document.documentElement.classList.contains('dark') ? 'pierre-dark' : 'pierre-light';
  for (const pre of pres) pre.outerHTML = h.codeToHtml(pre.dataset.code, {{lang: pre.dataset.shikiLang, theme}});
  return pres.length + ' code blocks highlighted';
}})"""

spec = {"component": "markdown", "source": "apps/web/src/components/ChatMarkdown.tsx, index.css .chat-markdown",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/markdown.json"), "w") as f:
    json.dump(spec, f, indent=1)
print("markdown", len(CASES), "cases")
