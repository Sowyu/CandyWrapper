#!/bin/zsh
# Runs one capture plan against the 5258 reference sandbox. Usage: run.sh <plan.json> <out-dir>
set -eu
sandbox="$HOME/CandyWrapper-research/sandbox-5258-ref"
runtime="$HOME/CandyWrapper-research/runtimes/t3-0.1.13-nightly.20261125.5258-darwin-arm64/t3"
if [[ "${CAPTURE_NO_PAIR:-0}" == 1 ]]; then
  CAPTURE_PROFILE="${CAPTURE_PROFILE:-$sandbox/chrome-5258-error-profile}" "${CAPTURE_BIN:-$sandbox/capture-4928}" "$1" "$2"
  exit
fi
pair="$sandbox/pairing.json"
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin "$runtime" auth pairing create --base-dir "$sandbox/t3home" --base-url http://127.0.0.1:47398 --json > "$pair"
chmod 600 "$pair"
url=$(/usr/bin/python3 - "$pair" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
for k,v in p.items():
 if isinstance(v,str) and '/pair#' in v: print(v);break
else: raise SystemExit('No pairing URL: '+str(list(p)))
PY
)
CAPTURE_PROFILE="${CAPTURE_PROFILE:-$sandbox/chrome-5258-profile}" "${CAPTURE_BIN:-$sandbox/capture-4928}" "$1" "$2" "$url"
