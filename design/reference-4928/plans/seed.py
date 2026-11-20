"""Writes the seed plans that create the 4928 sandbox threads with real Claude Haiku 5.5 turns.
Usage: python3 seed.py <out-dir>. Each seed-*.json costs one turn per state; see README.md."""
import json, sys
from pathlib import Path
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
BASE = "http://127.0.0.1:47404"
def js(s, log=True): return {"js": s, "log": log}
def wait(ms): return {"wait": ms}
PICK_HAIKU = [{"key": "m", "meta": True, "shift": True}, wait(800), {"click": '[aria-label="Claude"][data-orientation]'}, wait(600),
              js("(()=>{const o=[...document.querySelectorAll('[role=option]')].find(e=>e.textContent.includes('Haiku 5.5'));o?.click();return !!o})()"), wait(600)]
def effort(level): return [js("[...document.querySelectorAll('[data-effort-level]')].find(e=>e.textContent.trim().startsWith(%s))?.click()" % json.dumps(level)), wait(400)]
def permissions(label): return [{"click": "[data-composer-permissions-trigger]"}, wait(500),
                                 {"click": '[role="menuitemradio"][aria-label="%s"]' % label}, wait(500)]
# Clears the prompt unless Claude Haiku 5.5 is selected, so a failed pick never bills another model.
GUARD = js("(()=>{const l=document.querySelector('[data-chat-provider-model-picker]').getAttribute('aria-label');if(!l.startsWith('Claude Haiku 5.5')){const e=document.querySelector('[data-testid=composer-editor]');e.focus();document.execCommand('selectAll');document.execCommand('delete');return 'BLOCKED '+l}return l})()")
CLOSE = [{"key": "Escape"}, wait(400)]
def send(prompt, settle=True, timeout=120000):
    a = [{"click": "[data-testid=composer-editor]"}, {"type": prompt}, wait(300), GUARD, {"key": "Enter"}, wait(6000)]
    if settle: a += [{"until": "!document.querySelector('[aria-label=\"Stop generation\"]')", "timeout": timeout}, wait(1500)]
    return a + [js("location.pathname")]
def plan(states): return {"base": BASE, "width": 1100, "height": 780, "scale": 2, "themes": ["dark"], "states": states}
def new_thread(name, prompt, perm=None, settle=True):
    acts = [wait(2500)] + PICK_HAIKU + (permissions(perm) if perm else []) + CLOSE + send(prompt, settle)
    return {"name": name, "path": "/", "actions": acts}
markdown = ("Reply with markdown only, no tools. Include: an H1 and an H2 heading, a small table, a task list with checked "
            "and unchecked items, three short code blocks (python, typescript, bash), a GitHub alert written as > [!NOTE], "
            "and a bulleted list. Keep it brief.")
commands = "Run these shell commands one at a time: `ls`, `git status --short`, `ls /nonexistent-dir`. Then reply in one short line."
question = ("Use your question tool (AskUserQuestion) to ask me two clarifying questions about a small CLI tool, one with "
            "options. Do not do anything else until I answer.")
approval = "Create approval-4928.txt containing hello."
notes = ("Add a one-line docstring to greet in hello.py and append the line '- Added a docstring.' to notes.md. "
         "No other changes. Reply in one short line.")
json.dump(plan([new_thread("seed-markdown", markdown), new_thread("seed-commands", commands),
                new_thread("seed-question", question, settle=False), new_thread("seed-approval", approval, "Supervised", settle=False),
                new_thread("seed-notes", notes, "Full access")]), open(OUT / "seed-turns-1-5.json", "w"), indent=1)

# Second batch, after the demo repo moved to /Users/Shared/cw-sandbox-4928 so tool rows show no account name.
IDS = json.loads((Path(__file__).resolve().parent / "sandbox-ids.json").read_text()) if (Path(__file__).resolve().parent / "sandbox-ids.json").exists() else None
ATT = "~/CandyWrapper-research/sandbox-4928-ref/attachments"  # the runner expands ~
def thread_path(key): return "/%s/%s" % (IDS["environment"], IDS["threads"][key])
def followup(name, key, prompt, level=None, files=None, dry=False):
    acts = [js("['t3code:composer-drafts:v1'].forEach(k=>localStorage.removeItem(k))"), {"path": thread_path(key)},
            wait(3000), {"key": "m", "meta": True, "shift": True}, wait(800)] + (effort(level) if level else []) + CLOSE
    if files: acts += [{"upload": files}, wait(1500)]
    if dry: acts += [{"click": "[data-testid=composer-editor]"}, {"type": prompt}, GUARD, wait(500)]
    else: acts += send(prompt)
    return {"name": name, "path": thread_path(key), "actions": acts}
if IDS:
    full_access_md = {"name": "seed-md-full-access", "path": thread_path("md"),
                      "actions": [wait(3000), {"key": "m", "meta": True, "shift": True}, wait(800)] + permissions("Full access") + CLOSE + [wait(800)]}
    media = followup("seed-media", "notes", "Say ok.", "Low", [ATT + "/sky.png", ATT + "/todo.txt"])
    json.dump(plan([dict(media, name="dry-media", actions=followup("x", "notes", "Say ok.", "Low", [ATT + "/sky.png", ATT + "/todo.txt"], dry=True)["actions"])]),
              open(OUT / "seed-dry-media.json", "w"), indent=1)
    json.dump(plan([full_access_md, new_thread("seed-approval-2", approval, "Supervised", settle=False), media]),
              open(OUT / "seed-turns-6-7.json", "w"), indent=1)
