#!/usr/bin/python3
"""Run the signed probes inside the GUI user's security session, with UI disabled."""
import json
from pathlib import Path
import subprocess
import sys

folder = Path(sys.argv[1]).resolve()
assert folder.is_relative_to(Path.home() / 'CandyWrapper-research/sandbox')
subprocess.run(['cp', str(folder / 'keychain-plain'), str(folder / 'keychain-outsider')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'dev.candywrapper.space-spike.outsider',
                str(folder / 'keychain-outsider')], check=True, capture_output=True)
commands = [('keychain-plain', 'dp'), ('keychain-group', 'dp'), ('keychain-access-only', 'dp'),
            ('keychain-plain', 'acl-write'), ('keychain-plain', 'acl-read'),
            ('keychain-outsider', 'acl-read'), ('keychain-same-team-other-app', 'acl-read')]
results = []


def run(binary, mode):
    process = subprocess.run(['sudo', 'launchctl', 'asuser', '502', 'sudo', '-u', 'mrm',
                              str(folder / binary), mode], capture_output=True, text=True, timeout=25)
    result = {'binary': binary, 'mode': mode, 'exit': process.returncode,
              'stdout': process.stdout.strip(), 'stderr': process.stderr.strip()}
    print(json.dumps(result), flush=True)
    results.append(result)


try:
    for binary, mode in commands:
        run(binary, mode)
finally:
    run('keychain-plain', 'acl-delete')
    (folder / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
