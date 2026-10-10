"""Run constructor-only probes in the isolated lab, never the installed system app."""
from pathlib import Path
import json
import subprocess
import sys

root = Path(__file__).resolve().parent
tests = [
    ('fixture-arm64', root / 'fixture', root / 'libFFProbe.dylib'),
    ('fixture-arm64e', root / 'fixture-arm64e', root / 'libFFProbe-arm64e.dylib'),
    ('freeform-adhoc', root / 'lab/FreeformLab.app/Contents/MacOS/Freeform', root / 'libFFProbe-arm64e.dylib'),
]
results = []
label = sys.argv[1] if len(sys.argv) > 1 else 'initial'
if not label.isalnum(): raise SystemExit('Use an alphanumeric run label')
for name, target, probe in tests:
    log = root / 'logs' / (name + '-' + label + '.jsonl')
    if log.exists():
        raise SystemExit(f'Refusing to overwrite prior probe evidence: {log}')
    command = ['/usr/bin/sandbox-exec', '-f', str(root / 'lab/probe.sb'),
               str(root / 'launch-probe'), str(target), str(probe), str(log)]
    try:
        run = subprocess.run(command, capture_output=True, text=True, timeout=8)
        result = dict(name=name, exitCode=run.returncode, stdout=run.stdout[-8000:], stderr=run.stderr[-8000:])
    except subprocess.TimeoutExpired as error:
        result = dict(name=name, timeout=True, stdout=str(error.stdout or '')[-8000:], stderr=str(error.stderr or '')[-8000:])
    result['constructorLogExists'] = log.exists()
    if log.exists():
        records = [json.loads(line) for line in log.read_text().splitlines()]
        result['eventCount'] = len(records)
        result['loaded'] = any(x.get('event') == 'loaded' for x in records)
    results.append(result)
    print(json.dumps(result), flush=True)
(root / 'logs' / ('launch-results-' + label + '.json')).write_text(json.dumps(results, indent=2) + '\n')
