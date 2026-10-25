#!/usr/bin/env python3
"""Sum readiness waits during the ten paced scroll visits; keep the raw logs unchanged."""
import argparse
import json
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=pathlib.Path)
args = parser.parse_args()
results = []
for path in sorted(args.directory.glob('*/events.jsonl')):
    events = [json.loads(line) for line in path.read_text().splitlines()]
    result = {'case': path.parent.name}
    for phase in ['back', 'return']:
        scrolls = [e for e in events if e['event'] == 'scroll' and e['phase'] == phase]
        visits = []
        for scroll in scrolls:
            view = next((e for e in events if e['event'] == 'viewport' and e.get('label') == scroll['label']), None)
            if view is None:
                continue
            ready = {}
            preview_pages = set()
            for event in events:
                if not scroll['ms'] <= event['ms'] <= view['ms']:
                    continue
                delay = None
                if event['event'] in ['native-layout', 'preview-layout']:
                    delay = event['ms'] - scroll['ms']
                    if event['event'] == 'preview-layout':
                        preview_pages.add(event['page'])
                elif event['event'] == 'resident-at-scroll' and event.get('label') == scroll['label']:
                    delay = event['ms'] - scroll['ms']
                elif event['event'] == 'resident-snapshot' and event.get('label') == scroll['label'] and event['success']:
                    delay = event['snapshotMs']
                if delay is not None:
                    ready[event['page']] = min(ready.get(event['page'], delay), delay)
            pages = [f['page'] for f in view['frames']]
            complete = bool(pages) and all(page in ready for page in pages)
            visits.append({'label': scroll['label'], 'complete': complete,
                           'waitMs': round(max(ready[page] for page in pages), 3) if complete else None,
                           'cachedPreviews': len(preview_pages), 'pages': pages})
        result[phase] = {'visits': visits, 'completeVisits': sum(v['complete'] for v in visits),
                         'totalVisits': len(visits),
                         'cumulativeReadyWaitMs': round(sum(v['waitMs'] for v in visits), 3)
                         if len(visits) == 10 and all(v['complete'] for v in visits) else None,
                         'fixedPacingMs': 20000}
    results.append(result)
destination = args.directory / 'scroll-derived.json'
destination.write_text(json.dumps(results, indent=2) + '\n')
for result in results:
    print(result['case'], *('%s %s ms (%s/10)' % (phase, result[phase]['cumulativeReadyWaitMs'], result[phase]['completeVisits']) for phase in ['back', 'return']))
