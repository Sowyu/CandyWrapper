#!/bin/zsh
# Captures the whole 4928 set into design/reference-4928, in the order the README describes.
# Run from the repo root after the sandbox is seeded. running.json costs two Claude Haiku 5.5 turns, so it is not run here.
set -u
here=design/reference-4928/plans; out=design/reference-4928
rpc=$HOME/CandyWrapper-research/sandbox-4928-ref/tools/rpc
repo=/Users/Shared/cw-sandbox-4928/demo-repo
ids=$here/sandbox-ids.json
md=$(/usr/bin/python3 -c "import json;print(json.load(open('$ids'))['threads']['md'])")
for plan in main narrow diff-turn extras composer new-4928; do
  echo "== $plan"; $here/run.sh $here/$plan.json $out
done
# 51: the markdown thread on main while the checkout sits on another branch, with an unsent draft.
u() { uuidgen | tr A-Z a-z; }
$rpc orchestration.dispatchCommand "{\"type\":\"thread.metadata.update\",\"commandId\":\"$(u)\",\"threadId\":\"$md\",\"branch\":\"main\"}" >/dev/null
git -C $repo checkout -q -b reference-banner 2>/dev/null || git -C $repo checkout -q reference-banner
$rpc vcs.refreshStatus "{\"cwd\":\"$repo\",\"localOnly\":true}" >/dev/null
echo "== notice"; $here/run.sh $here/notice.json $out
git -C $repo checkout -q main
$rpc vcs.refreshStatus "{\"cwd\":\"$repo\",\"localOnly\":true}" >/dev/null
$rpc orchestration.dispatchCommand "{\"type\":\"thread.metadata.update\",\"commandId\":\"$(u)\",\"threadId\":\"$md\",\"branch\":null}" >/dev/null
echo "== error"; CAPTURE_NO_PAIR=1 $here/run.sh $here/error.json $out
cp $out/05-approval-request.dark.png $out/05-approval-request-3473.dark.png
cp $out/05-approval-request.light.png $out/05-approval-request-3473.light.png
cp $out/48-diff-turn-file.dark.png $out/48-diff-turn-file-3473.dark.png
cp $out/48-diff-turn-file.light.png $out/48-diff-turn-file-3473.light.png
/usr/bin/python3 $here/manifest.py
