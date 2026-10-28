"""Nightly 3814: source classes from ProviderAuthenticationSection.tsx:176-260 and
AddProviderInstanceDialog.tsx:91-140; RadioGroup.tsx:8-11. Uses the existing settings and icon spec helpers."""
import os, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {'__file__': os.path.join(ROOT, 'scripts/gen-settings-pages2-spec.py')}
source = open(ns['__file__']).read()
exec(source[:source.index('# --- Project: the overview card')], ns)
row, button = ns['row'], ns['button']
cases = []
for kind, text, label in [('idle', 'Sign in on Fixture machine.', 'Sign in'), ('signed-in', 'Signed in.', 'Change account')]:
    html = row('Account', text, '<div class="flex items-center gap-1.5">' + button('outline', 'sm', label) + '</div>')
    cases.append({'name': 'account.'+kind, 'html':html, 'wrapperStyle':'display:block;width:592px', 'native':{'kind':kind}})
choices = []
for kind, label, icon in [('codex','Codex','OpenAI'), ('claudeAgent','Claude','ClaudeAI')]:
    selected = kind == 'codex'
    cls = 'relative flex cursor-pointer items-center gap-3 rounded-lg bg-card px-3 py-3 text-left text-muted-foreground outline-none ring-1 ring-black/5 dark:bg-white/3 dark:ring-white/5'
    if selected: cls += ' data-checked:bg-primary/8 data-checked:text-foreground data-checked:ring-2 data-checked:ring-inset data-checked:ring-primary dark:data-checked:bg-primary/15 dark:data-checked:ring-primary'
    check = '<span class="grid size-5 shrink-0 place-items-center rounded-full bg-primary text-primary-foreground">'+ns['lucide']('check','size-3.5')+'</span>' if selected else ''
    choices.append('<button '+('data-checked ' if selected else '')+'class="'+cls+'" >'+ns['tsx_icon'](icon,'size-4')+'<span class="min-w-0 flex-1 truncate text-sm font-medium text-foreground">'+label+'</span>'+check+'</button>')
cases.append({'name':'wizard.drivers','html':'<div class="grid grid-cols-2 gap-3">'+''.join(choices)+'</div>', 'wrapperStyle':'display:block;width:592px','native':{'kind':'drivers'}})
with open(os.path.join(ROOT,'design/component-reference/provider-setup.json'),'w') as f:
    json.dump({'component':'provider-setup','source':'ProviderAuthenticationSection.tsx:176-260; AddProviderInstanceDialog.tsx:91-140; ui/radio-group.tsx:8-11','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=2)
