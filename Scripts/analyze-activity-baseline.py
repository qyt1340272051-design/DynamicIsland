#!/usr/bin/env python3
"""Independently verify process counters; never infer product acceptance."""

import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


COUNTERS = ('userMachTicks', 'systemMachTicks', 'cpuEnergyNanojoules',
            'performanceCPUEnergyNanojoules', 'packageIdleWakeups',
            'interruptWakeups', 'diskReadBytes', 'diskWrittenBytes')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(raw_path, summary_path):
    rows = [json.loads(line) for line in raw_path.read_text(encoding='utf-8').splitlines()]
    metadata, samples = rows[0], rows[1:]
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    require(metadata['type'] == 'metadata' and len(samples) >= 2, 'Missing metadata or samples.')
    require(metadata['observationClock'] == 'mach_continuous_time_scaled_to_nanoseconds_includes_sleep',
            'Unexpected observation clock.')
    require(metadata['cpuUnit'] == 'mach_timebase_ticks', 'Unexpected CPU units.')
    require(metadata['energyUnit'] == 'CPU_nanojoules_attributed_by_kernel_not_whole_device',
            'Unexpected energy units.')
    require(metadata['intervalSeconds'] == 5, 'Unexpected sample interval.')
    require(summary['evidenceStatus'] == 'valid_counter_window', 'Invalid source summary.')
    require(metadata['schemaVersion'] == summary['schemaVersion'] == 1, 'Unsupported schema.')
    require(metadata['label'] in ('no-plugins', 'installed-disabled', 'installed-running'), 'Unknown phase.')
    require(summary['label'] == metadata['label'], 'Phase differs from summary.')
    requested = metadata['requestedDurationSeconds']
    require(type(requested) in (int, float) and math.isfinite(requested) and 300 <= requested <= 1800,
            'Unsupported measurement duration.')
    require(all(type(metadata[field]) is int and metadata[field] > 0
                for field in ('timebaseNumerator', 'timebaseDenominator')), 'Invalid Mach timebase.')
    require(summary['sampleCount'] == len(samples), 'Sample count differs from summary.')
    require(all(item['type'] == 'sample' and item['schemaVersion'] == 1 for item in samples),
            'Unexpected sample type or version.')
    require([item['index'] for item in samples] == list(range(len(samples))), 'Invalid sample sequence.')
    require(all(item['identity'] == metadata['identity'] == summary['identity'] for item in samples),
            'Process identity changed.')
    gaps = [(after['monotonicNanoseconds'] - before['monotonicNanoseconds']) / 1e9
            for before, after in zip(samples, samples[1:])]
    require(all(0 < gap <= 15 for gap in gaps), 'Nonmonotonic clock or excessive sample gap.')
    require(all(after[field] >= before[field]
                for before, after in zip(samples, samples[1:]) for field in COUNTERS), 'Counter rollback.')
    elapsed = (samples[-1]['monotonicNanoseconds'] - samples[0]['monotonicNanoseconds']) / 1e9
    require(elapsed >= requested == summary['requestedDurationSeconds'], 'Insufficient measurement window.')
    scale = metadata['timebaseNumerator'] / metadata['timebaseDenominator'] / 1e9

    def delta(field):
        return samples[-1][field] - samples[0][field]

    cpu = (delta('userMachTicks') + delta('systemMachTicks')) * scale
    energy = delta('cpuEnergyNanojoules') / 1e9
    interval_rates = sorted((after['userMachTicks'] - before['userMachTicks']
                             + after['systemMachTicks'] - before['systemMachTicks']) * scale / gap * 100
                            for before, after, gap in zip(samples, samples[1:], gaps))
    expected = {
        'measuredDurationSeconds': elapsed, 'cpuSeconds': cpu,
        'meanSingleCoreCPUPercent': cpu / elapsed * 100,
        'maximumIntervalSingleCoreCPUPercent': interval_rates[-1],
        'p95IntervalSingleCoreCPUPercent': interval_rates[max(0, math.ceil(len(interval_rates) * .95) - 1)],
        'attributedCPUEnergyJoules': energy,
        'equivalentMeanCPUPowerMilliwatts': energy / elapsed * 1000,
        'packageIdleWakeups': delta('packageIdleWakeups'),
        'packageIdleWakeupsPerMinute': delta('packageIdleWakeups') / elapsed * 60,
        'interruptWakeups': delta('interruptWakeups'),
        'interruptWakeupsPerMinute': delta('interruptWakeups') / elapsed * 60,
        'diskReadBytes': delta('diskReadBytes'), 'diskWrittenBytes': delta('diskWrittenBytes'),
        'peakPhysicalFootprintBytes': max(item['physicalFootprintBytes'] for item in samples)
    }
    require(all(math.isclose(summary[key], value, rel_tol=1e-10, abs_tol=1e-8)
                for key, value in expected.items()), 'Summary differs from raw counters.')
    require(summary['cpuEnergyCounterAdvanced'] == (energy > 0), 'Energy counter status differs.')
    return {
        'schemaVersion': 1, 'state': 'independently_verified_counter_window',
        'rawSHA256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
        'summarySHA256': hashlib.sha256(summary_path.read_bytes()).hexdigest(),
        'identity': metadata['identity'], 'sampleCount': len(samples),
        'firstUTC': samples[0]['utc'], 'lastUTC': samples[-1]['utc'],
        'maximumSampleGapSeconds': max(gaps), 'recomputedMetrics': expected,
        'firstPhysicalFootprintBytes': samples[0]['physicalFootprintBytes'],
        'lastPhysicalFootprintBytes': samples[-1]['physicalFootprintBytes'],
        'medianPhysicalFootprintBytes': statistics.median(item['physicalFootprintBytes'] for item in samples),
        'cpuEnergyCounterAdvanced': energy > 0,
        'limits': ['Identity and monotonic counters verified; display/power/workload conditions need separate evidence.',
                   'CPU energy attribution is not Energy Impact or whole-device/battery/GPU/display/network energy.',
                   'No historical performance equivalence, animation smoothness or product acceptance is inferred.']
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New file; refuses overwrite.')
    args = parser.parse_args()
    result = verify(args.raw, args.summary)
    with args.output.open('x', encoding='utf-8') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
    print(json.dumps({'state': result['state'], 'sampleCount': result['sampleCount'],
                      'measuredDurationSeconds': result['recomputedMetrics']['measuredDurationSeconds'],
                      'cpuEnergyCounterAdvanced': result['cpuEnergyCounterAdvanced']}))


if __name__ == '__main__':
    main()
