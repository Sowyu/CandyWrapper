"""Wide table references from ChatMarkdown.tsx:562-692 and index.css:2031-2075.
Run with python3 -I scripts/gen-wide-table-spec.py, then scripts/component-reference.
"""
import os

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
source = open(os.path.join(root, "scripts/gen-markdown-spec.py")).read()
exec(source[:source.index('case("text",')])
long = "A long cell with words and averylongunbrokenidentifier " * 4
headers = ["Process", "Status", "Memory", "Owner", "Description", "CPU"]
rows = [["worker", "running", "128 MB", "sandbox", long, "0.4%"]]
markdown = "| " + " | ".join(headers) + " |\n|---|---|---|---|---|---|\n| " + " | ".join(rows[0]) + " |"
for expanded in [False, True]:
    body = table(headers, [None] * 6, rows)
    if not expanded:
        body = body.replace('data-expanded="true"', 'data-expanded="false"').replace(
            button("secondary", "minimize-2", ' aria-pressed="true" aria-label="Collapse table cells"'),
            button("ghost-muted", "maximize-2", ' aria-pressed="false" aria-label="Expand table cells"'))
    case("expanded" if expanded else "collapsed", markdown, body, width=480)
    CASES[-1]["native"]["expanded"] = "true" if expanded else "false"
# Base UI computes the overflow variables. Keep its 24px mask and the shared native 7px bar lane.
prepare = """(() => {
for (const viewport of document.querySelectorAll('[data-slot=scroll-area-viewport]')) {
 const overflow = viewport.scrollWidth - viewport.clientWidth;
 viewport.style.setProperty('--scroll-area-overflow-x-end', overflow + 'px');
 if (overflow > 0) {
  viewport.parentElement.style.paddingBottom = '7px';
  const bar = document.createElement('div');
  bar.style.cssText = `position:absolute;bottom:0;height:7px;border-radius:99px;background:color-mix(in srgb,var(--contrast-border) 78%,transparent);width:${viewport.clientWidth * viewport.clientWidth / viewport.scrollWidth}px`;
  viewport.parentElement.append(bar);
 }
}
})()"""
with open(os.path.join(ROOT, "design/component-reference/wide-tables.json"), "w") as out:
    json.dump({"component": "wide-tables", "states": ["rest"], "themes": ["light", "dark"], "cases": CASES, "prepare": prepare}, out, indent=2)
