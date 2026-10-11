"""WP7.12b visual states from the official component markup. No browser UI ships."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {'__file__': os.path.join(ROOT, 'scripts/gen-files-spec.py')}
src = open(ns['__file__']).read()
exec(src[:src.index('ROWS = [')], ns)
button = ns['button']
import ast
forms = {'__file__': os.path.join(ROOT, 'scripts/gen-forms-spec.py')}
tree = ast.parse(open(forms['__file__']).read())
for node in tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom, ast.Assign, ast.FunctionDef)):
        exec(compile(ast.Module(body=[node], type_ignores=[]), forms['__file__'], 'exec'), forms)
input_html, textarea_html = forms['input_html'], forms['textarea_html']
cases = []
# DiffCommentAnnotation.tsx:100-145.
html = ('<div style="width:480px;height:114px" class="bg-background text-foreground px-3 py-2 font-sans">'
        + textarea_html('sm', placeholder='Add a comment…') +
        '<div class="mt-1.5 flex items-center gap-1"><span class="mr-auto text-3xs text-muted-foreground/70">⌘/Ctrl Enter to send</span>'
        + button('ghost-muted', 'xs', 'Cancel') + button('default', 'xs', 'Comment', extra='opacity-50') + '</div></div>')
cases.append({'name': 'review-draft', 'html': html, 'native': {'case': 'review-draft'}, 'wrapperStyle': 'display:block;width:480px'})
# DeviceHostEditor.tsx:79-153. Field widths and vertical spacing copied from the editor.
html = '<div style="width:440px;height:380px" class="bg-background text-foreground text-sm">'
for label, placeholder in [('Name', 'Mac mini'), ('SSH target', 'user@host or SSH alias'), ('Identity file', 'SSH config default'), ('Port', 'Default')]:
    html += '<label class="block" style="height:66px"><span class="block h-5">'+label+'</span><div class="mt-1">'+input_html(placeholder=placeholder)+'</div></label>'
html += '<div class="flex justify-end" style="margin-top:4px">'+button('outline','sm','Test connection')+'</div><p class="text-xs text-muted-foreground" style="margin-top:10px">Check access before saving</p></div>'
cases.append({'name':'ssh-host-form','html':html,'native':{'case':'ssh-host-form'},'wrapperStyle':'display:block;width:440px'})
# DiffCommentAnnotation.tsx:68-97, submitted card. Rest state hides the delete button.
html = ('<div style="width:480px;height:40px" class="flex min-w-0 items-start gap-2.5 border-s-2 border-primary/55 bg-primary/[0.045] px-3 py-2.5 font-sans text-foreground">'
        + '<svg class="mt-0.5 size-3.5 shrink-0 text-primary/70" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>'
        + '<p class="min-w-0 flex-1 whitespace-pre-wrap text-sm leading-5">Keep the historical revision.</p></div>')
cases.append({'name':'review-card','html':html,'native':{'case':'review-card'},'wrapperStyle':'display:block;width:480px'})
# DeviceHostUpdates.tsx:29-71 with the shared DeviceToolVersions trigger.
html = ('<div style="width:480px;height:132px" class="relative rounded-md border border-border/60 text-xs">'
        '<div style="position:absolute;left:12px;top:8px" class="font-medium">Build host</div>'
        '<div style="position:absolute;left:12px;right:12px;top:28px" class="text-muted-foreground">Device support could not start.<br>Check the host connection and network access, then retry. Your device settings are saved.</div>'
        '<div style="position:absolute;right:12px;top:8px">'+button('outline','compact','Retry')+'</div>'
        '<div style="position:absolute;left:8px;bottom:4px;width:142px">'+button('ghost-muted','xs','Versions', extra='w-full')+'</div></div>')
cases.append({'name':'host-failed','html':html,'native':{'case':'host-failed'},'wrapperStyle':'display:block;width:480px'})
with open(os.path.join(ROOT,'design/component-reference/panel-leftovers.json'),'w') as f:
    json.dump({'component':'panel-leftovers','source':'DiffCommentAnnotation.tsx:100-145; DeviceHostEditor.tsx:79-153','states':['rest'],'themes':['light','dark'],'cases':cases}, f, indent=1)
