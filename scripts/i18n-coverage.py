#!/usr/bin/env python3
# Counts CandyWrapper string literals that already have a key in T3's translation catalogs.
# Usage: scripts/i18n-coverage.py Packages/CandyKit/Sources/Features Packages/CandyKit/Sources/DesignSystem App/Sources ...
import json, re, os, sys, collections
en=json.load(open(os.path.expanduser('~/CandyWrapper-research/t3code/apps/web/src/i18n/translations/en.json')))
strs={}
for k,v in en.items():
    if isinstance(v,str): strs.setdefault(v,[]).append(k)
    else:
        txt="".join(x if isinstance(x,str) else "{}" for x in v)
        strs.setdefault(txt,[]).append(k)
def shape(s):
    s=re.sub(r"\{[^{}]*(\{[^{}]*\}[^{}]*)*\}","{}",s)  # ICU args incl. plural blocks -> {}
    return s.strip()
enshape=collections.defaultdict(list)
for s,ks in strs.items(): enshape[shape(s)].extend(ks)
lit=re.compile(r'"((?:[^"\\\n]|\\.)*)"')
roots=sys.argv[1:]
found=set(); total=set(); per=collections.Counter(); matchedper=collections.Counter()
for root in roots:
    for dp,dn,fn in os.walk(root):
        for f in fn:
            if not f.endswith('.swift') or 'generated' in f.lower(): continue
            p=os.path.join(dp,f)
            for line in open(p,encoding='utf-8',errors='ignore'):
                t=line.strip()
                if t.startswith('//') or t.startswith('///'): continue
                for m in lit.finditer(line):
                    s=m.group(1)
                    if len(s)<2 or not re.search(r'[A-Za-z]{2}',s): continue
                    if not re.match(r'^[A-Z]',s) and ' ' not in s: continue   # identifiers, keys
                    if re.match(r'^[a-z]+[A-Z.:/]',s) or '://' in s or s.startswith('/'): continue
                    sh=re.sub(r'\\\((?:[^()]|\([^()]*\))*\)','{}',s).replace('\\"','"').strip()
                    total.add(sh)
                    area=p.split('Sources/')[-1].split('/')[0] if 'Sources/' in p else '?'
                    if 'Features/' in p: area='Features/'+p.split('Features/')[1].split('/')[0]
                    per[area]+=1
                    if sh in strs or sh in enshape:
                        found.add(sh); matchedper[area]+=1
print("candidate UI strings", len(total), "with a T3 key", len(found))
for a,c in per.most_common(30): print(f"  {a:28} {c:5} matched {matchedper[a]}")


