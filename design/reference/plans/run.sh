#!/bin/zsh
# usage: run.sh plan.json outdir
cd /Users/mrm/CandyWrapper-research/sandbox
URL=$(env -i HOME=/Users/mrm USER=mrm LOGNAME=mrm SHELL=/bin/zsh LANG=en_US.UTF-8 TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin T3CODE_TELEMETRY_ENABLED=false T3CODE_HOME=$PWD/t3home ~/.t3/runtime/versions/0.0.46-nightly.20261009.2861/t3 pair --base-dir $PWD/t3home | grep -o 'http://127.0.0.1:47391/pair#token=[A-Za-z0-9_.-]*')
cd /Users/mrm/CandyWrapper
/tmp/cap/cap "$1" "$2" "$URL"
