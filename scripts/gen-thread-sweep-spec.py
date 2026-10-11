"""Thread sweep states from ComposerTasksBadge.tsx:166-218, PermissionUpdateNotice.tsx:52-75,
ui/toast.tsx:360-400,668-672 and ChatView.tsx:11341-11354.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {"__file__": os.path.join(ROOT, "scripts/gen-button-spec.py")}
src = open(g['__file__']).read()
exec(src[:src.index('cases = []')], g)
def button(label, variant):
    return '<button class="'+g['merge'](g['BASE']+' '+g['VARIANTS'][variant]+' '+g['SIZES']['xs'])+'">'+label+'</button>'
cases=[]
for state,icon,tone,opacity,duration in [('completed','<path d="m9 12 2 2 4-4"/>','success','55','1m 2s'),('running','<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="1"/>','primary','90','now'),('pending','<circle cx="12" cy="12" r="10"/>','muted-foreground/40','70','')]:
    if state=='completed': icon='<path d="m20 6-11 11-5-5"/>'
    text='Run the thread checks and inspect the complete conversation at a narrow width'
    fg='foreground' if state=='running' else 'muted-foreground'
    html='<div style="width:300px;padding:4px 0;display:flex;align-items:start;font-size:12px;line-height:16px"><span style="width:28px;flex-shrink:0;padding:2px 6px" class="text-'+tone+'"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'+icon+'</svg></span><span class="text-'+fg+'/'+opacity+'" style="width:212px;overflow-wrap:anywhere">'+text+'</span><span class="text-muted-foreground/45" style="margin-left:8px;width:48px;font-size:10px">'+duration+'</span></div>'
    cases.append({'name':'task-'+state,'html':html,'native':{'kind':'task','state':state,'text':text}})
html='<div class="dropdown-glass rounded-[10px] text-sm shadow-xl" style="position:relative;border-radius:10px;width:360px;border:1px solid color-mix(in oklab,var(--foreground) 10%,transparent);padding:10px 14px;line-height:20px"><div class="font-medium">Permissions have changed for Sandbox</div><div class="text-muted-foreground" style="margin-top:2px">Pair again using a new link with the permissions you need.</div><div class="flex justify-end gap-1.5" style="margin-top:8px">'+button('Dismiss','ghost')+button('Open Connections','default')+'</div><div class="bg-popover text-muted-foreground rounded-full shadow-sm" style="position:absolute;right:-6px;top:-6px;width:24px;height:24px;border:1px solid color-mix(in oklab,var(--foreground) 10%,transparent);display:flex;align-items:center;justify-content:center"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round"><path d="m18 6-12 12M6 6l12 12"/></svg></div></div>'
cases.append({'name':'permission-stacked','html':html,'native':{'kind':'permission'}})
spec={'component':'thread-sweep','source':'apps/web/src/components/chat/ComposerTasksBadge.tsx; components/PermissionUpdateNotice.tsx; components/ui/toast.tsx','states':['rest'],'themes':['light','dark'],'cases':cases}
with open(os.path.join(ROOT,'design/component-reference/thread-sweep.json'),'w') as f: json.dump(spec,f,indent=2)
