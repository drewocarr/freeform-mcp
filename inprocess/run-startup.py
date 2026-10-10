"""Bounded normal-startup experiment for the disposable re-signed copy only."""
from pathlib import Path
import json
import fcntl
import os
import subprocess
import sys

root = Path(__file__).resolve().parent
label = sys.argv[1] if len(sys.argv) > 1 else 'startup1'
if not label.isalnum(): raise SystemExit('Use an alphanumeric run label')
duration = int(os.environ.get("FF_STARTUP_SECONDS", "15"))
if not 0 <= duration <= 3600: raise SystemExit("Duration must be 0 (until quit) or 1 to 3600 seconds")
lock_file = (root / "lab/launcher.lock").open("a")
try: fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: raise SystemExit("Another lab launcher is already running")
manifest_path = root / "lab/data/transport/session.json"
if manifest_path.exists():
    prior = json.loads(manifest_path.read_text())
    try: os.kill(prior["pid"], 0)
    except ProcessLookupError: pass
    else: raise SystemExit("A previous lab session is still running; quit it before relaunching")
log = root / 'logs' / (label + '.jsonl')
if log.exists(): raise SystemExit('Refusing to overwrite prior evidence')
command = ['/usr/bin/sandbox-exec', '-f', str(root / 'lab/probe.sb'), str(root / 'launch-probe'),
           str(root / 'lab/FreeformLab.app/Contents/MacOS/Freeform'),
           str(root / 'libFFProbe-arm64e.dylib'), str(log), 'startup']
with (root / 'logs' / (label + '.stdout')).open('w') as output, (root / 'logs' / (label + '.stderr')).open('w') as error:
    environment = os.environ.copy()
    if environment.get("FF_OFFLINE_MODE") == "stub":
        scratch = root / "lab/data/home"
        scratch.mkdir(parents=True, exist_ok=True)
        environment["CFFIXED_USER_HOME"] = str(scratch)
    process = subprocess.Popen(command, stdout=output, stderr=error, env=environment)
    try:
        code = process.wait(timeout=duration or None)
        result = dict(exitCode=code, reachedTimeLimit=False)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as stop:
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        result = dict(exitCode=process.returncode, reachedTimeLimit=isinstance(stop, subprocess.TimeoutExpired))
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("pid") == process.pid:
            manifest_path.unlink()
result['events'] = []
if log.exists():
    result['events'] = [x for x in map(json.loads,log.read_text().splitlines()) if x.get('event') not in ('class','method','offline_method')]
(root / 'logs' / (label + '-result.json')).write_text(json.dumps(result,indent=2)+'\n')
summary = {key: value for key, value in result.items() if key != 'events'}
summary['eventCount'] = len(result['events'])
summary['evidence'] = str(root / 'logs' / (label + '-result.json'))
print(json.dumps(summary,indent=2))
