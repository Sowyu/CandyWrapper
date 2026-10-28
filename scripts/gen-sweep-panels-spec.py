"""Nightly 3824 ComposerCodeBlockLanguagePicker.tsx:110-139 and combobox.tsx search/list geometry."""
import json, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cases = []
for name, labels in [('language-filter', ['Java', 'JavaScript']), ('language-empty', [])]:
    rows = ''.join('<div class="h-7 px-2 py-1 text-sm rounded-sm '+('bg-accent' if i == 0 else '')+'">'+label+'</div>' for i,label in enumerate(labels))
    if not labels: rows = '<div class="px-2 py-1 text-xs text-muted-foreground">No matching languages.</div>'
    html = '<div class="bg-popover text-foreground font-sans" style="width:222px;height:'+str(35+8+28*max(1,len(labels)))+'px"><div class="text-sm px-2 pt-1" style="height:35px">'+('java' if labels else 'nonesuch')+'</div><div class="p-1">'+rows+'</div></div>'
    cases.append({'name':name,'html':html,'native':{},'wrapperStyle':'display:block;width:222px'})
with open(os.path.join(root,'design/component-reference/sweep-panels.json'),'w') as f: json.dump({'component':'sweep-panels','states':['rest'],'themes':['light','dark'],'cases':cases},f,indent=2)
