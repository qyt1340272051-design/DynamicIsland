#!/usr/bin/env python3
"""Check local handbook links and exact, validated example sources. No network."""
import re
import subprocess
from pathlib import Path

from di_plugin import read_json, validate_manifest, validate_node

TOPICS = (
    'quick-start', 'manifest', 'activity', 'ui-components', 'actions',
    'storage', 'network', 'permissions', 'settings', 'lifecycle', 'debugging',
    'packaging', 'publishing', 'verification', 'README',
)
SOURCES = {
    'docs/quick-start.sh', 'examples/hello-world/manifest.json',
    'examples/hello-world/index.js', 'docs/snippets/activity.js',
    'docs/snippets/settings.js', 'docs/snippets/network.js',
    'docs/snippets/open-link.js', 'docs/snippets/progress.json',
}


def check(sdk):
    sdk = Path(sdk).resolve()
    seen = set()
    links = 0
    for topic in TOPICS:
        document = sdk / 'docs' / (topic + '.md')
        lines = document.read_text(encoding='utf-8').splitlines(keepends=True)
        index = 0
        prose = []
        while index < len(lines):
            line = lines[index]
            if not line.startswith('```'):
                prose.append(line)
                index += 1
                continue
            language = line.strip()[3:]
            marker = re.fullmatch(r'<!-- sdk-source: ([^<>]+) -->\n?', lines[index - 1]) if index else None
            if not marker:
                raise ValueError(f'{document.name}:{index + 1}: example needs sdk-source')
            source = (document.parent / marker[1]).resolve()
            relative = source.relative_to(sdk).as_posix()
            if relative not in SOURCES:
                raise ValueError(f'{document.name}: unknown example {relative}')
            index += 1
            body = []
            while index < len(lines) and lines[index].strip() != '```':
                body.append(lines[index])
                index += 1
            if index == len(lines):
                raise ValueError(f'{document.name}: unclosed code block')
            if ''.join(body) != source.read_text(encoding='utf-8'):
                raise ValueError(f'{document.name}: example drift: {relative}')
            expected_language = {'.js': 'js', '.json': 'json', '.sh': 'sh'}[source.suffix]
            if language != expected_language:
                raise ValueError(f'{document.name}: wrong language for {relative}')
            if source.suffix == '.json':
                value = read_json(source)
                (validate_manifest if source.name == 'manifest.json' else validate_node)(value)
            elif source.suffix == '.js':
                subprocess.run(['node', '--check', str(source)], check=True, capture_output=True, timeout=15)
            elif source.suffix == '.sh':
                subprocess.run(['bash', '-n', str(source)], check=True, capture_output=True, timeout=15)
            seen.add(relative)
            index += 1
        # Only inline local links are used by this handbook. Code is excluded.
        for target in re.findall(r'\]\(([^)]+)\)', ''.join(prose)):
            if target.startswith(('https://', 'http://', '#')):
                continue
            path = target.split('#', 1)[0]
            if not (document.parent / path).exists():
                raise ValueError(f'{document.name}: broken link {target}')
            links += 1
    if seen != SOURCES:
        raise ValueError(f'Examples missing from handbook: {sorted(SOURCES - seen)}')
    return {'documents': len(TOPICS), 'examples': len(seen), 'localLinks': links}


if __name__ == '__main__':
    import json
    print(json.dumps(check(Path(__file__).resolve().parent.parent), sort_keys=True))
