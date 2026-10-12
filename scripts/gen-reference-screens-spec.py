"""Writes design/component-reference/reference-screens.json for scripts/component-reference: the parts of the
reference screens that no other case covered (design/reference 31, 43, 45 and 46).

- find: find in thread's match paint over chat markdown (43). T3 paints CSS custom highlights
  (threadFindHighlights.ts:226-233, index.css:376-394); the prepare hook below sets them the same way. The
  compiled stylesheet drops the `@variant dark` block inside `::highlight()` (it becomes `:is()`), so both
  themes get the light colors, as 43.dark shows.
- go-to-file: the file picker (45), files/ProjectFilePicker.tsx:70-150 inside CommandPaletteContent.tsx:28-97
  with `panelSize="tall-list"` and `escapeLabel="Back"`, rows from CommandPaletteResults.tsx:190-225.
- project-search: Search project contents on a Python file (46), search/ProjectContentSearchDialog.tsx:150-320
  and HighlightedSearchLine.tsx. The line is tokenized in the page by T3's own Shiki (pierre-light and
  pierre-dark, as resolveDiffThemeName picks), so its colors are T3's.
- sidebar-collapsed: the top bar with the sidebar collapsed (31 was captured with focus in the composer, where
  Mod+B is bold, so it shows the sidebar open; this case follows the source instead): the fixed SidebarTrigger
  (AppSidebarLayout.tsx:137-163, ui/sidebar.tsx:325-350) at `--workspace-controls-left` + 1px, and the
  chat header with `COLLAPSED_SIDEBAR_TITLEBAR_INSET_CLASS` (workspaceTitlebar.ts, ChatView.tsx:11280-11294,
  chat/ChatHeader.tsx:254-345, WorkspaceBreadcrumb.tsx). It uses the desktop app's macOS inset
  (`--desktop-window-controls-inset`, 90px, AppSidebarLayout.tsx:60), as CandyWrapper draws next to the
  traffic lights. The panel layout toggles at the right are left out on both sides.

Usage: /usr/bin/python3 -I scripts/gen-reference-screens-spec.py
Needs the installed T3 app's client assets (see gen-markdown-spec.py) and lucide-static.
"""
import glob, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, stop):
    src = open(os.path.join(ROOT, "scripts", name)).read()
    ns = {"__file__": os.path.join(ROOT, "scripts", name)}
    exec(src[:src.index(stop)], ns)
    return ns

pal = load("gen-command-palette-spec.py", "cases = [")
files = load("gen-files-spec.py", "ROWS = [")
tog = load("gen-toggles-spec.py", "for size, title, desc in")
md = load("gen-markdown-spec.py", "CASES = []")
side = load("gen-sidebar-search-spec.py", "SIDEBAR_BOX =")
lucide, entry_icon = files["lucide"], files["entry_icon"]
md["extract_assets"]()
DIFF_RENDERING = glob.glob(os.path.join(md["ASSETS"], "diffRendering-*.js"))[0]

# ------------------------------------------------------------------------------------------- Palette

def hint(keys, text):
    inner = "".join(f'<kbd data-slot="kbd" class="{pal["KBD"]}">{k}</kbd>' for k in keys)
    return f'<kbd data-slot="kbd-group" class="inline-flex items-center gap-1">{inner}<span>{text}</span></kbd>'

def footer(action, escape):
    hints = hint([lucide("arrow-up"), lucide("arrow-down")], "Navigate") + hint(["Enter"], action) + hint(["Esc"], escape)
    return f'<div class="{pal["FOOTER"]}" data-slot="command-footer"><div class="flex items-center gap-3">{hints}</div></div>'

# CommandPanel (ui/command.tsx:151-160) without the scrollbar and touch rules.
PANEL = "relative min-h-0 overflow-hidden rounded-t-xl bg-transparent"

def file_row(path):
    name = path.rsplit("/", 1)[-1]
    body = ('<span class="flex min-w-0 flex-1 flex-col"><span class="flex min-w-0 items-center gap-1.5 text-sm text-foreground">'
            f'<span class="truncate">{name}</span></span><span class="min-w-0 text-muted-foreground/70 text-xs">{path}</span></span>')
    return f'<div role="option" data-slot="command-item" class="{pal["ITEM"]}">{entry_icon(path, "size-4")}{body}</div>'

go_to_file = (f'<div role="dialog" data-slot="command-dialog-popup" class="{pal["POPUP"]} overflow-hidden">'
              + pal["input_row"]("Search files…", "", False)
              + f'<div class="{PANEL} max-h-[min(34rem,76vh)]">'
              + pal["results"]([("demo-repo", [file_row(p) for p in ["hello.py", "notes.md", "README.md", "src/answer.ts"]])])
              + "</div>" + footer("Open file", "Back") + "</div>")

def option(label):
    cls = tog["merge"](f'{tog["T_BASE"]} {tog["T_SIZES"]["segmented"]} {tog["T_VARIANTS"]["segmented"]}')
    return f'<button type="button" data-slot="toggle" aria-pressed="false" class="{cls}"><span class="font-mono">{label}</span></button>'
accessory = ('<div class="absolute inset-e-2.5 top-1/2 flex shrink-0 -translate-y-1/2 items-center gap-0.5 rounded-md border bg-muted/30 p-0.5">'
             + option("Aa") + option('<span class="underline decoration-2 underline-offset-2">ab</span>') + option(".*") + "</div>")
search_input = pal["input_row"]("Search in demo-repo", "hello", False)
search_input = search_input.replace('data-slot="autocomplete-input"', 'data-slot="autocomplete-input" style="padding-inline-end:7.5rem"', 1)
search_input = search_input[:-len("</div>")] + accessory + "</div>"
LINE = '    return f"Hello, {name}!"'
match = (f'<button type="button" class="flex h-7 w-full min-w-0 items-center gap-3 px-3 text-left font-mono text-xs hover:bg-accent/60 bg-accent text-accent-foreground">'
         '<span class="w-10 shrink-0 text-right tabular-nums text-muted-foreground/70">3</span>'
         f'<span class="min-w-0 flex-1 truncate whitespace-pre" data-search-line data-lang="python" data-start="13" data-end="18" '
         f'data-code="{LINE.replace(chr(34), "&quot;")}">{LINE.replace(chr(34), "&quot;")}</span></button>')
group = ('<section class="pb-2"><div class="sticky top-0 z-10 flex h-8 items-center gap-2 bg-popover/95 px-3 text-xs backdrop-blur-sm">'
         f'{entry_icon("hello.py", "size-3.5")}<span class="font-medium text-foreground">hello.py</span>'
         '<span class="ml-auto rounded-full bg-muted px-1.5 py-0.5 tabular-nums text-3xs text-muted-foreground">1</span></div>'
         f'{match}</section>')
project_search = (f'<div role="dialog" data-slot="command-dialog-popup" class="{pal["POPUP"]} overflow-hidden h-105">{search_input}'
                  f'<div class="{PANEL} flex min-h-0 flex-1 flex-col">'
                  '<div class="flex h-9 shrink-0 items-center border-b px-3 text-xs text-muted-foreground">1 results in 1 files</div>'
                  f'<div class="min-h-0 flex-1 overflow-hidden"><div class="py-2">{group}</div></div></div>'
                  + footer("Open file", "Back") + "</div>")

# ---------------------------------------------------------------------------------------------- Find

FIND_MARKDOWN = "Draft the markdown before the checks.\n\nThis reply is markdown only. No tools ran."
find = (f'<div class="{md["ROOT_CLASS"]}" data-find-query="markdown" data-find-active="0">'
        "<p>Draft the markdown before the checks.</p><p>This reply is markdown only. No tools ran.</p></div>")

# ----------------------------------------------------------------------------------- Collapsed sidebar

TEXT = "block min-w-0 truncate [text-box:trim-both_cap_alphabetic] supports-[text-box:trim-both_cap_alphabetic]:py-1.5"
monogram = side["favicon"]("demo-repo", "").replace("inline-flex size-4 shrink-0", "inline-flex size-3.5 shrink-0", 1)
breadcrumb = ('<div class="flex min-w-0 flex-1 items-center gap-2 sm:gap-3 pr-24">'
              '<nav aria-label="Thread breadcrumb" class="min-w-0 flex-1 overflow-clip [overflow-clip-margin:2px]">'
              '<ol class="m-0 flex min-w-0 list-none items-center gap-2 p-0 text-sm sm:gap-3">'
              '<li class="flex min-w-0 items-center font-medium text-muted-foreground shrink">'
              '<button type="button" class="inline-flex min-w-0 max-w-full cursor-pointer items-center gap-1.5 rounded-sm text-muted-foreground transition-colors">'
              f'{monogram}<span data-slot="workspace-breadcrumb-text" class="{TEXT} max-w-40">demo-repo</span></button></li>'
              f'<li aria-hidden="true" class="flex shrink-0 items-center text-icon-muted"><span class="{TEXT}">/</span></li>'
              '<li aria-current="page" class="flex items-center font-medium text-foreground min-w-10 flex-1">'
              '<button type="button" class="group/thread-title inline-flex min-w-0 max-w-full cursor-pointer items-center gap-1 rounded-sm text-left">'
              f'<h2 class="min-w-0"><span data-slot="workspace-breadcrumb-text" class="{TEXT}">Reply with markdown only</span></h2>'
              + lucide("chevron-down", "size-3.5 shrink-0 text-muted-foreground opacity-0") + "</button></li></ol></nav></div>")
trigger_cls = files["merge"](f'{files["ns"]["BASE"]} {files["ns"]["VARIANTS"]["ghost"]} {files["ns"]["SIZES"]["icon"]} size-[var(--workspace-titlebar-control-size)]!')
trigger = (f'<div style="position:absolute;left:90px;top:0" class="pointer-events-none z-50 ml-px flex h-[var(--workspace-topbar-height)] items-center">'
           f'<button type="button" data-slot="sidebar-trigger" aria-pressed="false" class="{trigger_cls} pointer-events-auto">'
           + lucide("panel-left", "size-4") + "</button></div>")
collapsed = ('<div class="relative bg-background" style="width:640px">'
             '<header class="relative bg-background flex h-[var(--workspace-topbar-height)] min-h-[var(--workspace-topbar-height)] shrink-0 items-center px-3 sm:px-5" '
             f'style="padding-left:130px">{breadcrumb}</header>{trigger}</div>')

# ------------------------------------------------------------------------------------------- Prepare

PREPARE = f"""(async () => {{
  const dark = document.documentElement.classList.contains('dark');
  const inactive = new Highlight(), active = new Highlight();
  for (const root of document.querySelectorAll('[data-find-query]')) {{
    const query = root.dataset.findQuery, current = Number(root.dataset.findActive);
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let n = 0;
    for (let node; (node = walker.nextNode());) {{
      for (let i = node.data.indexOf(query); i >= 0; i = node.data.indexOf(query, i + query.length)) {{
        const range = new Range(); range.setStart(node, i); range.setEnd(node, i + query.length);
        (n++ === current ? active : inactive).add(range);
      }}
    }}
  }}
  CSS.highlights.set('t3-thread-find', inactive);
  CSS.highlights.set('t3-thread-find-active', active);
  const lines = [...document.querySelectorAll('[data-search-line]')];
  const m = await import('file://{DIFF_RENDERING}');
  const h = await m.g({{themes: ['pierre-light', 'pierre-dark'], langs: [...new Set(lines.map(l => l.dataset.lang))], preferredHighlighter: 'shiki-wasm'}});
  for (const el of lines) {{
    const code = el.dataset.code, start = Number(el.dataset.start), end = Number(el.dataset.end);
    const tokens = h.codeToTokens(code, {{lang: el.dataset.lang, theme: dark ? 'pierre-dark' : 'pierre-light'}}).tokens[0];
    el.textContent = '';
    for (const t of tokens) {{
      const cuts = [t.offset, Math.max(t.offset, Math.min(start, t.offset + t.content.length)),
                    Math.max(t.offset, Math.min(end, t.offset + t.content.length)), t.offset + t.content.length];
      for (let k = 0; k < 3; k++) {{
        if (cuts[k + 1] <= cuts[k]) continue;
        const s = document.createElement(k === 1 ? 'mark' : 'span');
        if (k === 1) s.className = 'rounded-xs bg-primary/25 text-inherit';
        if (t.color) s.style.color = t.color;
        if (t.fontStyle & 1) s.style.fontStyle = 'italic';
        if (t.fontStyle & 2) s.style.fontWeight = '700';
        s.textContent = code.slice(cuts[k], cuts[k + 1]);
        el.appendChild(s);
      }}
    }}
  }}
  return lines.length + ' search lines highlighted';
}})()"""

# The collapsed top bar comes first and the second popup sits lower: a popup's shadow reaches into the next case's capture.
cases = [
    {"name": "sidebar-collapsed", "html": collapsed, "wrapperStyle": "display:block;width:640px", "native": {"case": "sidebar-collapsed"}},
    {"name": "find", "html": find, "wrapperStyle": "display:block;width:480px;--font-size-code:13px",
     "native": {"case": "find", "markdown": FIND_MARKDOWN}},
    {"name": "go-to-file", "html": go_to_file, "wrapperStyle": "display:block;width:576px", "native": {"case": "go-to-file"}},
    {"name": "project-search", "html": project_search, "wrapperStyle": "display:block;width:576px;margin-top:48px", "native": {"case": "project-search"}},
]
spec = {"component": "reference-screens",
        "source": "apps/web/src/components/{chat/threadFindHighlights.ts,files/ProjectFilePicker.tsx,search/ProjectContentSearchDialog.tsx,AppSidebarLayout.tsx,chat/ChatHeader.tsx}",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/reference-screens.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
