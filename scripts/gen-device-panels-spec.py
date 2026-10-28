"""Nightly 3824 DevicePanel.tsx:233-310 empty and unavailable states, in T3's exact classes."""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {'__file__': os.path.join(ROOT, 'scripts/gen-files-spec.py')}
src = open(ns['__file__']).read()
exec(src[:src.index('ROWS = [')], ns)
button, lucide = ns['button'], ns['lucide']
cases = []
for name, detail in [('empty', 'No simulators or emulators were found on this environment.'), ('unavailable', 'The device hub failed to start.')]:
    html = ('<div style="width:480px;height:360px" class="flex bg-background"><div class="scrollbar-gutter-both flex size-full flex-col overflow-y-auto px-5 py-8 text-sm text-muted-foreground">'
            '<div class="mx-auto flex w-full max-w-xl flex-col gap-6 my-auto items-center text-center">'
            + lucide('smartphone', 'size-6 opacity-60') + '<p class="max-w-sm">' + detail + '</p>'
            + button('outline', 'sm', 'Refresh devices') + '</div></div></div>')
    cases.append({'name': name, 'html': html, 'native': {'case': name}, 'wrapperStyle': 'display:block;width:480px'})
with open(os.path.join(ROOT, 'design/component-reference/device-panels.json'), 'w') as f:
    json.dump({'component': 'device-panels', 'source': 'apps/web/src/components/device/DevicePanel.tsx:233-310', 'states': ['rest'], 'themes': ['light', 'dark'], 'cases': cases}, f, indent=1)
