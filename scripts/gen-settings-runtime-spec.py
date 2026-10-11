"""WP7.13b references: appearanceFonts.ts:97-136 and ResourceTelemetryDiagnostics.tsx:401-467."""
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent
buckets = [(0,0,0),(12,60,20),(60,30,10),(30,10,70),(3,1,0)]
legend = ''.join(f'<span class="inline-flex items-center gap-1.5"><span class="h-1.5 w-3 rounded-full {color}"></span>{label}</span>' for label,color in [('CPU average','bg-foreground/70'),('I/O reads','bg-info/70'),('I/O writes','bg-warning/80')])
bars = ''
for cpu,read,write in buckets:
    values = [0 if cpu == 0 else max(2,cpu/60*100),0 if read == 0 else max(1,read/80*100),0 if write == 0 else max(1,write/80*100)]
    bars += '<div class="grid h-full min-w-1 flex-1 grid-cols-3 items-end gap-px">' + ''.join(f'<span class="block rounded-t-sm {color}" style="height:{v}%"></span>' for v,color in zip(values,['bg-foreground/65','bg-info/70','bg-warning/80'])) + '</div>'
chart = f'<div class="border-t border-border/60 px-4 py-4 sm:px-5"><div class="mb-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-3xs text-muted-foreground/65">{legend}</div><div class="flex h-32 items-end gap-1 overflow-hidden rounded-lg border border-border/40 bg-muted/8 px-2 pt-3 pb-2">{bars}</div></div>'
cases = [dict(name='telemetry',html=chart,wrapperStyle='width:600px',native={'kind':'telemetry'})]
for name,size,code,family in [('default',14,13,'-apple-system'),('custom',17.5,16,'Menlo')]:
    html=f'<div style="width:360px;height:52px;color:var(--foreground)"><div style="font-family:{family};font-size:{size}px;line-height:24px">The quick brown fox 0O 1lI</div><div style="font-family:Menlo;font-size:{code}px;line-height:24px">let value = 42;</div></div>'
    cases.append(dict(name='fonts.'+name,html=html,native={'kind':name}))
(root/'design/component-reference/settings-runtime.json').write_text(json.dumps(dict(component='settings-runtime',source='apps/web/src/appearanceFonts.ts; components/settings/ResourceTelemetryDiagnostics.tsx',states=['rest'],themes=['light','dark'],cases=cases),indent=2)+'\n')
