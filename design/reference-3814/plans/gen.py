"""Copy the established states and adapt their routes/selectors for Nightly 3814."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent
OLD=HERE.parent.parent/'reference/plans'
IDS=json.loads((HERE/'sandbox-ids.json').read_text())
E=IDS['environment'];T=IDS['threads']
oldE='cc77e38e-569c-437d-b3ff-16ac64620624'
oldT={'approval':'23245e8d-9f47-48e9-8fd2-69d6494acd8b','input':'bdbff8f9-22f2-4f67-ba88-213a966febf0','md':'a959b73c-f2b2-4fe9-9ed0-1e1c976fb922','cmds':'e9ec2c7b-a21c-4651-89c2-276bf1c5fe84','notes':'c4ff4c86-9db4-4d8a-a846-a1493c31e49b'}
def load(name):
 s=(OLD/name).read_text().replace('47391','47402').replace(oldE,E)
 for k,v in oldT.items():s=s.replace(v,T[k])
 return json.loads(s)
def dump(p,name): (HERE/name).write_text(json.dumps(p,indent=2)+'\n')
def tp(k):return '/'+E+'/'+T[k]
def js(s):return {'js':s,'log':True}
def wait(n=800):return {'wait':n}
def scroll(f):return js("(()=>{const e=[...(document.querySelector('[data-app-modal]')||document).querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+30&&['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.clientWidth>350).sort((a,b)=>b.clientHeight-a.clientHeight)[0];if(e)e.scrollTop=(e.scrollHeight-e.clientHeight)*%s;return e?.scrollTop})()"%f)
def clicktext(s):return {'click':'text='+s}
p=load('main.json');out=[]
for s in p['states']:
 name=s['name'];n=name[:2]
 if n in ['22','23','26']:continue
 if '/settings/' in s['path']:
  target=s['path'].replace('/settings/storage','/settings/maintenance').replace('/settings/integrations','/settings/browser')
  labels={'general':'General','appearance':'Appearance','providers':'Providers','keybindings':'Keybindings','source-control':'Source control','projects':'Projects','connections':'Environments','archived':'Archive','scheduled-tasks':'Scheduled tasks','snap-shot':'SnapShots','maintenance':'Maintenance','diagnostics':'Maintenance','browser':'Browser'}
  label=labels[target.rsplit('/',1)[1]]
  s['path']=tp('md');s['actions']=[{'click':'[aria-label="Settings"]'},wait(),js("[...document.querySelectorAll('[data-app-modal] button')].find(e=>e.textContent.trim()==="+json.dumps(label)+").click()"),wait(1800)]
  if n=='16':s['actions'] += [scroll(0 if '16a' in name else .5 if '16b' in name else 1)]
  if n=='18':s['actions'] += [clicktext('Claude'),wait(),scroll(.45)]
  if n=='39':s['actions'] += [js("[...document.querySelectorAll('[data-app-modal] a')].find(e=>e.textContent.trim()==='View diagnostics').click()"),wait(1800)]
 if n=='13':s['actions']=s['actions'][:6]+[js("document.querySelector('[data-chat-provider-model-picker-label]').closest('button').click()"),wait(1200)]
 if n=='20':
  s['actions']=s['actions'][:6]+[js("(()=>{const e=document.querySelector('[data-sidebar-row$=\""+T['md']+"\"]');const r=e.getBoundingClientRect();e.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:r.x+60,clientY:r.y+20,button:2}));})()"),wait()]
 if n=='21':s['actions']=s['actions'][:6]+[{'click':'[aria-label="Toggle thread details panel"]'},{'click':'[aria-label="Git action options"]'},wait()]
 if n=='41':s['actions']=s['actions'][:6]+[{'click':'[data-composer-shortcut="composer.effort"]'},wait()]
 if n=='42':s['actions']=s['actions'][:6]+[{'click':'[aria-label="Runtime mode"]'},wait()]
 if n in ['09','10']:
  s['actions']=s['actions'][:6]+[{'key':'d','meta':True},wait(1200),{'click':'[aria-label="'+('Split diff view' if n=='09' else 'Stacked diff view')+'"]'},js("document.querySelector('[aria-label=\"Expand all files\"]')?.click()"),wait()]

 if n in ['32','33']:s['path']=target;s['actions']=[wait(1800)]
 out.append(s)
p['states']=out;dump(p,'main.json')
for name in ['narrow.json','diff-turn.json']:
 p=load(name)
 if name=='narrow.json':
  for s in p['states']:
   s['actions']=[scroll(.3) if 'const els=' in a.get('js','') else a for a in s['actions']]
 if name=='diff-turn.json':
  p['states'][1]['actions'] += [{'click':'[aria-label="Stacked diff view"]'},wait()]
 dump(p,name)
p=load('main.json');p['states']=[s for s in p['states'] if s['name'].startswith(('05-','06-'))];dump(p,'panels-3814.json')
