"""Run an actual Freeform getter on synthetic zeroed storage, before app main."""
from pathlib import Path
import json
import os
import subprocess
import sys

root = Path(__file__).resolve().parent
label = sys.argv[1] if len(sys.argv) > 1 else 'selftest1'
if not label.isalnum():
    raise SystemExit('Use an alphanumeric run label')
log = root / 'logs' / (label + '.jsonl')
result_path = root / 'logs' / (label + '-result.json')
if log.exists() or result_path.exists():
    raise SystemExit('Refusing to overwrite prior evidence')
command = ['/usr/bin/sandbox-exec', '-f', str(root / 'lab/probe.sb'),
           str(root / 'launch-probe'),
           str(root / 'lab/FreeformLab.app/Contents/MacOS/Freeform'),
           str(root / 'libFFProbe-arm64e.dylib'), str(log)]
environment = os.environ.copy()
environment['FF_PROBE_SELFTEST'] = '1'
try:
    run = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=8)
    result = dict(exitCode=run.returncode, stdout=run.stdout[-2000:], stderr=run.stderr[-2000:])
except subprocess.TimeoutExpired:
    result = dict(timeout=True)
result['events'] = []
if log.exists():
    result['events'] = [record for record in map(json.loads, log.read_text().splitlines())
                        if record.get('event') not in ('class', 'method')]
result_path.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
