"""Writes design/component-reference/diff.json, the diff panel body cases for scripts/component-reference.

Each case is a patch rendered in the page by T3's own bundled @pierre/diffs (the vanilla FileDiff
class from the installed client's renderDiffChildren chunk) with the options DiffPanel.tsx passes
(lineDiffType none, wrap, sticky headers) and T3's stylesheet overrides (DIFF_VIEW_UNSAFE_CSS in
StyledDiffCodeView.tsx plus DIFF_SURFACE_THEME_UNSAFE_CSS in lib/diffRendering.ts), inside a
`diff-render-surface` host. Header slots get T3's markup: the icon-micro ghost collapse chevron, the
copy path button. The native side (DiffPanelView in Features/Diff) renders the same patches.

Deviations: the file's `collapsed` state is set per case; copy buttons use the rest state only.

Usage: /usr/bin/python3 -I scripts/gen-diff-spec.py
Needs the client assets extracted by scripts/gen-markdown-spec.py and lucide-static for icon markup.
"""
import glob, html, json, os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or os.path.expanduser("~/CandyWrapper-research")
T3 = os.environ.get("CANDY_T3_SOURCE") or os.path.join(RESEARCH, "t3code/apps/web/src")

def source_file(relative):
    """Read the design tag without changing the shared checkout."""
    if os.environ.get("CANDY_T3_SOURCE"):
        return open(os.path.join(os.environ["CANDY_T3_SOURCE"], relative)).read()
    return subprocess.check_output(["git", "-C", os.path.expanduser("~/CandyWrapper-research/t3code"), "show",
        "v0.1.4-nightly.20261028.3824:apps/web/src/" + relative], text=True)
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")
ASSETS = os.path.join(RESEARCH, "t3-client-assets")

def lucide(name, cls):
    src = open(os.path.join(LUCIDE, f"{name}.svg")).read()
    inner = src[src.index(">", src.index("<svg")) + 1:src.rindex("</svg>")].strip()
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

src = open(os.path.join(ROOT, "scripts/gen-button-spec.py")).read()
ns = {}
exec(src[:src.index("PLUS = (")], ns)
def button(variant, size, inner, extra=""):
    cls = ns["merge"](f'{ns["BASE"]} {ns["VARIANTS"][variant]} {ns["SIZES"][size]} {extra}')
    return f'<button type="button" data-slot="button" class="{cls}">{inner}</button>'

def template(path, name):
    """The body of `const NAME = `...`;` in a T3 source file."""
    text = source_file(path)
    start = text.index(f"const {name} = `") + len(f"const {name} = `")
    return text[start:text.index("`;", start)]

surface = template("lib/diffRendering.ts", "DIFF_SURFACE_THEME_UNSAFE_CSS")
unsafe = template("components/diffs/StyledDiffCodeView.tsx", "DIFF_VIEW_UNSAFE_CSS").replace("${DIFF_SURFACE_THEME_UNSAFE_CSS}", surface)

# Header slot markup (DiffPanel.tsx DiffFileCollapseToggle, DiffFilePathCopyButton).
ICON_CLASS = {kind: "text-muted-foreground/80" for kind in ["new", "deleted", "change", "rename-pure", "rename-changed", "other"]}
PREFIX = {f"{k}.{icon}": button("ghost", "icon-micro", lucide(icon, f"size-4 {v}"), "-ms-0.5")
          for k, v in ICON_CLASS.items() for icon in ["chevron-right", "chevron-down"]}
COPY = '<span data-diff-copy-path class="inline-flex">' + button("ghost-muted", "icon-micro", lucide("copy", "size-3")) + "</span>"

PATCHES = {
"modified": """diff --git a/src/greet.ts b/src/greet.ts
index 1a2b3c4..5d6e7f8 100644
--- a/src/greet.ts
+++ b/src/greet.ts
@@ -3,6 +3,7 @@ import { format } from "./format";
 // Greets people by name.
-export function greet(name: string) {
-  return "Hello " + name;
+export function greet(name: string): string {
+  const trimmed = name.trim();
+  return `Hello, ${trimmed}!`;
 }
{SP}
 const LIMIT = 42;
@@ -20,3 +21,3 @@ export const VERSION = 1;
 export function wave() {
-  return "bye";
+  return "wave";
 }
\\ No newline at end of file
""",
"added": """diff --git a/notes.py b/notes.py
new file mode 100644
index 0000000..41b0019
--- /dev/null
+++ b/notes.py
@@ -0,0 +1,5 @@
+def total(items):
+    \"\"\"Sum the prices of items.\"\"\"
+    return sum(item.price for item in items)
+
+print(total([]))  # 0
""",
"deleted": """diff --git a/old.json b/old.json
deleted file mode 100644
index 41b0019..0000000
--- a/old.json
+++ /dev/null
@@ -1,4 +0,0 @@
-{
-  "name": "demo",
-  "version": 2
-}
""",
"wrap": """diff --git a/docs/a-rather-long-directory-name/with-a-deeply-nested/path/to/the-readme-file.md b/docs/a-rather-long-directory-name/with-a-deeply-nested/path/to/the-readme-file.md
index 1111111..2222222 100644
--- a/docs/a-rather-long-directory-name/with-a-deeply-nested/path/to/the-readme-file.md
+++ b/docs/a-rather-long-directory-name/with-a-deeply-nested/path/to/the-readme-file.md
@@ -1,2 +1,2 @@
 # Title
-This line is long enough that it has to wrap at the panel width, so the row grows by one line height per extra visual line.
+This line is long enough that it has to wrap at the panel width too, so the row grows by one line height per extra visual line, and then some more words.
""",
}

# Git writes a blank context line as a single space; keep it explicit so editors don't strip it.
PATCHES = {k: v.replace("{SP}", " ") for k, v in PATCHES.items()}

CASES = []
def case(name, patch, style, collapsed=False, width=460):
    CASES.append({"name": name, "native": {"patch": patch, "style": style, "collapsed": collapsed, "width": width},
                  "html": f'<div data-patch="{html.escape(patch)}" data-style="{style}" data-collapsed="{int(collapsed)}" style="width:{width}px"></div>'})

for style in ["unified", "split"]:
    for key in ["modified", "added", "deleted", "wrap"]:
        case(f"{key}.{style}", PATCHES[key], style, width=460 if style == "unified" else 700)
case("collapsed", PATCHES["modified"] + PATCHES["added"] + PATCHES["deleted"], "unified", collapsed=True)

diff_children = glob.glob(os.path.join(ASSETS, "renderDiffChildren-*.js"))[0]
diff_rendering = glob.glob(os.path.join(ASSETS, "diffRendering-*.js"))[0]
# Export names at this T3 version: renderDiffChildren `r` is pierre's vanilla FileDiff,
# diffRendering `c` is T3's getRenderablePatch (parsePatchFiles plus T3's fallbacks).
PREPARE = """(async () => { try {
  // Importing the client chunks runs T3's theme bootstrap, which rewrites the root class.
  const failures = [];
  window.addEventListener('unhandledrejection', e => failures.push(String(e.reason?.stack ?? e.reason)));
  const rootClass = document.documentElement.className;
  const dark = rootClass.includes('dark');
  const fd = await import('file://DIFF_CHILDREN');
  const dr = await import('file://DIFF_RENDERING');
  await new Promise(r => setTimeout(r, 300));
  document.documentElement.className = rootClass;
  // Nightly 3824 readableSyntaxTheme.ts: darken syntax, preserving the editor palette.
  const readable = color => {
    if (!/^#[0-9a-f]{6}$/i.test(color)) return color;
    let rgb = [1, 3, 5].map(i => parseInt(color.slice(i, i + 2), 16));
    const minimum = ['#1ca1c7', '#636363', '#1a85d4'].includes(color.toLowerCase()) ? 6 : 4.5;
    const contrast = () => {
      const c = rgb.map(v => v / 255).map(v => v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
      return .74 / (.2126 * c[0] + .7152 * c[1] + .0722 * c[2] + .05);
    };
    while (contrast() < minimum) rgb = rgb.map(v => Math.floor(v * .96));
    return '#' + rgb.map(v => v.toString(16).padStart(2, '0')).join('');
  };
  await dr.g({themes: ['pierre-light', 'pierre-dark'], langs: []});
  const baseTheme = dr.S.getResolvedTheme('pierre-light');
  dr.S.registerThemeIfAbsent('t3-light', async () => ({...baseTheme, name: 't3-light',
    settings: baseTheme.settings.map(t => ({...t, settings: {...t.settings,
      ...(t.settings.foreground ? {foreground: readable(t.settings.foreground)} : {})}}))}));
  const prefix = PREFIX_JSON, copy = COPY_JSON, unsafe = UNSAFE_JSON;
  const el = h => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content.firstChild; };
  const known = new Set(['new', 'deleted', 'change', 'rename-pure', 'rename-changed']);
  let count = 0;
  for (const host of document.querySelectorAll('[data-patch]')) {
    const patch = dr.c(host.dataset.patch, 'diff-panel');
    for (const fileDiff of patch.files) {
      const collapsed = host.dataset.collapsed === '1';
      const view = new fd.r({
        theme: { light: 't3-light', dark: 'pierre-dark' }, themeType: dark ? 'dark' : 'light',
        diffStyle: host.dataset.style, lineDiffType: 'none', overflow: 'wrap', stickyHeaders: true,
        collapsed, unsafeCSS: unsafe,
        renderHeaderPrefix: f => el(prefix[(known.has(f.type) ? f.type : 'other') + (collapsed ? '.chevron-right' : '.chevron-down')]),
        renderHeaderFilenameSuffix: () => el(copy),
      });
      const wrapper = document.createElement('div');
      host.appendChild(wrapper);
      await view.render({ fileDiff, containerWrapper: wrapper });
      const c = wrapper.firstElementChild;
      c.classList.add('diff-render-surface');
      c.style.setProperty('--code-background', 'var(--background)');
      count++;
    }
  }
  for (let tries = 0; tries < 300; tries++) {
    if ([...document.querySelectorAll('[data-patch]')].every(h => h.clientHeight > 0)) break;
    await new Promise(r => setTimeout(r, 100));
  }
  if ([...document.querySelectorAll('[data-patch]')].some(h => h.clientHeight === 0))
    throw new Error('Empty diff render: ' + failures.join('; ') + ' ' + document.querySelector('[data-patch]').innerHTML.slice(0, 1200));
  return count + ' files rendered';
} catch (e) { throw e; } })()"""
PREPARE = (PREPARE.replace("DIFF_CHILDREN", diff_children).replace("DIFF_RENDERING", diff_rendering)
           .replace("PREFIX_JSON", json.dumps(PREFIX)).replace("COPY_JSON", json.dumps(COPY)).replace("UNSAFE_JSON", json.dumps(unsafe)))

# Pierre lays out in the code font at --diffs-font-size, which T3 sets on the root at runtime
# (appearanceFonts.ts:121-123); 13px is the default code size.
for c in CASES:
    c["wrapperStyle"] = "display:block; --diffs-font-size: 13px; --font-size-code: 13px"

spec = {"component": "diff", "source": "@pierre/diffs FileDiff with DiffPanel.tsx options and StyledDiffCodeView.tsx CSS",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE, "cases": CASES}
with open(os.path.join(ROOT, "design/component-reference/diff.json"), "w") as f:
    json.dump(spec, f, indent=1)
print("diff", len(CASES), "cases")
