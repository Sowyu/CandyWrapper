#!/usr/bin/env python3
"""Compare corrected batches without treating incomplete scroll passes as zero."""
import argparse
import json
import pathlib

p = argparse.ArgumentParser()
p.add_argument('before', type=pathlib.Path)
p.add_argument('after', type=pathlib.Path)
a = p.parse_args()

def read(path):
    return json.loads(path.read_text())

def identity(case):
    return '-'.join([case['case'], case['mode'], case['appearance']])

def without_urls(value):
    if isinstance(value, dict):
        return {k: without_urls(v) for k, v in value.items() if k != 'url'}
    if isinstance(value, list):
        return [without_urls(v) for v in value]
    return value

assert without_urls(read(a.before / 'manifest-used.json')) == without_urls(read(a.after / 'manifest-used.json')), 'Fixture content changed'
batches = []
for root in [a.before, a.after]:
    cases = {identity(case): case for case in read(root / 'derived.json')}
    scrolls = {case['case']: case for case in read(root / 'scroll-derived.json')}
    for name, case in cases.items():
        case['scroll'] = scrolls[name]
        case['competingBuildSamples'] = sum(bool(json.loads(line)['competingBuilds'])
                                          for line in (root / name / 'memory.jsonl').read_text().splitlines())
    batches.append(cases)
assert batches[0].keys() == batches[1].keys(), 'Case matrix changed'
results = []
for name in sorted(batches[0]):
    before, after = [batch[name] for batch in batches]
    result = {'case': name, 'before': before, 'after': after,
              'arrivalChangePercent': round((after['coldMedianMs'] / before['coldMedianMs'] - 1) * 100, 1),
              'combinedPeakChangeMB': round(after['sampledCombinedPeakMB'] - before['sampledCombinedPeakMB'], 3)}
    results.append(result)
    print(name, 'arrival', before['coldMedianMs'], '->', after['coldMedianMs'], 'ms;',
          'combined peak', before['sampledCombinedPeakMB'], '->', after['sampledCombinedPeakMB'], 'MB;',
          'WebKit', before['sampledWebKitPeakCount'], '->', after['sampledWebKitPeakCount'])
    for phase in ['back', 'return']:
        values = [case['scroll'][phase] for case in [before, after]]
        print(' ', phase, ' -> '.join('%s ms (%s/10)' % (v['cumulativeReadyWaitMs'], v['completeVisits']) for v in values))
(a.after / 'comparison.json').write_text(json.dumps(results, indent=2) + '\n')
