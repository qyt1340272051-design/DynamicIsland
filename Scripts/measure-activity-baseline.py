#!/usr/bin/env python3
"""Collect a repeatable, read-only process baseline using the audited T31 observer.

The caller starts an isolated ordinary Release and records its build provenance.
This script never launches, stops, attaches to, or changes the observed app.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
OBSERVER = ROOT / 'Scripts/ActivityProcessSampler.swift'


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def process_identity(pid, executable):
    owner = int(run('/bin/ps', '-p', str(pid), '-o', 'uid='))
    if owner != os.getuid():
        raise RuntimeError('Target must be an owned live process.')
    actual = Path(run('/bin/ps', '-ww', '-p', str(pid), '-o', 'comm=')).resolve(strict=True)
    if actual != executable:
        raise RuntimeError('Observed executable differs from --expected-executable.')
    return {'pid': pid, 'uid': owner, 'executable': str(actual),
            'processStartText': run('/bin/ps', '-p', str(pid), '-o', 'lstart='),
            'executableSHA256': digest(actual)}


def write_json(path, value):
    with path.open('x', encoding='utf-8') as output:
        json.dump(value, output, indent=2, ensure_ascii=False)
        output.write('\n')
    path.chmod(0o600)


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--expected-executable', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True,
                        help='New directory; existing directories are never overwritten.')
    parser.add_argument('--phase', choices=('no-plugins', 'installed-disabled', 'installed-running'), required=True,
                        help='Actual plugin state; no-plugins is distinct from installed-disabled.')
    parser.add_argument('--seconds', type=int, default=300,
                        help='At least 300 seconds; default 5 minutes.')
    parser.add_argument('--warmup-seconds', type=int, default=300,
                        help='Idle period before counters; default 5 minutes.')
    parser.add_argument('--build-note', required=True,
                        help='Actual build/source provenance, not inferred from observation HEAD.')
    parser.add_argument('--scenario-note', required=True,
                        help='Observed display, power, music, plugin count and workload conditions.')
    args = parser.parse_args()
    if args.pid <= 1 or not 300 <= args.seconds <= 1800 or not 0 <= args.warmup_seconds <= 1800:
        parser.error('Require PID > 1, 300..1800 sample seconds and 0..1800 warmup seconds.')
    return args


def main():
    args = parse_arguments()
    executable = args.expected_executable.resolve(strict=True)
    identity = process_identity(args.pid, executable)
    output = args.output_dir.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    sampler = output / 'energy-sampler'
    # Compile before the warmup and measurement window, never during them.
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', str(OBSERVER), '-o', str(sampler)],
                   check=True, stdout=subprocess.DEVNULL)
    info_path = executable.parent.parent / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes()) if info_path.is_file() else {}
    preflight = {
        'schemaVersion': 1, 'createdUTC': utc(), 'target': identity,
        'observationHEAD': run('git', '-C', str(ROOT), 'rev-parse', 'HEAD'),
        'buildNote': args.build_note, 'scenarioNote': args.scenario_note,
        'model': run('/usr/sbin/sysctl', '-n', 'hw.model'),
        'architecture': run('/usr/bin/uname', '-m'),
        'operatingSystem': run('/usr/bin/sw_vers', '-productVersion'),
        'operatingSystemBuild': run('/usr/bin/sw_vers', '-buildVersion'),
        'bundleID': info.get('CFBundleIdentifier'),
        'appVersion': info.get('CFBundleShortVersionString'),
        'appBuild': info.get('CFBundleVersion'),
        'powerAtStart': run('/usr/bin/pmset', '-g', 'batt'),
        'powerConfiguration': run('/usr/bin/pmset', '-g', 'custom'),
        'phase': args.phase, 'warmupSeconds': args.warmup_seconds,
        'requestedSampleSeconds': args.seconds, 'intervalSeconds': 5,
        'observerSource': str(OBSERVER.relative_to(ROOT)),
        'observerSourceSHA256': digest(OBSERVER), 'observerExecutableSHA256': digest(sampler),
        'wrapperSourceSHA256': digest(Path(__file__).resolve()),
        'scope': 'Owned process CPU, physical footprint, wakeups, I/O and kernel-attributed CPU energy. '
                 'Not Activity Monitor Energy Impact or whole-device/battery/GPU/display/network power.',
        'acceptance': 'Measurement only; does not automatically accept T02 or T08.'
    }
    write_json(output / 'preflight.json', preflight)
    print(f'Prepared baseline in {output}; warmup {args.warmup_seconds}s, sample {args.seconds}s.', flush=True)
    end = time.monotonic() + args.warmup_seconds
    while time.monotonic() < end:
        time.sleep(min(5, max(0, end - time.monotonic())))
        if process_identity(args.pid, executable) != identity:
            raise RuntimeError('Target changed during warmup.')
    if process_identity(args.pid, executable) != identity:
        raise RuntimeError('Target changed before sampling.')
    write_json(output / 'window-start.json', {'utc': utc(), 'target': identity,
                                            'power': run('/usr/bin/pmset', '-g', 'batt')})
    result = subprocess.run([str(sampler), '--pid', str(args.pid), '--seconds', str(args.seconds),
                             '--interval', '5', '--label', args.phase,
                             '--output', str(output / 'samples.jsonl'),
                             '--summary', str(output / 'summary.json')], check=False)
    final_identity = process_identity(args.pid, executable)
    write_json(output / 'window-end.json', {'utc': utc(), 'target': final_identity,
                                          'identityUnchanged': final_identity == identity,
                                          'observerExitCode': result.returncode,
                                          'power': run('/usr/bin/pmset', '-g', 'batt')})
    if result.returncode != 0 or final_identity != identity:
        raise RuntimeError('Invalid measurement; retain the artifacts and retry in a new directory.')
    print('Counters saved. Review power/display/workload and the summary before accepting any task.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Baseline failed: {error}', file=sys.stderr)
        sys.exit(1)
