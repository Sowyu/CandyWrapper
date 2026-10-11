"""T3 V2LifecycleRow.tsx:243-327, 420-530 and ThreadDetailsPrRow.tsx:347-382, 460-477.
Run with python3 -I scripts/gen-mcp-followups-spec.py, then scripts/component-reference on the JSON.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {'__file__': os.path.join(ROOT, 'scripts/gen-git-spec.py')}
s = open(g['__file__']).read()
exec(s[:s.index('def panel_label')], g)
lucide, S, CTRL = g['lucide'], g['S'], g['CTRL']
cases = []
# `notification` is SubagentNotificationLink (V2LifecycleRow.tsx:335-398): a completed outcome reads
# "Finished" beside the title, and the event's time stands where the elapsed time was.
for name, status, label, detail, elapsed, child in [
    ('completed', 'completed', 'Completed', 'Found two problems', '1m 05s', True),
    ('notification', 'completed', 'Finished', 'Found two problems', '10:05', True),
    ('failed', 'failed', 'Failed', 'Could not read the index', '8s', True),
    ('waiting', 'waiting', 'Waiting', '', '', True),
    ('stopped', 'interrupted', 'Stopped', '', '12s', False),
]:
    dot = {'completed':'bg-success','failed':'bg-destructive','waiting':'bg-info','interrupted':'bg-muted-foreground/60'}[status]
    tone = 'text-destructive' if status == 'failed' else 'text-muted-foreground'
    avatar = f'<span class="relative inline-flex size-6 shrink-0 items-center justify-center rounded-full border border-border/70 bg-muted ring-2 ring-background">{lucide("bot", "size-3.5 text-muted-foreground")}<span class="absolute -right-px -bottom-px size-2 rounded-full ring-2 ring-background {dot}"></span></span>'
    status_html = f'<span class="shrink-0 text-3xs {tone}">{label}</span>' if detail and (status != 'completed' or name == 'notification') else ''
    content = f'{avatar}<span class="min-w-0 flex-1"><span class="flex items-baseline gap-2"><span class="min-w-0 truncate text-xs font-medium text-foreground">Audit the schema</span>{status_html}</span><span class="block text-2xs leading-relaxed {tone}">{detail or label}</span></span><span class="shrink-0 text-xs text-muted-foreground tabular-nums">{elapsed}</span>'
    if child: content += lucide('chevron-right', 'size-3.5 shrink-0 text-muted-foreground/60')
    html = f'<div class="pb-2"><button class="group/subagent flex w-full min-w-0 items-center gap-2.5 rounded-md px-2 py-1.5 text-left">{content}</button></div>'
    cases.append({'name':name, 'html':html, 'wrapperStyle':'display:block;width:520px', 'native':{'status':status,'detail':detail,'notification':name=='notification','seconds':65 if name=='completed' else 8 if name=='failed' else 12 if name=='stopped' else None,'child':child}})
html = f'<div class="{S["THREAD_DETAILS_PANEL_SPLIT_GROUP_CLASS"]}"><button class="{CTRL} {S["THREAD_DETAILS_PANEL_SPLIT_PRIMARY_CLASS"]}">{lucide("git-pull-request-arrow", "size-4 shrink-0 text-success")}<span class="min-w-0 flex-1 truncate text-left">#1: Improve the queue</span></button><span class="{S["THREAD_DETAILS_PANEL_SPLIT_SEPARATOR_CLASS"]}"></span><button class="{CTRL} {S["THREAD_DETAILS_PANEL_SPLIT_SECONDARY_CLASS"]}">{lucide("eye", "size-4")}</button></div>'
cases.append({'name':'watch','html':html,'wrapperStyle':'display:block;width:262px','native':{}})
# ThreadHoverCard.tsx:7-39, SubagentTooltipContent.tsx:141-196.
popups = open(os.path.join(ROOT, 'scripts/gen-popups-spec.py')).read()
t = {}
exec(popups[popups.index('T_BASE ='):popups.index('specs["tooltip"]')], t)
body = '<div class="flex min-w-0 max-w-80 flex-col gap-2 px-1 py-2"><div class="min-w-0 truncate text-xs leading-tight font-medium text-foreground">Audit the schema</div><div class="grid gap-1.5 pl-0.5 text-xs text-muted-foreground">'
body += '<div class="flex min-w-0 items-center gap-2">' + lucide('bot','size-3 shrink-0') + '<span class="text-foreground/75">Not reported</span></div>'
body += '<div class="flex min-w-0 items-center justify-between gap-4"><span class="inline-flex items-center gap-1 rounded-sm font-medium capitalize text-success">' + lucide('check','size-3 shrink-0') + 'Completed</span><span class="tabular-nums">1m 05s</span></div>'
body += '<div class="flex min-w-0 items-center gap-2">' + lucide('terminal','size-3 shrink-0') + '<span>Found two problems</span></div></div></div>'
cases.append({'name':'hover-card', 'html': t['tooltip']('glass', body).replace('rounded-md','rounded-lg').replace('text-balance','text-left'), 'wrapperStyle':'display:block;width:320px', 'native':{}})
with open(os.path.join(ROOT,'design/component-reference/mcp-followups.json'),'w') as f: json.dump({'component':'mcp-followups','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=2)
