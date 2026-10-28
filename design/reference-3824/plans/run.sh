#!/bin/zsh
set -eu
sandbox="$HOME/CandyWrapper-research/sandbox-3824-ref"
runtime="$HOME/CandyWrapper-research/runtimes/t3-0.1.4-nightly.20261028.3824-darwin-arm64/t3"
if [[ "${CAPTURE_NO_PAIR:-0}" == 1 ]]; then
  CAPTURE_PROFILE="${CAPTURE_PROFILE:-$sandbox/chrome-3824-error-profile}" "${CAPTURE_BIN:-$sandbox/capture-3824}" "$1" "$2"
  exit
fi
pair="$sandbox/pairing.json"
env -i HOME="$HOME" USER=mrm LOGNAME=mrm PATH=/usr/bin:/bin "$runtime" auth pairing create --base-dir "$sandbox/t3home" --base-url http://127.0.0.1:47403 --json > "$pair"
chmod 600 "$pair"
url=$(/usr/bin/python3 - "$pair" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
for k,v in p.items():
 if isinstance(v,str) and '/pair#' in v: print(v);break
else: raise SystemExit('No pairing URL: '+str(list(p)))
PY
)
CAPTURE_PROFILE="${CAPTURE_PROFILE:-$sandbox/chrome-3824-profile}" "${CAPTURE_BIN:-$sandbox/capture-3824}" "$1" "$2" "$url"
