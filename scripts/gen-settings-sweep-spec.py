"""Settings sweep references from official SettingsRow and PanelAnimationsPreview markup."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
ns = {'__file__': str(root/'scripts/gen-settings-spec.py')}
source = (root/'scripts/gen-settings-spec.py').read_text()
exec(source[:source.index('behavior = section(')], ns)
row = ns['row']
invalid = row('t3.json is invalid', 'A t3.json exists in this checkout but fails to parse, so every action and icon it declares is ignored. Check the JSON syntax and icon values.', '')
preview = '''<button class="flex h-10 w-full cursor-pointer overflow-hidden rounded-lg border border-border bg-background p-1 shadow-xs/5 outline-none"><span class="h-full w-4 shrink-0 rounded-md bg-sidebar"></span><span class="flex min-w-0 flex-1 flex-col px-1"><span class="flex min-h-0 flex-1 flex-col gap-1 pt-1"><span class="h-0.5 w-full rounded-full bg-muted-foreground/25"></span><span class="h-0.5 w-4/5 rounded-full bg-muted-foreground/20"></span><span class="h-0.5 w-3/5 rounded-full bg-muted-foreground/15"></span></span><span class="flex h-2 shrink-0 items-center overflow-hidden border-t border-border/70 bg-foreground/5 px-2"><span class="h-px w-2/3 rounded-full bg-muted-foreground/25"></span></span></span><span class="h-full w-5 shrink-0 rounded-md bg-muted"></span></button>'''
cases = [dict(name='invalid-project', html=invalid, wrapperStyle='width:640px'), dict(name='motion-preview', html=preview, wrapperStyle='width:176px')]
for name,add,delete in [('diff-default','var(--diff-addition)','var(--diff-deletion)'),('diff-blue-orange','light-dark(var(--color-blue-600),var(--color-blue-400))','light-dark(var(--color-orange-600),var(--color-orange-400))')]:
    cases.append(dict(name=name,html=f'<div style="display:flex;width:160px;height:32px"><span style="width:80px;background:{add}"></span><span style="width:80px;background:{delete}"></span></div>'))
(root/'design/component-reference/settings-sweep.json').write_text(json.dumps(dict(component='settings-sweep',source='ProjectActionsSettings.tsx:213-220; PanelAnimationsPreview.tsx:8-82; index.css:2086-2099',states=['rest'],themes=['light','dark'],cases=cases),indent=2)+'\n')
