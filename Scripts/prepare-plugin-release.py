#!/usr/bin/env python3
"""Prepare official plugin archives and a candidate catalog without publishing."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'SDK/tools'))
from di_plugin import read_json, validate_manifest  # noqa: E402
from package_plugin import package  # noqa: E402

REPOSITORY = 'https://github.com/qyt1340272051-design/DynamicIsland'
OFFICIAL = ('pomodoro', 'github')


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def prepare(output, tag):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', tag):
        raise ValueError('Use a fixed portable release tag.')
    output = output.absolute()
    output.mkdir(parents=False, exist_ok=False)
    entries, sources = [], {}
    # Staging contains only our explicitly selected source files and license.
    # No installation state, credentials, arbitrary workspace files or app.
    with tempfile.TemporaryDirectory(prefix='dynamic-island-official-release-') as temporary:
        for name in OFFICIAL:
            source = ROOT / 'docs/plugin-system/examples' / name
            stage = Path(temporary) / name
            stage.mkdir()
            source_hashes = {}
            for filename in ('manifest.json', 'index.js', 'README.md'):
                path = source / filename
                if path.is_symlink() or not path.is_file():
                    raise ValueError('Official sources must be regular files.')
                data = path.read_bytes()
                (stage / filename).write_bytes(data)
                source_hashes[filename] = hashlib.sha256(data).hexdigest()
            license_data = (ROOT / 'LICENSE').read_bytes()
            (stage / 'LICENSE').write_bytes(license_data)
            source_hashes['LICENSE'] = hashlib.sha256(license_data).hexdigest()
            # Catalog metadata must describe the same captured bytes that
            # enter the archive, even if author sources change while staging.
            manifest = read_json(stage / 'manifest.json')
            validate_manifest(manifest)
            filename = name + '-' + manifest['version'] + '.dip'
            destination = output / filename
            package(stage, destination)
            entry = {
                'id': manifest['id'], 'name': manifest['name'], 'version': manifest['version'],
                'download': REPOSITORY + '/releases/download/' + tag + '/' + filename,
                'source': REPOSITORY, 'minHostVersion': manifest['minimumHostVersion'],
                'hash': hashlib.sha256(destination.read_bytes()).hexdigest(),
            }
            entries.append(entry)
            sources[filename] = {'source': source.relative_to(ROOT).as_posix(),
                                 'filesSHA256': source_hashes,
                                 'archiveBytes': destination.stat().st_size}
    write_json(output / 'registry.candidate.json', {'schemaVersion': 1, 'plugins': entries})
    write_json(output / 'release-manifest.json', {
        'status': 'local candidate; assets and catalog have not been published',
        'repository': REPOSITORY, 'tag': tag, 'sources': sources,
        'permissionRule': 'Install disabled. Enabling grants no permissions. Review each declared permission.',
    })
    checksums = ''.join(entry['hash'] + '  ' + Path(entry['download']).name + '\n' for entry in entries)
    (output / 'SHA256SUMS').write_text(checksums, encoding='ascii')
    return {'output': str(output), 'tag': tag, 'archives': len(entries), 'published': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True, help='Fixed candidate Release tag; no tag is created.')
    parser.add_argument('--output', required=True, type=Path, help='New output directory; never overwritten.')
    arguments = parser.parse_args()
    try:
        result = prepare(arguments.output, arguments.tag)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Release preparation failed: {error}\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
