#!/usr/bin/env python3
"""Capture page one before page two arrives, using the already-built benchmark app."""
import argparse, json, os, pathlib, pwd, signal, subprocess, time
REPO=pathlib.Path(__file__).resolve().parents[2]
ROOT=pathlib.Path.home()/'CandyWrapper-research/sandbox/html-benchmark'
p=argparse.ArgumentParser();p.add_argument('--tag',default='baseline-one-page');p.add_argument('--label',choices=['before','after'],default='before');a=p.parse_args()
assert a.tag.replace('-','').replace('_','').isalnum()
APP=pathlib.Path('/tmp/cw-dd-html-benchmark/Build/Products/Debug/CandyWrapper.app')
assert APP.exists() and (ROOT/'probe').exists(), 'Needs existing benchmark app and probe; this script never builds'
assert subprocess.check_output([str(REPO/'scripts/ui/screen-lock'),'who'],text=True).startswith('html-benchmark ')
for mode in ['thread','conductor']:
    for appearance in ['dark','light']:
        out=ROOT/a.tag/('collage-'+mode+'-'+appearance);out.mkdir(parents=True,exist_ok=True)
        assert not (out/'events.jsonl').exists(), 'Do not overwrite before captures'
        subprocess.run(['defaults','delete','dev.candywrapper.test.html-benchmark'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        env=dict(os.environ,CANDY_APP=str(APP),CANDY_THEME='dither',CANDY_THREAD_CACHE='off')
        args=[str(REPO/'scripts/run-app'),'--server','http://127.0.0.1:47391','--token-file',str(ROOT.parent/'session.token'),'--fake-t3-connect','--appearance',appearance,'--thread-preview','--html-benchmark',str(ROOT/'manifest.json'),'collage',mode,str(out)]
        app_log=open(out/'app.log','w');proc=subprocess.Popen(args,env=env,stdout=app_log,stderr=subprocess.STDOUT)
        pid=None
        try:
            deadline=time.monotonic()+20
            while time.monotonic()<deadline:
                if proc.poll() is not None: raise RuntimeError('App exited: '+str(out))
                path=out/'events.jsonl'
                if path.exists():
                    events=[json.loads(s) for s in path.read_text().splitlines()]
                    if events: pid=events[0]['pid']
                    if any(e['event']=='arrival' and e['count']>1 for e in events): raise RuntimeError('Missed first page capture window')
                    if any(e['event']=='native-layout' and e['page']=='collage page 1' for e in events): break
                time.sleep(.02)
            else: raise RuntimeError('First page never became ready')
            time.sleep(.25)
            gui=['sudo','launchctl','asuser',str(os.getuid()),'sudo','-u',pwd.getpwuid(os.getuid()).pw_name]
            subprocess.run(gui+['/tmp/cw-ui/front',str(pid)],check=True,stdout=subprocess.DEVNULL)
            w=json.loads(subprocess.check_output([str(ROOT/'probe'),'window',str(pid),'2'],text=True))
            rect=','.join(str(round(w[k])) for k in ['x','y','w','h'])
            dest=out/(a.label+'.png')
            subprocess.run(gui+['/usr/sbin/screencapture','-x','-R'+rect,str(dest)],check=True)
            after=[json.loads(s) for s in path.read_text().splitlines()]
            assert not any(e['event']=='arrival' and e['count']>1 for e in after), 'Second page arrived during capture'
            (out/'capture.json').write_text(json.dumps({'page':1,'firstPageOnly':True,'appearance':appearance,'mode':mode,'window':w,'screenScale':1,'path':str(dest)},indent=2))
            print(dest,flush=True)
        finally:
            if pid and proc.poll() is None: os.kill(pid,signal.SIGTERM)
            proc.wait(timeout=10);app_log.close()
        time.sleep(1)
