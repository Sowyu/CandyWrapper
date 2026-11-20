"""Builds the Nightly 4928 capture plans from the 3824 ones: new sandbox IDs and port, 4928 selectors, new states."""
import json
from pathlib import Path
HERE = Path(__file__).resolve().parent
OLD = HERE.parent.parent / "reference-3824/plans"
IDS = json.loads((HERE / "sandbox-ids.json").read_text()); E = IDS["environment"]; T = IDS["threads"]
OLD_IDS = json.loads((OLD / "sandbox-ids.json").read_text())
ATT = "~/CandyWrapper-research/sandbox-4928-ref/attachments"  # the runner expands ~
def load(name):
    s = (OLD / name).read_text().replace("47403", "47404").replace(OLD_IDS["environment"], E)
    for k, v in OLD_IDS["threads"].items(): s = s.replace(v, T[k])
    return json.loads(s)
def js(s, log=True): return {"js": s, "log": log}
# Puts back the layout a state may leave in the browser profile: main sidebar open, thread details card closed.
RESET = js("(()=>{const r=[];const s=document.querySelector('[data-slot=sidebar][data-side=left]');if(s&&s.dataset.state==='collapsed'){document.querySelector('[data-sidebar=trigger]')?.click();r.push('sidebar')}const d=document.querySelector('[aria-label=\"Toggle thread details panel\"][data-popup-open]');if(d){d.click();r.push('details')}return r.join(',')})()")
def dump(p, name):
    # Every fresh state starts from the default layout, whatever the state before it left in the profile.
    if name not in ("error.json", "running.json"):
        for s in p["states"]:
            a = s.get("actions", [])
            if s.get("continue") or any(x is RESET or x == RESET for x in a): continue
            i = next((k + 1 for k, x in enumerate(a) if x.get("key") == "Escape"), 0)
            s["actions"] = a[:i] + [RESET, {"wait": 600}] + a[i:]
    (HERE / name).write_text(json.dumps(p, indent=1) + "\n")
def tp(k): return "/" + E + "/" + T[k]
def js(s, log=True): return {"js": s, "log": log}
def wait(n=800): return {"wait": n}
CLEAR = js("['t3code:diff-panel-state:v1','t3code:right-panel-state:v2','t3code:terminal-state:v1','t3code:composer-drafts:v1'].forEach(k=>localStorage.removeItem(k))", False)
def clean(path, settle=1300): return [CLEAR, {"path": path}, wait(600), {"key": "Escape"}, wait(400), RESET, wait(settle)]
def state(name, path, actions, **kw): return dict({"name": name, "path": path, "actions": actions}, **kw)
def modal_scroll(f): return js("(()=>{const e=[...(document.querySelector('[data-app-modal]')||document).querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+30&&['auto','scroll'].includes(getComputedStyle(e).overflowY)&&e.clientWidth>350).sort((a,b)=>b.clientHeight-a.clientHeight)[0];if(e)e.scrollTop=(e.scrollHeight-e.clientHeight)*%s;return e?.scrollTop})()" % f)
def settings(label): return [{"click": '[aria-label="Settings"]'}, wait(), js("[...document.querySelectorAll('[data-app-modal] button,[data-app-modal] a')].find(e=>e.textContent.trim()===%s)?.click()" % json.dumps(label)), wait(1800)]
PICKER = '[data-chat-provider-model-picker]'

# Main set: keep 3824's states and names, swap the composer selectors for 4928's combined control.
p = load("main.json")
for s in p["states"]:
    n = s["name"][:3].rstrip("-")
    if n == "13": s["actions"] = clean(tp("md")) + [{"click": PICKER}, wait(1200)]
    if n in ("41",): s["actions"] = clean(tp("md")) + [{"key": "e", "meta": True, "shift": True}, wait(1200)]
    if n == "31": s["afterActions"] = [{"key": "b", "meta": True}, wait(800)]
    if n == "42": s["actions"] = clean(tp("md")) + [{"key": "a", "meta": True, "shift": True}, wait(1200)]
dump(p, "main.json")
for name in ["narrow.json", "diff-turn.json", "extras.json", "notice.json", "error.json"]: dump(load(name), name)
c = load("composer-3824.json")
c["states"][0]["actions"] = clean(tp("md")) + [{"key": "e", "meta": True, "shift": True}, wait(1200)]
dump(c, "composer.json")

# Running turn (two real Haiku turns): 01 and 29 as at 3824, then 57 (a burst of two steers, stopped)
# and 56 (a Low-effort follow-up with an image and a text file and no text: model switch row, media, file card).
PICK_HAIKU = [{"key": "m", "meta": True, "shift": True}, wait(800), {"click": '[aria-label="Claude"][data-orientation]'}, wait(600),
              js("(()=>{const o=[...document.querySelectorAll('[role=option]')].find(e=>e.textContent.includes('Haiku 5.5'));o?.click();return !!o})()"), wait(600)]
def effort(level): return [js("[...document.querySelectorAll('[data-effort-level]')].find(e=>e.textContent.trim().startsWith(%s))?.click()" % json.dumps(level)), wait(400)]
def permissions(label): return [{"click": "[data-composer-permissions-trigger]"}, wait(500), {"click": '[role="menuitemradio"][aria-label="%s"]' % label}, wait(500)]
GUARD = js("(()=>{const l=document.querySelector('[data-chat-provider-model-picker]').getAttribute('aria-label');if(!l.startsWith('Claude Haiku 5.5')){const e=document.querySelector('[data-testid=composer-editor]');e.focus();document.execCommand('selectAll');document.execCommand('delete');return 'BLOCKED '+l}return l})()")
EDITOR = {"click": "[data-testid=composer-editor]"}
QUEUE = js("document.querySelector('[aria-label=\"Steer message\"]')?.dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}))")
STOP = [{"click": '[aria-label="Stop generation"]'}, wait(1000), {"until": "!document.querySelector('[aria-label=\"Stop generation\"]')", "timeout": 20000}, wait(1500)]
CLOSE_TOASTS = js("[...document.querySelectorAll('button')].filter(b=>/close|dismiss/i.test(b.getAttribute('aria-label')||'')&&b.closest('[data-slot*=toast],[role=status],[role=alert],li')).map(b=>(b.click(),b.getAttribute('aria-label')))")
IDLE = {"until": "!document.querySelector('[aria-label=\"Stop generation\"]')&&document.querySelector('[aria-label=\"Submit message\"]')", "timeout": 300000}
running = {"base": "http://127.0.0.1:47404", "width": 1100, "height": 780, "scale": 2, "themes": ["dark"], "states": [
    state("01-running-turn", "/", [CLEAR, {"path": "/"}, wait(2500), RESET, wait(800)] + PICK_HAIKU + effort("Medium") + permissions("Full access") + [{"key": "Escape"}, wait(400),
          EDITOR, {"type": "Write a 4000-word story about a lighthouse. No tools."}, GUARD, {"key": "Enter"}, wait(6000), js("location.pathname")]),
    state("01-running-turn", None, [], theme="light", **{"continue": True}),
    state("29-queued-messages", None, [EDITOR, {"type": "First queued note."}, QUEUE, wait(1500), EDITOR, {"type": "Second queued note."}, QUEUE, wait(1500), CLOSE_TOASTS, wait(600)], **{"continue": True}),
    state("29-queued-messages", None, [], theme="light", afterActions=[js("document.querySelector('[aria-label=\"Remove queued message\"]')?.click()"), wait(700),
          js("document.querySelector('[aria-label=\"Remove queued message\"]')?.click()"), wait(700), IDLE, wait(3000), IDLE], **{"continue": True}),
    state("56-model-switch-media", None, [{"key": "m", "meta": True, "shift": True}, wait(800)] + effort("Low") + [{"key": "Escape"}, wait(400),
          {"upload": [ATT + "/sky.png", ATT + "/todo.txt"]}, wait(1500), EDITOR, GUARD, {"key": "Enter"}, wait(5000), IDLE, wait(2000), CLOSE_TOASTS,
          js("(()=>{const e=[...document.querySelectorAll('*')].find(e=>e.children.length===0&&/Medium.*Low/.test(e.textContent));e?.scrollIntoView({block:'center'});return e?.textContent})()"), wait(800)], **{"continue": True}),
    state("56-model-switch-media", None, [], theme="light", **{"continue": True}),
]}
dump(running, "running.json")

# States 4928 added. No model turns.
def native_set(sel, value): return js("(()=>{const e=document.querySelector(%s);if(!e)return 'missing';const d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value');d.set.call(e,%s);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return e.value})()" % (json.dumps(sel), json.dumps(value)))
def dialog_scroll(f): return js("(()=>{const e=[...document.querySelectorAll('[role=dialog] *')].filter(e=>e.scrollHeight>e.clientHeight+30&&['auto','scroll'].includes(getComputedStyle(e).overflowY)).sort((a,b)=>b.clientHeight-a.clientHeight)[0];if(e)e.scrollTop=(e.scrollHeight-e.clientHeight)*%s;return e?.scrollTop})()" % f)
NEW_TASK = [CLEAR, {"path": "/settings/scheduled-tasks"}, wait(2200), {"click": "text=New task"}, wait(1200),
            {"click": "#scheduled-task-title"}, {"type": "Check the notes"}, {"click": "#scheduled-task-prompt"}, {"type": "Summarize notes.md in one line."},
            js("[...document.querySelectorAll('[role=dialog] button')].find(e=>e.textContent.trim()==='Once')?.click()"), wait(800)]
new = {"base": "http://127.0.0.1:47404", "width": 1100, "height": 780, "scale": 2, "themes": ["dark", "light"], "states": [
    state("55-picker-permissions-menu", tp("md"), clean(tp("md")) + [{"click": PICKER}, wait(1000), {"click": "[data-composer-permissions-trigger]"}, wait(900)]),
    state("58-issues-page", "/issues", [CLEAR, {"path": "/issues"}, wait(2500)]),
    state("59-settings-thread-details-items", tp("md"), settings("Appearance") + [js("document.querySelector('[aria-label^=\"Thread details:\"]')?.scrollIntoView({block:'center'})"), wait(500),
          {"click": '[aria-label^="Thread details:"]'}, wait(900)]),
    state("60-thread-details-notes", tp("notes"), clean(tp("notes")) + [{"click": '[aria-label="Toggle thread details panel"]'}, wait(1200)]),
    state("61-sidebar-undo-notice", tp("md"), clean(tp("md")) + [{"hover": '[data-sidebar-row$="%s"]' % T["scratch"]}, wait(400),
          {"click": '[data-sidebar-row$="%s"] [aria-label="Settle thread"]' % T["scratch"]}, wait(900)],
          afterActions=[{"key": "z", "meta": True}, wait(1500)]),
    state("56-model-switch-media", tp("story2"), clean(tp("story2")) + [js("(()=>{const e=[...document.querySelectorAll('*')].find(e=>e.children.length===0&&/Medium.*Low/.test(e.textContent));e?.scrollIntoView({block:'start'});let p=e?.parentElement;while(p&&!(p.scrollHeight>p.clientHeight&&['auto','scroll'].includes(getComputedStyle(p).overflowY)))p=p.parentElement;if(p)p.scrollTop-=80;return e?.textContent})()"), wait(800)]),
    state("57-user-message-burst", tp("story1"), clean(tp("story1")) + [js("(()=>{const e=[...document.querySelectorAll('*')].find(e=>e.children.length===0&&e.textContent.trim()==='Keep it short.');e?.scrollIntoView({block:'center'});return !!e})()"), wait(800)]),
    state("62-side-chat-panel", tp("cmds"), clean(tp("cmds")) + [{"key": "b", "meta": True, "alt": True}, wait(1200), {"click": "text=Side chat"}, wait(1500)]),
    state("64a-scheduled-task-once-top", "/settings/scheduled-tasks", NEW_TASK + [dialog_scroll(0), wait(400)]),
    state("64b-scheduled-task-once", "/settings/scheduled-tasks", NEW_TASK + [native_set("#scheduled-task-run-at", "2026-12-01T09:00"),
          js("[...document.querySelectorAll('[role=dialog] button')].find(e=>e.textContent.trim()==='Once')?.scrollIntoView({block:'start'})"), wait(500)]),
]}
dump(new, "new-4928.json")

