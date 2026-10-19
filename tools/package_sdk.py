#!/usr/bin/env python3
"""Build a deterministic standalone SDK snapshot; never publish or execute it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import zipfile

from di_plugin import SDK_VERSION


ROOT_FILES = ('README.md', 'VERSIONING.md', 'DISTRIBUTION.md', 'CHANGELOG.md', 'LICENSE',
              'package.json', 'package-lock.json', 'tsconfig.json')
SOURCE_TREES = ('types', 'schema', 'examples', 'docs', 'tools', 'tests')
ARCHIVE_ROOT = 'DynamicIslandSDK'


def source_files(sdk):
    sdk = Path(sdk)
    paths = [sdk / name for name in ROOT_FILES]
    def failed_scan(error):
        raise error
    for name in SOURCE_TREES:
        root = sdk / name
        if root.is_symlink() or not root.is_dir():
            raise ValueError('SDK source trees must be real directories')
        for directory, directories, names in os.walk(root, followlinks=False, onerror=failed_scan):
            directories[:] = sorted(value for value in directories
                                    if not value.startswith('.') and value not in ('__pycache__', 'node_modules'))
            for value in directories:
                if (Path(directory) / value).is_symlink():
                    raise ValueError('SDK source links are not supported')
            for value in sorted(names):
                if value.startswith('.') or value.endswith(('.pyc', '.pyo')):
                    continue
                paths.append(Path(directory) / value)
    files = {}
    for path in sorted(paths):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('SDK sources must be regular files without links')
        files[path.relative_to(sdk).as_posix()] = path.read_bytes()
    return files


def package(sdk, destination):
    sdk = Path(sdk)
    if sdk.is_symlink() or not sdk.is_dir():
        raise ValueError('SDK root must be a real directory')
    sdk = sdk.resolve()
    destination = Path(destination).absolute()
    if destination.suffix.lower() != '.zip' or destination.resolve().is_relative_to(sdk):
        raise ValueError('output must be a new .zip outside the SDK directory')
    files = source_files(sdk)
    metadata = json.loads(files['package.json'])
    version = metadata['version']
    lock = json.loads(files['package-lock.json'])
    if lock['version'] != version or lock['packages']['']['version'] != version or version != SDK_VERSION:
        raise ValueError('SDK version metadata does not match the lockfile')
    example = json.loads(files['examples/hello-world/manifest.json'])
    schema = json.loads(files['schema/plugin-manifest-v1.schema.json'])
    manifest = {
        'artifactFormatVersion': 1,
        'sdkVersion': version,
        'status': 'experimental' if '-' in version.split('+', 1)[0] else 'stable-candidate',
        'wireAPIVersion': '1.0.0',
        'manifestSchemaVersion': schema['properties']['schemaVersion']['const'],
        'minimumHostVersion': example['minimumHostVersion'],
        'files': {name: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                  for name, data in files.items()},
    }
    contents = dict(files)
    contents['distribution-manifest.json'] = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode('utf-8')
    created = False
    try:
        with destination.open('xb') as output:
            created = True
            with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=6, allowZip64=False) as archive:
                for name, data in sorted(contents.items()):
                    entry = zipfile.ZipInfo(ARCHIVE_ROOT + '/' + name, (1980, 1, 1, 0, 0, 0))
                    entry.create_system = 3
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = (stat.S_IFREG | 0o644) << 16
                    archive.writestr(entry, data)
    except Exception:
        if created:
            destination.unlink(missing_ok=True)
        raise
    return {'sdkVersion': version, 'files': len(files),
            'bytes': destination.stat().st_size,
            'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='new ZIP outside the SDK directory')
    arguments = parser.parse_args()
    try:
        result = package(Path(__file__).resolve().parent.parent, arguments.output)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, zipfile.LargeZipFile):
        parser.exit(1, 'SDK snapshot creation failed. Output must be new and outside the SDK.\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
