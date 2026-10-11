"""WP7.17: AssistantSelectionToolbar.tsx:142-173. Uses the official Button classes."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {"__file__": os.path.join(ROOT, "scripts/gen-button-spec.py")}
src = open(g["__file__"]).read()
exec(src[:src.index("cases = []")], g)
quote = '<svg\n  class="size-3.5"\n  xmlns="http://www.w3.org/2000/svg"\n  width="14"\n  height="14"\n  viewBox="0 0 24 24"\n  fill="none"\n  stroke="currentColor"\n  stroke-width="2"\n  stroke-linecap="round"\n  stroke-linejoin="round"\n>\n  <path d="M16 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" />\n  <path d="M5 3a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2 1 1 0 0 1 1 1v1a2 2 0 0 1-2 2 1 1 0 0 0-1 1v2a1 1 0 0 0 1 1 6 6 0 0 0 6-6V5a2 2 0 0 0-2-2z" />\n</svg>\n'
cases=[]
for long in [False, True]:
    cls=g['merge'](g['BASE']+' '+g['VARIANTS']['glass']+' '+g['SIZES']['xs'])
    html='<button class="'+cls+'"'+(' disabled' if long else '')+'>'+quote+('Shorten selection' if long else 'Cite')+'</button>'
    cases.append({'name':'shorten' if long else 'cite','html':html,'native':{'tooLong':long}})
with open(os.path.join(ROOT,'design/component-reference/wp717.json'),'w') as f:
    json.dump({'component':'wp717','source':'apps/web/src/components/chat/AssistantSelectionToolbar.tsx:142-173','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=1)
