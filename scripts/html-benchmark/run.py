#!/usr/bin/env python3
"""Run isolated Debug UI cases and sample the app's responsible WebKit processes."""
import argparse, ctypes, datetime, json, os, pathlib, pwd, signal, statistics, subprocess, time
REPO = pathlib.Path(__file__).resolve().parents[2]
ROOT = pathlib.Path.home()/'CandyWrapper-research/sandbox/html-benchmark'
APP = pathlib.Path('/tmp/cw-dd-html-benchmark/Build/Products/Debug/CandyWrapper.app')
p=argparse.ArgumentParser(); p.add_argument('--tag',default='baseline'); p.add_argument('--case',choices=['light','collage','chart']); p.add_argument('--mode',choices=['thread','conductor']); p.add_argument('--appearance',choices=['dark','light']); a=p.parse_args()
assert APP.exists(), 'Build with scripts/build-test-app html-benchmark'
assert a.tag.replace('-','').replace('_','').isalnum()
probe=ROOT/'probe'
if not probe.exists():
    subprocess.run([str(REPO/'scripts/preflight')],check=True)
    subprocess.run(['swiftc','-O',str(REPO/'scripts/perf/probe.swift'),'-o',str(probe)],check=True)
responsible=ctypes.CDLL('/usr/lib/libSystem.B.dylib').responsibility_get_pid_responsible_for_pid
responsible.argtypes=[ctypes.c_int]; responsible.restype=ctypes.c_int

def owned_processes(app_pid, preexisting):
    rows=subprocess.check_output(['ps','-axo','pid,ppid,rss,comm'],text=True).splitlines()[1:]
    answer=[]; competing=[]
    for row in rows:
        bits=row.split(None,3)
        if len(bits)!=4: continue
        pid,ppid,rss=map(int,bits[:3]); name=bits[3]
        if pathlib.Path(name).name in ['xcodebuild','swift-frontend','swift-build','swiftc','clang','ld','xctest','swiftpm-testing-helper']:
            competing.append({'pid':pid,'name':name})
        if pid==app_pid or ('WebKit' in name and pid not in preexisting and responsible(pid)==responsible(app_pid)):
            answer.append({'pid':pid,'ppid':ppid,'rssKiB':rss,'name':name,'responsible':responsible(pid),'attribution':'app' if pid==app_pid else 'new-webkit-same-responsibility'})
    if answer:
        usage=subprocess.check_output([str(probe),'rusage']+[str(r['pid']) for r in answer],text=True)
        byid={v['pid']:v for v in map(json.loads,usage.splitlines())}
        for r in answer: r.update(byid.get(r['pid'],{}))
    return answer,competing

def capture(pid,path):
    out=subprocess.run([str(probe),'window',str(pid),'2'],capture_output=True,text=True)
    if out.returncode: return
    w=json.loads(out.stdout)
    rect=','.join(str(round(w[k])) for k in ['x','y','w','h'])
    subprocess.run(['sudo','launchctl','asuser',str(os.getuid()),'sudo','-u',pwd.getpwuid(os.getuid()).pw_name,'/usr/sbin/screencapture','-x','-R'+rect,str(path)],check=True)

cases=[(k,m,'dark') for k in ['light','collage','chart'] for m in ['thread','conductor']]+[('collage',m,'light') for m in ['thread','conductor']]
cases=[v for v in cases if (not a.case or v[0]==a.case) and (not a.mode or v[1]==a.mode) and (not a.appearance or v[2]==a.appearance)]
# Lock ownership is an external precondition, so one command can never monopolize the screen silently.
owner=subprocess.check_output([str(REPO/'scripts/ui/screen-lock'),'who'],text=True)
assert owner.startswith('html-benchmark '), 'Take screen-lock html-benchmark first'
start=time.monotonic(); summaries=[]
for kind,mode,appearance in cases:
    assert time.monotonic()-start<780, 'Give the screen back before 15 minutes'
    output=ROOT/a.tag/(kind+'-'+mode+'-'+appearance); output.mkdir(parents=True,exist_ok=True)
    assert not (output/'events.jsonl').exists(), 'Use a fresh --tag; never overwrite a baseline'
    subprocess.run(['defaults','delete','dev.candywrapper.test.html-benchmark'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    env=dict(os.environ,CANDY_APP=str(APP),CANDY_THEME='dither',CANDY_THREAD_CACHE='off')
    args=[str(REPO/'scripts/run-app'),'--server','http://127.0.0.1:47391','--token-file',str(ROOT.parent/'session.token'),'--fake-t3-connect','--appearance',appearance,'--thread-preview','--html-benchmark',str(ROOT/'manifest.json'),kind,mode,str(output)]
    app_log=open(output/'app.log','w')
    preexisting={int(row.split()[0]) for row in subprocess.check_output(['ps','-axo','pid,comm'],text=True).splitlines()[1:] if 'WebKit' in row}
    proc=subprocess.Popen(args,env=env,stdout=app_log,stderr=subprocess.STDOUT)
    pid=None; deadline=time.monotonic()+100; last_sample=0; captured=set(); samples=[]
    try:
        while proc.poll() is None and time.monotonic()<deadline:
            events=[]
            if (output/'events.jsonl').exists():
                for line in (output/'events.jsonl').read_text().splitlines():
                    try: events.append(json.loads(line))
                    except json.JSONDecodeError: pass
                if events: pid=events[0]['pid']
            now=time.monotonic()
            if pid and now-last_sample>=1:
                processes,competing=owned_processes(pid,preexisting)
                sample={'time':time.time(),'eventMs':events[-1]['ms'],'phase':events[-1]['phase'],'processes':processes,'competingBuilds':competing}
                samples.append(sample); last_sample=now
                with (output/'memory.jsonl').open('a') as f: f.write(json.dumps(sample)+'\n')
            if pid:
                for e in events:
                    if e['event']=='capture' and e['label'] in ['back-10','back-6','back-1','return-10'] and e['label'] not in captured:
                        capture(pid,output/(e['label']+'.png')); captured.add(e['label'])
            time.sleep(.1)
        if proc.poll() is None:
            if pid: os.kill(pid,signal.SIGTERM)
            raise RuntimeError('Benchmark timed out; inspect '+str(output))
        if not events or not any(e['event']=='done' for e in events): raise RuntimeError('Benchmark did not finish: '+str(output))
    finally:
        if pid and proc.poll() is None: os.kill(pid,signal.SIGTERM)
        proc.wait(timeout=10); app_log.close()
    arrivals={e['page']:e['ms'] for e in events if e['event']=='arrival'}
    ready=[e for e in events if e['event']=='native-layout' and e['phase']=='arrival']
    first_ready={}
    for e in ready: first_ready.setdefault(e['page'],e)
    cold=[{'page':e['page'],'ms':e['ms']-arrivals[e['page']],'height':e['height']} for e in first_ready.values()]
    counts={phase:sum(e['event']=='activate' and e['phase']==phase for e in events) for phase in ['arrival','back','return']}
    blank=[e for e in events if e['event']=='viewport' and any(not f['live'] for f in e['frames'])]
    app_peak=max((r.get('footprint',0) for s in samples for r in s['processes'] if r['pid']==pid),default=0)
    total_peak=max((sum(r.get('footprint',0) for r in s['processes']) for s in samples),default=0)
    web_peak=max((sum('WebKit' in r['name'] for r in s['processes']) for s in samples),default=0)
    summary={'kind':kind,'mode':mode,'appearance':appearance,'exit':proc.returncode,'cold':cold,'coldMedianMs':statistics.median(v['ms'] for v in cold) if cold else None,'activations':counts,'blankViewports':len(blank),'appPeakFootprintBytes':app_peak,'combinedPeakFootprintBytes':total_peak,'webKitPeakProcesses':web_peak,'path':str(output)}
    summary['noisy']=any(s['competingBuilds'] for s in samples)
    summary['memoryAttribution']='New WebKit processes sharing inherited responsibility, excluding pre-launch PIDs; no unrelated WebKit app launched during runs'
    (output/'summary.json').write_text(json.dumps(summary,indent=2)); summaries.append(summary)
    print(json.dumps(summary),flush=True)
    time.sleep(2)
(ROOT/a.tag/'summary.json').write_text(json.dumps(summaries,indent=2))
