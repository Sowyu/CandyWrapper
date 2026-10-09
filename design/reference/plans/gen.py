import json,sys
def tag(sel,text): 
    return {"js":"document.querySelectorAll('[data-cap]').forEach(e=>e.removeAttribute('data-cap')); [...document.querySelectorAll(%s)].filter(e=>e.offsetParent!==null).find(e=>e.textContent.includes(%s)).setAttribute('data-cap','1')"%(json.dumps(sel),json.dumps(text))}
def ctag(sel,text):
    return [tag(sel,text),{"click":"[data-cap=\"1\"]"}]
def model(name="Haiku 5.5"):
    return [{"click":"[data-slot=popover-trigger]"},{"wait":500}]+ctag("[role=option]",name)+[{"wait":400}]
def mode(name):
    return [{"click":"[aria-label=\"Runtime mode\"]"},{"wait":400}]+ctag("[role=option]",name)+[{"wait":400}]
def send(text,wait=1500):
    return [{"click":".composer-tiptap"},{"type":text},{"wait":300},{"key":"Enter"},{"wait":wait}]
def plan(name,states,themes=("dark","light"),w=1100,h=780):
    return {"base":"http://127.0.0.1:47391","width":w,"height":h,"scale":2,"themes":list(themes),"states":states}
def dump(p,f): json.dump(p,open(f,"w"),indent=1)
PATH={"js":"location.pathname","log":True}
E="cc77e38e-569c-437d-b3ff-16ac64620624"
T=dict(approval="23245e8d-9f47-48e9-8fd2-69d6494acd8b",input="bdbff8f9-22f2-4f67-ba88-213a966febf0",
 md="a959b73c-f2b2-4fe9-9ed0-1e1c976fb922",cmds="e9ec2c7b-a21c-4651-89c2-276bf1c5fe84",notes="c4ff4c86-9db4-4d8a-a846-a1493c31e49b",story="9f399107-2798-4ee1-865d-53f55d45ea29")
def tp(k): return "/%s/%s"%(E,T[k])
ESC=[{"key":"Escape"},{"wait":500}]
def S(name,path,actions,**kw):
    d={"name":name,"path":path,"actions":ESC+actions}; d.update(kw); return d
def scroll(frac):
    return {"js":"(()=>{const els=[...document.querySelectorAll('main *, [data-slot] *')].filter(e=>e.scrollHeight>e.clientHeight+50&&['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.clientWidth>600);const e=els.sort((a,b)=>b.clientHeight-a.clientHeight)[0];if(!e)return 'none';e.scrollTop=(e.scrollHeight-e.clientHeight)*%s;return e.scrollTop})()"%frac,"log":True}
story="Write a 700 word story about a lighthouse keeper, in 8 paragraphs. No tools."
RESET="['t3code:diff-panel-state:v1','t3code:right-panel-state:v2','t3code:terminal-state:v1','t3code:composer-drafts:v1'].forEach(k=>localStorage.removeItem(k))"
def S(name,path,actions,reset=True,esc=True,**kw):
    pre=[{"js":RESET},{"path":path},{"wait":600}] if reset else []
    d={"name":name,"path":path,"actions":pre+(ESC if esc else [])+actions}; d.update(kw); return d
def tagattr(sel,sub):
    return {"js":"document.querySelectorAll('[data-cap]').forEach(e=>e.removeAttribute('data-cap')); [...document.querySelectorAll(%s)].filter(e=>e.offsetParent!==null).find(e=>(e.getAttribute('aria-label')||'').toLowerCase().includes(%s)).setAttribute('data-cap','1')"%(json.dumps(sel),json.dumps(sub.lower()))}
CAP={"click":"[data-cap=\"1\"]"}
def NS(name,path,actions): return S(name,path,actions,esc=False)
