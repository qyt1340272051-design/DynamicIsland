import csv
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import statistics

parser = argparse.ArgumentParser(description='Recompute T31 evidence into a new empty directory without changing source evidence.')
parser.add_argument('--input-dir', type=pathlib.Path, default=pathlib.Path(__file__).parent)
parser.add_argument('--output-dir', type=pathlib.Path, required=True)
args = parser.parse_args()
INPUT = args.input_dir.resolve()
OUT = args.output_dir.resolve()
if OUT == INPUT or (OUT.exists() and any(OUT.iterdir())):
    raise RuntimeError('Output must be a new or empty directory, separate from the source evidence.')
OUT.mkdir(parents=True, exist_ok=True)

def save(name, value):
    path = OUT / name
    if path.exists():
        raise RuntimeError(f'Refusing overwrite: {path}')
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def local_seconds(utc):
    stamp = dt.datetime.fromisoformat(utc.replace('Z', '+00:00'))
    stamp = stamp.astimezone(dt.timezone(dt.timedelta(hours=8)))
    return stamp.hour * 3600 + stamp.minute * 60 + stamp.second

def time_text(seconds):
    return f'{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}'

raw = json.loads((INPUT / 'log-exports.json').read_text())
full = {}
for capture in raw['captures']:
    assert json.loads(capture['rawJSONText']) == capture['value']
    value = capture['value']
    for plugin in value['plugins']:
        if not plugin.get('complete'):
            continue
        assert plugin['id'] not in full
        decoded = json.loads(json.dumps(plugin))
        encoding = value.get('encoding')
        if encoding:
            assert encoding['mode'] == 'exact-phrase-replacement'
            for page in decoded['pages']:
                encoded = page['rawLogBlock']
                page['rawLogBlock'] = encoded.replace(encoding['sentinel'], encoding['phrase'])
                assert page['rawLogBlock'].replace(encoding['phrase'], encoding['sentinel']) == encoded
        decoded['captureCompletedUTC'] = capture['captureCompletedUTC']
        decoded['callID'] = capture['callID']
        full[plugin['id']] = decoded
assert set(full) == {f'com.example.t31.idle{n:02d}' for n in range(1, 21)}
save('decoded-log-pages.json', {'schemaVersion': 1, 'plugins': list(full.values())})

samples = {}
summaries = {}
for phase in ['disabled', 'running']:
    rows = [json.loads(s) for s in (INPUT / f'{phase}.jsonl').read_text().splitlines()]
    metadata = rows[0]
    assert metadata['type'] == 'metadata'
    assert metadata['observationClock'] == 'mach_continuous_time_scaled_to_nanoseconds_includes_sleep'
    records = rows[1:]
    assert all(r['type'] == 'sample' for r in records)
    summary = json.loads((INPUT / f'{phase}-summary.json').read_text())
    assert summary['evidenceStatus'] == 'valid_counter_window'
    assert len(records) == summary['sampleCount'] == 173
    assert all(r['identity'] == metadata['identity'] == summary['identity'] for r in records)
    assert [r['index'] for r in records] == list(range(len(records)))
    spans = [(b['monotonicNanoseconds'] - a['monotonicNanoseconds']) / 1e9 for a, b in zip(records, records[1:])]
    assert min(spans) > 0 and max(spans) <= 15
    duration = (records[-1]['monotonicNanoseconds'] - records[0]['monotonicNanoseconds']) / 1e9
    assert duration >= 900 and abs(duration - summary['measuredDurationSeconds']) < 1e-8
    counters = ['cpuEnergyNanojoules', 'userMachTicks', 'systemMachTicks', 'packageIdleWakeups', 'interruptWakeups', 'diskReadBytes', 'diskWrittenBytes']
    assert all(b[k] >= a[k] for a, b in zip(records, records[1:]) for k in counters)
    ratio = metadata['timebaseNumerator'] / metadata['timebaseDenominator'] / 1e9
    cpu = sum(records[-1][k] - records[0][k] for k in ['userMachTicks', 'systemMachTicks']) * ratio
    assert abs(cpu / duration * 100 - summary['meanSingleCoreCPUPercent']) < 1e-8
    energy = (records[-1]['cpuEnergyNanojoules'] - records[0]['cpuEnergyNanojoules']) / 1e9
    assert abs(energy - summary['attributedCPUEnergyJoules']) < 1e-8
    with (OUT / f'{phase}-samples.csv').open('x', newline='') as stream:
        fields = [k for k in records[0] if k != 'identity']
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows({k: row[k] for k in fields} for row in records)
    summaries[phase] = summary
    samples[phase] = {'firstUTC': records[0]['utc'], 'lastUTC': records[-1]['utc'], 'maximumSampleGapSeconds': max(spans), 'firstPhysicalFootprintBytes': records[0]['physicalFootprintBytes'], 'lastPhysicalFootprintBytes': records[-1]['physicalFootprintBytes']}
assert summaries['disabled']['identity'] == summaries['running']['identity']

start = local_seconds(samples['running']['firstUTC'])
end = local_seconds(samples['running']['lastUTC'])
assert (start, end) == (78088, 78989)
record_regex = re.compile(r'(INFO|DEBUG|WARNING|ERROR)\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)\s+插件日志 pluginMessage Plugin log message omitted\.')
coverage = []
log_rows = []
for plugin_id, plugin in sorted(full.items()):
    records = set()
    earliest = end
    for page in plugin['pages']:
        for match in record_regex.finditer(page['rawLogBlock']):
            level, hh, mm, ss, meridiem = match.groups()
            seconds = (int(hh) % 12 + (12 if meridiem == 'PM' else 0)) * 3600 + int(mm) * 60 + int(ss)
            earliest = min(earliest, seconds)
            records.add((seconds, level))
    assert earliest < start
    window = sorted((s, l) for s, l in records if start <= s <= end)
    infos = [s for s, l in window if l == 'INFO']
    assert len(infos) >= 13 and all(l == 'INFO' for s, l in window)
    gaps = [b - a for a, b in zip(infos, infos[1:])]
    assert min(gaps) >= 60 and max(gaps) <= 75
    assert infos[0] - start <= 75 and end - infos[-1] <= 75
    assert 'v1.0.1, 运行中' in plugin['rawStateRow']
    assert '主程序调度策略：background' in plugin['header']
    assert 'App 在前台：否' in plugin['header'] and '低功耗模式：关' in plugin['header']
    coverage.append({'id': plugin_id, 'windowINFOCount': len(infos), 'windowWARNINGOrERRORCount': 0, 'firstLocalTime': time_text(infos[0]), 'lastLocalTime': time_text(infos[-1]), 'minimumGapSeconds': min(gaps), 'maximumGapSeconds': max(gaps), 'firstDelaySeconds': infos[0] - start, 'lastMarginSeconds': end - infos[-1], 'decodedPages': len(plugin['pages']), 'runningAtCapture': True, 'coveragePassed': True})
    log_rows.extend({'pluginID': plugin_id, 'localTime': time_text(s), 'level': l, 'category': '插件日志', 'code': 'pluginMessage', 'message': 'Plugin log message omitted.'} for s, l in window)
with (OUT / 'window-plugin-logs.csv').open('x', newline='') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(log_rows[0]), lineterminator='\n')
    writer.writeheader()
    writer.writerows(log_rows)
save('log-coverage.json', {'schemaVersion': 1, 'timezone': 'Asia/Shanghai', 'windowStartLocal': time_text(start), 'windowEndLocal': time_text(end), 'method': 'Deduplicate actual AX rows by plugin ID, timestamp, level and fixed category/code; omit records outside the measured window. INFO meaning comes from audited fixture, not redacted message text.', 'coverageCriteria': {'minimumWindowINFOCount': 13, 'maximumGapOrBoundaryMarginSeconds': 75, 'minimumGapSeconds': 60, 'purpose': 'Experimental completeness check, not a new product acceptance threshold.'}, 'allTwentyPassed': True, 'totalWindowINFOCount': len(log_rows), 'plugins': coverage})
save('counter-review.json', {'schemaVersion': 1, 'sameIdentityBothWindows': True, 'independentlyRecomputedCPUAndEnergyMatch': True, 'windows': samples, 'cpuMeanDeltaPercentagePoints': summaries['running']['meanSingleCoreCPUPercent'] - summaries['disabled']['meanSingleCoreCPUPercent'], 'cpuMeanRelativeIncreasePercent': (summaries['running']['meanSingleCoreCPUPercent'] / summaries['disabled']['meanSingleCoreCPUPercent'] - 1) * 100, 'cpuMeanPowerDeltaMilliwatts': summaries['running']['equivalentMeanCPUPowerMilliwatts'] - summaries['disabled']['equivalentMeanCPUPowerMilliwatts'], 'cpuMeanPowerRelativeIncreasePercent': (summaries['running']['equivalentMeanCPUPowerMilliwatts'] / summaries['disabled']['equivalentMeanCPUPowerMilliwatts'] - 1) * 100})
print(json.dumps({'allTwentyPassed': True, 'INFOCount': len(log_rows), 'countRange': [min(p['windowINFOCount'] for p in coverage), max(p['windowINFOCount'] for p in coverage)], 'maxGapSeconds': max(p['maximumGapSeconds'] for p in coverage), 'windows': samples}, ensure_ascii=False, indent=2))
