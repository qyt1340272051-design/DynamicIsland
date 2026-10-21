"""Verify the actual portable SDK artifact, not an invented directory subset."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SDK = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SDK / 'tools'))
import package_sdk


class DistributionTests(unittest.TestCase):
    def test_unreadable_source_subdirectory_cannot_produce_an_incomplete_archive(self):
        with tempfile.TemporaryDirectory(prefix='sdk-distribution-') as directory:
            destination = Path(directory) / 'incomplete.zip'
            blocked = SDK.resolve() / 'tests/fixtures'
            self.assertTrue(blocked.is_dir())
            original_scandir = os.scandir

            def scandir(path):
                if Path(path) == blocked:
                    raise PermissionError('Fixture directory cannot be scanned')
                return original_scandir(path)

            with mock.patch.object(package_sdk.os, 'scandir', side_effect=scandir):
                with self.assertRaises(PermissionError):
                    package_sdk.package(SDK, destination)
            self.assertFalse(destination.exists(), 'An unreadable subtree must not become a successful partial SDK.')

    def test_archive_is_repeatable_complete_and_runs_without_repository(self):
        with tempfile.TemporaryDirectory(prefix='sdk-distribution-') as directory:
            root = Path(directory)
            first, second = root / 'first.zip', root / 'second.zip'
            summary = package_sdk.package(SDK, first)
            package_sdk.package(SDK, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(summary['sha256'], hashlib.sha256(first.read_bytes()).hexdigest())
            with zipfile.ZipFile(first) as archive:
                archive.extractall(root / 'unpacked')
                names = archive.namelist()
                self.assertFalse(any('__pycache__' in name or 'node_modules' in name or '/.' in name for name in names))
            sdk = root / 'unpacked' / 'DynamicIslandSDK'
            manifest = json.loads((sdk / 'distribution-manifest.json').read_text())
            self.assertEqual(manifest['sdkVersion'], json.loads((SDK / 'package.json').read_text())['version'])
            self.assertEqual(manifest['status'], 'stable')
            self.assertEqual(manifest['wireAPIVersion'], '1.0.0')
            self.assertEqual(manifest['manifestSchemaVersion'], 1)
            self.assertEqual(manifest['minimumHostVersion'], '0.6.0')
            self.assertEqual(len(manifest['files']), summary['files'])
            for name, expected in manifest['files'].items():
                data = (sdk / name).read_bytes()
                self.assertEqual(len(data), expected['bytes'])
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected['sha256'])
            self.assertEqual((sdk / 'LICENSE').read_bytes(), (SDK / 'LICENSE').read_bytes())
            # Every Markdown entry point must remain navigable after extraction.
            for page in sdk.rglob('*.md'):
                body = re.sub(r'```[^\n]*\n.*?```', '', page.read_text(encoding='utf-8'), flags=re.S)
                for target in re.findall(r'\]\(([^)]+)\)', body):
                    if not target.startswith(('https://', 'http://', '#')):
                        self.assertTrue((page.parent / target.split('#', 1)[0]).exists(), (page.name, target))
            environment = dict(os.environ, TMPDIR=directory, HISTFILE=os.devnull)
            shell = ['zsh', '-f', '-i'] if shutil.which('zsh') else ['bash', '--noprofile', '--norc', '-i']
            command = (sdk / 'docs/quick-start-command.sh').read_text()
            result = subprocess.run(shell, input=command + '\nexit\n', cwd=sdk, env=environment,
                                    check=True, capture_output=True, text=True, timeout=30)
            packages = [Path(line.removeprefix('Plugin package: ')) for line in result.stdout.splitlines()
                        if line.startswith('Plugin package: ')]
            self.assertEqual(len(packages), 1)
            self.assertEqual(packages[0].read_bytes(), (sdk / 'tests/fixtures/hello-world.dip').read_bytes())
            result = subprocess.run([sys.executable, 'tools/di_plugin.py', 'validate-node',
                                     'tests/fixtures/valid-node.json'], cwd=sdk, check=True,
                                    capture_output=True, text=True, timeout=15)
            self.assertTrue(json.loads(result.stdout)['ok'])

    def test_existing_output_is_preserved_and_source_caches_are_omitted(self):
        with tempfile.TemporaryDirectory(prefix='sdk-distribution-') as directory:
            root = Path(directory)
            sdk = root / 'SDK'
            shutil.copytree(SDK, sdk, ignore=shutil.ignore_patterns('node_modules', '__pycache__'))
            (sdk / 'tools/__pycache__').mkdir()
            (sdk / 'tools/__pycache__/cache.pyc').write_bytes(b'not part of the SDK')
            (sdk / 'tools/.private').write_bytes(b'not part of the SDK')
            (sdk / 'node_modules').mkdir()
            (sdk / 'node_modules/compiler.js').write_bytes(b'not part of the SDK')
            destination = root / 'snapshot.zip'
            package_sdk.package(sdk, destination)
            original = destination.read_bytes()
            with self.assertRaises(FileExistsError):
                package_sdk.package(sdk, destination)
            self.assertEqual(destination.read_bytes(), original)
            with self.assertRaises(ValueError):
                package_sdk.package(sdk, sdk / 'snapshot.zip')
            (sdk / 'tools/alias.py').symlink_to(sdk / 'tools/di_plugin.py')
            with self.assertRaises(ValueError):
                package_sdk.package(sdk, root / 'linked.zip')
            (sdk / 'tools/alias.py').unlink()
            metadata = json.loads((sdk / 'package.json').read_text())
            metadata['version'] = '2.0.0'
            (sdk / 'package.json').write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError, 'version metadata'):
                package_sdk.package(sdk, root / 'inconsistent-version.zip')


if __name__ == '__main__':
    unittest.main()
