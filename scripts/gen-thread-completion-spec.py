"""WP7.10c: official ComposerTasksBadge:34-94,
MessagesTimeline:1863-1900, V2ItemInspector:250-281.
Use scripts/component-reference with an explicit sandbox Chromium binary.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {"__file__": os.path.join(ROOT, "scripts/gen-button-spec.py")}
src = open(g["__file__"]).read()
exec(src[:src.index("cases = []")], g)
def button(label, variant='ghost', size='xs'):
    return '<button class="'+g['merge'](g['BASE']+' '+g['VARIANTS'][variant]+' '+g['SIZES'][size])+'">'+label+'</button>'
cases=[]
for current in [0,2]:
    strips=''
    for i in range(6):
        strips+='<span style="position:absolute;left:0;top:'+str(i*8)+'px;height:2px;width:8px;border-radius:1px;background:color-mix(in oklab,var(--'+('foreground' if current==i else 'muted-foreground')+') '+('90' if current==i else '35')+'%,transparent)"></span>'
    cases.append({'name':'minimap-'+str(current),'html':'<div style="position:relative;width:40px;height:42px">'+strips+'</div>','native':{'kind':'minimap','current':current}})
for count,complete in [(3,1),(3,3),(11,2)]:
    segments=''
    if count<=10:
        for i in range(count):
            cls='bg-success' if i<complete else 'bg-primary' if i==complete else 'bg-muted-foreground/25'
            segments+='<span class="h-[3px] min-w-0 flex-1 rounded-full '+cls+'"></span>'
    # ComposerBanner's comfortable row, plus its 17px lower overlap.
    html='<div class="composer-glass rounded-t-xl" style="width:600px;height:51px;padding:5px 8px;font-size:12px"><div class="flex items-center gap-1" style="height:24px"><span style="width:24px"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="6" height="6" rx="1"/><path d="m3 17 2 2 4-4M13 6h8M13 10h8M13 16h8M13 20h8"/></svg></span><span class="text-muted-foreground">Tasks</span><span class="min-w-0 flex-1 truncate font-medium text-foreground/80">'+('Finish' if complete==count else 'Build')+'</span><span class="text-muted-foreground">'+str(complete)+'/'+str(count)+'</span><span class="flex items-center gap-0.5" style="width:80px">'+segments+'</span><span><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m6 9 6 6 6-6"/></svg></span></div></div>'
    cases.append({'name':'tasks-'+str(count)+'-'+str(complete),'html':html,'native':{'kind':'tasks','count':count,'complete':complete}})
for failed in [False,True]:
    html='<div class="space-y-1.5 font-mono text-muted-foreground" style="width:320px;font-size:13px;line-height:1.625"><div>Sources/Chat.swift</div>'+('<div class="text-destructive">Patch did not apply</div>' if failed else '')+button('Open diff','outline')+'</div>'
    cases.append({'name':'inspector-'+('failed' if failed else 'file'),'html':html,'native':{'kind':'inspector','failed':failed}})
spec={'component':'thread-completion','source':'apps/web/src/components/chat/{ComposerTasksBadge,MessagesTimeline,V2ItemInspector}.tsx','states':['rest'],'themes':['light','dark'],'cases':cases}
with open(os.path.join(ROOT,'design/component-reference/thread-completion.json'),'w') as out: json.dump(spec,out,indent=1)
