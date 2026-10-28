"""3814 QueuedRunsControl.tsx:218-555. Unsent bubbles and their action rows."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
g = {"__file__": os.path.join(ROOT, "scripts/gen-composer-attachments-spec.py")}
s = open(g["__file__"]).read(); exec(s[:s.index("# MARK: shelf")], g)
btn, icon = g['btn'], g['lucide']

def row(kind, text):
    editing = kind == 'editing'
    color = 'border-primary/60 text-foreground' if editing else 'border-guest/50 text-muted-foreground' if kind == 'guest' else 'border-muted-foreground/40 text-muted-foreground'
    fold = kind in ['agent', 'automation']
    sender = '<p class="me-1 text-2xs text-muted-foreground/70">Sent by T3 Code</p>' if kind == 'server' else '<p class="me-1 text-2xs text-guest-foreground">Guest</p>' if kind == 'guest' else ''
    if fold:
        label = 'Automation' if kind == 'automation' else 'Review helper'
        glyph = 'calendar-clock' if kind == 'automation' else 'messages-square'
        body = (f'<button class="flex w-full min-w-0 items-center gap-1.5 rounded-2xl px-3 py-2 text-left text-sm">{icon(glyph,"size-4 shrink-0 stroke-2 text-muted-foreground")}'
                f'<span class="max-w-1/2 shrink-0 truncate text-muted-foreground">{label}</span><span class="min-w-0 flex-1 truncate">{text}</span>{icon("chevron-down","size-3.5 shrink-0 text-muted-foreground")}</button>')
    else:
        body = f'<div class="flex flex-col gap-2"><p class="whitespace-pre-wrap wrap-anywhere">{text}</p></div>'
    bubble = f'<div class="flex min-w-0 max-w-[80%] flex-col rounded-2xl border border-dashed text-sm {color} ' + ('' if fold else 'px-3 py-2') + f'">{body}</div>'
    actions = ('<span class="px-1 text-foreground">Editing in the composer</span>'+btn('ghost','xs','Cancel')) if editing else btn('ghost-muted','xs',icon('arrow-up')+'Send now')+btn('ghost-muted','icon-xs',icon('pencil'))+btn('ghost-muted','icon-xs',icon('x'))
    return f'<section class="relative mx-auto flex w-full max-w-(--chat-content-max-width) flex-col gap-2 pb-4"><ol class="flex flex-col items-end gap-3"><li class="group/queued flex w-full flex-col items-end gap-1">{sender}{bubble}<div class="flex items-center gap-0.5 pe-1 text-xs text-muted-foreground">{actions}</div></li></ol></section>'

cases = []
for kind, text in [('user','second queued message'),('editing','second queued message'),('agent','Check the upload queue'),('automation','Daily review'),('server','Continue the review'),('guest','A message from a guest'),('long','First line\nSecond line with more detail\nThird line')]:
    cases.append({'name':kind,'html':row(kind,text),'wrapperStyle':'display:block;width:600px','native':{'kind':kind,'text':text}})
with open(os.path.join(ROOT,'design/component-reference/queue.json'),'w') as f:
    json.dump({'component':'queue','sourceVersion':'v0.1.4-nightly.20261028.3814','source':'apps/web/src/components/chat/QueuedRunsControl.tsx:218-555','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=2)
