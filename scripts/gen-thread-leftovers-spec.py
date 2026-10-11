"""WP7.10b references: ThreadFindBar.tsx:43-121 and ContextWindowMeter.tsx:42-103.
Run with python3 -I, then scripts/component-reference design/component-reference/thread-leftovers.json.
"""
import json, os, math
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {"__file__": os.path.join(ROOT, "scripts/gen-button-spec.py")}
src = open(g["__file__"]).read()
exec(src[:src.index("cases = []")], g)
f = {}
src = open(os.path.join(ROOT, "scripts/gen-forms-spec.py")).read()
exec(src[src.index("# Input (input.tsx)"):src.index("W240 =")], f)
src2 = src[src.index("# InputGroup"):src.index("cases = [", src.index("# InputGroup"))]
exec(src2, f)
def button(icon, disabled=False):
    paths = {"up": '<path d="m18 15-6-6-6 6"/>', "down": '<path d="m6 9 6 6 6-6"/>', "x": '<path d="M18 6 6 18M6 6l12 12"/>'}
    svg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + paths[icon] + '</svg>'
    cls = g['merge'](g['BASE'] + ' ' + g['VARIANTS']['ghost'] + ' ' + g['SIZES']['icon-xs'])
    return '<button data-slot="button" class="' + cls + '"' + (' disabled' if disabled else '') + '>' + svg + '</button>'
cases=[]
for name,query,count in [('empty','',''),('matches','thread','2/8'),('none','missing','0/0'),('loading','thread','Searching…')]:
    control=f['IG_BASE'] + ' dropdown-glass rounded-2xl h-9'
    color='text-destructive' if name=='none' else 'text-muted-foreground'
    html='<div data-slot="input-group" class="'+control+'"><span data-size="sm" data-slot="input-control"><input class="'+f['INPUT_INNER']['sm']+'" value="'+query+'" placeholder="Find in thread"></span>'
    html+='<div data-align="inline-end" style="padding-right:4px;gap:2px" class="flex items-center order-last [&_button]:rounded-full"><span class="min-w-10 text-center text-xs tabular-nums '+color+'">'+count+'</span>'
    html+=button('up',name!='matches')+button('down',name!='matches')+button('x')+'</div></div>'
    cases.append({'name':name,'html':html,'wrapperStyle':'display:block;width:384px','native':{'kind':'find','query':query,'index':1 if name=='matches' else 0,'count':8 if name=='matches' else 0,'loading':name=='loading'}})
for percent in [0,25,95]:
    circ=2*math.pi*9.75
    color='var(--color-error)' if percent>90 else 'color-mix(in oklab,var(--color-muted-foreground) 72%,transparent)'
    html='<div style="display:flex;width:28px;height:28px;align-items:center;justify-content:center"><svg style="width:20px;height:20px;transform:rotate(-90deg)" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.75" fill="none" class="stroke-muted-foreground/24" stroke-width="3"/><circle cx="12" cy="12" r="9.75" fill="none" stroke="'+color+'" stroke-width="3" stroke-linecap="round" stroke-dasharray="'+str(circ)+'" stroke-dashoffset="'+str(circ*(1-percent/100))+'"/></svg></div>'
    cases.append({'name':'meter-'+str(percent),'html':html,'native':{'kind':'meter','used':percent*1000,'max':100000}})
spec={'component':'thread-leftovers','source':'apps/web/src/components/chat/{ThreadFindBar,ContextWindowMeter}.tsx','states':['rest'],'themes':['light','dark'],'cases':cases}
with open(os.path.join(ROOT,'design/component-reference/thread-leftovers.json'),'w') as out: json.dump(spec,out,indent=1)
