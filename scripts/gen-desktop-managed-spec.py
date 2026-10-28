# Reference stylesheet and component primitives: T3 Nightly 3814.
"""WP7.18 fidelity spec: SshPasswordPromptDialog.tsx:178-220 and RelayClientInstallDialog.tsx:87-127.
The input markup comes from scripts/gen-forms-spec.py. Capture with scripts/component-reference."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {'__file__':os.path.join(ROOT,'scripts/gen-forms-spec.py')}
src = open(ns['__file__']).read()
exec(src[:src.index('W240 =')],ns)
cases=[]
for expired in [False,True]:
    inp=ns['input_html']().replace('type="text"','type="password"'+(' disabled' if expired else ''))
    color='text-destructive' if expired else 'text-muted-foreground'
    countdown_color=color+(' font-medium' if expired else '')
    html='<div class="space-y-3"><div class="space-y-2"><div class="flex items-center justify-between gap-3"><p class="text-sm font-medium text-foreground">Enter the SSH password or verification code for fixture.</p><span class="shrink-0 text-xs '+countdown_color+'">'+('Expired' if expired else '3:00')+'</span></div>'+inp+'</div><p class="text-sm '+color+'">'+('This SSH verification prompt expired. Try connecting again.' if expired else 'SSH keys may replace a password, but your server can still require a verification code.')+'</p></div>'
    cases.append({'name':'ssh-expired' if expired else 'ssh','html':html,'wrapperStyle':'display:block;width:398px','native':{'kind':'ssh','expired':str(expired)}})
html='<div class="rounded-xl border border-border/70 bg-muted/35 p-3"><p class="text-sm font-medium text-foreground">Managed relay client</p><p class="mt-1 text-sm leading-relaxed text-muted-foreground">T3 Code will download and install version 2026.10.9 locally.</p></div>'
cases.append({'name':'relay-confirm','html':html,'wrapperStyle':'display:block;width:398px','native':{'kind':'relay'}})
for i,(stage,label) in enumerate([('checking','Checking current installation'),('waiting_for_lock','Waiting for installer'),('downloading','Downloading relay client'),('verifying','Verifying download'),('installing','Installing relay client'),('validating','Validating executable'),('activating','Activating installation')]):
    html='<div class="space-y-2.5"><div class="flex items-center justify-between gap-3 text-sm"><p class="font-medium text-foreground">'+label+'</p><p class="shrink-0 tabular-nums text-muted-foreground">'+str(i+1)+' of 7</p></div><div class="h-2 w-full overflow-hidden rounded-full bg-muted"><div class="h-2 rounded-full bg-primary" style="width:'+str((i+1)/7*100)+'%"></div></div><p class="text-xs leading-relaxed text-muted-foreground">Keep T3 Code open while the relay client is installed.</p></div>'
    cases.append({'name':'relay-'+stage,'html':html,'wrapperStyle':'display:block;width:398px','native':{'kind':'relay','stage':stage}})
with open(os.path.join(ROOT,'design/component-reference/desktop-managed.json'),'w') as f: json.dump({'component':'desktop-managed','source':'SshPasswordPromptDialog.tsx:178-220; RelayClientInstallDialog.tsx:87-127','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=2)
