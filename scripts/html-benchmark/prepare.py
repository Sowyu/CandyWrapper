#!/usr/bin/env python3
"""Generate fixed sandbox HTML attachments with the pinned T3 bootstrap. No model turns."""
import argparse, base64, hashlib, json, pathlib, random, re, struct, uuid, zlib
ROOT = pathlib.Path.home() / 'CandyWrapper-research/sandbox'
p = argparse.ArgumentParser()
p.add_argument('--root', type=pathlib.Path, default=ROOT / 'html-benchmark')
p.add_argument('--source', type=pathlib.Path, default=pathlib.Path.home() / 'CandyWrapper-research/t3code')
a = p.parse_args()
a.root = a.root.resolve()
assert a.root.is_relative_to(ROOT.resolve()), 'All benchmark files must stay in the sandbox'
a.root.mkdir(parents=True, exist_ok=True)
source = (a.source / 'packages/shared/src/htmlRender.ts').read_text()
css_part = source.split('const BASE_CSS =', 1)[1].split('function rootRule', 1)[0]
css = ''.join(json.loads(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', '\n'.join(s for s in css_part.splitlines() if not s.lstrip().startswith('//'))))
script = re.search(r'const BOOTSTRAP_SCRIPT = `(.*?)`;', source, re.S)[1]
script = script.replace('\\\\', '\\').replace('\\`', '`')
script = script.replace('${JSON.stringify(BASE_CSS)}', json.dumps(css)).replace('${THEME_FRAGMENT_KEY}', 't3-theme')
for name in re.findall(r'\$\{JSON.stringify\((\w+)\)\}', script):
    if name == 'EVENT_CODE_SHORTCUT_KEYS':
        key_source = (a.source / 'packages/shared/src/keybindings.ts').read_text()
        block = re.search(r'export const EVENT_CODE_SHORTCUT_KEYS[^=]*=\s*({.*?})', key_source, re.S)[1]
        value = {k: json.loads(v) for k,v in re.findall(r'(\w+):\s*("(?:[^"\\]|\\.)*")', block)}
    else:
        value = json.loads(re.search(r'const '+name+r' = ("[^"\n]*")', source)[1])
    script = script.replace('${JSON.stringify('+name+')}', json.dumps(value))
assert '${' not in script
bootstrap = '<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><style id="t3-theme">'+css+'</style><script>'+script+'</script>'

def png(index):
    rng = random.Random(112358 + index)
    w = h = 240
    rows = b''.join(b'\0' + bytes(rng.randrange(256) for _ in range(w*3)) for y in range(h))
    def chunk(t, data):
        return struct.pack('!I', len(data)) + t + data + struct.pack('!I', zlib.crc32(t+data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', w,h,8,2,0,0,0)) + chunk(b'IDAT', zlib.compress(rows,6)) + chunk(b'IEND',b'')
images = [png(i) for i in range(6)]
for i, data in enumerate(images): (a.root / ('tile-%d.png'%i)).write_bytes(data)
collage = '<div class="grid">' + ''.join('<figure><img width="240" height="240" src="data:image/png;base64,'+base64.b64encode(data).decode()+'"><figcaption>Local tile %d</figcaption></figure>'%i for i,data in enumerate(images)) + '</div>'
light = '<div class="cards">' + ''.join('<article><b>Metric %d</b><p>%d completed</p></article>'%(i, i*137) for i in range(4)) + '</div><p>A small HTML report with deterministic text, cards and a table.</p><table>'+''.join('<tr><td>Region %d</td><td>%d</td><td>Ready</td></tr>'%(i,i*31) for i in range(8))+'</table>'
chart = '<canvas id="chart" width="680" height="330" style="width:100%;height:330px"></canvas><p>1,200 deterministic chart samples, rendered once.</p><script>const c=document.getElementById("chart"),x=c.getContext("2d");x.strokeStyle=getComputedStyle(document.documentElement).getPropertyValue("--chart-2").trim()||"#2dd4bf";x.lineWidth=2;x.beginPath();for(let i=0;i<1200;i++){let y=160+100*Math.sin(i/41)+30*Math.sin(i/13);i?x.lineTo(i*680/1199,y):x.moveTo(0,y)}x.stroke();</script>'
finish = '''<script>window.addEventListener('load',async()=>{await document.fonts.ready;await Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));requestAnimationFrame(()=>requestAnimationFrame(()=>{parent.postMessage({benchmark:'paint-opportunity',height:Math.ceil(document.body.getBoundingClientRect().height),images:document.images.length,broken:[...document.images].filter(i=>!i.naturalWidth).length},'*')}))});</script>'''
styles = '<style>body{padding:20px;box-sizing:border-box}h2{margin:0 0 12px;font-size:22px}p{margin:12px 0}article,table,figure{border:1px solid var(--border);border-radius:10px;background:var(--card)}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}article{padding:12px}table{width:100%;border-collapse:collapse}td{padding:8px;border-bottom:1px solid var(--border)}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}figure{margin:0;overflow:hidden}img{display:block;width:100%;height:auto}figcaption{padding:6px 10px;font-size:12px}</style>'
attachments = ROOT / 't3home/userdata/attachments'
assert attachments.is_dir(), 'Start scripts/sandbox-server first'
manifest = {'version':1,'server':'http://127.0.0.1:47391','imageBytes':sum(map(len,images)), 'bootstrapSHA256':hashlib.sha256(script.encode()).hexdigest(),'cases':{}}
for kind, body in [('light',light),('collage',collage),('chart',chart)]:
    html = '<!doctype html><html><head>'+bootstrap+styles+'</head><body><h2>HTML benchmark: '+kind+'</h2>'+body+finish+'</body></html>'
    (a.root/(kind+'.html')).write_text(html)
    pages=[]
    for i in range(10):
        aid = 'html-benchmark-'+str(uuid.uuid5(uuid.NAMESPACE_URL,'candywrapper-html-benchmark-v1-'+kind+'-'+str(i)))+'-html'
        path = attachments/(aid+'.html')
        path.write_text(html)
        pages.append({'attachmentId':aid,'title':kind+' page '+str(i+1),'height':1500,'fileName':kind+'.html'})
    manifest['cases'][kind]={'bytes':len(html.encode()),'sha256':hashlib.sha256(html.encode()).hexdigest(),'pages':pages}
(a.root/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(a.root/'manifest.json')
