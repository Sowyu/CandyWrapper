#!/usr/bin/env python3
"""Derive summary numbers from immutable event and process samples, without rerunning the UI."""
import argparse, json, pathlib, statistics
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);a=p.parse_args()
all_summaries=[]
for path in sorted(a.directory.glob('*/events.jsonl')):
    events=[json.loads(s) for s in path.read_text().splitlines()]
    samples=[json.loads(s) for s in path.with_name('memory.jsonl').read_text().splitlines()]
    setup=next(e for e in events if e['event']=='setup'); pid=setup['pid']
    arrivals={e['page']:e['ms'] for e in events if e['event']=='arrival'}
    def median(values): return round(statistics.median(values),3) if values else None
    first_ready={}
    for e in events:
        if e['event']=='native-layout' and e['phase']=='arrival': first_ready.setdefault(e['page'],e)
    cold=[dict(page=e['page'],ms=round(e['ms']-arrivals[e['page']],3),height=e['height']) for e in first_ready.values()]
    scrolls=[e for e in events if e['event']=='scroll']
    reloads=[]
    for e in events:
        if e['event']=='native-layout' and e['phase'] in ['back','return']:
            prev=[s for s in scrolls if s['ms']<=e['ms']]
            s=prev[-1] if prev else None
            if s: reloads.append(dict(phase=e['phase'],page=e['page'],label=s['label'],ms=round(e['ms']-s['ms'],3),height=e['height']))
    residents=[dict(phase=e['phase'],page=e['page'],label=e['label'],ms=round(e['snapshotMs'],3),success=e['success']) for e in events if e['event']=='resident-snapshot']
    viewport=[e for e in events if e['event']=='viewport']
    bad=[dict(phase=e['phase'],label=e['label'],frames=e['frames']) for e in viewport if not e['frames'] or any(not f['live'] and not f.get('preview',False) for f in e['frames'])]
    paint=[e for e in events if e['event']=='message' and e.get('message',{}).get('benchmark')=='paint-opportunity']
    content_peaks={}
    for kind in ['GPU','Networking','WebContent']:
        content_peaks[kind]=max((sum(kind in r['name'] for r in s['processes']) for s in samples),default=0)
    summary=dict(case=setup['kind'],mode=setup['mode'],appearance=path.parent.name.split('-')[-1],completed=any(e['event']=='done' for e in events),cold=cold,coldMedianMs=median([v['ms'] for v in cold]),coldWorstMs=max((v['ms'] for v in cold),default=None),coldPages=len(set(v['page'] for v in cold)),repeatedArrivalReadyEvents=sum(e['event']=='native-layout' and e['phase']=='arrival' for e in events)-len(cold),activations={phase:sum(e['event']=='activate' and e['phase']==phase for e in events) for phase in ['arrival','back','return']},reloads=reloads,residentSnapshots=residents,scrollReloadMedianMs={phase:median([v['ms'] for v in reloads if v['phase']==phase]) for phase in ['back','return']},residentSnapshotMedianMs=median([v['ms'] for v in residents]),blankOrMissingViewports=bad,viewportChecks=len(viewport),paintPages=len(set(e['page'] for e in paint)),brokenImageReports=sum(e['message'].get('broken',0) for e in paint),sampledAppPeakMB=round(max((r.get('footprint',0) for s in samples for r in s['processes'] if r['pid']==pid),default=0)/1e6,3),appLifetimePeakMB=round(max((r.get('peak_footprint',0) for s in samples for r in s['processes'] if r['pid']==pid),default=0)/1e6,3),sampledCombinedPeakMB=round(max((sum(r.get('footprint',0) for r in s['processes']) for s in samples),default=0)/1e6,3),webKitProcessPeaks=content_peaks,sampledWebKitPeakCount=max((sum('WebKit' in r['name'] for r in s['processes']) for s in samples),default=0),memoryAttribution='New WebKit PIDs since launch sharing inherited responsibility. Inferential: no unrelated WebKit app may launch during capture.',artifactDirectory=str(path.parent))
    path.with_name('derived.json').write_text(json.dumps(summary,indent=2));all_summaries.append(summary)
    print('%s %-9s %-5s arrival %s ms (%d/10), scroll reload %s/%s ms, resident %s ms, blanks %d/%d, app %.1f MB, total %.1f MB, WebKit %d'%(summary['case'],summary['mode'],summary['appearance'],summary['coldMedianMs'],summary['coldPages'],summary['scrollReloadMedianMs']['back'],summary['scrollReloadMedianMs']['return'],summary['residentSnapshotMedianMs'],len(bad),len(viewport),summary['sampledAppPeakMB'],summary['sampledCombinedPeakMB'],summary['sampledWebKitPeakCount']))
(a.directory/'derived.json').write_text(json.dumps(all_summaries,indent=2))
